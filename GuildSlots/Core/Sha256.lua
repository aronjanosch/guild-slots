-- Pure Lua SHA-256 and HMAC-SHA256 for Lua 5.1 plus a LuaBitOp-style `bit` library.
-- `bit` returns signed values under LuaJIT and unsigned ones in the WoW Forever client, so no
-- bit result is trusted to have a particular sign: values are summed and reduced with % 2^32.
-- Only band, bxor and rshift are used (no ror/rol/tobit/tohex/bswap); rotations are built from
-- rshift plus plain arithmetic: rotr(x, n) = rshift(x, n) + (x % 2^n) * 2^(32-n), so every operand handed to `bit` is already in [0, 2^32).
-- Hex output avoids string.format("%x") on values >= 2^31, which overflows where C long is 32 bit.
local _, ns = ...
ns = ns or {}

local band, bxor, rshift = bit.band, bit.bxor, bit.rshift
local floor, byte, char, rep, sub, format = math.floor, string.byte, string.char, string.rep, string.sub, string.format
local concat = table.concat
local M = 4294967296

local K = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local INIT = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }

local w = {}

-- Compress one 64-byte block of `s` starting at byte offset `off` (0-based) into H (8 words).
local function block(H, s, off)
	for j = 1, 16 do
		local a, b, c, d = byte(s, off + j * 4 - 3, off + j * 4)
		w[j] = ((a * 256 + b) * 256 + c) * 256 + d
	end
	for j = 17, 64 do
		local x, y = w[j - 15], w[j - 2]
		-- s0 = rotr7 ^ rotr18 ^ shr3, s1 = rotr17 ^ rotr19 ^ shr10
		local s0 = bxor(
			rshift(x, 7) + (x % 128) * 33554432,
			rshift(x, 18) + (x % 262144) * 16384,
			rshift(x, 3))
		local s1 = bxor(
			rshift(y, 17) + (y % 131072) * 32768,
			rshift(y, 19) + (y % 524288) * 8192,
			rshift(y, 10))
		w[j] = (w[j - 16] + s0 + w[j - 7] + s1) % M
	end
	local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
	for j = 1, 64 do
		-- S1 = rotr6 ^ rotr11 ^ rotr25, ch = g ^ (e & (f ^ g))
		local S1 = bxor(
			rshift(e, 6) + (e % 64) * 67108864,
			rshift(e, 11) + (e % 2048) * 2097152,
			rshift(e, 25) + (e % 33554432) * 128)
		local t1 = h + S1 + bxor(g, band(e, bxor(f, g))) + K[j] + w[j]
		-- S0 = rotr2 ^ rotr13 ^ rotr22, maj = (a & b) ^ (c & (a ^ b))
		local ab = bxor(a, b)
		local S0 = bxor(
			rshift(a, 2) + (a % 4) * 1073741824,
			rshift(a, 13) + (a % 8192) * 524288,
			rshift(a, 22) + (a % 4194304) * 1024)
		h, g, f, e = g, f, e, (d + t1) % M
		d, c, b, a = c, b, a, (t1 + S0 + bxor(band(a, b), band(c, ab))) % M
	end
	H[1], H[2], H[3], H[4] = (H[1] + a) % M, (H[2] + b) % M, (H[3] + c) % M, (H[4] + d) % M
	H[5], H[6], H[7], H[8] = (H[5] + e) % M, (H[6] + f) % M, (H[7] + g) % M, (H[8] + h) % M
end

local function lengthBytes(bits)
	local t = {}
	for i = 8, 1, -1 do
		t[i] = bits % 256
		bits = floor(bits / 256)
	end
	return char(unpack(t))
end

-- Hash `msg` continuing from chaining state H0 after `prefix` bytes (a multiple of 64) were
-- already absorbed. Returns the 32-byte digest. H0 is not modified.
local function digest(H0, prefix, msg)
	local H = { H0[1], H0[2], H0[3], H0[4], H0[5], H0[6], H0[7], H0[8] }
	local len = #msg
	local full = floor(len / 64)
	for i = 0, full - 1 do block(H, msg, i * 64) end
	local tail = sub(msg, full * 64 + 1) .. "\128"
	tail = tail .. rep("\0", (55 - len) % 64) .. lengthBytes((len + prefix) * 8)
	for off = 0, #tail - 64, 64 do block(H, tail, off) end
	local out = {}
	for i = 1, 8 do
		local x = H[i]
		local d = x % 256
		x = floor(x / 256)
		local c = x % 256
		x = floor(x / 256)
		local b = x % 256
		out[i] = char(floor(x / 256), b, c, d)
	end
	return concat(out)
end

local HEX, UNHEX = {}, {}
for i = 0, 255 do
	local pair = format("%02x", i)
	HEX[char(i)] = pair
	UNHEX[pair] = char(i)
end

local Sha256 = {}

function Sha256.toHex(bytes)
	return (bytes:gsub(".", HEX))
end

function Sha256.fromHex(hex)
	if type(hex) ~= "string" or #hex % 2 ~= 0 or hex:find("[^0-9a-f]") then return nil end
	return (hex:gsub("..", UNHEX))
end

function Sha256.raw(msg)
	return digest(INIT, 0, msg)
end

function Sha256.hex(msg)
	return Sha256.toHex(digest(INIT, 0, msg))
end

-- Chaining states after absorbing the ipad and opad key blocks.
local function keyStates(key)
	if #key > 64 then key = digest(INIT, 0, key) end
	key = key .. rep("\0", 64 - #key)
	local ipad, opad = {}, {}
	for i = 1, 64 do
		local k = byte(key, i)
		ipad[i] = char(bxor(k, 0x36))
		opad[i] = char(bxor(k, 0x5c))
	end
	local Hi = { INIT[1], INIT[2], INIT[3], INIT[4], INIT[5], INIT[6], INIT[7], INIT[8] }
	local Ho = { INIT[1], INIT[2], INIT[3], INIT[4], INIT[5], INIT[6], INIT[7], INIT[8] }
	block(Hi, concat(ipad), 0)
	block(Ho, concat(opad), 0)
	return Hi, Ho
end

function Sha256.keyed(key)
	local Hi, Ho = keyStates(key)
	return function(msg, raw)
		local out = digest(Ho, 64, digest(Hi, 64, msg))
		if raw then return out end
		return Sha256.toHex(out)
	end
end

function Sha256.hmacRaw(key, msg)
	return Sha256.keyed(key)(msg, true)
end

function Sha256.hmac(key, msg)
	return Sha256.keyed(key)(msg)
end

ns.Sha256 = Sha256
return Sha256
