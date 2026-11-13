local _, ns = ...

-- Packs an account (entry text forms) into one text for the LOG messages and back
-- (docs/payout-spec.md section 3, docs/witness-spec.md section 5). Items are separated by "\n":
--   =<entry text>              one entry, verbatim
--   s<stake>[*<count>]         level-0 spins S|n|<stake>|0|ok|, numbered on from the last spin
--   g[*<count>]                level-0 gamble steps G|n|g|0|ok| of the current spin
--   @<name>                    adds a name to the dictionary (index 1, 2, ...)
--   S<stake>|<A>|<o|v>|<list>  spin n + 1 with status and contributions <value64><index>,...
--   G<A>|<o|v>|<list>          gamble step g + 1 of the current spin, same list form
-- A partial log (the entries after entry number `from`) starts with a line >`from`
-- (docs/follow-spec.md section 5); its short forms number on from a start n the caller passes.
-- Pure Lua 5.1. decode never raises, whatever the input.

local Engine = ns.Engine

local Pack = {}
ns.Pack = Pack

local find, sub, match, concat, byte, floor = string.find, string.sub, string.match, table.concat, string.byte, math.floor
local dec, validName = Engine.dec, Engine.validName

Pack.CHUNK = 220
-- decode never builds more entries than this unless the caller passes its own limit.
Pack.MAX_ENTRIES = 100000

local MAX_NUMBER = 9007199254740991 -- 2^53 - 1
local MAX_SPIN = 2147483648 -- 2^31

-- Canonical decimal of at most 16 digits below 2^53, or nil.
local function number(text)
	if type(text) ~= "string" or #text > 16 or (text ~= "0" and not find(text, "^[1-9]%d*$")) then
		return nil
	end
	local v = tonumber(text)
	if not v or v > MAX_NUMBER then
		return nil
	end
	return v
end

-- The running spin number and gamble step after a verbatim entry. A spin or step whose numbers
-- cannot be read leaves both unknown (nil), so no short form can follow until the next one.
local function track(text, n, g)
	if sub(text, 1, 2) == "S|" then
		local a = number(match(text, "^S|([^|]*)|"))
		return a, a and 0 or nil
	elseif sub(text, 1, 2) == "G|" then
		local a, b = match(text, "^G|([^|]*)|([^|]*)|")
		a, b = number(a), number(b)
		if a and b then
			return a, b
		end
		return nil, nil
	end
	return n, g
end

local function spinText(n, stake)
	return "S|" .. dec(n) .. "|" .. stake .. "|0|ok|"
end

local function stepText(n, g)
	return "G|" .. dec(n) .. "|" .. dec(g) .. "|0|ok|"
end

-- Values ------------------------------------------------------------------------------------------

-- A 64-bit value as 11 characters: the top 4 bits, then ten characters of 6 bits. Three hex
-- digits (12 bits) make two characters, so no bit operations are needed.
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
local HEX = "0123456789abcdef"
local DIGIT = {} -- character byte -> 0..63
for i = 1, 64 do
	DIGIT[byte(ALPHABET, i)] = i - 1
end

local function at(s, i)
	return sub(s, i + 1, i + 1)
end

local function toValue64(hex)
	local out = { at(ALPHABET, tonumber(sub(hex, 1, 1), 16)) }
	for i = 2, 16, 3 do
		local v = tonumber(sub(hex, i, i + 2), 16)
		out[#out + 1] = at(ALPHABET, floor(v / 64)) .. at(ALPHABET, v % 64)
	end
	return concat(out)
end

-- 11 characters to 16 hex, or nil (wrong length, a character outside the alphabet, top above 15).
local function fromValue64(text)
	if #text ~= 11 then
		return nil
	end
	local top = DIGIT[byte(text, 1)]
	if not top or top > 15 then
		return nil
	end
	local out = { at(HEX, top) }
	for i = 2, 10, 2 do
		local a, b = DIGIT[byte(text, i)], DIGIT[byte(text, i + 1)]
		if not a or not b then
			return nil
		end
		local v = a * 64 + b
		out[#out + 1] = at(HEX, floor(v / 256)) .. at(HEX, floor(v / 16) % 16) .. at(HEX, v % 16)
	end
	return concat(out)
end

-- Dictionary items --------------------------------------------------------------------------------

local STATUS = { ok = "o", void = "v" }
local STATUS_TEXT = { o = "ok", v = "void" }

-- The fields of an S or G entry text, when a dictionary item can hold them, or nil:
-- n, g (nil for S), stake text (nil for G), A text, status letter, { { name, value }, ... }.
local function parseFields(text)
	local n, g, stake, A, status, list
	if sub(text, 1, 2) == "S|" then
		n, stake, A, status, list = match(text, "^S|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
		local s = number(stake)
		if not s or s < 1 then
			return nil
		end
	elseif sub(text, 1, 2) == "G|" then
		n, g, A, status, list = match(text, "^G|([^|]*)|([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
		g = number(g)
		if not g then
			return nil
		end
	else
		return nil
	end
	n = number(n)
	if not n or not number(A) or not STATUS[status] then
		return nil
	end
	local contribs = {}
	if list ~= "" then
		local pos = 1
		while true do
			local comma = find(list, ",", pos, true)
			local name, value = match(sub(list, pos, comma and comma - 1 or #list), "^(.*):(.*)$")
			if not name or not validName(name) or #value ~= 16 or find(value, "[^0-9a-f]") then
				return nil
			end
			contribs[#contribs + 1] = { name, value }
			if not comma then
				break
			end
			pos = comma + 1
		end
	end
	return n, g, stake, A, STATUS[status], contribs
end

-- The contributions text of a dictionary item's list, or nil.
local function listText(list, dict)
	if list == "" then
		return ""
	end
	local parts, pos = {}, 1
	while true do
		local comma = find(list, ",", pos, true)
		local item = sub(list, pos, comma and comma - 1 or #list)
		local value = fromValue64(sub(item, 1, 11))
		local index = number(sub(item, 12))
		local name = index and dict[index]
		if not value or not name then
			return nil
		end
		parts[#parts + 1] = name .. ":" .. value
		if not comma then
			return concat(parts, ",")
		end
		pos = comma + 1
	end
end

-- Encode ------------------------------------------------------------------------------------------

-- from: number of entries before these (nil or 0 for a whole account); n: the spin number after
-- entry `from` (only used with from).
function Pack.encode(entries, from, n)
	local items = {}
	local g = 0
	if from and from > 0 then
		items[1] = ">" .. dec(from)
		n = n or 0
	else
		n = 0
	end
	local kind, stake, count = nil, nil, 0 -- the run being collected: "s" or "g"
	local dict, names = {}, 0 -- name -> dictionary index

	local function flush()
		if kind then
			local item = kind == "s" and ("s" .. stake) or "g"
			items[#items + 1] = count > 1 and (item .. "*" .. count) or item
		end
		kind, stake, count = nil, nil, 0
	end

	-- Writes an in-sequence S/G entry as a dictionary item; false when it does not fit one.
	local function dictItem(text)
		if not n or not g then
			return false
		end
		local en, eg, estake, A, status, contribs = parseFields(text)
		local start
		if not en then
			return false
		elseif estake and en == n + 1 then
			start = "S|" .. dec(en) .. "|" .. estake
		elseif eg and en == n and eg == g + 1 then
			start = "G|" .. dec(en) .. "|" .. dec(eg)
		else
			return false
		end
		-- The decoder rebuilds the text from the parts: it must be this very text.
		local parts = {}
		for i, c in ipairs(contribs) do
			parts[i] = c[1] .. ":" .. c[2]
		end
		if start .. "|" .. A .. "|" .. STATUS_TEXT[status] .. "|" .. concat(parts, ",") ~= text then
			return false
		end
		flush()
		local list = {}
		for i, c in ipairs(contribs) do
			if not dict[c[1]] then
				names = names + 1
				dict[c[1]] = names
				items[#items + 1] = "@" .. c[1]
			end
			list[i] = toValue64(c[2]) .. dict[c[1]]
		end
		local prefix = estake and ("S" .. estake .. "|") or "G"
		items[#items + 1] = prefix .. A .. "|" .. status .. "|" .. concat(list, ",")
		if estake then
			n, g = en, 0
		else
			g = eg
		end
		return true
	end

	for _, text in ipairs(entries) do
		local s = n and match(text, "^S|[^|]*|([1-9]%d*)|0|ok|$")
		if s and number(s) and text == spinText(n + 1, s) then
			if kind ~= "s" or stake ~= s then
				flush()
				kind, stake = "s", s
			end
			count = count + 1
			n, g = n + 1, 0
		elseif n and g and text == stepText(n, g + 1) then
			if kind ~= "g" then
				flush()
				kind = "g"
			end
			count = count + 1
			g = g + 1
		elseif not dictItem(text) then
			flush()
			items[#items + 1] = "=" .. text
			n, g = track(text, n, g)
		end
	end
	flush()
	return concat(items, "\n")
end

-- Decode ------------------------------------------------------------------------------------------

-- Returns entries, from (nil for a whole account), or nil, code. startN: the spin number after
-- entry `from` of a partial log (default 0); a whole account always starts at 0.
function Pack.decode(text, limit, startN)
	if type(text) ~= "string" then
		return nil, "bad_pack"
	end
	startN = startN or 0
	if type(startN) ~= "number" or startN % 1 ~= 0 or startN < 0 or startN > MAX_SPIN then
		return nil, "bad_pack"
	end
	limit = limit or Pack.MAX_ENTRIES
	local entries = {}
	local from, pos = nil, 1
	local n, g = 0, 0
	if sub(text, 1, 1) == ">" then
		local fromText, after = match(text, "^>([^\n]*)()")
		from = number(fromText)
		if not from or from < 1 or from > MAX_SPIN then
			return nil, "bad_pack"
		end
		if after > #text then
			return entries, from
		end
		pos = after + 1 -- the "\n" after the marker
		n = startN
	elseif text == "" then
		return entries
	end
	local dict, inDict = {}, {}
	while true do
		local nl = find(text, "\n", pos, true)
		local item = sub(text, pos, nl and nl - 1 or #text)
		local head = sub(item, 1, 1)
		if head == "=" then
			local entry = sub(item, 2)
			if entry == "" then
				return nil, "bad_pack"
			end
			if #entries >= limit then
				return nil, "too_many"
			end
			entries[#entries + 1] = entry
			n, g = track(entry, n, g)
		elseif head == "@" then
			local name = sub(item, 2)
			if not validName(name) or inDict[name] then
				return nil, "bad_pack"
			end
			inDict[name] = true
			dict[#dict + 1] = name
		elseif head == "S" or head == "G" then
			local stake, A, status, list
			if head == "S" then
				stake, A, status, list = match(item, "^S([^|]*)|([^|]*)|([^|]*)|([^|]*)$")
				local s = number(stake)
				if not s or s < 1 then
					return nil, "bad_pack"
				end
			else
				A, status, list = match(item, "^G([^|]*)|([^|]*)|([^|]*)$")
			end
			local contribs = list and listText(list, dict)
			if not contribs or not number(A) or not STATUS_TEXT[status] or not n or not g then
				return nil, "bad_pack"
			end
			if #entries >= limit then
				return nil, "too_many"
			end
			if (head == "S" and n + 1 > MAX_NUMBER) or (head == "G" and g + 1 > MAX_NUMBER) then
				return nil, "bad_pack"
			end
			local entry
			if head == "S" then
				n, g = n + 1, 0
				entry = "S|" .. dec(n) .. "|" .. stake
			else
				g = g + 1
				entry = "G|" .. dec(n) .. "|" .. dec(g)
			end
			entries[#entries + 1] = entry .. "|" .. A .. "|" .. STATUS_TEXT[status] .. "|" .. contribs
		elseif head == "s" or head == "g" then
			local body, countText = match(item, "^.([^*]*)%*(.*)$")
			if not body then
				body = sub(item, 2)
			end
			local count = 1
			if countText then
				count = number(countText)
				if not count or count < 2 then
					return nil, "bad_pack"
				end
			end
			if #entries + count > limit then
				return nil, "too_many"
			end
			if (n and n + count > MAX_NUMBER) or (g and g + count > MAX_NUMBER) then
				return nil, "bad_pack"
			end
			if head == "s" then
				local stake = number(body)
				if not stake or stake < 1 or not n then
					return nil, "bad_pack"
				end
				for _ = 1, count do
					n = n + 1
					entries[#entries + 1] = spinText(n, body)
				end
				g = 0
			else
				if body ~= "" or not n or not g then
					return nil, "bad_pack"
				end
				for _ = 1, count do
					g = g + 1
					entries[#entries + 1] = stepText(n, g)
				end
			end
		else
			return nil, "bad_pack"
		end
		if not nl then
			break
		end
		pos = nl + 1
	end
	return entries, from
end

function Pack.split(text, size)
	size = size or Pack.CHUNK
	local chunks = {}
	for i = 1, #text, size do
		chunks[#chunks + 1] = sub(text, i, i + size - 1)
	end
	return chunks
end

function Pack.join(chunks)
	return concat(chunks)
end
