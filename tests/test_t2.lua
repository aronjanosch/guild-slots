local t, ns = ...
local Tables, Engine, Sha256 = ns.Tables, ns.Engine, ns.Sha256

-- Table T2 (docs/table-t2-spec.md): window evaluation, rounds with free games, and the T2 rules
-- of Settings, Ledger and Verify.

local T2 = Tables.get("T2")

local function chars(text)
	local out = {}
	for i = 1, #text do out[i] = text:sub(i, i) end
	return out
end

-- A table with T2's lines and pays whose reels are 3-stop strips, so stop 1 shows the strip
-- as the window: columns are given top to bottom, e.g. { "KSG", ... } is top K, middle S, bottom G.
local function grid(cols, freeCols)
	local reels, free = {}, {}
	for r = 1, 5 do
		reels[r] = chars(cols[r])
		free[r] = chars((freeCols or cols)[r])
	end
	return setmetatable({ reels = reels, freeReels = free }, { __index = T2 })
end

local ONES = { 1, 1, 1, 1, 1 }

t.test("T2 definition: kind, sizes and strips", function()
	t.eq(T2.id, "T2", "id")
	t.eq(T2.kind, "lines", "kind")
	t.eq(Tables.get("T1").kind, "classic", "T1 kind")
	t.eq(T2.rows, 3, "rows")
	t.eq(T2.lineCount, 10, "lineCount")
	t.eq(#T2.lines, 10, "lines")
	local base, free = { 41, 40, 55, 50, 29 }, { 41, 56, 59, 53, 55 }
	for r = 1, 5 do
		t.eq(#T2.reels[r], base[r], "base reel " .. r)
		t.eq(#T2.freeReels[r], free[r], "free reel " .. r)
	end
	t.eq(T2.reels[1][1], "K", "base reel 1 stop 0")
	t.eq(T2.reels[5][29], "M", "base reel 5 last stop")
	t.eq(T2.freeReels[3][59], "C", "free reel 3 last stop")
	t.eq(table.concat(T2.lines[8], ","), "2,2,1,0,0", "line 8")
	t.eq(T2.pays.L[2], 10, "L pays 10 for 2")
	t.eq(T2.pays.K[2], nil, "K pays nothing for 2")
	t.eq(T2.pays.T[4], 40, "T pays 40 for 4")
	t.eq(T2.pays.B, nil, "B has no line pay")
end)

t.test("evaluate: plain line on the middle row", function()
	-- middle row K K K S G: line 1 pays K x3 = 5 line bets; nothing else wins.
	local tbl = grid({ "SKG", "GKS", "SKG", "GST", "TGW" })
	local res = assert(Tables.evaluate(tbl, ONES, 100))
	t.eq(#res.lines, 1, "one winning line")
	local l = res.lines[1]
	t.eq(l.line, 1, "line") t.eq(l.symbol, "K", "symbol") t.eq(l.count, 3, "count") t.eq(l.win, 50, "win")
	t.eq(res.scatter.count, 0, "no books") t.eq(res.scatter.win, 0, "no scatter win")
	t.eq(res.expand, nil, "no expansion in the base game")
	t.eq(res.win, 50, "window win")
	t.eq(res.window[2][2], "K", "window reel 2 middle")
	t.eq(res.window[5][3], "W", "window reel 5 bottom")
end)

local function lineWins(res)
	local out = {}
	for i, l in ipairs(res.lines) do
		out[i] = l.line .. ":" .. l.symbol .. "x" .. l.count .. "=" .. l.win
	end
	return table.concat(out, " ")
end

t.test("evaluate: a wild in the middle of a line counts for the target", function()
	-- middle row M B M M K: M x4 = 100 line bets; stake 100, line bet 10.
	local res = assert(Tables.evaluate(grid({ "SMG", "GBT", "TMK", "KMW", "WKT" }), ONES, 100))
	t.eq(lineWins(res), "1:Mx4=1000", "lines")
	t.eq(res.scatter.count, 1, "one book")
	t.eq(res.win, 1000, "window win")
end)

t.test("evaluate: leading wilds take the first symbol that is not B", function()
	-- middle row B B L D K: L x3 = 100 line bets; stake 10, line bet 1.
	local res = assert(Tables.evaluate(grid({ "SBG", "KBT", "WLM", "GDT", "TKW" }), ONES, 10))
	t.eq(lineWins(res), "1:Lx3=100", "lines")
	t.eq(res.scatter.count, 2, "two books, no scatter win")
	t.eq(res.scatter.win, 0, "scatter win")
	t.eq(res.win, 100, "window win")
end)

t.test("evaluate: five books on a line pay nothing as a line", function()
	-- middle row all B: line 1 pays nothing; 5 books scatter 200 x stake; line 10 is S B B B T = S x4.
	local res = assert(Tables.evaluate(grid({ "SBG", "KBT", "WBM", "GBS", "TBK" }), ONES, 10))
	t.eq(lineWins(res), "10:Sx4=25", "lines")
	t.eq(res.scatter.count, 5, "books") t.eq(res.scatter.win, 2000, "scatter win")
	t.eq(res.win, 2025, "window win")
end)

t.test("evaluate: L, M, D, C pay for 2 of a kind, K/S/G/T/W do not", function()
	-- middle row L L K S G: L x2 = 10 line bets; top row S S W G T: S x2 pays nothing. Stake 20.
	local res = assert(Tables.evaluate(grid({ "SLG", "SLT", "WKM", "GSD", "TGW" }), ONES, 20))
	t.eq(lineWins(res), "1:Lx2=20", "lines")
	t.eq(res.win, 20, "window win")
end)

t.test("evaluate: scatter pays 2, 20, 200 x stake for 3, 4, 5 or more books anywhere", function()
	local cases = {
		{ { "BKS", "TGW", "KSB", "GWT", "SBK" }, 3, 20 },
		{ { "BKS", "TBW", "KSB", "GWT", "SBK" }, 4, 200 },
		{ { "BKS", "TBW", "KSB", "GWB", "SBK" }, 5, 2000 },
		{ { "BKB", "TBW", "KSB", "GWB", "SBK" }, 6, 2000 },
		{ { "BKS", "TGW", "KSW", "GWT", "SBK" }, 2, 0 },
	}
	for _, c in ipairs(cases) do
		local res = assert(Tables.evaluate(grid(c[1]), ONES, 10))
		t.eq(res.scatter.count, c[2], "books")
		t.eq(res.scatter.win, c[3], c[2] .. " books")
		local sum = 0
		for _, l in ipairs(res.lines) do sum = sum + l.win end
		t.eq(res.win, sum + c[3], "window win = lines + scatter")
	end
end)

t.test("evaluate: the expanding symbol counts reels that need not be adjacent", function()
	-- L on reels 1, 3, 5 only; no line wins. L x3 = 100 line bets x 10 lines = 100 x stake.
	local res = assert(Tables.evaluate(grid({ "LKS", "GTW", "KSL", "WGT", "SLK" }), ONES, 10, "L"))
	t.eq(lineWins(res), "", "no line wins")
	t.ok(res.expand, "expands")
	t.eq(table.concat(res.expand.reels, ","), "1,3,5", "reels")
	t.eq(res.expand.count, 3, "count")
	t.eq(res.expand.win, 1000, "expansion win")
	t.eq(res.win, 1000, "window win")
end)

t.test("evaluate: a book does not count as the expanding symbol", function()
	-- M on reels 1 and 3, B on reel 2: m = 2, M x2 = 5 line bets x 10 = 50 at stake 10 (not M x3).
	local cols = { "KSM", "BGW", "TWM", "GTS", "LKS" }
	local res = assert(Tables.evaluate(grid(cols), ONES, 10, "M"))
	t.eq(lineWins(res), "", "no line wins")
	t.eq(res.scatter.count, 1, "one book")
	t.eq(table.concat(res.expand.reels, ","), "1,3", "reels")
	t.eq(res.expand.count, 2, "count")
	t.eq(res.expand.win, 50, "expansion win")
	t.eq(res.win, 50, "window win")
	-- Below the minimum count: T on reels 3 and 4 (T has no pay for 2), L on reel 5 only.
	t.eq(assert(Tables.evaluate(grid(cols), ONES, 10, "T")).expand, nil, "T on 2 reels")
	t.eq(assert(Tables.evaluate(grid(cols), ONES, 10, "L")).expand, nil, "L on 1 reel")
end)

t.test("evaluate: a free game uses the free strips", function()
	local tbl = grid({ "KKK", "KKK", "KKK", "KKK", "KKK" }, { "SSS", "SSS", "SSS", "SSS", "SSS" })
	t.eq(assert(Tables.evaluate(tbl, ONES, 10)).window[1][1], "K", "base strips")
	t.eq(assert(Tables.evaluate(tbl, ONES, 10, "L")).window[1][1], "S", "free strips")
end)

t.test("evaluate: the real strips wrap around", function()
	-- reel 1 stop 0: top is the last stop (B), middle K, bottom T.
	local res = assert(Tables.evaluate(T2, { 0, 39, 54, 49, 28 }, 10))
	t.eq(table.concat(res.window[1]), "BKT", "reel 1")
	t.eq(table.concat(res.window[2]), "WGK", "reel 2 last stop: ...W G, then stop 0 K")
	t.eq(table.concat(res.window[5]), "KMW", "reel 5 last stop")
end)

-- Engine.round --------------------------------------------------------------------------------

local K = Engine.purchaseKey("0123456789abcdef", string.format("%032x", 7), "fedcba9876543210fedcba9876543210")

local function u32(s, i)
	local a, b, c, d = s:byte(i, i + 3)
	return ((a * 256 + b) * 256 + c) * 256 + d
end

-- Deep comparison; returns nil or the path of the first difference.
local function diff(a, b, path)
	path = path or "round"
	if type(a) ~= "table" or type(b) ~= "table" then
		if a ~= b then return path .. ": " .. tostring(a) .. " vs " .. tostring(b) end
		return nil
	end
	for k, v in pairs(a) do
		local d = diff(v, b[k], path .. "." .. tostring(k))
		if d then return d end
	end
	for k, v in pairs(b) do
		if a[k] == nil then return path .. "." .. tostring(k) .. ": missing vs " .. tostring(v) end
	end
	return nil
end

-- Base windows with books on reels 1..3 (every stop of a 3-stop strip shows all three cells).
local TRIGGER = { "KBS", "TBG", "BWK", "GST", "SKW" }
local NO_BOOKS = { "KSG", "TGW", "WKS", "GST", "SKW" }
local ALL_BOOKS = { "BBB", "BBB", "BBB", "BBB", "BBB" }

t.test("round: base game stops, window and fields follow the spin HMAC", function()
	for n = 1, 30 do
		local round = Engine.round(K, n, "", T2, 20, 0)
		local R = Sha256.hmacRaw(K, "spin|" .. n .. "|")
		for r = 1, 5 do
			t.eq(round.stops[r], u32(R, 4 * r - 3) % #T2.reels[r], "n " .. n .. " stop " .. r)
		end
		local res = Tables.evaluate(T2, round.stops, 20)
		t.eq(diff(round.window, res.window), nil, "window")
		t.eq(diff(round.lines, res.lines), nil, "lines")
		t.eq(diff(round.scatter, res.scatter), nil, "scatter")
		t.eq(round.kind, "lines", "kind") t.eq(round.n, n, "n")
		t.eq(round.stake, 20, "stake") t.eq(round.lineBet, 2, "lineBet")
		t.eq(round.base, res.win, "base")
		if round.free == nil then t.eq(round.win, res.win, "win without free games") end
	end
end)

t.test("round: deterministic, and the keyed key gives the same round", function()
	local keyed = Sha256.keyed(K)
	for n = 1, 20 do
		local a = Engine.round(K, n, "Bob:0123456789abcdef", T2, 10, 0)
		t.eq(diff(a, Engine.round(K, n, "Bob:0123456789abcdef", T2, 10, 0)), nil, "same input")
		t.eq(diff(a, Engine.round(keyed, n, "Bob:0123456789abcdef", T2, 10, 0)), nil, "keyed")
	end
end)

t.test("round: three books award 10 free games with the free-game HMAC and X", function()
	local tbl = grid(TRIGGER, NO_BOOKS)
	local round = Engine.round(K, 5, "", tbl, 10, 0)
	t.eq(round.scatter.count, 3, "books") t.eq(round.scatter.win, 20, "scatter win")
	local free = round.free
	t.ok(free, "free games")
	local R = Sha256.hmacRaw(K, "spin|5|")
	t.eq(free.symbol, ("KSGTWMDCL"):sub(u32(R, 21) % 9 + 1, u32(R, 21) % 9 + 1), "X from R[21..24]")
	t.eq(free.awarded, 10, "awarded") t.eq(#free.games, 10, "games")
	local sum = 0
	for i, g in ipairs(free.games) do
		local F = Sha256.hmacRaw(K, "free|5|" .. i .. "|")
		for r = 1, 5 do t.eq(g.stops[r], u32(F, 4 * r - 3) % 3, "game " .. i .. " stop " .. r) end
		local res = Tables.evaluate(tbl, g.stops, 10, free.symbol)
		t.eq(diff(g.window, res.window), nil, "window") t.eq(diff(g.expand, res.expand), nil, "expand")
		t.eq(g.win, res.win, "game win") t.eq(g.retrigger, false, "no retrigger")
		sum = sum + g.win
	end
	t.eq(free.win, sum, "free win")
	t.eq(round.win, round.base + sum, "round win")
end)

t.test("round: no free games below three books", function()
	local round = Engine.round(K, 5, "", grid(NO_BOOKS, ALL_BOOKS), 10, 0)
	t.eq(round.free, nil, "free")
	t.eq(round.win, round.base, "win")
end)

t.test("round: retriggers stop at 50 free games", function()
	-- Every free game shows 15 books: 200 x stake each, no line, no expansion (B is not X).
	local round = Engine.round(K, 9, "", grid(TRIGGER, ALL_BOOKS), 10, 0)
	t.eq(round.free.awarded, 50, "awarded")
	t.eq(#round.free.games, 50, "games")
	for i, g in ipairs(round.free.games) do
		t.eq(g.retrigger, true, "retrigger " .. i)
		t.eq(g.win, 2000, "game " .. i .. " win") t.eq(g.expand, nil, "no expansion")
		t.eq(#g.lines, 0, "no line wins")
	end
	t.eq(round.free.win, 100000, "free win")
	t.eq(round.win, round.base + 100000, "round win")
end)

t.test("round: the cap limits the round win only", function()
	local round = Engine.round(K, 9, "", grid(TRIGGER, ALL_BOOKS), 10, 5000)
	t.eq(round.win, 5000, "capped")
	t.eq(round.free.win, 100000, "free win uncapped")
	t.eq(Engine.round(K, 9, "", grid(TRIGGER, ALL_BOOKS), 10, 200000).win, round.base + 100000, "cap above")
end)

-- Searches spin numbers with K on the real T2 strips for a retrigger.
t.test("round: a retrigger on the real strips adds 10 games", function()
	local found
	for n = 1, 200000 do
		local round = Engine.round(K, n, "", T2, 10, 0)
		if round.free and round.free.awarded > 10 then found = round break end
	end
	t.ok(found, "a round with a retrigger")
	local free, retriggers = found.free, 0
	for _, g in ipairs(free.games) do
		if g.retrigger then retriggers = retriggers + 1 end
	end
	t.ok(retriggers >= 1, "retrigger flagged")
	t.eq(free.awarded, math.min(50, 10 + 10 * retriggers), "awarded")
	t.eq(#free.games, free.awarded, "games played")
end)

-- Settings, Ledger, Verify -------------------------------------------------------------------

local Settings, Ledger, Verify = ns.Settings, ns.Ledger, ns.Verify

t.test("settings: with T=T2 every stake must be a multiple of 10", function()
	local s = assert(Settings.parse("GSLOTS1;T=T2"))
	t.eq(s.T, "T2", "T2 with default stakes")
	t.ok(Settings.parse("GSLOTS1;E=10,50,100;T=T2"), "10,50,100")
	t.ok(Settings.parse("GSLOTS1;E=20,1000000;T=T2"), "20,1000000")
	local _, code = Settings.parse("GSLOTS1;E=10,15;T=T2")
	t.eq(code, "bad_stakes", "15 with T2")
	_, code = Settings.parse("GSLOTS1;T=T2;E=5")
	t.eq(code, "bad_stakes", "5 with T2, T first")
	t.ok(Settings.parse("GSLOTS1;E=10,15;T=T1"), "15 with T1")
	t.ok(Settings.parse("GSLOTS1;E=15"), "15 with the default table")
	t.eq(Settings.format({ L = 0, W = 2, R = 1, E = { 15 }, G = 3, C = 0, T = "T2", X = 1000 }), nil, "format")
end)

local NONCE = "fedcba9876543210fedcba9876543210"

local function buy(st, i, line, tokens)
	local seed = string.format("%032x", i)
	local e = { type = "B", buyId = string.format("%016x", i), officer = "Officer", tokens = tokens or 100000,
		commit = Engine.commit(seed), seed = seed, nonce = NONCE, time = 1700000000 + i, line = line }
	return assert(Ledger.apply(st, e)), e, Engine.purchaseKey(e.buyId, seed, NONCE)
end

local function spinEntry(n, stake)
	return { type = "S", n = n, stake = stake, A = 0, status = "ok", contribs = "" }
end

t.test("ledger: a T2 spin plays a round and moves the balance by the round win", function()
	local st = Ledger.start("Guild", "Alice")
	local _, _, key = buy(st, 1, "GSLOTS1;T=T2;G=0")
	local balance = st.balance
	for n = 1, 40 do
		local stake = n % 2 == 0 and 50 or 10
		local info = assert(Ledger.apply(st, spinEntry(n, stake)))
		local want = Engine.round(key, n, "", T2, stake, 0)
		t.eq(diff(info.round, want), nil, "round " .. n)
		t.eq(info.win, want.win, "win") t.eq(info.multiplier, want.win / stake, "multiplier")
		t.eq(info.stops, nil, "no stops")
		balance = balance - stake + want.win
		t.eq(info.balance, balance, "balance") t.eq(st.balance, balance, "state balance")
		t.eq(info.pending, 0, "G=0: no gamble") t.eq(info.head, st.head, "head")
	end
end)

t.test("ledger: T2 stakes outside E or not a multiple of 10 are bad_stake", function()
	local st = Ledger.start("Guild", "Alice")
	buy(st, 1, "GSLOTS1;T=T2")
	local _, code = Ledger.apply(st, spinEntry(1, 20))
	t.eq(code, "bad_stake", "20 not in E")
	-- Settings already reject such E; the ledger rule holds on its own as well.
	st.settings.E = { 15 }
	_, code = Ledger.apply(st, spinEntry(1, 15))
	t.eq(code, "bad_stake", "15")
end)

t.test("ledger: gamble steps after a T2 round risk the round win, capped by C", function()
	local st = Ledger.start("Guild", "Alice")
	buy(st, 1, "GSLOTS1;T=T2;G=2;C=100000")
	local stepped = 0
	for n = 1, 60 do
		local info = assert(Ledger.apply(st, spinEntry(n, 10)))
		local open = info.win > 0 and 2 * info.win <= 100000
		t.eq(info.pending, open and info.win or 0, "pending after round " .. n)
		local g = 0
		while st.pending > 0 do
			g = g + 1
			local before, risk = st.balance, st.pending
			local step = assert(Ledger.apply(st, { type = "G", n = n, g = g, A = 0, status = "ok", contribs = "" }))
			t.eq(step.balance, before + (step.won and risk or -risk), "step balance")
			stepped = stepped + 1
		end
	end
	t.ok(stepped > 0, "some gamble steps")
end)

t.test("verify: a T2 account gets the luck index from the T2 statistics and a round look-ahead", function()
	local st = Ledger.start("Guild", "Alice")
	local _, b, key = buy(st, 1, "GSLOTS1;T=T2;G=0")
	local entries, num, den = { b }, 0, 0
	local stats = Tables.stats(T2, 10, 0)
	for n = 1, 40 do
		local e = spinEntry(n, 10)
		local info = assert(Ledger.apply(st, e))
		entries[#entries + 1] = e
		num = num + 10 * (info.win / 10 - stats.rtp)
		den = den + 100 * stats.variance
	end
	local report = Verify.run({ guild = "Guild", player = "Alice", entries = entries, amount = 1,
		anchor = { anchors = 1, head = Ledger.shortHead(Ledger.replay("Guild", "Alice", { b })) }, known = { [b.buyId] = true },
		isOfficer = function() return true end })
	t.eq(report.light, "green", "no findings: " .. (report.findings[1] and report.findings[1].code or ""))
	t.eq(report.balance, st.balance, "balance")
	t.eq(report.luck.spins, 40, "spins")
	t.near(report.luck.total.z, num / math.sqrt(den), 1e-9, "total z")
	local sum = 0
	for k = 1, 20 do sum = sum + Engine.round(key, 40 + k, "", T2, 10, 0).win / 10 end
	t.near(report.lookahead.sum, sum, 1e-9, "look-ahead sum")
	t.near(report.lookahead.expected, 20 * stats.rtp, 1e-9, "look-ahead expected")
end)

t.test("stats: T2 returns the reference constants for any stake and cap", function()
	local s = assert(Tables.stats(T2, 10, 0))
	for _, f in ipairs({ "rtp", "hit", "variance", "freeRate" }) do
		t.ok(type(s[f]) == "number" and s[f] > 0, f)
	end
	t.eq(Tables.stats(T2, 50, 1000).rtp, s.rtp, "same with stake 50 and a cap")
	local _, code = Tables.stats(T2, 0, 0)
	t.eq(code, "bad_stake", "stake 0")
end)

t.test("the three-reel functions reject T2", function()
	local _, code = Tables.multiplier(T2, 0, 0, 0)
	t.eq(code, "bad_table", "multiplier")
	_, code = Tables.win(T2, 10, 0, 0, 0, 0)
	t.eq(code, "bad_table", "win")
	_, code = Tables.window(T2, 1, 0)
	t.eq(code, "bad_table", "window")
end)

t.test("evaluate rejects bad input", function()
	local _, code = Tables.evaluate(Tables.get("T1"), ONES, 10)
	t.eq(code, "bad_table", "T1")
	_, code = Tables.evaluate(T2, ONES, 15)
	t.eq(code, "bad_stake", "stake not a multiple of 10")
	_, code = Tables.evaluate(T2, { 0, 0, 0, 0, 29 }, 10)
	t.eq(code, "bad_stop", "stop beyond reel 5")
	_, code = Tables.evaluate(T2, ONES, 10, "B")
	t.eq(code, "bad_symbol", "B cannot expand")
end)
