local _, ns = ...

-- Packs an account (entry text forms) into one text for the LOG messages and back
-- (docs/payout-spec.md section 3). Items are separated by "\n":
--   =<entry text>            one entry, verbatim
--   s<stake>[*<count>]       level-0 spins S|n|<stake>|0|ok|, numbered on from the last spin
--   g[*<count>]              level-0 gamble steps G|n|g|0|ok| of the current spin
-- Pure Lua 5.1. decode never raises, whatever the input.

local Engine = ns.Engine

local Pack = {}
ns.Pack = Pack

local find, sub, match, concat = string.find, string.sub, string.match, table.concat
local dec = Engine.dec

Pack.CHUNK = 200
-- decode never builds more entries than this unless the caller passes its own limit.
Pack.MAX_ENTRIES = 100000

local MAX_NUMBER = 9007199254740991 -- 2^53 - 1

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

function Pack.encode(entries)
	local items = {}
	local n, g = 0, 0
	local kind, stake, count = nil, nil, 0 -- the run being collected: "s" or "g"

	local function flush()
		if kind then
			local item = kind == "s" and ("s" .. stake) or "g"
			items[#items + 1] = count > 1 and (item .. "*" .. count) or item
		end
		kind, stake, count = nil, nil, 0
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
		else
			flush()
			items[#items + 1] = "=" .. text
			n, g = track(text, n, g)
		end
	end
	flush()
	return concat(items, "\n")
end

function Pack.decode(text, limit)
	if type(text) ~= "string" then
		return nil, "bad_pack"
	end
	limit = limit or Pack.MAX_ENTRIES
	local entries = {}
	if text == "" then
		return entries
	end
	local n, g = 0, 0
	local pos = 1
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
	return entries
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
