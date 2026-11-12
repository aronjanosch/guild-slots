local t, ns = ...
local Solo = ns.Solo

-- rng that returns the given values in order, one per call.
local function seq(...)
	local values, i = { ... }, 0
	return function(n)
		i = i + 1
		local v = values[i]
		assert(v ~= nil, "rng called too often")
		assert(v >= 0 and v < n, "rng value out of range")
		return v
	end
end

-- T1 strip: stop 0 = K, 1 = S, 2 = G, 19 = D.

t.test("a new game starts idle with 1000 and the smallest stake", function()
	local g = Solo.new({ table = "T1", rng = seq() })
	t.eq(g:state(), "idle", "state")
	t.eq(g.balance, 1000, "balance")
	t.eq(g.stake, 10, "stake")
	t.eq(#g.stakes, 3, "stake count")
end)

t.test("a losing spin takes the stake and returns display data", function()
	local g = Solo.new({ table = "T1", rng = seq(0, 1, 2) })
	local r = g:spin()
	t.eq(r.kind, "spin", "kind")
	t.eq(r.stops[1], 0, "stop 1")
	t.eq(r.stops[3], 2, "stop 3")
	t.eq(r.symbols[1], "K", "symbol 1")
	t.eq(r.symbols[2], "S", "symbol 2")
	t.eq(r.symbols[3], "G", "symbol 3")
	-- window of reel 1 at stop 0: above wraps to the last stop (S), centre K, below S
	t.eq(r.window[1][1], "S", "above")
	t.eq(r.window[1][2], "K", "centre")
	t.eq(r.window[1][3], "S", "below")
	t.eq(r.multiplier, 0, "multiplier")
	t.eq(r.win, 0, "win")
	t.eq(r.balance, 990, "balance in result")
	t.eq(g.balance, 990, "balance")
	t.eq(r.canGamble, false, "no gamble")
	t.eq(g:state(), "idle", "state")
end)

t.test("a triple win pays stake times multiplier and offers a gamble", function()
	local g = Solo.new({ table = "T1", rng = seq(19, 19, 19) })
	g:setStake(50)
	local r = g:spin()
	t.eq(r.multiplier, 500, "multiplier")
	t.eq(r.win, 25000, "win")
	t.eq(r.balance, 1000 - 50 + 25000, "balance")
	t.eq(r.canGamble, true, "gamble offered")
	t.eq(r.pending, 25000, "pending")
	t.eq(r.winReels[1] and r.winReels[2] and r.winReels[3], true, "all reels win")
	t.eq(g:state(), "gamble", "state")
end)

t.test("a pair marks reels 1 and 2 as winning and flags anticipation", function()
	local g = Solo.new({ table = "T1", rng = seq(1, 1, 0) })
	local r = g:spin()
	t.eq(r.multiplier, 2, "pair S")
	t.eq(r.win, 20, "win")
	t.eq(r.winReels[1], true, "reel 1")
	t.eq(r.winReels[2], true, "reel 2")
	t.eq(r.winReels[3], false, "reel 3")
	t.eq(r.anticipation, true, "reels 1 and 2 match")
end)

t.test("no anticipation when reels 1 and 2 differ", function()
	local r = Solo.new({ table = "T1", rng = seq(0, 1, 1) }):spin()
	t.eq(r.anticipation, false, "anticipation")
	t.eq(r.winReels[2], false, "reel 2 does not win")
end)

t.test("take closes the gamble offer and keeps the win", function()
	local g = Solo.new({ table = "T1", rng = seq(1, 1, 0) })
	g:spin()
	local r = g:take()
	t.eq(r.kind, "take", "kind")
	t.eq(r.amount, 20, "amount")
	t.eq(r.balance, 1010, "balance")
	t.eq(g:state(), "idle", "state")
	t.eq(g.pending, 0, "pending")
end)

t.test("a won gamble doubles the amount at stake", function()
	local g = Solo.new({ table = "T1", rng = seq(1, 1, 0, 0) })
	g:spin() -- balance 1010, pending 20
	local r = g:gamble()
	t.eq(r.kind, "gamble", "kind")
	t.eq(r.won, true, "won")
	t.eq(r.step, 1, "step")
	t.eq(r.amount, 20, "amount risked")
	t.eq(r.pending, 40, "now at stake")
	t.eq(r.balance, 1030, "balance")
	t.eq(r.canGamble, true, "can gamble again")
	t.eq(g:state(), "gamble", "state")
end)

t.test("a lost gamble loses the amount at stake", function()
	local g = Solo.new({ table = "T1", rng = seq(1, 1, 0, 1) })
	g:spin()
	local r = g:gamble()
	t.eq(r.won, false, "lost")
	t.eq(r.pending, 0, "nothing at stake")
	t.eq(r.balance, 990, "balance back to before the win")
	t.eq(r.canGamble, false, "no further gamble")
	t.eq(g:state(), "idle", "state")
end)

t.test("at most three gamble steps, then the win is kept", function()
	local g = Solo.new({ table = "T1", rng = seq(1, 1, 0, 0, 0, 0) })
	g:spin()
	g:gamble()
	g:gamble()
	local r = g:gamble()
	t.eq(r.step, 3, "step")
	t.eq(r.won, true, "won")
	t.eq(r.canGamble, false, "limit reached")
	t.eq(r.balance, 1000 - 10 + 160, "pair S 20 doubled three times")
	t.eq(g:state(), "idle", "state")
	local _, err = g:gamble()
	t.eq(err, "no_gamble", "fourth step refused")
end)

t.test("gamble and take are refused without a win", function()
	local g = Solo.new({ table = "T1", rng = seq() })
	local r, err = g:gamble()
	t.eq(r, nil, "no result")
	t.eq(err, "no_gamble", "code")
	t.eq(select(2, g:take()), "no_gamble", "take code")
end)

t.test("spinning during a gamble offer takes the win first", function()
	local g = Solo.new({ table = "T1", rng = seq(1, 1, 0, 0, 1, 2) })
	g:spin() -- 1010
	local r = g:spin()
	t.eq(r.balance, 1000, "1010 minus stake 10")
	t.eq(g.pending, 0, "pending cleared")
end)

t.test("spin is refused when the balance is below the stake", function()
	local g = Solo.new({ table = "T1", rng = seq(0, 1, 2), start = 15 })
	g:spin()
	local r, err = g:spin()
	t.eq(r, nil, "no result")
	t.eq(err, "no_funds", "code")
	t.eq(g.balance, 5, "balance unchanged")
end)

t.test("setStake accepts only offered stakes and only when idle", function()
	local g = Solo.new({ table = "T1", rng = seq(1, 1, 0) })
	t.eq(g:setStake(100), true, "100 ok")
	t.eq(g.stake, 100, "stake")
	local ok, err = g:setStake(20)
	t.eq(ok, nil, "20 refused")
	t.eq(err, "bad_stake", "code")
	g:setStake(10)
	g:spin()
	t.eq(select(2, g:setStake(50)), "busy", "refused during gamble offer")
end)

t.test("refill resets the balance to 1000 and drops a gamble offer", function()
	local g = Solo.new({ table = "T1", rng = seq(19, 19, 19) })
	g:spin()
	local r = g:refill()
	t.eq(r.kind, "refill", "kind")
	t.eq(r.balance, 1000, "balance")
	t.eq(g:state(), "idle", "state")
end)

t.test("a saved balance can be restored", function()
	local g = Solo.new({ table = "T1", rng = seq(), balance = 4321 })
	t.eq(g.balance, 4321, "balance")
	t.eq(Solo.new({ table = "T1", rng = seq(), balance = -5 }).balance, 1000, "bad value ignored")
end)

t.test("info gives pair/triple multipliers and the return rate", function()
	local info = Solo.new({ table = "T1", rng = seq() }):info()
	t.eq(info.pair.D, 50, "pair D")
	t.eq(info.triple.K, 5, "triple K")
	t.ok(info.rtp > 0 and info.rtp < 2, "rtp plausible")
	t.eq(info.order[1], "D", "best symbol first")
	t.eq(info.maxGamble, 3, "gamble steps")
end)

-- Table T2 (the default). Base stops 1,16,0,0,0: line 5 shows M M M (30 at stake 10).
-- Base stops 40,35,52,0,0: three books on the middle line, free games. Free stops 33,55,50,5,29
-- with M expanding: three books again (retrigger) and M on reels 3, 4, 5.
local function rep(list, times)
	local out = {}
	for _ = 1, times do
		for _, v in ipairs(list) do out[#out + 1] = v end
	end
	return out
end

local function seqList(list)
	return seq(unpack(list))
end

t.test("T3 is the default table with stakes 10, 50, 100", function()
	local g = Solo.new({ rng = seq() })
	t.eq(g.tbl.id, "T3", "table")
	t.eq(table.concat(g.stakes, ","), "10,50,100", "stakes")
end)

t.test("a T2 losing round carries the round and no T1 fields", function()
	local g = Solo.new({ table = "T2", rng = seq(0, 0, 0, 0, 0) })
	local r = g:spin()
	t.eq(r.kind, "spin", "kind")
	t.eq(r.stake, 10, "stake")
	t.eq(r.win, 0, "win")
	t.eq(r.balance, 990, "balance")
	t.eq(r.canGamble, false, "no gamble")
	t.eq(r.round.kind, "lines", "round kind")
	t.eq(table.concat(r.round.stops, ","), "0,0,0,0,0", "stops")
	t.eq(r.round.window[1][1], "B", "reel 1 top")
	t.eq(r.round.free, nil, "no free games")
	t.eq(r.stops, nil, "no T1 stops")
	t.eq(r.symbols, nil, "no T1 symbols")
	t.eq(r.winReels, nil, "no T1 winReels")
end)

t.test("a T2 line win pays and offers the gamble", function()
	local g = Solo.new({ table = "T2", rng = seq(1, 16, 0, 0, 0) })
	local r = g:spin()
	t.eq(r.win, 30, "win")
	t.eq(#r.round.lines, 1, "one line")
	t.eq(r.round.lines[1].line, 5, "line 5")
	t.eq(r.round.lines[1].symbol, "M", "symbol")
	t.eq(r.balance, 1020, "balance")
	t.eq(r.pending, 30, "pending")
	t.eq(r.canGamble, true, "gamble")
end)

t.test("T2 free games: symbol from rng(9), ten games, a retrigger adds ten", function()
	-- base, X = M (index 5), game 1 retriggers, games 2..20 lose.
	local values = { 40, 35, 52, 0, 0, 5, 33, 55, 50, 5, 29 }
	for _, v in ipairs(rep({ 1, 1, 1, 1, 1 }, 19)) do values[#values + 1] = v end
	local g = Solo.new({ table = "T2", rng = seqList(values) })
	local r = g:spin()
	local free = r.round.free
	t.ok(free, "free games")
	t.eq(free.symbol, "M", "expanding symbol")
	t.eq(free.awarded, 20, "10 + 10 games")
	t.eq(free.games[1].retrigger, true, "retrigger")
	t.eq(free.games[1].expand.win, 300, "expansion on three reels at stake 10")
	t.eq(r.round.base, 110, "base win")
	t.eq(free.win, 1075, "free win")
	t.eq(r.win, 110 + 1075, "round win")
	t.eq(g.balance, 1000 - 10 + 1185, "balance")
end)

t.test("T2 free games stop at 50 and the cap limits the round win", function()
	-- Every free game retriggers.
	local values = { 40, 35, 52, 0, 0, 5 }
	for _, v in ipairs(rep({ 33, 55, 50, 5, 29 }, 50)) do values[#values + 1] = v end
	local g = Solo.new({ table = "T2", rng = seqList(values), cap = 5000 })
	local r = g:spin()
	t.eq(r.round.free.awarded, 50, "at most 50 games")
	t.eq(r.win, 5000, "capped")
	t.eq(g.balance, 1000 - 10 + 5000, "balance")
end)

t.test("T2 info gives pays, lines, scatter and the return rate", function()
	local info = Solo.new({ table = "T2", rng = seq() }):info()
	t.eq(info.kind, "lines", "kind")
	t.eq(info.pays.L[5], 5000, "L five")
	t.eq(#info.lines, 10, "lines")
	t.eq(info.scatter.symbol, "B", "scatter")
	t.eq(info.order[1], "L", "best symbol first")
	t.near(info.rtp, 0.95, 0.001, "rtp")
	t.eq(info.lineBet, 1, "line bet at stake 10")
	t.eq(info.maxGamble, 3, "gamble steps")
end)
