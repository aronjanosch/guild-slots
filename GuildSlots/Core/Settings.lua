local _, ns = ...

-- Guild settings: one line in the guild info text, e.g.
--   GSLOTS1;L=1;W=2;R=1;E=10,50,100;G=3;C=0;T=T1;X=1000
-- Pure Lua. Bad input returns nil, code; nothing here raises on bad values.

local Settings = {}
ns.Settings = Settings

local PREFIX = "GSLOTS1"
local MAX_LENGTH = 120
local MAX_STAKES = 5
local MAX_STAKE = 1000000
local MAX_TOKENS = 1000000000

-- Integer rules for the single-value fields. Key -> default, bounds, error code.
local RULES = {
	L = { default = 0, lo = 0, hi = 2, code = "bad_level" },
	W = { default = 2, lo = 1, hi = 5, code = "bad_witnesses" },
	R = { default = 1, lo = 0, hi = 9, code = "bad_rank" },
	G = { default = 3, lo = 0, hi = 5, code = "bad_gamble" },
	C = { default = 0, lo = 0, hi = MAX_TOKENS, code = "bad_cap" },
	X = { default = 1000, lo = 1, hi = MAX_TOKENS, code = "bad_rate" },
}

local RULE_ORDER = { "L", "W", "R", "G", "C", "X" }

local DEFAULT_STAKES = { 10, 50, 100 }
local DEFAULT_TABLE = "T1"

-- Canonical decimal: "0" or a digit string without leading zero. Rejects signs, decimals, exponents.
local function parseInt(text, lo, hi)
	if type(text) ~= "string" then
		return nil
	end
	if text ~= "0" and not text:match("^[1-9]%d*$") then
		return nil
	end
	if #text > 10 then
		return nil
	end
	local n = tonumber(text)
	if n < lo or n > hi then
		return nil
	end
	return n
end

-- Splits on "," keeping empty items, so "10,,50" and "10,50," are visible as errors.
local function splitCommas(text)
	local items = {}
	local pos = 1
	while true do
		local comma = text:find(",", pos, true)
		items[#items + 1] = text:sub(pos, comma and comma - 1 or #text)
		if not comma then
			break
		end
		pos = comma + 1
	end
	return items
end

local function parseStakes(text)
	local items = splitCommas(text)
	if #items < 1 or #items > MAX_STAKES then
		return nil
	end
	local stakes, seen = {}, {}
	for i, item in ipairs(items) do
		local n = parseInt(item, 1, MAX_STAKE)
		if not n or seen[n] then
			return nil
		end
		seen[n] = true
		stakes[i] = n
	end
	table.sort(stakes)
	return stakes
end

function Settings.defaults()
	return {
		L = RULES.L.default,
		W = RULES.W.default,
		R = RULES.R.default,
		E = { DEFAULT_STAKES[1], DEFAULT_STAKES[2], DEFAULT_STAKES[3] },
		G = RULES.G.default,
		C = RULES.C.default,
		T = DEFAULT_TABLE,
		X = RULES.X.default,
		Z = 2 * RULES.W.default + 3,
	}
end

function Settings.parse(line)
	if type(line) ~= "string" then
		return nil, "bad_format"
	end
	if #line > MAX_LENGTH then
		return nil, "too_long"
	end
	if line:find("[%z\1-\31|]") then
		return nil, "bad_char"
	end

	local rest
	if line == PREFIX then
		rest = nil
	elseif line:sub(1, #PREFIX + 1) == PREFIX .. ";" then
		rest = line:sub(#PREFIX + 2)
	else
		return nil, "bad_format"
	end

	-- Collect key=value pairs. Keys are case-sensitive; unknown keys are kept but ignored.
	local values, seen = {}, {}
	if rest then
		local pos = 1
		while true do
			local semi = rest:find(";", pos, true)
			local seg = rest:sub(pos, semi and semi - 1 or #rest)
			local eq = seg:find("=", 1, true)
			if not eq or eq == 1 then
				return nil, "bad_field"
			end
			local key, value = seg:sub(1, eq - 1), seg:sub(eq + 1)
			if seen[key] then
				return nil, "repeated_key"
			end
			seen[key] = true
			values[key] = value
			if not semi then
				break
			end
			pos = semi + 1
		end
	end

	local s = Settings.defaults()

	-- Fixed order, so a line with several bad fields always reports the same code.
	for _, key in ipairs(RULE_ORDER) do
		local rule = RULES[key]
		if values[key] ~= nil then
			local n = parseInt(values[key], rule.lo, rule.hi)
			if n == nil then
				return nil, rule.code
			end
			s[key] = n
		end
	end

	if values.E ~= nil then
		local stakes = parseStakes(values.E)
		if not stakes then
			return nil, "bad_stakes"
		end
		s.E = stakes
	end

	if values.T ~= nil then
		if ns.Tables.get(values.T) == nil then
			return nil, "bad_table"
		end
		s.T = values.T
	end

	-- A lines table (T2, T3) splits the stake over its lines: every stake must divide evenly.
	local lineCount = ns.Tables.get(s.T).lineCount
	if lineCount then
		for _, stake in ipairs(s.E) do
			if stake % lineCount ~= 0 then
				return nil, "bad_stakes"
			end
		end
	end

	s.Z = 2 * s.W + 3
	return s
end

function Settings.format(s)
	if type(s) ~= "table" or type(s.E) ~= "table" then
		return nil, "bad_settings"
	end
	local sorted = {}
	for i, v in ipairs(s.E) do
		sorted[i] = v
	end
	table.sort(sorted)
	local stakes = {}
	for i, v in ipairs(sorted) do
		stakes[i] = tostring(v)
	end
	local line = PREFIX
		.. ";L=" .. tostring(s.L)
		.. ";W=" .. tostring(s.W)
		.. ";R=" .. tostring(s.R)
		.. ";E=" .. table.concat(stakes, ",")
		.. ";G=" .. tostring(s.G)
		.. ";C=" .. tostring(s.C)
		.. ";T=" .. tostring(s.T)
		.. ";X=" .. tostring(s.X)
	-- Validate the result so an invalid settings table never yields a line.
	local _, code = Settings.parse(line)
	if code then
		return nil, code
	end
	return line
end

function Settings.find(infoText)
	if type(infoText) ~= "string" then
		return nil
	end
	local text = infoText .. "\n"
	for raw in text:gmatch("([^\n]*)\n") do
		local line = raw:match("^[ \t\r]*(.-)[ \t\r]*$")
		if line == PREFIX or line:sub(1, #PREFIX + 1) == PREFIX .. ";" then
			return line
		end
	end
	return nil
end
