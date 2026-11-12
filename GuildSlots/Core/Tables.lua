local _, ns = ...

-- Symbol tables for the slot machine. Pure Lua: no WoW API, no clock, no randomness.
-- Bad input returns nil, code; nothing here raises on bad values.

local Tables = {}
ns.Tables = Tables

local STOPS = 34
local REEL_COUNT = 3

local STRIP_T1 = "K,S,G,K,T,S,K,W,G,S,K,M,T,K,S,G,W,K,S,D,G,K,T,S,K,G,M,S,K,W,T,G,K,S"

local function parseStrip(text)
	local strip = {}
	for sym in text:gmatch("[^,]+") do
		strip[#strip + 1] = sym
	end
	return strip
end

local function newTable(id, strip, pair, triple)
	return {
		id = id,
		reels = { parseStrip(strip), parseStrip(strip), parseStrip(strip) },
		pair = pair,
		triple = triple,
	}
end

local BY_ID = {
	T1 = newTable(
		"T1",
		STRIP_T1,
		{ K = 1, S = 2, G = 3, T = 5, W = 10, M = 20, D = 50 },
		{ K = 5, S = 10, G = 15, T = 30, W = 60, M = 150, D = 500 }
	),
}

-- Cache of stats() results, keyed by table id, stake and cap.
local STATS_CACHE = {}

local function isStop(s)
	return type(s) == "number" and s % 1 == 0 and s >= 0 and s <= STOPS - 1
end

local function isInteger(v, lo, hi)
	return type(v) == "number" and v % 1 == 0 and v >= lo and v <= hi
end

local function isTable(tbl)
	return type(tbl) == "table" and type(tbl.reels) == "table"
end

-- Multiplier from three symbols. A pair is reels 1 and 2 equal with reel 3 different;
-- reels 2 and 3 equal (or 1 and 3) pays nothing.
local function multiplierOf(tbl, a, b, c)
	if a == b and b == c then
		return tbl.triple[a]
	end
	if a == b then
		return tbl.pair[a]
	end
	return 0
end

function Tables.get(id)
	if type(id) ~= "string" then
		return nil
	end
	return BY_ID[id]
end

function Tables.symbols(tbl, s1, s2, s3)
	if not isTable(tbl) then
		return nil, "bad_table"
	end
	local stops = { s1, s2, s3 }
	local syms = {}
	for r = 1, REEL_COUNT do
		local s = stops[r]
		if not isStop(s) then
			return nil, "bad_stop"
		end
		syms[r] = tbl.reels[r][s + 1]
	end
	return syms[1], syms[2], syms[3]
end

function Tables.multiplier(tbl, s1, s2, s3)
	local a, b, c = Tables.symbols(tbl, s1, s2, s3)
	if a == nil then
		return nil, b
	end
	return multiplierOf(tbl, a, b, c)
end

function Tables.window(tbl, reel, stop)
	if not isTable(tbl) then
		return nil, "bad_table"
	end
	if not isInteger(reel, 1, REEL_COUNT) then
		return nil, "bad_reel"
	end
	if not isStop(stop) then
		return nil, "bad_stop"
	end
	local strip = tbl.reels[reel]
	local n = #strip
	local above = strip[(stop - 1) % n + 1]
	local centre = strip[stop + 1]
	local below = strip[(stop + 1) % n + 1]
	return above, centre, below
end

function Tables.win(tbl, stake, cap, s1, s2, s3)
	if not isTable(tbl) then
		return nil, "bad_table"
	end
	if not isInteger(stake, 1, math.huge) then
		return nil, "bad_stake"
	end
	if not isInteger(cap, 0, math.huge) then
		return nil, "bad_cap"
	end
	local m, err = Tables.multiplier(tbl, s1, s2, s3)
	if m == nil then
		return nil, err
	end
	local w = stake * m
	if cap > 0 and w > cap then
		w = cap
	end
	return w
end

-- Enumerates all stop combinations. The effective multiplier is win / stake, so a cap
-- lowers rtp and variance. Results are cached per (id, stake, cap).
function Tables.stats(tbl, stake, cap)
	if not isTable(tbl) then
		return nil, "bad_table"
	end
	if not isInteger(stake, 1, math.huge) then
		return nil, "bad_stake"
	end
	if not isInteger(cap, 0, math.huge) then
		return nil, "bad_cap"
	end

	local key = tbl.id .. "|" .. stake .. "|" .. cap
	local cached = STATS_CACHE[key]
	if cached then
		return cached
	end

	local r1, r2, r3 = tbl.reels[1], tbl.reels[2], tbl.reels[3]
	local sumM, sumM2, hits, combos = 0, 0, 0, 0
	for a = 1, STOPS do
		local sa = r1[a]
		for b = 1, STOPS do
			local sb = r2[b]
			for c = 1, STOPS do
				local w = stake * multiplierOf(tbl, sa, sb, r3[c])
				if cap > 0 and w > cap then
					w = cap
				end
				local e = w / stake
				sumM = sumM + e
				sumM2 = sumM2 + e * e
				if w > 0 then
					hits = hits + 1
				end
				combos = combos + 1
			end
		end
	end

	local rtp = sumM / combos
	local result = {
		rtp = rtp,
		hit = hits / combos,
		variance = sumM2 / combos - rtp * rtp,
		combos = combos,
	}
	STATS_CACHE[key] = result
	return result
end
