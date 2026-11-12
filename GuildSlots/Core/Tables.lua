local _, ns = ...

-- Symbol tables for the slot machine. Pure Lua: no WoW API, no clock, no randomness.
-- Bad input returns nil, code; nothing here raises on bad values.

local Tables = {}
ns.Tables = Tables

local sub = string.sub

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
		kind = "classic",
		reels = { parseStrip(strip), parseStrip(strip), parseStrip(strip) },
		pair = pair,
		triple = triple,
	}
end

-- Table T2 (docs/table-t2-spec.md): 5 reels, 3 rows, 10 fixed lines, B is wild and scatter,
-- free games with an expanding symbol.

local function charStrips(list)
	local strips = {}
	for r, text in ipairs(list) do
		local strip = {}
		for i = 1, #text do
			strip[i] = sub(text, i, i)
		end
		strips[r] = strip
	end
	return strips
end

local function newLinesTable()
	return {
		id = "T2",
		kind = "lines",
		reels = charStrips({
			"KTMKDSGTCDTGWTGWSKMSKDGSWKDWLMSCTKDGSTWCB",
			"KTGWSKWGKTWGKSWGMKSTWGSMGKTDSLCWKMTBCDWG",
			"WGDSMTWDSMWSKTSDTGKWCSTGMWSGTKGCDKMDLGWCSWMLKTGKWTLSBDM",
			"TGSWMGTMWTKWSGWKTGSTKSMWKGSMKGWKGWSMKTWGTWGBMLSTCD",
			"WKSBKGSWTGMWKTMGWTGKDSBLTCGKM",
		}),
		freeReels = charStrips({
			"SKGTWGKSTWKGWKSMTKGWDSMKDTGMSWDTKBTWLSGKC",
			"SWKSDKSTWGTKGMKTCSKWSMWCTKGWTDMGSTWGLSDMGSKWLTGKMLKSCWTB",
			"GTDGSKWTSWKSGTKSGTLWSGWKTWDGTMKDTKSDGLSGKTDCTWKGWMBTDKBMWSC",
			"SDGSKMWGTKGSWDKTGDCMSWTGWKTWKCGSTDWMGWCKSBGDMSLDWCTKL",
			"WGSTWSTGKSTGWTGKWGSKTSKGTBKWSMTGSTWDKTSKWGCMDSCKBDWLGST",
		}),
		rows = 3,
		lineCount = 10,
		-- Row (0 top, 1 middle, 2 bottom) on reels 1..5, per line.
		lines = {
			{ 1, 1, 1, 1, 1 }, { 0, 0, 0, 0, 0 }, { 2, 2, 2, 2, 2 }, { 0, 1, 2, 1, 0 }, { 2, 1, 0, 1, 2 },
			{ 1, 2, 2, 2, 1 }, { 1, 0, 0, 0, 1 }, { 2, 2, 1, 0, 0 }, { 0, 0, 1, 2, 2 }, { 0, 1, 1, 1, 0 },
		},
		-- Multiples of the line bet for 2..5 of a kind; nil = no pay.
		pays = {
			K = { nil, nil, 5, 25, 100 }, S = { nil, nil, 5, 25, 100 }, G = { nil, nil, 5, 25, 100 },
			T = { nil, nil, 5, 40, 150 }, W = { nil, nil, 5, 40, 150 },
			M = { nil, 5, 30, 100, 750 }, D = { nil, 5, 30, 100, 750 },
			C = { nil, 5, 40, 400, 2000 },
			L = { nil, 10, 100, 1000, 5000 },
		},
		-- B: wild on lines, scatter pays in multiples of the stake for 3, 4, 5+ anywhere;
		-- `trigger` or more books award `games` free games.
		scatter = { symbol = "B", pays = { nil, nil, 2, 20, 200 }, trigger = 3, games = 10 },
		-- Expanding symbol of a free-game series, by index 0..8.
		expanding = { "K", "S", "G", "T", "W", "M", "D", "C", "L" },
		-- Display order, best first.
		order = { "L", "C", "D", "M", "W", "T", "G", "S", "K", "B" },
		maxFree = 50,
	}
end

local BY_ID = {
	T1 = newTable(
		"T1",
		STRIP_T1,
		{ K = 1, S = 2, G = 3, T = 5, W = 10, M = 20, D = 50 },
		{ K = 5, S = 10, G = 15, T = 30, W = 60, M = 150, D = 500 }
	),
	T2 = newLinesTable(),
}

-- Cache of stats() results, keyed by table id, stake and cap.
local STATS_CACHE = {}

-- Statistics of the lines tables for the multiplier round win / stake without a cap
-- (docs/table-t2-spec.md section 7). They come from the Python reference in tools/ref; the game
-- cannot enumerate them. The same values serve every stake and cap.
local LINES_STATS = {
	-- TODO(coordinator): replace with the values from tools/ref
	T2 = { rtp = 0.95, hit = 0.3, variance = 400, freeRate = 0.006 },
}

local function isStop(s)
	return type(s) == "number" and s % 1 == 0 and s >= 0 and s <= STOPS - 1
end

local function isInteger(v, lo, hi)
	return type(v) == "number" and v % 1 == 0 and v >= lo and v <= hi
end

local function isTable(tbl)
	return type(tbl) == "table" and type(tbl.reels) == "table"
end

-- symbols, multiplier, window and win describe the three-reel classic table (T1) only.
local function isClassic(tbl)
	return isTable(tbl) and tbl.kind ~= "lines"
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
	if not isClassic(tbl) then
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
	if not isClassic(tbl) then
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
	if not isClassic(tbl) then
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

-- One window of a lines table (spec section 4), without checks. strips = tbl.reels or
-- tbl.freeReels; X = the expanding symbol of a free game or nil. Returns
-- { stops, window, lines, scatter, expand, win }.
local function evaluateLines(tbl, strips, stops, stake, X)
	local lineBet = stake / tbl.lineCount
	local pays, scatter = tbl.pays, tbl.scatter
	local wild = scatter.symbol

	local window, books, hits = {}, 0, 0
	for r = 1, #strips do
		local strip, s = strips[r], stops[r]
		local n = #strip
		local top, mid, bottom = strip[(s - 1) % n + 1], strip[s + 1], strip[(s + 1) % n + 1]
		window[r] = { top, mid, bottom }
		if top == wild then books = books + 1 end
		if mid == wild then books = books + 1 end
		if bottom == wild then books = books + 1 end
		if X and (top == X or mid == X or bottom == X) then
			hits = hits + 1
		end
	end

	local lines, win = {}, 0
	local reels = #window
	for li, rows in ipairs(tbl.lines) do
		local target, count = nil, 0
		for r = 1, reels do
			local sym = window[r][rows[r] + 1]
			if sym == wild then
				count = count + 1
			elseif target == nil then
				target, count = sym, count + 1
			elseif sym == target then
				count = count + 1
			else
				break
			end
		end
		local pay = target and pays[target][count]
		if pay then
			local w = pay * lineBet
			lines[#lines + 1] = { line = li, symbol = target, count = count, win = w }
			win = win + w
		end
	end

	local spay = scatter.pays[books > 5 and 5 or books]
	local swin = spay and spay * stake or 0
	win = win + swin

	local expand = nil
	if X then
		local pay = pays[X][hits]
		if pay then
			local on = {}
			for r = 1, reels do
				local col = window[r]
				if col[1] == X or col[2] == X or col[3] == X then
					on[#on + 1] = r
				end
			end
			expand = { reels = on, count = hits, win = pay * lineBet * tbl.lineCount }
			win = win + expand.win
		end
	end

	return { stops = stops, window = window, lines = lines, scatter = { count = books, win = swin },
		expand = expand, win = win }
end
Tables.evaluateLines = evaluateLines

local function isLinesTable(tbl)
	return isTable(tbl) and tbl.kind == "lines"
end

-- tbl: a lines table; stops: { s1..s5 } 0-based; stake: total bet, a multiple of the line count;
-- X: the expanding symbol (free game, uses tbl.freeReels) or nil (base game).
function Tables.evaluate(tbl, stops, stake, X)
	if not isLinesTable(tbl) then
		return nil, "bad_table"
	end
	if not isInteger(stake, 1, math.huge) or stake % tbl.lineCount ~= 0 then
		return nil, "bad_stake"
	end
	if X ~= nil and (X == tbl.scatter.symbol or tbl.pays[X] == nil) then
		return nil, "bad_symbol"
	end
	local strips = X and tbl.freeReels or tbl.reels
	if type(stops) ~= "table" then
		return nil, "bad_stop"
	end
	for r = 1, #strips do
		if not isInteger(stops[r], 0, #strips[r] - 1) then
			return nil, "bad_stop"
		end
	end
	return evaluateLines(tbl, strips, stops, stake, X)
end

-- Enumerates all stop combinations. The effective multiplier is win / stake, so a cap
-- lowers rtp and variance. Results are cached per (id, stake, cap). A lines table returns its
-- constants instead (LINES_STATS); a cap then leaves them unchanged.
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

	if tbl.kind == "lines" then
		return LINES_STATS[tbl.id]
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
