local t, ns = ...
local Ledger, Engine, Tables = ns.Ledger, ns.Engine, ns.Tables

local T1 = Tables.get("T1")
local GUILD, PLAYER, OFF = "Guild", "Alice", "Officer"
local NONCE = "fedcba9876543210fedcba9876543210"
local SEED = "0123456789abcdef0123456789abcdef"

-- Literals computed independently with Python's hashlib.
local H0 = "70495648f340f61d1245fbf3fdf4791de8cee192df2c29d8aa0e692686409623"
local H1 = "91daf511e2ca0ee72e15ab4445ac02aee7aef4efe0590b93efdf847c87d28851"
local REF_BUY = {
	type = "B", buyId = "00112233aabbccdd", officer = OFF, tokens = 1000,
	commit = "3eb1bd439947eb762998e566ccc2e099c791118b2f40579cc4f7da2b5061b7f9",
	seed = SEED, nonce = NONCE, time = 1700000000, line = "GSLOTS1;L=0;E=10,50,100",
}
-- Spins 1..5 of REF_BUY's key with empty contributions all pay nothing (T S K, G T S, W S G, K S G, W S G).

local function copyEntry(e)
	local c = {}
	for k, v in pairs(e) do c[k] = v end
	return c
end

local function with(e, changes)
	local c = copyEntry(e)
	for k, v in pairs(changes) do c[k] = v end
	return c
end

local function buy(i, line, tokens)
	local seed = string.format("%032x", i)
	return {
		type = "B", buyId = string.format("%016x", i), officer = OFF, tokens = tokens or 1000,
		commit = Engine.commit(seed), seed = seed, nonce = NONCE, time = 1700000000 + i,
		line = line or "GSLOTS1",
	}
end

local function spin(n, stake, A, status, contribs)
	return { type = "S", n = n, stake = stake or 10, A = A or 0, status = status or "ok", contribs = contribs or "" }
end

local function gam(n, g, A, status, contribs)
	return { type = "G", n = n, g = g, A = A or 0, status = status or "ok", contribs = contribs or "" }
end

local function pay(i, amount, after)
	return { type = "P", payId = string.format("%016x", 1000000 + i), officer = OFF, amount = amount,
		balanceAfter = after, time = 1700100000 + i }
end

local function keyOf(e)
	return Engine.purchaseKey(e.buyId, e.seed, e.nonce)
end

-- Deterministic search over purchase ids for a key with the wanted outcome.
local function findBuy(line, pred, from)
	for i = from or 1, 20000 do
		local e = buy(i, line)
		if pred(keyOf(e)) then return e end
	end
	error("no purchase found")
end

local function spinMult(K, n, contribs)
	return Tables.multiplier(T1, Engine.spin(K, n, contribs or "", T1))
end

local function new(entries)
	local st = Ledger.start(GUILD, PLAYER)
	for i, e in ipairs(entries or {}) do
		local info, code = Ledger.apply(st, e)
		if not info then error("setup entry " .. i .. " failed: " .. tostring(code), 2) end
	end
	return st
end

local function expectFail(st, e, code, msg)
	local info, got = Ledger.apply(st, e)
	t.eq(info, nil, (msg or code) .. ": apply should fail")
	t.eq(got, code, msg or code)
end

local SCALARS = { "head", "count", "anchors", "balance", "n", "g", "pending", "K", "line" }
local function snapshot(st)
	local s = {}
	for _, k in ipairs(SCALARS) do s[k] = st[k] end
	s.settings, s.tbl, s.keyed = st.settings, st.tbl, st.keyed
	s.buys, s.pays = 0, 0
	for _ in pairs(st.buyIds) do s.buys = s.buys + 1 end
	for _ in pairs(st.payIds) do s.pays = s.pays + 1 end
	return s
end
local function sameState(st, s, msg)
	local now = snapshot(st)
	for k, v in pairs(s) do t.eq(now[k], v, (msg or "") .. " field " .. k) end
end

-- Basics -----------------------------------------------------------------------------------

t.test("start gives the genesis state", function()
	local st = Ledger.start(GUILD, PLAYER)
	t.eq(st.head, H0, "h0")
	t.eq(st.guild, GUILD) t.eq(st.player, PLAYER)
	t.eq(st.count, 0) t.eq(st.anchors, 0) t.eq(st.balance, 0)
	t.eq(st.n, 0) t.eq(st.g, 0) t.eq(st.pending, 0)
	t.eq(Ledger.shortHead(st), string.sub(H0, 1, 32), "short head")
end)

t.test("a purchase extends the chain and credits tokens", function()
	local st = Ledger.start(GUILD, PLAYER)
	local info = Ledger.apply(st, REF_BUY)
	t.ok(info, "applied")
	t.eq(st.head, H1, "h1")
	t.eq(info.type, "B")
	t.eq(info.balance, 1000)
	t.eq(info.pending, 0)
	t.eq(info.head, H1)
	t.eq(st.balance, 1000) t.eq(st.count, 1) t.eq(st.anchors, 1)
	t.eq(st.line, REF_BUY.line)
	t.eq(st.settings.L, 0)
	t.eq(st.tbl, T1)
	t.eq(st.K, keyOf(REF_BUY))
	t.ok(st.buyIds[REF_BUY.buyId], "buy id recorded")
	t.eq(Ledger.encode(REF_BUY), "B|00112233aabbccdd|Officer|1000|" .. REF_BUY.commit .. "|" .. SEED
		.. "|" .. NONCE .. "|1700000000|GSLOTS1;L=0;E=10,50,100")
end)

t.test("losing spins cost the stake and advance n", function()
	local st = new({ REF_BUY })
	local info = Ledger.apply(st, spin(1, 50))
	t.ok(info, "spin 1")
	t.eq(info.type, "S")
	t.eq(info.stops[1], 22) t.eq(info.stops[2], 23) t.eq(info.stops[3], 13)
	t.eq(info.multiplier, 0) t.eq(info.win, 0)
	t.eq(info.balance, 950) t.eq(info.pending, 0)
	t.eq(st.n, 1) t.eq(st.g, 0) t.eq(st.anchors, 1) t.eq(st.count, 2)
	t.ok(Ledger.apply(st, spin(2, 100)))
	t.eq(st.balance, 850)
end)

-- Text forms -------------------------------------------------------------------------------

t.test("encode and decode round trip for every entry type", function()
	local entries = {
		REF_BUY,
		spin(3, 10, 0, "ok", ""),
		spin(4, 1000000, 10000, "void", "Bob:0011223344556677,Carol:8899aabbccddeeff"),
		gam(2147483648, 5, 7, "ok", "Bob:0011223344556677"),
		pay(1, 9007199254740991, 0),
		with(REF_BUY, { tokens = 1000000000, time = 0 }),
	}
	for i, e in ipairs(entries) do
		local text = Ledger.encode(e)
		t.ok(type(text) == "string", "encode " .. i)
		local d, code = Ledger.decode(text)
		t.ok(d, "decode " .. i .. ": " .. tostring(code))
		for k, v in pairs(e) do t.eq(d[k], v, "entry " .. i .. " field " .. k) end
		for k in pairs(d) do t.ok(e[k] ~= nil, "extra field " .. k) end
		t.eq(Ledger.encode(d), text, "re-encode " .. i)
	end
	t.eq(Ledger.encode(spin(3, 10, 2, "void", "")), "S|3|10|2|void|")
	t.eq(Ledger.encode(gam(3, 1, 0, "ok", "")), "G|3|1|0|ok|")
	t.eq(Ledger.encode(pay(1, 9007199254740991, 0)), "P|00000000000f4241|Officer|9007199254740991|0|1700100001")
end)

t.test("encode refuses an invalid entry", function()
	local s, code = Ledger.encode(spin(0))
	t.eq(s, nil) t.eq(code, "bad_entry")
end)

t.test("decode rejects malformed text", function()
	local B = Ledger.encode(REF_BUY)
	local bad = {
		"", "X|1", "S", "S|1|10|0|ok", "S|1|10|0|ok||x", -- wrong type / field counts
		"G|1|1|0|ok", "P|0000000000000001|Off|5|0", "P|0000000000000001|Off|5|0|1|2",
		B .. "|extra", (B:gsub("|1700000000|", "|")),
		"S|01|10|0|ok|", "S|1|010|0|ok|", "S|1|10|00|ok|", "P|0000000000000001|Off|05|0|1", -- leading zeros
		"S|+1|10|0|ok|", "S|-1|10|0|ok|", "S|1.0|10|0|ok|", "S|1e3|10|0|ok|", "S| 1|10|0|ok|",
		"S|0|10|0|ok|", "S|2147483649|10|0|ok|", "S|1|0|0|ok|", "S|1|1000001|0|ok|", "S|1|10|10001|ok|",
		"S|1|10|0|OK|", "S|1|10|0|done|",
		"S|1|10|0|ok|Bob:00112233445566AA", "S|1|10|0|ok|Bob:001122334455667", -- uppercase / short value
		"S|1|10|0|ok|Carol:8899aabbccddeeff,Bob:0011223344556677", -- unsorted contribs
		"S|1|10|0|ok|Bob:0011223344556677,Bob:0011223344556677", -- duplicate contribs
		"P|0000000000000001|Off|0|0|1", "P|000000000000000|Off|5|0|1", "P|00000000000000001|Off|5|0|1",
		"P|000000000000000A|Off|5|0|1", "P|0000000000000001||5|0|1", "P|0000000000000001|O,ff|5|0|1",
		"P|0000000000000001|O:ff|5|0|1", "P|0000000000000001|O;ff|5|0|1", "P|0000000000000001|O\1ff|5|0|1",
		"P|0000000000000001|" .. string.rep("x", 49) .. "|5|0|1",
		"P|0000000000000001|Off|9007199254740992|0|1", -- amount >= 2^53
		(B:gsub("|1000|", "|0|")), (B:gsub("|1000|", "|1000000001|")),
		(B:gsub(REF_BUY.commit, REF_BUY.commit:upper())), (B:gsub(REF_BUY.commit, REF_BUY.commit:sub(2))),
		(B:gsub(SEED, SEED .. "00")), (B:gsub(NONCE, NONCE:sub(3))),
		(B:gsub("00112233aabbccdd", "00112233AABBCCDD")),
	}
	for _, text in ipairs(bad) do
		local e, code = Ledger.decode(text)
		t.eq(e, nil, "decode should fail: " .. text)
		t.eq(code, "bad_entry", text)
	end
	t.ok(Ledger.decode("P|0000000000000001|" .. string.rep("x", 48) .. "|5|0|1"), "48-byte name")
	t.ok(Ledger.decode("S|2147483648|10|0|ok|"), "n = 2^31")
end)

-- Rule order and error codes -----------------------------------------------------------------

t.test("bad_entry for malformed tables of every type", function()
	local st = new({ REF_BUY })
	local bad = {
		{ type = "X" },
		with(REF_BUY, { buyId = "short" }), with(REF_BUY, { tokens = 0 }), with(REF_BUY, { tokens = 1.5 }),
		with(REF_BUY, { tokens = "1000" }), with(REF_BUY, { officer = "a|b" }), with(REF_BUY, { line = "GSLOTS1|x" }),
		with(REF_BUY, { line = false }), with(REF_BUY, { time = -1 }), with(REF_BUY, { seed = SEED:upper() }),
		spin(0), spin(2147483649), spin(1, 0), spin(1, 1000001), spin(1, 10, -1), spin(1, 10, 10001),
		spin(1, 10, 0, "OK"), spin(1, 10, 0, "ok", "x"), with(spin(1), { contribs = false }),
		gam(1, -1), gam(1, 1.5), gam(0, 1), gam(1, 1, 0, "void", "Bob"),
		pay(1, 0, 0), pay(1, 1, -1), pay(1, 2 ^ 53, 0), with(pay(1, 1, 0), { payId = "zz" }),
		with(pay(1, 1, 0), { time = 0.5 }),
	}
	for i, e in ipairs(bad) do expectFail(st, e, "bad_entry", "case " .. i) end
	t.eq(st.count, 1, "nothing applied")
end)

t.test("before the first purchase only a purchase is allowed", function()
	local st = Ledger.start(GUILD, PLAYER)
	expectFail(st, spin(1), "no_purchase")
	expectFail(st, gam(1, 1), "no_purchase")
	expectFail(st, pay(1, 1, 0), "no_purchase")
	-- A malformed entry reports bad_entry first.
	expectFail(st, spin(0), "bad_entry", "bad_entry before no_purchase")
end)

t.test("purchase rules: bad_commit, dup_buy, bad_settings in that order", function()
	local st = new({ REF_BUY })
	local wrongCommit = with(buy(2), { commit = REF_BUY.commit })
	expectFail(st, wrongCommit, "bad_commit")
	-- Same buyId, wrong commit and bad line: commit first.
	expectFail(st, with(REF_BUY, { commit = buy(2).commit, line = "GSLOTS1;L=7" }), "bad_commit", "commit before dup")
	-- Same buyId and bad line: dup first.
	expectFail(st, with(REF_BUY, { line = "GSLOTS1;L=7" }), "dup_buy", "dup before settings")
	expectFail(st, buy(2, "GSLOTS1;L=7"), "bad_settings")
	expectFail(st, buy(2, "NOPE"), "bad_settings")
	-- The line's form (1..120 bytes, no byte below 32, no "|") is a field check: bad_entry.
	expectFail(st, buy(2, ""), "bad_entry", "empty line")
	expectFail(st, buy(2, "GSLOTS1;" .. string.rep("Y", 113)), "bad_entry", "line too long")
	expectFail(st, buy(2, "GSLOTS1;\tL=1"), "bad_entry", "control byte")
	t.ok(Ledger.apply(Ledger.copy(st), buy(2, "GSLOTS1;" .. string.rep("Y", 108) .. "=1")), "120 bytes")
	expectFail(st, buy(2, "GSLOTS1;L=1;L=1"), "bad_settings", "repeated key")
	t.ok(Ledger.apply(st, buy(2, "GSLOTS1;E=20")), "valid second purchase")
	t.eq(st.balance, 2000) t.eq(st.anchors, 2)
end)

t.test("a purchase switches key, settings and table, and keeps the stored line", function()
	local st = new({ REF_BUY })
	local b2 = buy(7, "  GSLOTS1;E=20;G=0  ")
	-- Leading spaces make it not parse: the stored line must be the trimmed one.
	expectFail(st, b2, "bad_settings", "untrimmed line")
	b2 = buy(7, "GSLOTS1;E=20;G=0;Q=unknown")
	t.ok(Ledger.apply(st, b2))
	t.eq(st.K, keyOf(b2))
	t.eq(st.line, "GSLOTS1;E=20;G=0;Q=unknown")
	t.eq(st.settings.G, 0)
	expectFail(st, spin(1, 10), "bad_stake", "old stake no longer allowed")
	t.ok(Ledger.apply(st, spin(1, 20)), "new stake allowed")
end)

t.test("spin rules: bad_number, bad_stake, bad_contribs, no_funds in that order", function()
	local st = new({ buy(3, "GSLOTS1", 15) })
	expectFail(st, spin(2), "bad_number")
	expectFail(st, spin(2, 20, 1, "ok", "Bob:0011223344556677"), "bad_number", "number first")
	expectFail(st, spin(1, 20), "bad_stake")
	expectFail(st, spin(1, 20, 1), "bad_stake", "stake before contribs")
	expectFail(st, spin(1, 10, 1), "bad_contribs", "A at level 0")
	expectFail(st, spin(1, 10, 0, "ok", "Bob:0011223344556677"), "bad_contribs", "contribs at level 0")
	expectFail(st, spin(1, 10, 0, "void"), "bad_contribs", "void at level 0")
	expectFail(st, spin(1, 50), "no_funds")
	expectFail(st, spin(1, 50, 1), "bad_contribs", "contribs before funds")
	t.ok(Ledger.apply(st, spin(1, 10)))
	expectFail(st, spin(1, 10), "bad_number", "repeated number")
end)

t.test("payout rules: dup_pay, no_funds, bad_balance in that order", function()
	local st = new({ REF_BUY, pay(1, 100, 900) })
	t.eq(st.balance, 900) t.eq(st.anchors, 2)
	expectFail(st, pay(1, 100, 800), "dup_pay")
	expectFail(st, pay(1, 5000, 1), "dup_pay", "dup before funds")
	expectFail(st, pay(2, 901, 0), "no_funds")
	expectFail(st, pay(2, 901, 7), "no_funds", "funds before balance")
	expectFail(st, pay(2, 100, 799), "bad_balance")
	local info = Ledger.apply(st, pay(2, 900, 0))
	t.eq(info.type, "P") t.eq(info.balance, 0) t.eq(info.pending, 0)
	t.eq(st.balance, 0) t.eq(st.anchors, 3)
end)

t.test("gamble rules: bad_gamble before bad_contribs", function()
	local st = new({ REF_BUY })
	expectFail(st, gam(1, 1), "bad_gamble", "no spin yet")
	t.ok(Ledger.apply(st, spin(1)))
	expectFail(st, gam(1, 1), "bad_gamble", "nothing pending after a loss")
	expectFail(st, gam(1, 1, 3, "ok", "Bob:0011223344556677"), "bad_gamble", "gamble before contribs")
end)

-- Wins and gambling ------------------------------------------------------------------------------

t.test("a win sets pending and a won gamble chain stops at G", function()
	local line = "GSLOTS1;G=2"
	local b = findBuy(line, function(K)
		return spinMult(K, 1) > 0 and Engine.gamble(K, 1, 1, "") and Engine.gamble(K, 1, 2, "")
	end)
	local K = keyOf(b)
	local m = spinMult(K, 1)
	local w = 10 * m
	local st = new({ b })
	local info = Ledger.apply(st, spin(1, 10))
	t.eq(info.multiplier, m) t.eq(info.win, w)
	t.eq(info.balance, 1000 - 10 + w) t.eq(info.pending, w)
	expectFail(st, gam(1, 2), "bad_gamble", "step skipped")
	expectFail(st, gam(2, 1), "bad_gamble", "wrong spin number")
	expectFail(st, gam(1, 1, 1), "bad_contribs", "A at level 0")
	info = Ledger.apply(st, gam(1, 1))
	t.eq(info.type, "G") t.eq(info.won, true)
	t.eq(info.balance, 1000 - 10 + 2 * w) t.eq(info.pending, 2 * w)
	t.eq(st.g, 1)
	info = Ledger.apply(st, gam(1, 2))
	t.eq(info.won, true)
	t.eq(info.balance, 1000 - 10 + 4 * w) t.eq(info.pending, 0, "g == G ends the chain")
	expectFail(st, gam(1, 3), "bad_gamble", "beyond G")
	t.ok(Ledger.apply(st, spin(2, 10)), "next spin")
	t.eq(st.g, 0)
end)

t.test("a lost gamble takes the amount at risk", function()
	local b = findBuy("GSLOTS1", function(K)
		return spinMult(K, 1) > 0 and Engine.gamble(K, 1, 1, "") and not Engine.gamble(K, 1, 2, "")
	end)
	local w = 10 * spinMult(keyOf(b), 1)
	local st = new({ b, spin(1, 10), gam(1, 1) })
	t.eq(st.balance, 990 + 2 * w)
	local info = Ledger.apply(st, gam(1, 2))
	t.eq(info.won, false)
	t.eq(info.balance, 990) t.eq(info.pending, 0)
	expectFail(st, gam(1, 3), "bad_gamble", "nothing left at risk")
end)

t.test("G = 0 disables gambling", function()
	local b = findBuy("GSLOTS1;G=0", function(K) return spinMult(K, 1) > 0 end)
	local st = new({ b })
	local info = Ledger.apply(st, spin(1, 10))
	t.ok(info.win > 0) t.eq(info.pending, 0)
	expectFail(st, gam(1, 1), "bad_gamble")
end)

t.test("cap C cuts wins and blocks gambling when a double would exceed it", function()
	-- Multiplier >= 2 with stake 10 and C = 15: win capped to 15, 2 * 15 > 15 so no gamble.
	local b = findBuy("GSLOTS1;C=15", function(K) return spinMult(K, 1) >= 2 end)
	local st = new({ b })
	local info = Ledger.apply(st, spin(1, 10))
	t.eq(info.win, 15) t.eq(info.balance, 1005) t.eq(info.pending, 0)
	expectFail(st, gam(1, 1), "bad_gamble")
end)

t.test("cap C ends a gamble chain once the next double would exceed it", function()
	-- Multiplier 1, stake 10, C = 40: 2*10 <= 40 pending 10; won -> p = 20, 2*20 <= 40 pending 20;
	-- won -> p = 40, 2*40 > 40 pending 0.
	local b = findBuy("GSLOTS1;C=40;G=5", function(K)
		return spinMult(K, 1) == 1 and Engine.gamble(K, 1, 1, "") and Engine.gamble(K, 1, 2, "")
	end)
	local st = new({ b })
	local info = Ledger.apply(st, spin(1, 10))
	t.eq(info.win, 10) t.eq(info.pending, 10)
	info = Ledger.apply(st, gam(1, 1))
	t.eq(info.balance, 1010) t.eq(info.pending, 20)
	info = Ledger.apply(st, gam(1, 2))
	t.eq(info.balance, 1030) t.eq(info.pending, 0)
	expectFail(st, gam(1, 3), "bad_gamble")
end)

t.test("a payout clears pending and play continues after paying out to zero", function()
	local b = findBuy("GSLOTS1", function(K) return spinMult(K, 1) > 0 end)
	local st = new({ b, spin(1, 10) })
	t.ok(st.pending > 0)
	local bal = st.balance
	t.ok(Ledger.apply(st, pay(1, bal, 0)))
	t.eq(st.pending, 0)
	expectFail(st, gam(1, 1), "bad_gamble", "payout ended the gamble")
	expectFail(st, spin(2, 10), "no_funds")
	local headBefore = st.head
	t.ok(Ledger.apply(st, buy(9000, "GSLOTS1", 100)))
	t.ok(st.head ~= headBefore)
	t.eq(st.balance, 100)
	t.ok(Ledger.apply(st, spin(2, 10)), "chain continues with n = 2")
	t.eq(st.n, 2)
end)

-- Levels 1 and 2 --------------------------------------------------------------------------------

local V1, V2 = "0011223344556677", "8899aabbccddeeff"

t.test("level 2: officers' contributions, void with fewer", function()
	local st = new({ REF_BUY, buy(11, "GSLOTS1;L=2") })
	expectFail(st, spin(1, 10, 0, "ok", ""), "bad_contribs", "ok needs one contribution")
	expectFail(st, spin(1, 10, 1, "ok", "Bob:" .. V1), "bad_contribs", "A must be 0")
	expectFail(st, spin(1, 10, 0, "ok", "Alice:" .. V1), "bad_contribs", "player's own")
	local nine = {}
	for i = 1, 9 do nine[i] = "O" .. i .. ":" .. V1 end
	expectFail(st, spin(1, 10, 0, "ok", table.concat(nine, ",")), "bad_contribs", "nine contributions")
	expectFail(st, spin(1, 10, 0, "void", table.concat(nine, ",")), "bad_contribs", "nine contributions void")
	local info = Ledger.apply(st, spin(1, 10, 0, "void", ""))
	t.ok(info, "void with none")
	t.eq(info.balance, 2000) t.eq(info.pending, 0)
	t.eq(st.n, 1) t.eq(st.g, 0)
	t.ok(Ledger.apply(st, spin(2, 10, 0, "ok", "Bob:" .. V1 .. ",Carol:" .. V2)), "ok with two")
end)

t.test("level 2 void gamble step only advances g", function()
	local line = "GSLOTS1;L=2"
	local c = "Bob:" .. V1
	local b = findBuy(line, function(K)
		return spinMult(K, 1, c) > 0 and Engine.gamble(K, 1, 2, c)
	end)
	local st = new({ b, spin(1, 10, 0, "ok", c) })
	local before = { balance = st.balance, pending = st.pending }
	local info = Ledger.apply(st, gam(1, 1, 0, "void", ""))
	t.ok(info, "void step")
	t.eq(st.g, 1) t.eq(st.balance, before.balance) t.eq(st.pending, before.pending)
	info = Ledger.apply(st, gam(1, 2, 0, "ok", c))
	t.eq(info.won, true)
	t.eq(st.balance, before.balance + before.pending)
end)

-- Names drawn and not drawn by the level-1 lottery, found by a deterministic search.
-- Z = 2*2+3 = 7; with A = 10000 the limit is floor(7 * 2^32 / 10000) = 3006477.
local LIMIT = 3006477
local function findWitness(kind, n, g, wantDrawn)
	for i = 1, 100000 do
		local name = "W" .. i
		local l = Engine.lot(name, PLAYER, kind, n, g)
		if (l < LIMIT) == wantDrawn then return name end
	end
	error("no witness found")
end

t.test("level 1: A range, W..8 contributions, lottery for the reported A", function()
	local st = new({ buy(21, "GSLOTS1;L=1;W=2") })
	local d1 = findWitness("spin", 1, 0, true)
	local d2
	for i = 1, 100000 do
		local name = "V" .. i
		if Engine.lot(name, PLAYER, "spin", 1, 0) < LIMIT then d2 = name break end
	end
	local u = findWitness("spin", 1, 0, false)
	local function cs(names)
		table.sort(names)
		local parts = {}
		for i, nm in ipairs(names) do parts[i] = nm .. ":" .. V1 end
		return table.concat(parts, ",")
	end
	expectFail(st, spin(1, 10, 0, "ok", cs({ d1, d2 })), "bad_contribs", "A = 0 at level 1")
	expectFail(st, spin(1, 10, 0, "void", ""), "bad_contribs", "A = 0 at level 1, void")
	expectFail(st, spin(1, 10, 10000, "ok", cs({ d1 })), "bad_contribs", "fewer than W")
	expectFail(st, spin(1, 10, 10000, "ok", cs({ d1, u })), "bad_contribs", "undrawn contributor")
	expectFail(st, spin(1, 10, 10000, "void", cs({ u })), "bad_contribs", "undrawn contributor, void")
	expectFail(st, spin(1, 10, 10000, "ok", cs({ d1, d2, "Alice" })), "bad_contribs", "player's own")
	-- With A <= Z every name is drawn.
	local copy = Ledger.copy(st)
	t.ok(Ledger.apply(copy, spin(1, 10, 7, "ok", cs({ d1, u }))), "A <= Z draws everyone")
	-- Void with fewer than W drawn contributions is fine.
	local copy2 = Ledger.copy(st)
	t.ok(Ledger.apply(copy2, spin(1, 10, 10000, "void", cs({ d1 }))), "void with one")
	t.ok(Ledger.apply(copy2, spin(2, 10, 3, "void", "")), "void with none")
	t.ok(Ledger.apply(st, spin(1, 10, 10000, "ok", cs({ d1, d2 }))), "two drawn")
end)

t.test("level 1 lottery for a gamble step uses kind gam and step g", function()
	local line = "GSLOTS1;L=1;W=1"
	local c = "Bob:" .. V1 -- A = 1 <= Z, so anyone is drawn for the spin
	local b = findBuy(line, function(K) return spinMult(K, 1, c) > 0 end)
	local st = new({ b, spin(1, 10, 1, "ok", c) })
	t.ok(st.pending > 0)
	-- Z = 5, A = 10000: limit floor(5 * 2^32 / 10000) = 2147483
	local drawn, undrawn
	for i = 1, 100000 do
		local name = "G" .. i
		local l = Engine.lot(name, PLAYER, "gam", 1, 1)
		if l < 2147483 then drawn = drawn or name else undrawn = undrawn or name end
		if drawn and undrawn then break end
	end
	expectFail(st, gam(1, 1, 10000, "ok", undrawn .. ":" .. V1), "bad_contribs", "undrawn for the step")
	t.ok(Ledger.apply(st, gam(1, 1, 10000, "ok", drawn .. ":" .. V1)), "drawn for the step")
end)

-- Checkpoints and replay ------------------------------------------------------------------------

t.test("a failed apply leaves the state untouched", function()
	local b = findBuy("GSLOTS1", function(K) return spinMult(K, 1) > 0 end)
	local st = new({ b, spin(1, 10) })
	local snap = snapshot(st)
	local failing = {
		spin(1), spin(2, 20), spin(2, 1000, 0), gam(1, 2), pay(1, 1, 5), pay(1, 1e6, 0),
		with(b, { line = "GSLOTS1;L=9" }), with(buy(50), { commit = b.commit }), buy(51, "BAD"), spin(0),
	}
	for i, e in ipairs(failing) do
		t.eq(Ledger.apply(st, e), nil, "case " .. i)
		sameState(st, snap, "case " .. i)
	end
	t.ok(Ledger.apply(st, pay(1, 1, st.balance - 1)))
	expectFail(st, pay(1, 1, st.balance - 1), "dup_pay")
end)

t.test("copy gives an independent checkpoint", function()
	local st = new({ REF_BUY })
	local cp = Ledger.copy(st)
	t.ok(Ledger.apply(st, spin(1)))
	t.ok(Ledger.apply(st, pay(1, 5, 985)))
	t.ok(Ledger.apply(st, buy(2)))
	t.eq(cp.n, 0) t.eq(cp.balance, 1000) t.eq(cp.head, H1) t.eq(cp.count, 1) t.eq(cp.anchors, 1)
	t.ok(not cp.payIds[pay(1).payId], "pay ids independent")
	t.ok(not cp.buyIds[buy(2).buyId], "buy ids independent")
	-- The checkpoint still works on its own.
	t.ok(Ledger.apply(cp, pay(1, 5, 995)), "same pay id is new to the checkpoint")
	t.ok(Ledger.apply(cp, spin(1)))
	t.eq(cp.balance, 985)
end)

t.test("replay applies all entries and calls onStep after each", function()
	local entries = { REF_BUY, spin(1, 50), spin(2, 10), pay(1, 40, 900), spin(3, 100) }
	local steps = {}
	local st = Ledger.replay(GUILD, PLAYER, entries, function(i) steps[#steps + 1] = i end)
	t.ok(st, "replayed")
	t.eq(#steps, 5)
	for i = 1, 5 do t.eq(steps[i], i) end
	t.eq(st.balance, 800) t.eq(st.count, 5) t.eq(st.anchors, 2) t.eq(st.n, 3)
	local manual = new(entries)
	t.eq(st.head, manual.head)
	-- Text forms are accepted as well.
	local texts = {}
	for i, e in ipairs(entries) do texts[i] = Ledger.encode(e) end
	local st2 = Ledger.replay(GUILD, PLAYER, texts)
	t.eq(st2.head, st.head)
end)

t.test("replay reports the first failing entry and its index", function()
	local calls = 0
	local st, code, index = Ledger.replay(GUILD, PLAYER, { REF_BUY, spin(1), spin(3), spin(4) },
		function() calls = calls + 1 end)
	t.eq(st, nil) t.eq(code, "bad_number") t.eq(index, 3)
	t.eq(calls, 2)
	st, code, index = Ledger.replay(GUILD, PLAYER, { REF_BUY, "S|01|10|0|ok|" })
	t.eq(st, nil) t.eq(code, "bad_entry") t.eq(index, 2)
end)

t.test("the head depends on guild and player", function()
	local a = Ledger.replay(GUILD, PLAYER, { REF_BUY })
	local b = Ledger.replay(GUILD, "Bob", { REF_BUY })
	local c = Ledger.replay("Other", PLAYER, { REF_BUY })
	t.ok(a.head ~= b.head and a.head ~= c.head and b.head ~= c.head)
end)
