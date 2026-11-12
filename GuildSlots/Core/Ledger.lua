local _, ns = ...

-- The account of one player in one guild: entry text forms, the head-hash chain and the
-- replay rules (docs/core-spec.md section 6). Pure Lua 5.1. Bad input returns nil, code.

local Sha256, Tables, Settings, Engine = ns.Sha256, ns.Tables, ns.Settings, ns.Engine

local Ledger = {}
ns.Ledger = Ledger

local find, sub, concat = string.find, string.sub, table.concat
local validName, dec = Engine.validName, Engine.dec

local MAX_INT = 9007199254740991 -- 2^53 - 1
local MAX_SPIN = 2147483648 -- 2^31
local MAX_STAKE = 1000000
local MAX_TOKENS = 1000000000
local MAX_A = 10000
local MAX_CONTRIBS = 8
local MAX_LINE = 120

-- Field validators ---------------------------------------------------------------------------

local function isInt(v, lo, hi)
	return type(v) == "number" and v % 1 == 0 and v >= lo and v <= hi
end

local function isHex(v, len)
	return type(v) == "string" and #v == len and not find(v, "[^0-9a-f]")
end

-- The settings line as stored in a purchase: 1..120 bytes, no "|" and no byte below 32.
-- Whether it parses is a rule (bad_settings), not a matter of form.
local function isLine(v)
	return type(v) == "string" and #v >= 1 and #v <= MAX_LINE and not find(v, "[%z\1-\31|]")
end

local function isStatus(v)
	return v == "ok" or v == "void"
end

-- Field lists per type, in text order: name and check.
local FIELDS = {
	B = {
		{ "buyId", function(v) return isHex(v, 16) end },
		{ "officer", validName },
		{ "tokens", function(v) return isInt(v, 1, MAX_TOKENS) end },
		{ "commit", function(v) return isHex(v, 64) end },
		{ "seed", function(v) return isHex(v, 32) end },
		{ "nonce", function(v) return isHex(v, 32) end },
		{ "time", function(v) return isInt(v, 0, MAX_INT) end },
		{ "line", isLine },
	},
	S = {
		{ "n", function(v) return isInt(v, 1, MAX_SPIN) end },
		{ "stake", function(v) return isInt(v, 1, MAX_STAKE) end },
		{ "A", function(v) return isInt(v, 0, MAX_A) end },
		{ "status", isStatus },
		{ "contribs", function(v) return Engine.parseContribs(v) ~= nil end },
	},
	G = {
		{ "n", function(v) return isInt(v, 1, MAX_SPIN) end },
		{ "g", function(v) return isInt(v, 1, MAX_INT) end },
		{ "A", function(v) return isInt(v, 0, MAX_A) end },
		{ "status", isStatus },
		{ "contribs", function(v) return Engine.parseContribs(v) ~= nil end },
	},
	P = {
		{ "payId", function(v) return isHex(v, 16) end },
		{ "officer", validName },
		{ "amount", function(v) return isInt(v, 1, MAX_INT) end },
		{ "balanceAfter", function(v) return isInt(v, 0, MAX_INT) end },
		{ "time", function(v) return isInt(v, 0, MAX_INT) end },
	},
}

local NUMERIC = {
	tokens = true, time = true, n = true, stake = true, A = true, g = true, amount = true, balanceAfter = true,
}

local function wellFormed(entry)
	if type(entry) ~= "table" then
		return false
	end
	local fields = FIELDS[entry.type]
	if not fields then
		return false
	end
	for _, f in ipairs(fields) do
		if not f[2](entry[f[1]]) then
			return false
		end
	end
	return true
end

-- Text forms ---------------------------------------------------------------------------------

function Ledger.encode(entry)
	if not wellFormed(entry) then
		return nil, "bad_entry"
	end
	local parts = { entry.type }
	for i, f in ipairs(FIELDS[entry.type]) do
		local v = entry[f[1]]
		parts[i + 1] = NUMERIC[f[1]] and dec(v) or v
	end
	return concat(parts, "|")
end

-- Canonical decimal: "0" or [1-9][0-9]*, at most 16 digits.
local function parseNumber(text)
	if text ~= "0" and not find(text, "^[1-9]%d*$") then
		return nil
	end
	if #text > 16 then
		return nil
	end
	return tonumber(text)
end

function Ledger.decode(text)
	if type(text) ~= "string" then
		return nil, "bad_entry"
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
	local fields = FIELDS[parts[1]]
	if not fields or #parts ~= #fields + 1 then
		return nil, "bad_entry"
	end
	local entry = { type = parts[1] }
	for i, f in ipairs(fields) do
		local raw = parts[i + 1]
		if NUMERIC[f[1]] then
			local n = parseNumber(raw)
			if n == nil then
				return nil, "bad_entry"
			end
			entry[f[1]] = n
		else
			entry[f[1]] = raw
		end
	end
	if not wellFormed(entry) then
		return nil, "bad_entry"
	end
	return entry
end

-- State --------------------------------------------------------------------------------------

function Ledger.start(guild, player)
	return {
		guild = guild,
		player = player,
		head = Sha256.hex("GS1|KONTO|" .. guild .. "|" .. player),
		count = 0,
		anchors = 0,
		balance = 0,
		n = 0,
		g = 0,
		pending = 0,
		buyIds = {},
		payIds = {},
	}
end

local function copySet(s)
	local c = {}
	for k, v in pairs(s) do c[k] = v end
	return c
end

function Ledger.copy(state)
	local c = {}
	for k, v in pairs(state) do c[k] = v end
	c.buyIds = copySet(state.buyIds)
	c.payIds = copySet(state.payIds)
	return c
end

function Ledger.shortHead(state)
	return sub(state.head, 1, 32)
end

-- Contributions against the level of the settings in force (spec "Contributions per level").
local function checkContribs(state, entry, kind, g)
	local s = state.settings
	local list = Engine.parseContribs(entry.contribs)
	local count, ok = #list, entry.status == "ok"
	if count > MAX_CONTRIBS then
		return false
	end
	if s.L == 0 then
		return ok and entry.A == 0 and count == 0
	end
	for _, c in ipairs(list) do
		if c.name == state.player then
			return false
		end
	end
	if s.L == 1 then
		if entry.A < 1 or entry.A > MAX_A then
			return false
		end
		if ok and count < s.W then
			return false
		end
		for _, c in ipairs(list) do
			local lot = Engine.lot(c.name, state.player, kind, entry.n, g)
			if not Engine.drawn(lot, entry.A, s.Z) then
				return false
			end
		end
		return true
	end
	-- Level 2
	if entry.A ~= 0 then
		return false
	end
	return not ok or count >= 1
end

local function gambleOpen(settings, win)
	return settings.G > 0 and win > 0 and (settings.C == 0 or 2 * win <= settings.C)
end

-- Each rule function returns the changes to apply (a table of new state fields) plus the info,
-- or nil, code. Nothing touches the state until every check has passed.
local RULES = {}

function RULES.B(state, e)
	if Engine.commit(e.seed) ~= e.commit then
		return nil, "bad_commit"
	end
	if state.buyIds[e.buyId] then
		return nil, "dup_buy"
	end
	local settings = Settings.parse(e.line)
	if not settings then
		return nil, "bad_settings"
	end
	local K = Engine.purchaseKey(e.buyId, e.seed, e.nonce)
	local balance = state.balance + e.tokens
	return {
		balance = balance, pending = 0, K = K, keyed = Sha256.keyed(K), settings = settings,
		line = e.line, tbl = Tables.get(settings.T), anchors = state.anchors + 1,
	}, { type = "B", balance = balance, pending = 0 }
end

function RULES.S(state, e)
	local s = state.settings
	if e.n ~= state.n + 1 then
		return nil, "bad_number"
	end
	local allowed = false
	for _, v in ipairs(s.E) do
		if v == e.stake then allowed = true end
	end
	-- A lines table (T2) needs a stake that splits evenly over its lines.
	local lineCount = state.tbl.lineCount
	if not allowed or (lineCount and e.stake % lineCount ~= 0) then
		return nil, "bad_stake"
	end
	if not checkContribs(state, e, "spin", 0) then
		return nil, "bad_contribs"
	end
	if e.status == "void" then
		return { n = e.n, g = 0, pending = 0 }, { type = "S", balance = state.balance, pending = 0 }
	end
	if state.balance < e.stake then
		return nil, "no_funds"
	end
	local tbl = state.tbl
	if tbl.kind == "lines" then
		local round = Engine.round(state.keyed, e.n, e.contribs, tbl, e.stake, s.C)
		local win = round.win
		local balance = state.balance - e.stake + win
		local pending = gambleOpen(s, win) and win or 0
		return { n = e.n, g = 0, balance = balance, pending = pending },
			{ type = "S", round = round, multiplier = win / e.stake, win = win, balance = balance, pending = pending }
	end
	local s1, s2, s3 = Engine.spin(state.keyed, e.n, e.contribs, tbl)
	local multiplier = Tables.multiplier(tbl, s1, s2, s3)
	local win = Tables.win(tbl, e.stake, s.C, s1, s2, s3)
	local balance = state.balance - e.stake + win
	local pending = gambleOpen(s, win) and win or 0
	return { n = e.n, g = 0, balance = balance, pending = pending },
		{ type = "S", stops = { s1, s2, s3 }, multiplier = multiplier, win = win, balance = balance, pending = pending }
end

function RULES.G(state, e)
	local s = state.settings
	if e.n ~= state.n or e.g ~= state.g + 1 or e.g > s.G or state.pending <= 0 then
		return nil, "bad_gamble"
	end
	if not checkContribs(state, e, "gam", e.g) then
		return nil, "bad_contribs"
	end
	if e.status == "void" then
		return { g = e.g }, { type = "G", balance = state.balance, pending = state.pending }
	end
	local won = Engine.gamble(state.keyed, e.n, e.g, e.contribs)
	local balance, pending
	if won then
		balance = state.balance + state.pending
		pending = 2 * state.pending
		if e.g == s.G or (s.C > 0 and 2 * pending > s.C) then
			pending = 0
		end
	else
		balance = state.balance - state.pending
		pending = 0
	end
	return { g = e.g, balance = balance, pending = pending },
		{ type = "G", won = won, balance = balance, pending = pending }
end

function RULES.P(state, e)
	if state.payIds[e.payId] then
		return nil, "dup_pay"
	end
	if e.amount < 1 or e.amount > state.balance then
		return nil, "no_funds"
	end
	if e.balanceAfter ~= state.balance - e.amount then
		return nil, "bad_balance"
	end
	return { balance = e.balanceAfter, pending = 0, anchors = state.anchors + 1 },
		{ type = "P", balance = e.balanceAfter, pending = 0 }
end

function Ledger.apply(state, entry)
	if not wellFormed(entry) then
		return nil, "bad_entry"
	end
	if entry.type ~= "B" and not state.settings then
		return nil, "no_purchase"
	end
	local changes, info = RULES[entry.type](state, entry)
	if not changes then
		return nil, info
	end
	local head = Sha256.hex(state.head .. "|" .. Ledger.encode(entry))
	for k, v in pairs(changes) do
		state[k] = v
	end
	if entry.type == "B" then
		state.buyIds[entry.buyId] = true
	elseif entry.type == "P" then
		state.payIds[entry.payId] = true
	end
	state.head = head
	state.count = state.count + 1
	info.head = head
	return info
end

-- entries are tables or text forms. Returns state, or nil, code, index of the failing entry.
function Ledger.replay(guild, player, entries, onStep)
	local state = Ledger.start(guild, player)
	for i, e in ipairs(entries) do
		if type(e) == "string" then
			local d, code = Ledger.decode(e)
			if not d then
				return nil, code, i
			end
			e = d
		end
		local info, code = Ledger.apply(state, e)
		if not info then
			return nil, code, i
		end
		if onStep then
			onStep(i)
		end
	end
	return state
end
