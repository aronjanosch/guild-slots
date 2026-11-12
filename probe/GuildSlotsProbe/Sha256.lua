-- Pure Lua SHA-256 for Lua 5.1 + LuaBitOp-style `bit`.
-- Every bit result is normalised with % 2^32, so it works whether `bit` returns signed values
-- (LuaJIT, classic WoW) or unsigned ones (WoW Forever).
-- Hex output avoids string.format("%x") on values >= 2^31, which overflows where C long is 32 bit.
local _, ns = ...
ns = ns or {}

local band, bxor, bnot, rshift, lshift = bit.band, bit.bxor, bit.bnot, bit.rshift, bit.lshift
local floor, byte, char, rep, format = math.floor, string.byte, string.char, string.rep, string.format
local M = 4294967296

local function u(x) return x % M end
local function rotr(x, n) return u(rshift(x, n) + u(lshift(x, 32 - n))) end

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

local w = {}

local function block(H, s, off)
	for j = 1, 16 do
		local a, b, c, d = byte(s, off + j * 4 - 3, off + j * 4)
		w[j] = ((a * 256 + b) * 256 + c) * 256 + d
	end
	for j = 17, 64 do
		local x, y = w[j - 15], w[j - 2]
		local s0 = u(bxor(rotr(x, 7), rotr(x, 18), rshift(x, 3)))
		local s1 = u(bxor(rotr(y, 17), rotr(y, 19), rshift(y, 10)))
		w[j] = u(w[j - 16] + s0 + w[j - 7] + s1)
	end
	local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
	for j = 1, 64 do
		local S1 = u(bxor(rotr(e, 6), rotr(e, 11), rotr(e, 25)))
		local ch = u(bxor(band(e, f), band(u(bnot(e)), g)))
		local t1 = h + S1 + ch + K[j] + w[j]
		local S0 = u(bxor(rotr(a, 2), rotr(a, 13), rotr(a, 22)))
		local maj = u(bxor(band(a, b), band(a, c), band(b, c)))
		h, g, f, e = g, f, e, u(d + t1)
		d, c, b, a = c, b, a, u(t1 + S0 + maj)
	end
	H[1], H[2], H[3], H[4] = u(H[1] + a), u(H[2] + b), u(H[3] + c), u(H[4] + d)
	H[5], H[6], H[7], H[8] = u(H[5] + e), u(H[6] + f), u(H[7] + g), u(H[8] + h)
end

local function lengthBytes(bits)
	local t = {}
	for i = 8, 1, -1 do
		t[i] = bits % 256
		bits = floor(bits / 256)
	end
	return char(unpack(t))
end

local function hex32(x)
	return format("%04x%04x", floor(x / 65536), x % 65536)
end

function ns.sha256(msg)
	local len = #msg
	msg = msg .. "\128" .. rep("\0", (55 - len) % 64) .. lengthBytes(len * 8)
	local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
	for off = 0, #msg - 64, 64 do block(H, msg, off) end
	local out = {}
	for i = 1, 8 do out[i] = hex32(H[i]) end
	return table.concat(out)
end

return ns
