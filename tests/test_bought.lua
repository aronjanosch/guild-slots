local t, ns = ...
local Tables, Solo, Plan = ns.Tables, ns.Solo, ns.Plan

-- Bought free-game series (docs/table-t2-spec.md, "Bought free games (solo only)").
-- Free stops 33,55,50,5,29 with M: three books (retrigger) and an expansion; 1,1,1,1,1: nothing.

local T2 = Tables.get("T2")
local M_INDEX = 5

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

local function bought(freeList, cap, stake)
	return Tables.playBought(T2, stake or 10, cap or 0, {
		base = function() error("a bought series has no base game") end,
		symbol = function() return M_INDEX end,
		free = function(i) return freeList and freeList[i] or { 1, 1, 1, 1, 1 } end,
	})
end

t.test("the price lives in the table definition", function()
	t.eq(T2.buyPrice, 64, "64 x the stake")
end)

t.test("a bought series has the round shape with no base-game win", function()
	local r = bought()
	t.eq(r.kind, "lines", "kind")
	t.eq(r.bought, true, "bought")
	t.eq(r.base, 0, "no base win")
	t.eq(#r.lines, 0, "no lines")
	t.eq(r.scatter.count, 0, "no books")
	t.eq(r.scatter.win, 0, "no scatter win")
	t.eq(r.cost, 640, "cost = price x stake")
	t.eq(r.stake, 10, "stake")
	t.eq(r.lineBet, 1, "line bet")
	t.eq(r.free.symbol, "M", "expanding symbol")
	t.eq(r.free.awarded, 10, "ten games")
	t.eq(#r.free.games, 10, "ten games played")
	t.eq(r.win, r.free.win, "the win is the series")
end)

t.test("a bought series follows the free-game rules: retrigger and the cap", function()
	local r = bought({ { 33, 55, 50, 5, 29 } })
	t.eq(r.free.awarded, 20, "a retrigger adds ten")
	t.eq(r.free.games[1].retrigger, true, "first game retriggers")
	t.eq(r.free.games[1].expand.win, 300, "expansion")
	local all = {}
	for i = 1, 60 do all[i] = { 33, 55, 50, 5, 29 } end
	local long = bought(all)
	t.eq(long.free.awarded, 50, "at most 50 games")
	local c = bought({ { 33, 55, 50, 5, 29 } }, 500)
	t.eq(c.win, 500, "the cap limits the win")
	t.ok(c.free.win > 500, "the series itself is uncapped")
end)

t.test("the bought series plays the same games as a triggered one", function()
	local free = { { 33, 55, 50, 5, 29 } }
	local r = bought(free)
	local triggered = Tables.playRound(T2, 10, 0, {
		base = function() return { 40, 35, 52, 0, 0 } end,
		symbol = function() return M_INDEX end,
		free = function(i) return free[i] or { 1, 1, 1, 1, 1 } end,
	})
	t.eq(r.free.win, triggered.free.win, "same series win")
	t.eq(r.free.awarded, triggered.free.awarded, "same games")
end)

t.test("a bought series is a valid presentation plan", function()
	local p = Plan.build(bought({ { 33, 55, 50, 5, 29 } }), ns.Theme.timing, T2)
	local first = p.steps[1]
	t.eq(first.kind, "intro", "starts with the intro, no base spin")
	t.eq(first.bought, true, "intro knows the series was bought")
	t.eq(first.symbol, "M", "symbol reveal")
	local spins, sum = 0, 0
	for _, s in ipairs(p.steps) do
		if s.kind == "spin" then
			spins = spins + 1
			t.ok(s.game > 0 and s.free, "only free spins")
		end
		sum = sum + (s.amount or 0)
	end
	t.eq(spins, 20, "one spin per free game")
	t.eq(sum, 1075, "amounts sum to the series win") -- game 1 pays 1075, the rest nothing
	t.eq(p.steps[#p.steps].kind, "end", "ends")
	t.eq(p.steps[#p.steps].total, 1075, "final total")
end)

t.test("Solo:buy pays the price and the series, codes for the refusals", function()
	local rng = { M_INDEX, 33, 55, 50, 5, 29 }
	for _ = 2, 20 do
		for _, v in ipairs({ 1, 1, 1, 1, 1 }) do rng[#rng + 1] = v end
	end
	local g = Solo.new({ table = "T2", rng = seq(unpack(rng)) })
	t.eq(g:info().buy.price, 64, "info shows the price")
	local r = g:buy()
	t.eq(r.kind, "buy", "kind")
	t.eq(r.cost, 640, "cost")
	t.eq(r.win, 1075, "series win")
	t.eq(r.round.bought, true, "bought round")
	t.eq(g.balance, 1000 - 640 + 1075, "balance")
	t.eq(g:state(), "gamble", "take / gamble offered on the series win")
	local _, code = g:buy()
	t.eq(code, "busy", "not while the offer is open")
	g:take()
	g.balance = 639
	_, code = g:buy()
	t.eq(code, "no_funds", "not without the price")
	t.eq(g.balance, 639, "nothing taken")
	local t1 = Solo.new({ table = "T1", rng = seq() })
	_, code = t1:buy()
	t.eq(code, "unsupported", "classic table")
	t.eq(t1:info().buy, nil, "no buy on T1")
end)

t.test("200,000 bought series return about 94 % of the price", function()
	local seed = 20261112
	local function rng(n)
		-- Park-Miller with Schrage's method: exact in doubles.
		local hi = math.floor(seed / 127773)
		seed = 16807 * (seed - hi * 127773) - 2836 * hi
		if seed <= 0 then seed = seed + 2147483647 end
		return seed % n
	end
	local draw = {
		symbol = function() return rng(#T2.expanding) end,
		free = function()
			local s = {}
			for r = 1, 5 do s[r] = rng(#T2.freeReels[r]) end
			return s
		end,
	}
	local N, sum = 200000, 0
	for _ = 1, N do
		sum = sum + Tables.playBought(T2, 10, 0, draw).win
	end
	local ret = sum / N / 10 / T2.buyPrice
	t.ok(ret >= 0.92 and ret <= 0.96, "mean return " .. ret)
end)

t.test("200,000 bought T3 series return about 93 % of the price", function()
	-- Exact: 59.51 x the stake per series (tools/ref/t3_stats.json), 0.930 of the price 64.
	local T3 = Tables.get("T3")
	local seed = 20261113
	local function rng(n)
		local hi = math.floor(seed / 127773)
		seed = 16807 * (seed - hi * 127773) - 2836 * hi
		if seed <= 0 then seed = seed + 2147483647 end
		return seed % n
	end
	local draw = {
		symbol = function() return rng(#T3.expanding) end,
		free = function()
			local s = {}
			for r = 1, 5 do s[r] = rng(#T3.freeReels[r]) end
			return s
		end,
	}
	local N, sum = 200000, 0
	for _ = 1, N do
		sum = sum + Tables.playBought(T3, 10, 0, draw).win
	end
	local ret = sum / N / 10 / T3.buyPrice
	t.ok(ret >= 0.91 and ret <= 0.95, "mean return " .. ret)
end)
