local t, ns = ...
local Anim = ns.Anim

-- Reel timings like the Theme defaults: nudge 0.1 s, ramp 0.2 s, braking 0.4 s, 30 rows/s.
-- Travel without the re-seat is 30 * (stopAt - 0.1 - 0.1 - 0.2) rows: 15 for stopAt 0.9.
local SPEED = 30
local function opts(start, target, extra)
	local o = {
		start = start, target = target, n = 34, stopAt = 0.9,
		nudgeTime = 0.1, nudge = 0.12, accel = 0.2, decel = 0.4, speed = SPEED,
		bounce = 0.2, overshoot = 0.25, quickDecel = 0.2, minReseatSpeed = 20,
	}
	for k, v in pairs(extra or {}) do o[k] = v end
	return o
end

local function eachTarget(fn, extra)
	for target = 0, 33 do
		fn(Anim.plan(opts(7, target, extra)), target)
	end
end

-- Steps between samples that move further than the speed allows (the re-seats).
local function jumps(p, to)
	local dt, count = 1 / 240, 0
	local last = Anim.distance(p, 0)
	for i = 1, math.floor(to / dt + 0.5) do
		local d = Anim.distance(p, i * dt)
		if math.abs(d - last) > SPEED * dt + 1e-6 then
			count = count + 1
		end
		last = d
	end
	return count
end

t.test("cruise speed is the same constant for every target stop", function()
	eachTarget(function(p, target)
		for _, time in ipairs({ 0.31, 0.4, 0.49 }) do
			t.near(Anim.speed(p, time), SPEED, 1e-9, "target " .. target .. " at " .. time)
		end
	end)
end)

t.test("every target stop is hit exactly at the planned time", function()
	eachTarget(function(p, target)
		t.near(Anim.position(p, 0.9), target, 1e-9, "landed on " .. target)
		t.near(Anim.position(p, 3), target, 1e-9, "settled on " .. target)
		t.eq(Anim.landed(p, 0.8999), false, "not landed early")
		t.eq(Anim.landed(p, 0.9), true, "landed")
	end)
end)

t.test("total duration does not depend on the target", function()
	eachTarget(function(p, target)
		t.eq(Anim.done(p, 1.0999), false, "still bouncing, target " .. target)
		t.eq(Anim.done(p, 1.1), true, "done, target " .. target)
	end)
end)

t.test("position is continuous except for one re-seat by whole rows", function()
	eachTarget(function(p, target)
		t.ok(#p.jumps <= 1, "at most one re-seat")
		local want = 0
		for _, j in ipairs(p.jumps) do
			if j.rows ~= 0 then want = want + 1 end
			t.near(j.rows, math.floor(j.rows + 0.5), 1e-9, "whole rows")
		end
		t.eq(jumps(p, 1.2), want, "visible jumps, target " .. target)
	end)
end)

t.test("landing time snaps so that any speed re-seats by whole rows", function()
	-- 28 rows/s * (1.3 - 0.1 - 0.1 - 0.2) s = 25.2 rows -> 25 rows, landing 0.2/28 s earlier
	for target = 0, 33 do
		local p = Anim.plan(opts(7, target, { speed = 28, stopAt = 1.3 }))
		t.near(p.landAt, 1.3 - 0.2 / 28, 1e-9, "landing time")
		t.near(Anim.position(p, p.landAt), target, 1e-9, "on target " .. target)
		for _, j in ipairs(p.jumps) do
			t.near(j.rows, math.floor(j.rows + 0.5), 1e-9, "whole rows")
		end
	end
end)

t.test("re-seats happen at cruise speed and before braking", function()
	eachTarget(function(p)
		for _, j in ipairs(p.jumps) do
			t.ok(Anim.speed(p, j.t) >= 20, "fast enough")
			t.ok(j.t < 0.9 - 0.4, "before braking, so the last rows are true strip neighbours")
		end
	end)
end)

t.test("the spin starts with a small backwards nudge", function()
	local p = Anim.plan(opts(0, 5))
	t.near(Anim.distance(p, 0.05), -0.12, 1e-9, "nudge at its deepest")
	t.near(Anim.distance(p, 0.1), 0, 1e-9, "back at the start")
	t.near(Anim.speed(p, 0.2), SPEED / 2, 1e-9, "half way up the ramp")
end)

t.test("anticipation only lengthens the cruise", function()
	local short = Anim.plan(opts(3, 9))
	local long = Anim.plan(opts(3, 9, { stopAt = 1.7 }))
	for _, time in ipairs({ 0.02, 0.15, 0.25 }) do
		t.near(Anim.speed(long, time), Anim.speed(short, time), 1e-9, "start-up at " .. time)
	end
	for _, u in ipairs({ 0.05, 0.2, 0.39 }) do
		t.near(Anim.speed(long, 1.7 - u), Anim.speed(short, 0.9 - u), 1e-9, "braking " .. u .. " s before landing")
	end
	t.near(Anim.position(long, 1.7), 9, 1e-9, "lands on target")
end)

t.test("landing overshoots downwards and settles", function()
	local p = Anim.plan(opts(0, 0))
	local final = Anim.distance(p, 0.9)
	-- halfway through the bounce: 0.25 * sin(pi/2) * (1 - 0.5)
	t.near(Anim.distance(p, 1.0) - final, 0.125, 1e-9, "overshoot")
	t.near(Anim.distance(p, 1.1), final, 1e-9, "settled")
end)

t.test("quick stop brakes shortly and lands exactly", function()
	eachTarget(function(p, target)
		Anim.quickStop(p, 0.35)
		t.eq(Anim.landed(p, 0.5499), false, "still braking")
		t.eq(Anim.landed(p, 0.55), true, "lands after the short braking")
		t.near(Anim.position(p, 0.55), target, 1e-9, "on target " .. target)
		t.near(Anim.speed(p, 0.35), SPEED, 1e-9, "brakes from cruise speed")
		t.eq(Anim.done(p, 0.75), true, "bounce done")
		for _, j in ipairs(p.jumps) do
			t.ok(Anim.speed(p, j.t) >= 20, "re-seat at speed")
		end
	end)
end)

t.test("quick stop during start-up waits for full speed", function()
	local p = Anim.plan(opts(0, 5))
	Anim.quickStop(p, 0.05)
	t.eq(Anim.landed(p, 0.4999), false, "not before ramp + short braking")
	t.eq(Anim.landed(p, 0.5), true, "lands at 0.3 + 0.2")
	t.near(Anim.position(p, 0.5), 5, 1e-9, "on target")
end)

t.test("quick stop while braking changes nothing", function()
	local p = Anim.plan(opts(0, 5))
	Anim.quickStop(p, 0.6)
	t.eq(Anim.landed(p, 0.8999), false, "keeps braking")
	t.near(Anim.position(p, 0.9), 5, 1e-9, "lands as planned")
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

t.test("cell gives the same stops and rows as cells, without a table", function()
	for _, x in ipairs({ 0, 0.25, 7.5, 33.9 }) do
		local list = Anim.cells(x, 34)
		for j = -2, 2 do
			local index, row = Anim.cell(x, 34, j)
			t.eq(index, list[j + 3].index, "index at " .. x .. " / " .. j)
			t.near(row, list[j + 3].row, 1e-12, "row at " .. x .. " / " .. j)
		end
	end
end)

t.test("shuffle runs through the candidates and lands on the final one", function()
	local seen, last, changes = {}, nil, 0
	for i = 0, 200 do
		local v = Anim.shuffle(i / 100, 2, 9, 6)
		t.ok(v >= 1 and v <= 9, "in range")
		seen[v] = true
		if last and v ~= last then changes = changes + 1 end
		last = v
	end
	for k = 1, 9 do t.ok(seen[k], "candidate " .. k .. " shown") end
	t.eq(Anim.shuffle(2, 2, 9, 6), 6, "final at the end")
	t.eq(Anim.shuffle(5, 2, 9, 6), 6, "stays final")
	-- slows down: more changes in the first half than in the second
	local first, second = 0, 0
	local prev = Anim.shuffle(0, 2, 9, 6)
	for i = 1, 200 do
		local v = Anim.shuffle(i / 100, 2, 9, 6)
		if v ~= prev then
			if i <= 100 then first = first + 1 else second = second + 1 end
		end
		prev = v
	end
	t.ok(first > second, "slows down")
end)

t.test("particles start at the emitter, fly within bounds and fade", function()
	for i = 1, 16 do
		local x0, y0, a0 = Anim.particle(i, 0, 2)
		t.near(x0, 0, 1e-9, "x at start")
		t.near(y0, 0, 1e-9, "y at start")
		t.ok(a0 > 0.9, "visible at start")
		for k = 1, 19 do
			local x, y, a = Anim.particle(i, k * 0.1 - 0.001, 2, 0)
			t.ok(x >= -1 and x <= 1, "x bounded")
			t.ok(y >= -2 and y <= 1.5, "y bounded")
			t.ok(a >= 0 and a <= 1, "alpha")
		end
	end
	local x1 = Anim.particle(1, 0.5, 2)
	local x2 = Anim.particle(1, 0.5, 2)
	t.eq(x1, x2, "deterministic")
end)
