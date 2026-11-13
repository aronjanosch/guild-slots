local _, ns = ...

-- Provably fair randomness: purchase keys, witness values, the level-1 lottery, contributions,
-- spin stops and gamble outcomes (docs/core-spec.md section 5). Pure Lua 5.1; no `bit` is used,
-- so uint32 values are plain numbers in [0, 2^32) under every `bit` flavour.

local Sha256 = ns.Sha256

local Engine = {}
ns.Engine = Engine

local byte, sub, find, concat, sort, floor = string.byte, string.sub, string.find, table.concat, table.sort, math.floor

local MAX_CONTRIBS = 8
local TWO32 = 4294967296

-- A name is 1..48 bytes without | , : ; and without bytes below 32 (spec section 1).
local function validName(name)
	return type(name) == "string" and #name >= 1 and #name <= 48 and not find(name, "[%z\1-\31|,:;]")
end
Engine.validName = validName

local function validValue(v)
	return type(v) == "string" and #v == 16 and not find(v, "[^0-9a-f]")
end

-- Integer to decimal text without exponent, for values up to 2^53.
local function dec(n)
	if n < 1e9 then
		return string.format("%d", n)
	end
	local digits = {}
	while n > 0 do
		local d = n % 10
		digits[#digits + 1] = string.char(48 + d)
		n = (n - d) / 10
	end
	return string.reverse(concat(digits))
end
Engine.dec = dec

local function hmacRaw(key, msg)
	if type(key) == "function" then
		return key(msg, true)
	end
	return Sha256.hmacRaw(key, msg)
end

local function uint32be(s, i)
	local a, b, c, d = byte(s, i, i + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

function Engine.commit(seed)
	return Sha256.hex(seed)
end

function Engine.purchaseKey(buyId, seed, nonce)
	return Sha256.hex("GS1|K|" .. buyId .. "|" .. seed .. "|" .. nonce)
end

function Engine.witnessValue(S, player, kind, n, g, amount, head)
	local msg = player .. "|" .. kind .. "|" .. dec(n) .. "|" .. dec(g) .. "|" .. dec(amount) .. "|" .. head
	return sub(Sha256.hmac(S, msg), 1, 16)
end

function Engine.lot(witness, player, kind, n, g)
	local h = Sha256.hex(witness .. "|" .. player .. "|" .. kind .. "|" .. dec(n) .. "|" .. dec(g))
	return tonumber(sub(h, 1, 8), 16)
end

function Engine.drawn(lot, A, Z)
	if A <= Z then
		return true
	end
	return lot < floor(Z * TWO32 / A)
end

-- list = { {name=, value=, lot=}, ... }. Keeps the 8 lowest lots (ties: smaller name), one per
-- name (the lowest lot wins), then writes them sorted by name.
function Engine.contribs(list)
	local best = {}
	for _, c in ipairs(list) do
		local prev = best[c.name]
		if not prev or c.lot < prev.lot then
			best[c.name] = c
		end
	end
	local items = {}
	for _, c in pairs(best) do
		items[#items + 1] = c
	end
	sort(items, function(a, b)
		if a.lot ~= b.lot then return a.lot < b.lot end
		return a.name < b.name
	end)
	for i = #items, MAX_CONTRIBS + 1, -1 do
		items[i] = nil
	end
	sort(items, function(a, b) return a.name < b.name end)
	local parts = {}
	for i, c in ipairs(items) do
		parts[i] = c.name .. ":" .. c.value
	end
	return concat(parts, ",")
end

-- Returns { {name=, value=}, ... } or nil, "bad_contribs". Does not limit the count; the
-- ledger checks it against the level.
function Engine.parseContribs(text)
	if type(text) ~= "string" then
		return nil, "bad_contribs"
	end
	local out = {}
	if text == "" then
		return out
	end
	local pos, prev = 1, nil
	while true do
		local comma = find(text, ",", pos, true)
		local item = sub(text, pos, comma and comma - 1 or #text)
		local colon = find(item, ":", 1, true)
		if not colon then
			return nil, "bad_contribs"
		end
		local name, value = sub(item, 1, colon - 1), sub(item, colon + 1)
		if not validName(name) or not validValue(value) then
			return nil, "bad_contribs"
		end
		if prev and not (prev < name) then
			return nil, "bad_contribs"
		end
		prev = name
		out[#out + 1] = { name = name, value = value }
		if not comma then
			break
		end
		pos = comma + 1
	end
	return out
end

function Engine.spin(K, n, contribs, tbl)
	local R = hmacRaw(K, "spin|" .. dec(n) .. "|" .. contribs)
	local r = tbl.reels
	return uint32be(R, 1) % #r[1], uint32be(R, 5) % #r[2], uint32be(R, 9) % #r[3]
end

-- One round of a lines table (docs/table-t2-spec.md section 5): the base game plus every free
-- game it awards. One HMAC without free games, one more per free game. No input checks: the
-- ledger passes a valid table, stake and cap.
function Engine.round(K, n, contribs, tbl, stake, cap)
	local nText = dec(n)
	local R = hmacRaw(K, "spin|" .. nText .. "|" .. contribs)
	local function stopsFrom(H, strips)
		local stops = {}
		for r = 1, #strips do
			stops[r] = uint32be(H, 4 * r - 3) % #strips[r]
		end
		return stops
	end
	local round = ns.Tables.playRound(tbl, stake, cap, {
		base = function()
			return stopsFrom(R, tbl.reels)
		end,
		symbol = function()
			return uint32be(R, 21) % #tbl.expanding
		end,
		free = function(i)
			return stopsFrom(hmacRaw(K, "free|" .. nText .. "|" .. dec(i) .. "|" .. contribs), tbl.freeReels)
		end,
	})
	round.n = n
	return round
end

function Engine.gamble(K, n, g, contribs)
	local R = hmacRaw(K, "gam|" .. dec(n) .. "|" .. dec(g) .. "|" .. contribs)
	return byte(R, 1) < 128
end
