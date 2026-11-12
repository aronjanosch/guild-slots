local t, ns = ...
local Stats, Auto, Ticker, Anim = ns.Stats, ns.Auto, ns.Ticker, ns.Anim

-- Session statistics, autoplay rules, the guild ticker queue and the window shake.

local function result(stake, win, free, cost)
	return { stake = stake, win = win, cost = cost, round = { free = free and {} or nil } }
end

t.test("session numbers after a known sequence of rounds", function()
	local b = Stats.new()
	b:round("solo", result(10, 0))
	b:round("solo", result(10, 30))
	b:round("solo", result(10, 50))
	b:round("solo", result(10, 1185, true))
	b:round("solo", result(10, 0))
	b:round("solo", result(10, 0))
	local s = b:get("solo")
	t.eq(s.rounds, 6, "rounds")
	t.eq(s.staked, 60, "staked")
	t.eq(s.won, 1265, "won")
	t.eq(s.net, 1205, "net")
	t.eq(s.best, 1185, "best")
	t.near(s.bestMult, 118.5, 1e-9, "best multiplier")
	t.eq(s.streak, -2, "two losses in a row")
	t.eq(s.series, 1, "one free-game series")
	b:round("solo", result(10, 20))
	t.eq(b:get("solo").streak, 1, "a win starts a winning streak")
end)

t.test("gamble steps change the net, modes are separate, reset clears one", function()
	local b = Stats.new()
	b:round("solo", result(10, 30))
	b:gamble("solo", { won = true, amount = 30 })
	b:gamble("solo", { won = false, amount = 60 })
	t.eq(b:get("solo").net, 30 - 10 + 30 - 60, "net with gamble")
	b:round("guild", result(50, 0))
	t.eq(b:get("guild").rounds, 1, "guild counted apart")
	t.eq(b:get("solo").rounds, 1, "solo unchanged")
	b:reset("solo")
	t.eq(b:get("solo").rounds, 0, "solo reset")
	t.eq(b:get("guild").rounds, 1, "guild kept")
end)

t.test("a bought series counts its price as staked", function()
	local b = Stats.new()
	b:round("solo", { stake = 10, cost = 640, win = 700, round = { bought = true, free = {} } })
	local s = b:get("solo")
	t.eq(s.staked, 640, "price")
	t.eq(s.series, 1, "series")
	t.near(s.bestMult, 70, 1e-9, "multiple of the stake")
end)

t.test("autoplay counts rounds and stops on its conditions", function()
	local a = Auto.new({ rounds = 2 })
	t.eq(a:take(), true, "first")
	t.eq(a:after(result(10, 0), 990), nil, "go on")
	t.eq(a:take(), true, "second")
	t.eq(a:after(result(10, 0), 980), "done", "done after two")
	local ok, why = a:take()
	t.eq(ok, false, "no third")
	t.eq(why, "done", "done")

	local endless = Auto.new({ rounds = 0 })
	for _ = 1, 500 do t.eq(endless:take(), true, "until stopped") end
	t.eq(endless.left, nil, "no count")

	t.eq(Auto.new({ stopFree = true }):after(result(10, 50, true), 1000), "free", "free games")
	t.eq(Auto.new({ stopFree = false }):after(result(10, 50, true), 1000), nil, "free games off")
	t.eq(Auto.new({ stopWin = 20 }):after(result(10, 200), 1000), "win", "20 x the stake")
	t.eq(Auto.new({ stopWin = 20 }):after(result(10, 190), 1000), nil, "below 20 x")
	t.eq(Auto.new({ stopWin = 0 }):after(result(10, 100000), 1000), nil, "off")
	t.eq(Auto.new({ stopBelow = 500 }):after(result(10, 0), 499), "below", "balance below")
	t.eq(Auto.new({ stopBelow = 500 }):after(result(10, 0), 500), nil, "not below")
	t.eq(Auto.new({}):refused("wait"), "retry", "wait retries")
	t.eq(Auto.new({}):refused("no_funds"), "stop", "anything else stops")
end)

t.test("the ticker shows entries one after another, at most max waiting", function()
	local q = Ticker.new(4, 3)
	t.eq(q:update(0), nil, "empty")
	q:push({ player = "A" })
	q:push({ player = "B" })
	local e, dt = q:update(1)
	t.eq(e.player, "A", "first")
	t.eq(dt, 0, "just started")
	t.eq(q:update(4.9).player, "A", "still A")
	t.eq(q:update(5).player, "B", "then B")
	t.eq(q:update(9), nil, "then nothing")
	for i = 1, 5 do q:push({ player = "P" .. i }) end
	t.eq(q:update(10).player, "P3", "older waiting entries dropped")
	q:clear()
	t.eq(q:update(11), nil, "cleared")
end)

t.test("ticker texts", function()
	local L = { TICKER_WIN = "%s wins %s (x%s)", TICKER_FREE = "%s hits %d free games", TICKER_WIN_PLAIN = "%s wins %s" }
	local function fmt(n) return Anim.formatNumber(n, ",") end
	t.eq(Ticker.text({ player = "Bob", win = 5000, mult = 100, level = "legendary" }, L, fmt), "Bob wins 5,000 (x100)")
	t.eq(Ticker.text({ player = "Bob", win = 5000, mult = 100, free = 10, level = "free" }, L, fmt), "Bob hits 10 free games")
	t.eq(Ticker.text({ player = "Bob", win = 125, mult = 12.5, level = "big" }, L, fmt), "Bob wins 125 (x12.5)")
	local _, level = Ticker.text({ player = "Bob", win = 1, level = "huge" }, L, fmt)
	t.eq(level, "huge", "level for the colour")
end)

t.test("the shake dies away and ends exactly at rest", function()
	local x, y = Anim.shake(0, 0.4, 4, 17)
	t.eq(x, 0, "rest at 0")
	t.eq(y, 0, "rest at 0")
	x, y = Anim.shake(0.4, 0.4, 4, 17)
	t.ok(x == 0 and y == 0, "rest at the end")
	local moved = false
	for i = 1, 39 do
		local dx, dy = Anim.shake(i / 100, 0.4, 4, 17)
		t.ok(math.abs(dx) <= 4 and math.abs(dy) <= 4, "within the amplitude")
		if math.abs(dx) > 1 then moved = true end
	end
	t.ok(moved, "it moves")
end)
