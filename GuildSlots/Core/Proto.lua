local _, ns = ...

-- Wire format of the addon messages (docs/guild-spec.md section 2, docs/payout-spec.md section 2):
--   version | type | fields...   joined with "|", at most 255 bytes, no NUL.
-- LOG is the one message whose last field is free text and may contain "|".
-- Pure Lua 5.1. decode never raises, whatever the input.

local Sha256, Engine = ns.Sha256, ns.Engine

local Proto = {}
ns.Proto = Proto

Proto.VERSION = "1"
Proto.PREFIX = "GSLOTS"
Proto.MAX = 255

local find, sub, match, concat = string.find, string.sub, string.match, table.concat
local dec, validName = Engine.dec, Engine.validName

local MAX_INT = 9007199254740991 -- 2^53 - 1
local MAX_SPIN = 2147483648 -- 2^31

-- Field kinds: a check for the Lua value plus whether the wire form is a number.

local function hex(len)
	return function(v)
		return type(v) == "string" and #v == len and not find(v, "[^0-9a-f]")
	end
end

local function int(lo, hi)
	return function(v)
		return type(v) == "number" and v % 1 == 0 and v >= lo and v <= hi
	end, true
end

local function version(v)
	return type(v) == "string" and #v >= 1 and #v <= 16 and not find(v, "[^0-9A-Za-z.%-]")
end

local function headOrDash(v)
	return v == "-" or hex(32)(v)
end

local function field(name, check, numeric)
	return { name = name, check = check, numeric = numeric }
end

local REASONS = { declined = true, mismatch = true, expired = true, busy = true, too_large = true, bad_log = true }

local function reason(v)
	return REASONS[v] == true
end

-- LOG payload: 1..220 bytes, anything but NUL.
local function payload(v)
	return type(v) == "string" and #v >= 1 and #v <= 220 and not find(v, "%z")
end

-- Audit item lists (docs/witness-spec.md section 1). An AUD item is s<n> or g<n>.<g>; an AUDR
-- item is that plus =<value 16 hex><flag> or =-. Up to 8 items joined with ","; "-" is none.
local MAX_ITEMS = 8

local function canonical(text, lo, hi)
	if not text or #text > 16 or (text ~= "0" and not find(text, "^[1-9]%d*$")) then
		return nil
	end
	local v = tonumber(text)
	return v >= lo and v <= hi and v or nil
end

-- One item, or nil. answer: true when the item carried "=...".
local function auditItem(text)
	local key, rest = match(text, "^([^=]*)=(.*)$")
	key = key or text
	local item = {}
	local nText, gText = match(key, "^g([^.]*)%.(.*)$")
	if nText then
		item.kind, item.n, item.g = "gam", canonical(nText, 1, MAX_SPIN), canonical(gText, 1, 5)
	elseif sub(key, 1, 1) == "s" then
		item.kind, item.n, item.g = "spin", canonical(sub(key, 2), 1, MAX_SPIN), 0
	end
	if not item.n or not item.g then
		return nil
	end
	if rest and rest ~= "-" then
		local value, flag = match(rest, "^([0-9a-f]+)([+%-?])$")
		if not value or #value ~= 16 then
			return nil
		end
		item.value, item.flag = value, flag
	end
	return item, rest ~= nil
end

-- Returns the items and whether they are answers (AUDR form), or nil. Mixed lists are invalid.
local function parseItems(text)
	if type(text) ~= "string" then
		return nil
	end
	local list, answers = {}, nil
	if text == "-" then
		return list, nil
	end
	local pos = 1
	while true do
		local comma = find(text, ",", pos, true)
		local item, answer = auditItem(sub(text, pos, comma and comma - 1 or #text))
		if not item or #list >= MAX_ITEMS or (answers ~= nil and answers ~= answer) then
			return nil
		end
		answers = answer
		list[#list + 1] = item
		if not comma then
			return list, answers
		end
		pos = comma + 1
	end
end

function Proto.auditItems(text)
	return (parseItems(text))
end

local function audItems(v)
	local list, answers = parseItems(v)
	return list ~= nil and answers ~= true
end

local function audrItems(v)
	local list, answers = parseItems(v)
	return list ~= nil and answers ~= false
end

local TYPES = {
	HELLO = {
		field("version", version),
		field("n", int(0, MAX_SPIN)),
		field("head", headOrDash),
	},
	BUY1 = {
		field("buyId", hex(16)),
		field("player", validName),
		field("tokens", int(1, 1000000000)),
		field("commit", hex(64)),
		field("time", int(0, MAX_INT)),
		field("lineHash", hex(8)),
	},
	BUY2 = {
		field("buyId", hex(16)),
		field("nonce", hex(32)),
		field("head", hex(64)),
		field("anchors", int(0, MAX_SPIN)),
	},
	BUY3 = {
		field("buyId", hex(16)),
		field("seed", hex(32)),
	},
	SPIN = {
		field("n", int(1, MAX_SPIN)),
		field("stake", int(1, 1000000)),
		field("level", int(0, 2)),
		field("head", hex(32)),
		field("A", int(0, 10000)),
	},
	GAM = {
		field("n", int(1, MAX_SPIN)),
		field("g", int(1, 5)),
		field("amount", int(1, MAX_INT)),
		field("level", int(0, 2)),
		field("head", hex(32)),
		field("A", int(0, 10000)),
	},
	PAYREQ = {
		field("reqId", hex(16)),
		field("officer", validName),
		field("amount", int(1, MAX_INT)),
		field("head", hex(32)),
		field("count", int(1, MAX_SPIN)),
	},
	LOGREQ = {
		field("reqId", hex(16)),
		field("player", validName),
		field("from", int(0, MAX_SPIN)),
	},
	LOG = {
		field("reqId", hex(16)),
		-- seq and total are read up to 2^31 so that the officer can refuse more than 200 chunks
		-- with REJECT too_large instead of never hearing them.
		field("seq", int(1, MAX_SPIN)),
		field("total", int(1, MAX_SPIN)),
		field("payload", payload),
		rest = true, -- the last field takes the rest of the message
		valid = function(m) return m.seq <= m.total end,
	},
	PAY = {
		field("reqId", hex(16)),
		field("payId", hex(16)),
		field("player", validName),
		field("amount", int(1, MAX_INT)),
		field("balanceAfter", int(0, MAX_INT)),
		field("time", int(0, MAX_INT)),
		field("head", hex(32)),
		field("anchors", int(1, MAX_SPIN)),
		field("n", int(0, MAX_SPIN)),
		field("ck", hex(16)),
	},
	REJECT = {
		field("reqId", hex(16)),
		field("player", validName),
		field("reason", reason),
	},
	OSYNC = {
		field("player", validName),
		field("anchors", int(1, MAX_SPIN)),
		field("head", hex(32)),
		field("time", int(0, MAX_INT)),
	},
}

-- Milestone 5: audit and checkpoint sync (docs/witness-spec.md section 1).
TYPES.AUD = {
	field("reqId", hex(16)),
	field("witness", validName),
	field("player", validName),
	field("from", int(0, MAX_SPIN)),
	field("items", audItems),
}
TYPES.AUDR = {
	field("reqId", hex(16)),
	field("player", validName),
	field("items", audrItems),
}
TYPES.CSYNC = {
	field("player", validName),
	field("anchors", int(1, MAX_SPIN)),
	field("head", hex(32)),
	field("balance", int(0, MAX_INT)),
	field("n", int(0, MAX_SPIN)),
	field("ck", hex(16)),
	field("time", int(0, MAX_INT)),
}

function Proto.encode(msgType, fields)
	local spec = TYPES[msgType]
	if not spec then
		return nil, "bad_type"
	end
	if type(fields) ~= "table" then
		return nil, "bad_field"
	end
	local parts = { Proto.VERSION, msgType }
	for i, f in ipairs(spec) do
		local v = fields[f.name]
		if not f.check(v) then
			return nil, "bad_field"
		end
		parts[i + 2] = f.numeric and dec(v) or v
	end
	if spec.valid and not spec.valid(fields) then
		return nil, "bad_field"
	end
	local text = concat(parts, "|")
	if #text > Proto.MAX then
		return nil, "too_long"
	end
	return text
end

-- Canonical decimal: "0" or [1-9][0-9]*, at most 16 digits (so below 10^16 before range checks).
local function parseNumber(text)
	if #text > 16 or (text ~= "0" and not find(text, "^[1-9]%d*$")) then
		return nil
	end
	return tonumber(text)
end

function Proto.decode(text)
	if type(text) ~= "string" or #text > Proto.MAX or find(text, "%z") then
		return nil
	end
	-- Split into at most `limit` parts; the last part keeps any further bars.
	local function split(limit)
		local parts, pos = {}, 1
		while true do
			local bar = (not limit or #parts + 1 < limit) and find(text, "|", pos, true)
			parts[#parts + 1] = sub(text, pos, bar and bar - 1 or #text)
			if not bar then
				return parts
			end
			pos = bar + 1
		end
	end
	local parts = split(nil)
	if parts[1] ~= Proto.VERSION then
		return nil
	end
	local spec = TYPES[parts[2]]
	if not spec then
		return nil
	end
	if spec.rest then
		parts = split(#spec + 2)
	end
	if #parts ~= #spec + 2 then
		return nil
	end
	local msg = { type = parts[2] }
	for i, f in ipairs(spec) do
		local v = parts[i + 2]
		if f.numeric then
			v = parseNumber(v)
		end
		if v == nil or not f.check(v) then
			return nil
		end
		msg[f.name] = v
	end
	if spec.valid and not spec.valid(msg) then
		return nil
	end
	return msg
end

function Proto.lineHash(line)
	return sub(Sha256.hex(line), 1, 8)
end
