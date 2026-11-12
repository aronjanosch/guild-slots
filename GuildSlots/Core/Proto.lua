local _, ns = ...

-- Wire format of the addon messages (docs/guild-spec.md section 2):
--   version | type | fields...   joined with "|", at most 255 bytes, no NUL.
-- Pure Lua 5.1. decode never raises, whatever the input.

local Sha256, Engine = ns.Sha256, ns.Engine

local Proto = {}
ns.Proto = Proto

Proto.VERSION = "1"
Proto.PREFIX = "GSLOTS"
Proto.MAX = 255

local find, sub, concat = string.find, string.sub, table.concat
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
		field("head", hex(32)),
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
	local parts, pos = {}, 1
	while true do
		local bar = find(text, "|", pos, true)
		parts[#parts + 1] = sub(text, pos, bar and bar - 1 or #text)
		if not bar then
			break
		end
		pos = bar + 1
	end
	if parts[1] ~= Proto.VERSION then
		return nil
	end
	local spec = TYPES[parts[2]]
	if not spec or #parts ~= #spec + 2 then
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
	return msg
end

function Proto.lineHash(line)
	return sub(Sha256.hex(line), 1, 8)
end
