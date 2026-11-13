local _, ns = ...

-- Tokens and gold at the guild rate X (tokens per gold, from the settings line). Pure apart
-- from the optional client coin text (GetCoinTextureString, type-checked). Rounding: tokens
-- from copper and copper from tokens both round down. Display only: the add-on never moves
-- gold.

local Coins = {}
ns.Coins = Coins

local floor = math.floor
local GOLD = 10000 -- copper per gold

local function goodRate(rate)
	return type(rate) == "number" and rate >= 1 and rate % 1 == 0
end

-- Copper worth `tokens` at `rate`, rounded down; nil without a valid rate.
function Coins.tokensToCopper(tokens, rate)
	if not goodRate(rate) or type(tokens) ~= "number" then
		return nil
	end
	return floor(tokens * GOLD / rate)
end

-- Tokens `copper` buys at `rate`, rounded down; nil without a valid rate.
function Coins.copperToTokens(copper, rate)
	if not goodRate(rate) or type(copper) ~= "number" then
		return nil
	end
	-- Split so the products stay exact in a double.
	local g, c = floor(copper / GOLD), copper % GOLD
	return g * rate + floor(c * rate / GOLD)
end

-- "12", "12.5", "12,5", ".5" gold -> copper (digits past the copper are dropped); nil if bad.
function Coins.parseGold(text)
	if type(text) ~= "string" then
		return nil
	end
	text = text:gsub("^%s+", ""):gsub("%s+$", "")
	local whole, frac = text:match("^(%d*)[.,]?(%d*)$")
	if not whole or (whole == "" and frac == "") or #whole > 9 then
		return nil
	end
	frac = (frac .. "0000"):sub(1, 4)
	return (tonumber(whole) or 0) * GOLD + tonumber(frac)
end

function Coins.goldToTokens(text, rate)
	local copper = Coins.parseGold(text)
	if not copper then
		return nil
	end
	return Coins.copperToTokens(copper, rate)
end

local function clientText(copper)
	local fn = GetCoinTextureString
	if type(fn) ~= "function" and type(C_CurrencyInfo) == "table" then
		fn = C_CurrencyInfo.GetCoinTextureString
	end
	if type(fn) ~= "function" then
		return nil
	end
	local ok, s = pcall(fn, copper)
	if ok and type(s) == "string" and s ~= "" then
		return s
	end
end

local function fmt(key, fallback)
	local L = ns.L
	local v = L and rawget(L, key)
	return type(v) == "string" and v or fallback
end

-- "12g 50s" (or the client's coin text with icons) for an amount of copper.
function Coins.text(copper)
	copper = floor(tonumber(copper) or 0)
	local s = clientText(copper)
	if s then
		return s
	end
	local parts = {}
	local g, sv, cp = floor(copper / GOLD), floor(copper / 100) % 100, copper % 100
	if g > 0 then parts[#parts + 1] = string.format(fmt("COIN_G", "%dg"), g) end
	if sv > 0 then parts[#parts + 1] = string.format(fmt("COIN_S", "%ds"), sv) end
	if cp > 0 or #parts == 0 then parts[#parts + 1] = string.format(fmt("COIN_C", "%dc"), cp) end
	return table.concat(parts, " ")
end

-- The coin text for `tokens` at `rate`; nil without a valid rate.
function Coins.tokensText(tokens, rate)
	local copper = Coins.tokensToCopper(tokens, rate)
	return copper and Coins.text(copper) or nil
end

-- The guild rate X from the current settings line; nil without valid settings. An older
-- purchase line of the own account plays no part here.
function Coins.rate()
	local Roster = ns.Roster
	local s = Roster and Roster.settings() or nil
	local x = s and tonumber(s.X)
	return goodRate(x) and x or nil
end
