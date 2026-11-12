local t, ns = ...
local Anim = ns.Anim

local function opts(start, target, extra)
	local o = {
		start = start, target = target, n = 34, stopAt = 1,
		accel = 0.2, decel = 0.4, speed = 10, bounce = 0.2, overshoot = 0.25,
	}
	for k, v in pairs(extra or {}) do o[k] = v end
	return o
end

t.test("a reel plan travels whole revolutions to land on the same stop", function()
	-- 10 rows/s over 0.7 s effective = 7 rows nominal; the next multiple of 34 is 34.
	local p = Anim.plan(opts(0, 0))
	t.eq(p.distance, 34, "distance")
	t.near(Anim.distance(p, 0), 0, 1e-9, "start")
	t.near(Anim.distance(p, 1), 34, 1e-9, "landed")
	t.near(Anim.position(p, 1), 0, 1e-9, "position")
end)

t.test("a reel plan lands exactly on the target stop", function()
	-- start 5, target 2: 3 rows down plus one revolution (7 rows nominal) = 37
	local p = Anim.plan(opts(5, 2))
	t.eq(p.distance, 37, "distance")
	t.near(Anim.position(p, 1), 2, 1e-9, "position at stop")
	t.near(Anim.position(p, 5), 2, 1e-9, "position long after")
end)

t.test("the reel never moves backwards before it lands", function()
	local p = Anim.plan(opts(7, 30))
	local last = -1
	for i = 0, 100 do
		local d = Anim.distance(p, i / 100)
		t.ok(d >= last - 1e-9, "monotonic at " .. i)
		last = d
	end
end)

t.test("landing overshoots downwards and settles", function()
	local p = Anim.plan(opts(0, 0))
	-- halfway through the bounce: 0.25 * sin(pi/2) * (1 - 0.5)
	t.near(Anim.distance(p, 1.1), 34.125, 1e-9, "overshoot")
	t.near(Anim.distance(p, 1.2), 34, 1e-9, "settled")
	t.eq(Anim.done(p, 1.19), false, "still bouncing")
	t.eq(Anim.done(p, 1.2), true, "done")
	t.eq(Anim.landed(p, 0.99), false, "not landed")
	t.eq(Anim.landed(p, 1), true, "landed")
end)

t.test("quick stop lands the reel at the given time", function()
	local p = Anim.plan(opts(5, 2))
	Anim.quickStop(p, 0.3)
	t.ok(Anim.distance(p, 0.29) < 37, "still running before")
	t.eq(Anim.landed(p, 0.3), true, "landed at quick stop")
	t.near(Anim.position(p, 0.5), 2, 1e-9, "on target after bounce")
	-- a later quick stop does not delay the landing
	local q = Anim.plan(opts(5, 2))
	Anim.quickStop(q, 3)
	t.eq(Anim.landed(q, 1), true, "original stop kept")
end)

t.test("cells lists five strip stops with rows, moving down as the position falls", function()
	local c = Anim.cells(2.25, 34)
	t.eq(#c, 5, "count")
	t.eq(c[1].index, 0, "top index")
	t.near(c[1].row, -2.25, 1e-9, "top row")
	t.eq(c[3].index, 2, "middle index")
	t.near(c[3].row, -0.25, 1e-9, "stop 2 just above the payline")
	t.eq(c[4].index, 3, "index below")
	t.near(c[4].row, 0.75, 1e-9, "stop 3 has moved down")
end)

t.test("cells wrap around the strip", function()
	local c = Anim.cells(0.5, 34)
	t.eq(c[1].index, 32, "wraps to the end")
	t.eq(c[2].index, 33, "last stop")
	t.eq(c[3].index, 0, "first stop")
	local w = Anim.cells(33.75, 34)
	t.eq(w[5].index, 1, "wraps to the start")
end)

t.test("clip gives the visible part of a cell inside the window", function()
	local top, bottom = Anim.clip(0, 1.5)
	t.eq(top, 0, "full top")
	t.eq(bottom, 1, "full bottom")
	top, bottom = Anim.clip(1.25, 1.5)
	t.near(top, 0, 1e-9, "bottom cell top")
	t.near(bottom, 0.75, 1e-9, "bottom cell cut")
	top, bottom = Anim.clip(-1.25, 1.5)
	t.near(top, 0.25, 1e-9, "top cell cut")
	t.near(bottom, 1, 1e-9, "top cell bottom")
	t.eq(Anim.clip(2, 1.5), nil, "outside")
end)

t.test("countUp eases from one amount to another in whole numbers", function()
	t.eq(Anim.countUp(0, 100, 0, 1), 0, "start")
	t.eq(Anim.countUp(0, 100, 0.5, 1), 75, "ease out")
	t.eq(Anim.countUp(0, 100, 1, 1), 100, "end")
	t.eq(Anim.countUp(0, 100, 7, 1), 100, "after end")
	t.eq(Anim.countUp(50, 10, 1, 1), 10, "down")
	t.eq(Anim.countUp(0, 100, 0, 0), 100, "zero duration")
end)

t.test("pulse oscillates between 0 and 1", function()
	t.near(Anim.pulse(0, 1), 0, 1e-9, "start")
	t.near(Anim.pulse(0.5, 1), 1, 1e-9, "peak")
	t.near(Anim.pulse(1, 1), 0, 1e-9, "period")
end)

t.test("formatNumber groups thousands", function()
	t.eq(Anim.formatNumber(0), "0", "zero")
	t.eq(Anim.formatNumber(999), "999", "small")
	t.eq(Anim.formatNumber(1234567), "1,234,567", "millions")
	t.eq(Anim.formatNumber(-1500, "."), "-1.500", "negative with separator")
end)
