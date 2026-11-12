local t, ns = ...
local Verify, Ledger, Engine, Tables = ns.Verify, ns.Ledger, ns.Engine, ns.Tables

-- Verify.run (docs/core-spec.md section 7). Accounts are built with Ledger and Engine; every
-- manipulation below changes exactly one thing of an otherwise valid account.

local GUILD, PLAYER, OFF = "Guild", "Alice", "Officer"
local NONCE = "fedcba9876543210fedcba9876543210"
local T1 = Tables.get("T1")

local function secretOf(name)
	local sum = 0
	for i = 1, #name do sum = sum + name:byte(i) * i end
	return string.format("%032x", sum)
end

-- Account builder -----------------------------------------------------------------------------

local Acc = {}
Acc.__index = Acc

local function account()
	return setmetatable({ entries = {}, st = Ledger.start(GUILD, PLAYER), audit = {}, known = {}, infos = {} }, Acc)
end

function Acc:add(e)
	local info, code = Ledger.apply(self.st, e)
	if not info then error("setup entry " .. (#self.entries + 1) .. " failed: " .. tostring(code), 2) end
	self.entries[#self.entries + 1] = e
	self.infos[#self.infos + 1] = info
	if e.type == "B" or e.type == "P" then self.anchorHead = Ledger.shortHead(self.st) end
	return info
end

function Acc:buy(i, line, tokens, officer)
	local seed = string.format("%032x", i)
	local e = {
		type = "B", buyId = string.format("%016x", i), officer = officer or OFF, tokens = tokens or 100000,
		commit = Engine.commit(seed), seed = seed, nonce = NONCE, time = 1700000000 + i, line = line or "GSLOTS1",
	}
	self.known[e.buyId] = true
	return self:add(e)
end

function Acc:pay(i, amount)
	local e = { type = "P", payId = string.format("%016x", 1000000 + i), officer = OFF, amount = amount,
		balanceAfter = self.st.balance - amount, time = 1700100000 + i }
	self.known[e.payId] = true
	return self:add(e)
end

-- Contributions of `names` for the next spin/step, written into the audit as answered rows.
function Acc:contribs(names, kind, n, g, amount)
	local list = {}
	local head = Ledger.shortHead(self.st)
	if type(names) == "function" then names = names(kind, n, g) end
	for _, name in ipairs(names or {}) do
		local value = Engine.witnessValue(secretOf(name), PLAYER, kind, n, g, amount, head)
		list[#list + 1] = { name = name, value = value, lot = Engine.lot(name, PLAYER, kind, n, g) }
		self.audit[#self.audit + 1] = { kind = kind, n = n, g = g, witness = name, value = value, answered = true }
	end
	return Engine.contribs(list)
end

-- opts: stake = number or function(n); witnesses = names; A; status; gamble = take every possible step.
function Acc:spin(opts)
	opts = opts or {}
	local n = self.st.n + 1
	local stake = opts.stake or 10
	if type(stake) == "function" then stake = stake(n) end
	local status = opts.status or "ok"
	local c = self:contribs(opts.witnesses, "spin", n, 0, stake)
	local info = self:add({ type = "S", n = n, stake = stake, A = opts.A or 0, status = status, contribs = c })
	if opts.gamble then
		while self.st.pending > 0 do self:gam(opts) end
	end
	return info
end

function Acc:gam(opts)
	opts = opts or {}
	local n, g = self.st.n, self.st.g + 1
	local c = self:contribs(opts.witnesses, "gam", n, g, self.st.pending)
	return self:add({ type = "G", n = n, g = g, A = opts.A or 0, status = opts.gstatus or "ok", contribs = c })
end

function Acc:spins(count, opts)
	for _ = 1, count do self:spin(opts) end
	return self
end

function Acc:input(over)
	local input = {
		guild = GUILD, player = PLAYER, entries = self.entries, amount = 1,
		anchor = { anchors = self.st.anchors, head = self.anchorHead },
		known = self.known, audit = self.audit,
		isOfficer = function() return true end,
	}
	for k, v in pairs(over or {}) do
		if v == "nil" then input[k] = nil else input[k] = v end
	end
	return input
end

local function copyEntry(e)
	local c = {}
	for k, v in pairs(e) do c[k] = v end
	return c
end

-- Findings with this code: list of findings.
local function findings(report, code)
	local out = {}
	for _, f in ipairs(report.findings) do
		if f.code == code then out[#out + 1] = f end
	end
	return out
end

local function expectOnly(report, check, level, code, index, msg)
	msg = msg or code
	t.eq(#report.findings, 1, msg .. ": number of findings (first: " ..
		tostring(report.findings[1] and report.findings[1].code) .. ")")
	local f = report.findings[1]
	t.eq(f.code, code, msg .. ": code")
	t.eq(f.check, check, msg .. ": check")
	t.eq(f.level, level, msg .. ": level")
	t.eq(f.index, index, msg .. ": index")
	t.eq(report.light, level, msg .. ": light")
end

-- Clean account -------------------------------------------------------------------------------

t.test("a clean level-0 account is green with the replayed balance", function()
	local acc = account()
	acc:buy(1, "GSLOTS1;L=0;E=10,50,100")
	acc:spins(12, { gamble = true })
	local report = Verify.run(acc:input({ amount = 50 }))
	t.eq(#report.findings, 0, "no findings")
	t.eq(report.light, "green")
	t.eq(report.balance, acc.st.balance)
	t.eq(report.state.head, acc.st.head)
	t.eq(report.unconfirmed, 0)
end)

-- A level-0 account: purchase, 5 spins, payout, purchase, 5 spins.
-- Entry indexes: B=1, P=7, B=8.
local function twoBuys()
	local acc = account()
	acc:buy(1, "GSLOTS1;L=0")
	acc:spins(5)
	acc:pay(1, 100)
	acc:buy(2, "GSLOTS1;L=0")
	acc:spins(5)
	return acc
end

local function headsOf(acc)
	local heads = {}
	local st = Ledger.start(GUILD, PLAYER)
	for i, e in ipairs(acc.entries) do
		Ledger.apply(st, e)
		heads[i] = Ledger.shortHead(st)
	end
	return heads
end

-- Check 1: anchor --------------------------------------------------------------------------------

t.test("check 1: an anchor on an earlier purchase or payout matches", function()
	local acc = twoBuys()
	local heads = headsOf(acc)
	t.eq(#Verify.run(acc:input({ anchor = { anchors = 2, head = heads[7] } })).findings, 0, "anchor at the payout")
	t.eq(#Verify.run(acc:input({ anchor = { anchors = 1, head = heads[1] } })).findings, 0, "anchor at the first purchase")
	local r = Verify.run(acc:input({ anchor = { anchors = 1, head = heads[7] } }))
	expectOnly(r, 1, "red", "anchor_mismatch", 1, "head of another entry")
end)

t.test("check 1: a wrong head or a missing anchor entry is red anchor_mismatch", function()
	local acc = twoBuys()
	local r = Verify.run(acc:input({ anchor = { anchors = 3, head = string.rep("0", 32) } }))
	expectOnly(r, 1, "red", "anchor_mismatch", 8, "wrong head")
	r = Verify.run(acc:input({ anchor = { anchors = 4, head = Ledger.shortHead(acc.st) } }))
	expectOnly(r, 1, "red", "anchor_mismatch", nil, "account has fewer B/P entries")
end)

t.test("check 1: no anchor is yellow no_anchor", function()
	local acc = account()
	acc:buy(1, "GSLOTS1;L=0")
	acc:spins(3)
	expectOnly(Verify.run(acc:input({ anchor = "nil" })), 1, "yellow", "no_anchor", nil)
end)

-- Check 2: purchases -----------------------------------------------------------------------------

t.test("check 2: the officer of a purchase", function()
	local acc = twoBuys()
	local asked = {}
	local function isOfficer(result)
		return function(name, time)
			asked[#asked + 1] = name .. "@" .. tostring(time)
			return result
		end
	end
	local r = Verify.run(acc:input({ isOfficer = isOfficer(false) }))
	t.eq(#findings(r, "not_officer"), 2, "two purchases")
	t.eq(findings(r, "not_officer")[1].check, 2)
	t.eq(findings(r, "not_officer")[1].level, "red")
	t.eq(findings(r, "not_officer")[1].index, 1)
	t.eq(findings(r, "not_officer")[2].index, 8)
	t.eq(#r.findings, 2, "payouts are not asked about")
	t.eq(asked[1], OFF .. "@1700000001", "asked with the purchase time")
	r = Verify.run(acc:input({ isOfficer = isOfficer(nil) }))
	t.eq(#findings(r, "officer_unknown"), 2)
	t.eq(findings(r, "officer_unknown")[1].level, "yellow")
	t.eq(findings(r, "officer_unknown")[1].check, 2)
	t.eq(r.light, "yellow")
	-- Only the second purchase by a non-officer.
	r = Verify.run(acc:input({ isOfficer = function(_, time) return time ~= 1700000002 end }))
	expectOnly(r, 2, "red", "not_officer", 8)
end)

t.test("check 2: a bad commit or a reused purchase id fails the replay", function()
	local acc = account()
	acc:buy(1, "GSLOTS1;L=0")
	acc:spins(2)
	local entries = { acc.entries[1], acc.entries[2], acc.entries[3] }
	local bad = copyEntry(acc.entries[1])
	bad.commit = string.rep("a", 64)
	bad.buyId = "00000000000000ff"
	entries[4] = bad
	local anchor = { anchors = 1, head = headsOf(acc)[1] }
	expectOnly(Verify.run(acc:input({ entries = entries, anchor = anchor })), 2, "red", "bad_commit", 4)
	entries[4] = acc.entries[1]
	local r = Verify.run(acc:input({ entries = entries, anchor = anchor }))
	expectOnly(r, 2, "red", "dup_buy", 4)
	t.eq(r.balance, nil, "no balance after a failed replay")
	t.eq(r.state, nil, "no state after a failed replay")
end)

-- Check 3: known ---------------------------------------------------------------------------------

t.test("check 3: an unknown purchase covered by the anchor is yellow not_seen", function()
	local acc = twoBuys()
	acc.known["0000000000000001"] = nil
	expectOnly(Verify.run(acc:input()), 3, "yellow", "not_seen", 1)
end)

t.test("check 3: an unknown payout after the anchor is red unconfirmed", function()
	local acc = twoBuys()
	acc.known[acc.entries[7].payId] = nil
	local heads = headsOf(acc)
	expectOnly(Verify.run(acc:input({ anchor = { anchors = 1, head = heads[1] } })), 3, "red", "unconfirmed", 7)
	expectOnly(Verify.run(acc:input({ anchor = { anchors = 2, head = heads[7] } })), 3, "yellow", "not_seen", 7,
		"covered when the anchor includes it")
end)

t.test("check 3: without an anchor or with a wrong one every unknown entry is red", function()
	local acc = twoBuys()
	acc.known["0000000000000001"] = nil
	local r = Verify.run(acc:input({ anchor = "nil" }))
	t.eq(#r.findings, 2)
	t.eq(findings(r, "unconfirmed")[1].level, "red")
	t.eq(findings(r, "unconfirmed")[1].index, 1)
	t.eq(findings(r, "no_anchor")[1].level, "yellow")
	r = Verify.run(acc:input({ anchor = { anchors = 3, head = string.rep("0", 32) } }))
	t.eq(#findings(r, "unconfirmed"), 1, "a wrong anchor covers nothing")
	t.eq(r.light, "red")
	r = Verify.run(acc:input({ known = "nil" }))
	t.eq(#findings(r, "not_seen"), 3, "known missing: nothing is known")
end)

-- Check 4: chain ---------------------------------------------------------------------------------

-- Index of the entry of spin n (g = 0) or gamble step g of spin n.
local function indexOf(acc, n, g)
	for i, e in ipairs(acc.entries) do
		if (g == 0 and e.type == "S" and e.n == n) or (g > 0 and e.type == "G" and e.n == n and e.g == g) then
			return i
		end
	end
end

local function gambleAccount()
	local acc = account()
	acc:buy(1, "GSLOTS1;L=0;G=3")
	acc:spins(30, { gamble = true })
	return acc
end

t.test("check 4: heard requests on the chain are fine", function()
	local acc = gambleAccount()
	local heads = headsOf(acc)
	local i = indexOf(acc, 7, 0)
	t.eq(#Verify.run(acc:input({ heard = { n = 7, g = 0, head = heads[i - 1] } })).findings, 0, "spin")
	local step
	for j, e in ipairs(acc.entries) do
		if e.type == "G" then step = j break end
	end
	t.ok(step, "account has a gamble step")
	local e = acc.entries[step]
	t.eq(#Verify.run(acc:input({ heard = { n = e.n, g = e.g, head = heads[step - 1] } })).findings, 0, "gamble step")
end)

t.test("check 4: a different head is red rewritten", function()
	local acc = gambleAccount()
	local heads = headsOf(acc)
	local i = indexOf(acc, 7, 0)
	expectOnly(Verify.run(acc:input({ heard = { n = 7, g = 0, head = heads[i] } })), 4, "red", "rewritten", i)
end)

t.test("check 4: a request beyond the account is yellow incomplete", function()
	local acc = gambleAccount()
	expectOnly(Verify.run(acc:input({ heard = { n = 31, g = 0, head = string.rep("0", 32) } })),
		4, "yellow", "incomplete", nil, "next spin")
	local last = acc.entries[#acc.entries]
	expectOnly(Verify.run(acc:input({ heard = { n = last.n, g = (last.g or 0) + 1, head = string.rep("0", 32) } })),
		4, "yellow", "incomplete", nil, "next step of the last spin")
end)

t.test("check 4: a step missing inside the account is red rewritten", function()
	local acc = gambleAccount()
	-- A spin followed directly by the next spin has no step 1.
	local n
	for i = 2, #acc.entries - 1 do
		local e = acc.entries[i]
		if e.type == "S" and acc.entries[i + 1].type == "S" then n = e.n break end
	end
	expectOnly(Verify.run(acc:input({ heard = { n = n, g = 1, head = string.rep("0", 32) } })),
		4, "red", "rewritten", nil)
end)

-- Checks 5 and 6: spins and replay -----------------------------------------------------------------

t.test("checks 5/6: a broken spin stops the replay; earlier findings stay", function()
	local acc = account()
	acc:buy(1, "GSLOTS1;L=0")
	acc:spins(10)
	local entries = {}
	for i, e in ipairs(acc.entries) do entries[i] = e end
	entries[6] = copyEntry(entries[6])
	entries[6].stake = 20
	entries[8] = "garbage" -- never reached
	local steps = {}
	local r = Verify.run(acc:input({ entries = entries, isOfficer = function() return nil end,
		onStep = function(i) steps[#steps + 1] = i end }))
	t.eq(#r.findings, 2)
	t.eq(findings(r, "officer_unknown")[1].index, 1, "finding before the failure stays")
	local f = findings(r, "bad_stake")[1]
	t.eq(f.check, 5) t.eq(f.level, "red") t.eq(f.index, 6)
	t.eq(r.light, "red")
	t.eq(r.balance, nil) t.eq(r.state, nil) t.eq(r.lookahead, nil)
	t.eq(#steps, 5, "onStep for the entries before the failure")
end)

t.test("check 6: a payout with a wrong balance and an undecodable entry", function()
	local acc = twoBuys()
	local entries = {}
	for i, e in ipairs(acc.entries) do entries[i] = Ledger.encode(e) end
	t.eq(#Verify.run(acc:input({ entries = entries })).findings, 0, "text forms verify like tables")
	local p = copyEntry(acc.entries[7])
	p.balanceAfter = p.balanceAfter + 1
	entries[7] = Ledger.encode(p)
	local anchor = { anchors = 1, head = headsOf(acc)[1] }
	expectOnly(Verify.run(acc:input({ entries = entries, anchor = anchor })), 6, "red", "bad_balance", 7)
	entries[7] = "P|nonsense"
	expectOnly(Verify.run(acc:input({ entries = entries, anchor = anchor })), 6, "red", "bad_entry", 7)
	entries[7] = 42
	expectOnly(Verify.run(acc:input({ entries = entries, anchor = anchor })), 6, "red", "bad_entry", 7)
	entries[7] = { type = "S", n = "x" }
	expectOnly(Verify.run(acc:input({ entries = entries, anchor = anchor })), 5, "red", "bad_entry", 7)
end)

t.test("check 5: a spin before any purchase", function()
	local r = Verify.run({ guild = GUILD, player = PLAYER, entries = { "S|1|10|0|ok|" } })
	t.eq(findings(r, "no_purchase")[1].index, 1)
	t.eq(findings(r, "no_purchase")[1].check, 5)
end)

t.test("check 5: at level 2 a contributor who is not an officer is red witness_not_officer", function()
	local acc = account()
	acc:buy(1, "GSLOTS1;L=2")
	acc:spins(3, { witnesses = { "Wit1" } })
	acc:spins(2, { witnesses = { "Wit1", "Wit2" } })
	local r = Verify.run(acc:input({ isOfficer = function(name) return name ~= "Wit2" end }))
	local f = findings(r, "witness_not_officer")
	t.eq(#f, 2) t.eq(#r.findings, 2)
	t.eq(f[1].check, 5) t.eq(f[1].level, "red") t.eq(f[1].index, 5) t.eq(f[2].index, 6)
	r = Verify.run(acc:input({ isOfficer = function(name) if name == OFF then return true end end }))
	t.eq(#r.findings, 0, "an unknown roster is no finding for witnesses")
end)

t.test("check 5: at level 1 witnesses are not asked about", function()
	local acc = account()
	acc:buy(1, "GSLOTS1;L=1;W=2")
	acc:spins(3, { witnesses = { "Wit1", "Wit2" }, A = 3 })
	t.eq(#Verify.run(acc:input({ isOfficer = function(name) return name == OFF end })).findings, 0)
end)

-- Check 7: audit ---------------------------------------------------------------------------------

-- The first `count` names "Zeuge<k>" drawn by the lottery for A = 100, Z = 7 (W = 2).
local function drawnWitnesses(count)
	return function(kind, n, g)
		local out = {}
		for k = 1, 100000 do
			local name = "Zeuge" .. k
			if Engine.drawn(Engine.lot(name, PLAYER, kind, n, g), 100, 7) then
				out[#out + 1] = name
				if #out == count then return out end
			end
		end
		error("no witnesses found")
	end
end

local function level1()
	local acc = account()
	acc:buy(1, "GSLOTS1;L=1;W=2;G=2")
	acc:spins(10, { witnesses = drawnWitnesses(3), A = 100, gamble = true })
	return acc
end

local function copyAudit(audit)
	local out = {}
	for i, row in ipairs(audit) do out[i] = copyEntry(row) end
	return out
end

t.test("check 7: a level-1 account with lottery witnesses and a full audit is green", function()
	local acc = level1()
	local r = Verify.run(acc:input())
	t.eq(#r.findings, 0)
	t.eq(r.unconfirmed, 0)
	t.ok(#acc.audit >= 30, "three rows per entry")
end)

t.test("check 7: a different value is red witness_mismatch", function()
	local acc = level1()
	local audit = copyAudit(acc.audit)
	local row = audit[7]
	row.value = "0123456789abcdef"
	local i = indexOf(acc, row.n, row.g)
	expectOnly(Verify.run(acc:input({ audit = audit })), 7, "red", "witness_mismatch", i)
end)

t.test("check 7: an answer missing from an ok entry is yellow omitted", function()
	local acc = level1()
	local audit = copyAudit(acc.audit)
	audit[#audit + 1] = { kind = "spin", n = 4, g = 0, witness = "Late", value = "0123456789abcdef", answered = true }
	audit[#audit + 1] = { kind = "spin", n = 5, g = 0, witness = "Slow", answered = false }
	expectOnly(Verify.run(acc:input({ audit = audit })), 7, "yellow", "omitted", indexOf(acc, 4, 0))
end)

t.test("check 7: a void entry with enough answers is yellow void_with_answers", function()
	local acc = account()
	acc:buy(1, "GSLOTS1;L=1;W=2")
	acc:spin({ witnesses = { "Wit1", "Wit2" }, A = 3 })
	acc:spin({ status = "void", witnesses = { "Wit1" }, A = 3 })
	acc:spin({ status = "void", A = 3 })
	local audit = copyAudit(acc.audit)
	t.eq(#Verify.run(acc:input({ audit = audit })).findings, 0, "one answer is too few at W = 2")
	audit[#audit + 1] = { kind = "spin", n = 2, g = 0, witness = "Wit2", answered = true }
	expectOnly(Verify.run(acc:input({ audit = audit })), 7, "yellow", "void_with_answers", 3)
	audit[#audit + 1] = { kind = "spin", n = 3, g = 0, witness = "Wit2", answered = false }
	audit[#audit + 1] = { kind = "spin", n = 3, g = 0, witness = "Wit3", answered = true }
	t.eq(#Verify.run(acc:input({ audit = audit })).findings, 1, "spin 3 has one answer")

	-- Level 2 needs one.
	acc = account()
	acc:buy(1, "GSLOTS1;L=2")
	acc:spin({ witnesses = { "Wit1" } })
	acc:spin({ status = "void" })
	audit = copyAudit(acc.audit)
	t.eq(#Verify.run(acc:input({ audit = audit })).findings, 0)
	audit[#audit + 1] = { kind = "spin", n = 2, g = 0, witness = "Wit1", answered = true }
	expectOnly(Verify.run(acc:input({ audit = audit })), 7, "yellow", "void_with_answers", 3)
end)

t.test("check 7: unconfirmed counts ok entries with a contribution nobody confirmed", function()
	local acc = level1()
	local okEntries = 0
	for _, e in ipairs(acc.entries) do
		if e.type ~= "B" then okEntries = okEntries + 1 end
	end
	local r = Verify.run(acc:input({ audit = "nil" }))
	t.eq(r.unconfirmed, okEntries, "no audit")
	t.eq(#r.findings, 0, "a missing audit is no finding")
	-- Drop one row and strip the value of another (in a different entry).
	local audit = copyAudit(acc.audit)
	table.remove(audit, 1)
	audit[10].value = nil
	r = Verify.run(acc:input({ audit = audit }))
	t.eq(r.unconfirmed, 2)
	t.eq(#r.findings, 0)
	t.eq(Verify.run(acc:input()).unconfirmed, 0)
end)

-- Check 8: amount --------------------------------------------------------------------------------

t.test("check 8: more than the balance is red amount_too_high", function()
	local acc = twoBuys()
	t.eq(#Verify.run(acc:input({ amount = acc.st.balance })).findings, 0, "the whole balance")
	expectOnly(Verify.run(acc:input({ amount = acc.st.balance + 1 })), 8, "red", "amount_too_high", nil)
	t.eq(#Verify.run(acc:input({ amount = "nil" })).findings, 0, "no amount asked")
end)

-- Luck index -------------------------------------------------------------------------------------

-- Uncapped T1 statistics from the spec (section 4); the variance as an exact fraction from the
-- Python reference (tools/ref, Fraction arithmetic).
local MU = 4594 / 4913
local VAR = 532423222 / 24137569

t.test("luck: sums of a small account written out by hand", function()
	-- Purchase 8, stakes 10, 50, 100, 50, 10: multipliers 0, 3, 1, 0, 0 (wins 0, 150, 100, 0, 0).
	local acc = account()
	acc:buy(8, "GSLOTS1;G=0")
	local stakes = { 10, 50, 100, 50, 10 }
	acc:spins(5, { stake = function(n) return stakes[n] end })
	local luck = Verify.run(acc:input()).luck
	t.eq(luck.spins, 5) t.eq(luck.steps, 0) t.eq(luck.maxWin, 150)
	-- sum e*(m - mu) = 150 + 100 - 220 mu; sum e^2 var = (100 + 2500 + 10000 + 2500 + 100) var
	t.near(luck.total.z, (250 - 220 * MU) / math.sqrt(15200 * VAR), 1e-12, "total")
	-- ebar = 44; e - ebar = -34, 6, 56, 6, -34; sum (e - ebar) m = 6*3 + 56*1; sum (e - ebar) = 0
	t.near(luck.timing.z, 74 / math.sqrt((1156 + 36 + 3136 + 36 + 1156) * VAR), 1e-12, "timing")
	t.eq(luck.total.enough, false) t.eq(luck.total.light, "green")
	t.eq(luck.risk, nil, "no steps")
end)

t.test("luck: two purchases with different caps, cross-checked with the Python reference", function()
	local acc = account()
	local cycle = function(n) return ({ 10, 50, 100 })[n % 3 + 1] end
	acc:buy(3, "GSLOTS1;G=0")
	acc:spins(15, { stake = cycle })
	acc:pay(1, 100)
	acc:buy(4, "GSLOTS1;C=500;G=2")
	acc:spins(25, { stake = cycle, gamble = true })
	acc:buy(5, "GSLOTS1;G=3")
	acc:spins(28, { stake = cycle, gamble = true })
	t.eq(#acc.entries, 87, "same account as the Python run")
	local r = Verify.run(acc:input())
	t.eq(r.balance, 299340)
	-- Values printed by a Python script replaying the entry texts with tools/ref/gsref.py and
	-- summing with Fraction statistics per (stake, cap).
	t.eq(r.luck.spins, 53) t.eq(r.luck.steps, 15) t.eq(r.luck.maxWin, 500)
	t.near(r.luck.total.z, 0.301781112697972, 1e-12, "total")
	t.near(r.luck.timing.z, 0.797216240546794, 1e-12, "timing")
	t.near(r.luck.risk.z, 0.774596669241483, 1e-12, "risk")
	t.eq(r.luck.total.enough, true) t.eq(r.luck.risk.enough, true)
	t.eq(r.luck.total.light, "green")
end)

t.test("luck: a capped account uses the capped statistics", function()
	-- With C = 100 and stake 100 every win is capped to 100: m is 0 or 1, mu = hit = 7820/39304
	-- (= 115/578), var = hit * (1 - hit).
	local acc = account()
	acc:buy(1, "GSLOTS1;E=100;C=100")
	acc:spins(30, { stake = 100 })
	local wins = 0
	for _, info in ipairs(acc.infos) do
		if info.type == "S" and info.win > 0 then
			t.eq(info.win, 100, "capped win")
			wins = wins + 1
		end
	end
	local hit = 115 / 578
	local r = Verify.run(acc:input())
	t.near(r.luck.total.z, (wins - 30 * hit) / math.sqrt(30 * hit * (1 - hit)), 1e-12, "total")
	t.eq(r.luck.timing, nil, "all stakes equal")
	t.eq(r.luck.maxWin, wins > 0 and 100 or 0)
end)

t.test("luck: only spins after the last payout count", function()
	local acc = account()
	acc:buy(8, "GSLOTS1;G=0")
	acc:spins(40)
	acc:pay(1, 10)
	local r = Verify.run(acc:input())
	t.eq(r.luck.spins, 0) t.eq(r.luck.maxWin, 0)
	t.eq(r.luck.total.z, nil, "no spins") t.eq(r.luck.total.light, "green")
	t.eq(r.luck.timing, nil) t.eq(r.luck.risk, nil)
	local stakes = { 10, 50, 100, 50, 10 }
	acc:spins(5, { stake = function(n) return stakes[n - 40] end })
	r = Verify.run(acc:input())
	t.eq(r.luck.spins, 5)
	local maxWin = 0
	for i = #acc.infos - 4, #acc.infos do maxWin = math.max(maxWin, acc.infos[i].win) end
	t.eq(r.luck.maxWin, maxWin)
	t.ok(r.luck.total.z ~= nil and r.luck.timing ~= nil)
end)

t.test("luck: enough from 30 spins and 10 steps", function()
	local acc = account()
	acc:buy(1, "GSLOTS1;G=1")
	acc:spins(29)
	local r = Verify.run(acc:input())
	t.eq(r.luck.spins, 29) t.eq(r.luck.total.enough, false)
	acc:spins(1)
	r = Verify.run(acc:input())
	t.eq(r.luck.spins, 30) t.eq(r.luck.total.enough, true)

	acc = account()
	acc:buy(1, "GSLOTS1;G=1")
	acc:spins(120, { gamble = true })
	local steps, cut = 0, {}
	for i, e in ipairs(acc.entries) do
		if e.type == "G" then
			steps = steps + 1
			cut[steps] = i
		end
	end
	t.ok(steps >= 10, "enough steps in the account")
	local function prefix(k)
		local out = {}
		for i = 1, cut[k] do out[i] = acc.entries[i] end
		return Verify.run(acc:input({ entries = out })).luck.risk
	end
	t.eq(prefix(9).enough, false, "9 steps") t.eq(prefix(9).light, "green")
	t.eq(prefix(10).enough, true, "10 steps")
end)

-- Deterministic search over purchase ids: an account of `spins` spins whose luck matches pred.
local function searchLuck(line, spins, opts, pred)
	for i = 1, 5000 do
		local acc = account()
		acc:buy(i, line)
		acc:spins(spins, opts)
		local r = Verify.run(acc:input())
		if pred(r.luck) then return r end
	end
	error("no account found")
end

t.test("luck: light thresholds; luck does not change the report light", function()
	local r = searchLuck("GSLOTS1;E=10;G=0", 30, nil, function(l) return l.total.z >= 2 and l.total.z < 3 end)
	t.eq(r.luck.total.light, "yellow") t.eq(r.light, "green")
	r = searchLuck("GSLOTS1;E=10;G=0", 30, nil, function(l) return l.total.z >= 3 end)
	t.eq(r.luck.total.light, "red") t.eq(r.light, "green")
	r = searchLuck("GSLOTS1;E=10;G=0", 29, nil, function(l) return l.total.z >= 3 end)
	t.eq(r.luck.total.light, "green", "too little data")
	r = searchLuck("GSLOTS1;E=10;G=1", 60, { gamble = true }, function(l)
		return l.steps >= 10 and l.risk.z >= 2 and l.risk.z < 3
	end)
	t.eq(r.luck.risk.light, "yellow")
	r = searchLuck("GSLOTS1;E=10;G=1", 60, { gamble = true }, function(l)
		return l.steps >= 10 and l.risk.z <= -2
	end)
	t.eq(r.luck.risk.light, "green", "unlucky is green")
	-- Mixed stakes: timing exists and has its own light.
	r = searchLuck("GSLOTS1;G=0", 30, { stake = function(n) return n % 2 == 0 and 100 or 10 end },
		function(l) return l.timing.z >= 2 and l.timing.z < 3 end)
	t.eq(r.luck.timing.light, "yellow") t.eq(r.luck.timing.enough, true)
end)

t.test("bad account data never raises", function()
	local acc = level1()
	local junk = { 1, "x", true, {}, { type = "B" }, { type = "G", n = 1, g = "a" }, { type = "Q" } }
	for _, e in ipairs(junk) do
		local entries = { acc.entries[1], e }
		local r = Verify.run(acc:input({ entries = entries, audit = { 5, { kind = 3 }, { kind = "spin", n = {} } },
			heard = { n = 1, g = "x", head = 7 }, anchor = { anchors = "two" }, known = 4, isOfficer = 9 }))
		t.eq(r.findings[1].code, "officer_unknown", "isOfficer missing")
		t.eq(#findings(r, "bad_entry"), 1, "entry " .. tostring(e))
		t.eq(r.light, "red")
	end
	local r = Verify.run({ guild = GUILD, player = PLAYER })
	t.eq(r.light, "yellow", "no entries, no anchor")
	t.eq(r.balance, 0)
	t.eq(r.lookahead, nil, "no purchase")
	t.eq(r.luck.spins, 0)
end)

-- Look-ahead -------------------------------------------------------------------------------------

t.test("look-ahead: the next 20 spins of the current key", function()
	local acc = gambleAccount()
	local r = Verify.run(acc:input())
	-- Replaying 20 more spins gives the same multipliers.
	local st, sum = Ledger.copy(acc.st), 0
	for k = 1, 20 do
		local info = Ledger.apply(st, { type = "S", n = acc.st.n + k, stake = 10, A = 0, status = "ok", contribs = "" })
		sum = sum + info.multiplier
	end
	t.eq(r.lookahead.count, 20)
	t.eq(r.lookahead.sum, sum)
	t.near(r.lookahead.expected, 20 * 4594 / 4913, 1e-12)
	-- A capped purchase keeps the uncapped expectation.
	acc:buy(9, "GSLOTS1;C=20")
	t.near(Verify.run(acc:input()).lookahead.expected, 20 * 4594 / 4913, 1e-12, "uncapped")
	t.eq(Verify.run(level1():input()).lookahead, nil, "level 1")
end)

-- onStep -----------------------------------------------------------------------------------------

t.test("onStep: once per entry, and the run can yield from a coroutine", function()
	local acc = gambleAccount()
	local steps = {}
	local co = coroutine.create(function()
		return Verify.run(acc:input({ onStep = function(i)
			steps[#steps + 1] = i
			coroutine.yield(i)
		end }))
	end)
	local yields, report = 0, nil
	while true do
		local ok, v = coroutine.resume(co)
		t.ok(ok, tostring(v))
		if coroutine.status(co) == "dead" then
			report = v
			break
		end
		yields = yields + 1
		t.eq(v, yields, "yielded index")
	end
	t.eq(yields, #acc.entries)
	t.eq(#steps, #acc.entries)
	t.eq(report.light, "green")
	t.eq(report.balance, acc.st.balance)
end)

-- Vectors ----------------------------------------------------------------------------------------

t.test("vector accounts verify without red findings from checks 4 to 6", function()
	local V = t.load("vectors.lua")
	local accounts = V.ledger.accounts
	t.eq(#accounts, 6)
	for _, v in ipairs(accounts) do
		local st = Ledger.start(v.guild, v.player)
		local known, anchorHead, heard = {}, nil, nil
		for _, text in ipairs(v.entries) do
			local e = assert(Ledger.decode(text))
			local before = Ledger.shortHead(st)
			assert(Ledger.apply(st, e))
			if e.type == "B" then known[e.buyId] = true anchorHead = Ledger.shortHead(st) end
			if e.type == "P" then known[e.payId] = true anchorHead = Ledger.shortHead(st) end
			if e.type == "S" then heard = { n = e.n, g = 0, head = before } end
		end
		local r = Verify.run({
			guild = v.guild, player = v.player, entries = v.entries, amount = st.balance,
			anchor = { anchors = st.anchors, head = anchorHead }, known = known, heard = heard,
			isOfficer = function() return true end,
		})
		for _, f in ipairs(r.findings) do
			t.ok(f.level ~= "red" or f.check < 4 or f.check > 6, v.name .. ": " .. f.code)
		end
		t.eq(#r.findings, 0, v.name .. ": no findings at all")
		t.eq(r.balance, v.final.balance, v.name .. " balance")
	end
end)
