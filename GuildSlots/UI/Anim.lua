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

-- opts: start, target (0-based stops), n (strip length), stopAt (landing time, s),
-- accel (s to reach speed), decel (s of constant braking before stopAt),
-- speed (minimum rows/s), bounce (s), overshoot (rows).
-- Speed profile: linear ramp up, cruise, linear braking to 0 at stopAt. The cruise speed is
-- chosen so the reel travels a whole number of rows and lands exactly on `target`, which
-- makes the speed vary a little from spin to spin.
function Anim.plan(o)
	local n = o.n
	local eff = o.stopAt - o.accel / 2 - o.decel / 2
	if eff <= 0 then
		eff = 1e-3
	end
	local nominal = o.speed * eff
	local residue = (o.start - o.target) % n
	local k = math.ceil((nominal - residue) / n)
	if k < 0 then k = 0 end
	local d = residue + k * n
	return {
		start = o.start,
		target = o.target,
		n = n,
		stopAt = o.stopAt,
		accel = o.accel,
		decel = o.decel,
		bounce = o.bounce or 0,
		overshoot = o.overshoot or 0,
		distance = d,
		v = d / eff,
	}
end

local function landTime(p)
	if p.snap and p.snap < p.stopAt then
		return p.snap
	end
	return p.stopAt
end

local function travelled(p, t)
	if t <= 0 then
		return 0
	end
	local v, a, h, T = p.v, p.accel, p.decel, p.stopAt
	local braking = T - h
	-- Ramp up (cut short if braking starts before the ramp ends; only with odd timings).
	if t < a and t < braking then
		return v * t * t / (2 * a)
	end
	local rampEnd = v * a / 2
	if t < braking then
		return rampEnd + v * (t - a)
	end
	local u = t - braking
	return p.distance - v * (h - u) * (h - u) / (2 * h)
end

-- Travelled rows at time t (seconds since the spin started), including the landing bounce.
function Anim.distance(p, t)
	local L = landTime(p)
	if t < L then
		return travelled(p, t)
	end
	local b = p.bounce
	if b <= 0 or t >= L + b then
		return p.distance
	end
	local k = (t - L) / b
	return p.distance + p.overshoot * sin(pi * k) * (1 - k)
end

function Anim.position(p, t)
	return (p.start - Anim.distance(p, t)) % p.n
end

function Anim.landed(p, t)
	return t >= landTime(p)
end

function Anim.done(p, t)
	return t >= landTime(p) + p.bounce
end

-- Quick stop: land at time `at` (jumping to the target) unless the reel lands earlier anyway.
function Anim.quickStop(p, at)
	if not p.snap or at < p.snap then
		p.snap = at
	end
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
