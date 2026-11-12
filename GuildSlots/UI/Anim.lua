local _, ns = ...

-- Pure animation math for the slot window: reel motion, clipping, count-ups.
-- No WoW API; tested by tests/test_anim.lua.
--
-- Reel model: a reel's position x is a float stop index (0..n). The symbol at stop i is
-- drawn at row (i - x) relative to the payline, positive rows below. Spinning moves the
-- reel downwards, so x falls by the travelled distance d: x = (start - d) mod n.

local Anim = {}
ns.Anim = Anim

local floor, sin, cos, pi = math.floor, math.sin, math.cos, math.pi

local function clamp01(u)
	if u < 0 then return 0 end
	if u > 1 then return 1 end
	return u
end

function Anim.easeOutQuad(u)
	u = clamp01(u)
	return 1 - (1 - u) * (1 - u)
end

-- Reel plan. opts:
--   start, target   0-based stops; n strip length
--   stopAt          landing time in s (anticipation just passes a later stopAt)
--   nudgeTime, nudge  short backwards nudge before the start (s, rows; 0 = none)
--   accel           s of linear ramp up to `speed`
--   speed           cruise speed in rows/s, the same for every spin and reel
--   decel           s of constant braking that ends at stopAt
--   quickDecel      s of braking after a quick stop
--   bounce, overshoot  landing bounce (s, rows)
--   minReseatSpeed  a re-seat is only allowed at or above this speed (default speed * 0.6)
--
-- Every spin of a reel has the same speed profile: nudge, ramp, cruise, braking, bounce. Only
-- the cruise length depends on stopAt. To land on `target` anyway, the strip position is
-- re-seated once in the middle of the cruise: a jump of whole rows that cannot be seen at
-- cruise speed. For that, the landing time is shifted by at most 1/(2 * speed) s so the
-- profile itself travels whole rows (p.landAt is the real landing time). After the
-- jump the reel runs through the true strip, so the last rows before landing are the real
-- neighbours of the stop.
function Anim.plan(o)
	local p = {
		start = o.start,
		target = o.target,
		n = o.n,
		v = o.speed,
		tn = o.nudgeTime or 0,
		nudge = o.nudge or 0,
		ta = o.accel,
		quickDecel = o.quickDecel or o.decel,
		bounce = o.bounce or 0,
		overshoot = o.overshoot or 0,
		minReseat = o.minReseatSpeed or o.speed * 0.6,
	}
	-- Shift the landing time a little so the profile travels a whole number of rows; then the
	-- re-seat is a whole-row jump for every target.
	local travel = p.v * (o.stopAt - p.tn - p.ta / 2 - o.decel / 2)
	local stopAt = o.stopAt + (floor(travel + 0.5) - travel) / p.v
	p.cruiseAt = p.tn + p.ta
	p.decelAt = stopAt - o.decel
	assert(p.decelAt >= p.cruiseAt, "Anim.plan: stopAt too early for nudge + accel + decel")
	p.h = o.decel
	p.landAt = stopAt
	p.jumps = {}
	Anim.reseat(p, (p.cruiseAt + p.decelAt) / 2)
	return p
end

-- Distance travelled by the speed profile alone (no re-seats, no bounce).
local function raw(p, t)
	local v = p.v
	if t <= 0 then
		return 0
	end
	if t < p.tn then
		return -p.nudge * sin(pi * t / p.tn)
	end
	if t < p.cruiseAt then
		local u = t - p.tn
		return v * u * u / (2 * p.ta)
	end
	local cruiseEnd = v * p.ta / 2 + v * (p.decelAt - p.cruiseAt)
	if t < p.decelAt then
		return v * p.ta / 2 + v * (t - p.cruiseAt)
	end
	local u = math.min(t, p.landAt) - p.decelAt
	return cruiseEnd + v * u - v * u * u / (2 * p.h)
end

local function jumped(p, t)
	local sum = 0
	for _, j in ipairs(p.jumps) do
		if t >= j.t then
			sum = sum + j.rows
		end
	end
	return sum
end

-- Replaces all re-seats at or after `at` by one at `at` that makes the reel land on target.
function Anim.reseat(p, at)
	assert(Anim.speed(p, at) >= p.minReseat, "Anim.reseat: reel too slow to hide a re-seat")
	local kept = {}
	for _, j in ipairs(p.jumps) do
		if j.t < at then
			kept[#kept + 1] = j
		end
	end
	p.jumps = kept
	local need = (p.start - p.target) % p.n -- rows to travel, modulo whole turns
	local rows = (need - raw(p, p.landAt) - jumped(p, at)) % p.n
	if math.abs(rows - floor(rows + 0.5)) < 1e-9 then
		rows = floor(rows + 0.5) % p.n
	end
	kept[#kept + 1] = { t = at, rows = rows }
end

-- Speed in rows/s at time t (positive = downwards).
function Anim.speed(p, t)
	local v = p.v
	if t <= 0 or t >= p.landAt then
		return 0
	end
	if t < p.tn then
		return -p.nudge * pi / p.tn * cos(pi * t / p.tn)
	end
	if t < p.cruiseAt then
		return v * (t - p.tn) / p.ta
	end
	if t < p.decelAt then
		return v
	end
	return v * (1 - (t - p.decelAt) / p.h)
end

-- Travelled rows at time t (seconds since the spin started), with re-seats and bounce.
function Anim.distance(p, t)
	local d = raw(p, t) + jumped(p, t)
	if t >= p.landAt then
		d = floor(d + 0.5) -- whole rows by construction; drop float noise
	end
	local b = p.bounce
	if t > p.landAt and b > 0 and t < p.landAt + b then
		local k = (t - p.landAt) / b
		d = d + p.overshoot * sin(pi * k) * (1 - k)
	end
	return d
end

function Anim.position(p, t)
	return (p.start - Anim.distance(p, t)) % p.n
end

function Anim.landed(p, t)
	return t >= p.landAt
end

function Anim.done(p, t)
	return t >= p.landAt + p.bounce
end

-- Quick stop requested at time `at`: braking starts at `at` (or at full speed, if the reel is
-- still starting) with the short quickDecel, after one re-seat. No effect once braking began.
function Anim.quickStop(p, at)
	local from = math.max(at, p.cruiseAt)
	if from >= p.decelAt then
		return
	end
	p.decelAt = from
	p.h = p.quickDecel
	p.landAt = from + p.quickDecel
	Anim.reseat(p, from)
end

-- The five strip stops around position x with their rows (-2.x .. 2.x).
function Anim.cells(x, n)
	local i0 = floor(x)
	local f = x - i0
	local out = {}
	for j = -2, 2 do
		out[#out + 1] = { index = (i0 + j) % n, row = j - f }
	end
	return out
end

-- Stop index and row of cell j (-2..2) around position x, like cells(x, n)[j + 3], without
-- building a table (for per-frame use).
function Anim.cell(x, n, j)
	local i0 = floor(x)
	return (i0 + j) % n, j - (x - i0)
end

-- Visible part of a cell centred on `row` (height 1) inside the window [-half, half].
-- Returns top, bottom as fractions 0..1 of the cell measured from its top, or nil.
function Anim.clip(row, half)
	local top = row - 0.5
	local visTop = top < -half and -half or top
	local visBottom = row + 0.5 > half and half or row + 0.5
	if visBottom - visTop <= 1e-6 then
		return nil
	end
	return visTop - top, visBottom - top
end

function Anim.countUp(from, to, t, dur)
	if dur <= 0 or t >= dur then
		return to
	end
	local v = from + (to - from) * Anim.easeOutQuad(t / dur)
	return floor(v + 0.5)
end

-- 0 at t = 0, 1 at half a period.
function Anim.pulse(t, freq)
	return (1 - cos(2 * pi * freq * t)) / 2
end

function Anim.formatNumber(v, sep)
	sep = sep or ","
	local neg = v < 0
	local s = tostring(floor(neg and -v or v))
	local out = s:reverse():gsub("(%d%d%d)", "%1" .. sep):reverse()
	if out:sub(1, #sep) == sep then
		out = out:sub(#sep + 1)
	end
	return (neg and "-" or "") .. out
end

-- Candidate shown at time t of a shuffle that steps through `count` candidates, slowing down,
-- and lands on `final` (1..count) at `dur`.
function Anim.shuffle(t, dur, count, final)
	if t >= dur then
		return final
	end
	local steps = 2 * count + 3
	local k = floor(steps * Anim.easeOutQuad(t / dur))
	return (final - 1 - steps + k) % count + 1
end

-- A cheap pseudo-random value 0..1 per particle and channel, the same on every call.
local function noise(i, ch)
	local v = sin(i * 12.9898 + ch * 78.233) * 43758.5453
	return v - floor(v)
end

-- Particle i, t seconds after its launch, with a lifetime `life`: returns x, y (in units of the
-- spread, y up, starting at 0, 0) and alpha. Thrown upwards and sideways, falls back, fades.
function Anim.particle(i, t, life)
	local u = t / life
	if u < 0 then u = 0 elseif u > 1 then u = 1 end
	local vx = noise(i, 1) * 2 - 1
	local vy = 1.2 + 0.8 * noise(i, 2)
	return vx * u, vy * u - 2.5 * u * u, 1 - u * u
end
