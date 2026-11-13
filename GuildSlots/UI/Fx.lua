local _, ns = ...

-- Effects of the slot window from the design: coin rain, sparkles, turning rays, a shine sweep,
-- popping banners and flipbooks. Every effect creates its textures once (pooled) and is driven
-- by the window's OnUpdate clock: start(now), update(now) (no tables built), stop() (hides it
-- at once). The maths is in UI/Anim.lua.

local Theme, Anim, Skin = ns.Theme, ns.Anim, ns.Skin

local Fx = {}
ns.Fx = Fx

local floor = math.floor

-- Shows frame i of a Theme.sheets entry on a texture.
function Fx.setFrame(tex, sheet, i)
	tex:SetTexCoord(Anim.gridCoord(i, sheet.cols, sheet.rows))
end

---------------------------------------------------------------------------------------------
-- Coin rain over the whole window: pooled coins from the coin flipbook.

local Rain = {}
Rain.__index = Rain

-- parent: a frame covering the window (w x h).
function Fx.rain(parent, w, h)
	local L = Theme.layout
	local o = setmetatable({ parent = parent, w = w, h = h, coins = {}, active = false, count = L.coins }, Rain)
	for i = 1, L.coins do
		local t = parent:CreateTexture(nil, "OVERLAY")
		t:SetTexture(Theme.tex.coinSheet)
		t:Hide()
		o.coins[i] = t
	end
	return o
end

-- count: coins in the rain (at most the pool), default all.
function Rain:start(now, count)
	self.t0, self.active = now, true
	self:setCount(count)
end

-- More (or fewer) coins while it rains; the coins already falling keep their paths.
function Rain:setCount(count)
	local n = #self.coins
	count = math.min(count or n, n)
	self.count = count
	for i = count + 1, n do
		self.coins[i]:Hide()
	end
end

function Rain:stop()
	self.active = false
	for _, t in ipairs(self.coins) do t:Hide() end
end

function Rain:update(now)
	if not self.active then
		return
	end
	local tm, sheet, sizes = Theme.timing, Theme.sheets.coin, Theme.layout.coinSizes
	local life, n = tm.coinLife, self.count
	local t = now - self.t0
	for i = 1, n do
		local c = self.coins[i]
		local tt = t - (i - 1) * tm.coinBurst / n
		if tt < 0 then
			c:Hide()
		else
			local cycle = floor(tt / life)
			local u = tt - cycle * life
			local x, y, sizeClass, phase = Anim.coin(i + cycle * 31, u, life)
			local size = sizes[sizeClass]
			local top = y * self.h
			if top >= self.h then
				c:Hide()
			else
				c:ClearAllPoints()
				c:SetPoint("TOPLEFT", self.parent, "TOPLEFT", x * (self.w - size), -top)
				c:SetSize(size, size)
				local f = (Anim.frameAt(u, sheet.fps, sheet.frames, true) + phase - 1) % sheet.frames + 1
				Fx.setFrame(c, sheet, f)
				c:Show()
			end
		end
	end
end

---------------------------------------------------------------------------------------------
-- Sparkles: the sparkle flipbook played once at a point (winning cells).

local Sparks = {}
Sparks.__index = Sparks

function Fx.sparkles(parent)
	local L = Theme.layout
	local o = setmetatable({ parent = parent, list = {}, next = 1, active = 0 }, Sparks)
	for i = 1, L.sparkles do
		local t = parent:CreateTexture(nil, "OVERLAY", nil, 3)
		t:SetTexture(Theme.tex.sparkleSheet)
		t:SetSize(L.sparkle, L.sparkle)
		Skin.add(t)
		t:Hide()
		o.list[i] = { tex = t, t0 = nil }
	end
	return o
end

-- Plays one sparkle centred on window point x, y (y downwards), `delay` s from now.
function Sparks:play(x, y, now, delay)
	local s = self.list[self.next]
	self.next = self.next % #self.list + 1
	s.t0 = now + (delay or 0)
	s.tex:ClearAllPoints()
	s.tex:SetPoint("CENTER", self.parent, "TOPLEFT", x, -y)
	s.tex:Hide()
	self.active = #self.list
end

function Sparks:update(now)
	if self.active == 0 then
		return
	end
	local sheet = Theme.sheets.sparkle
	local live = 0
	for i = 1, #self.list do
		local s = self.list[i]
		if s.t0 then
			local t = now - s.t0
			if t >= sheet.frames / sheet.fps then
				s.t0 = nil
				s.tex:Hide()
			elseif t >= 0 then
				Fx.setFrame(s.tex, sheet, Anim.frameAt(t, sheet.fps, sheet.frames, false))
				s.tex:Show()
				live = live + 1
			else
				live = live + 1
			end
		end
	end
	self.active = live
end

function Sparks:stop()
	for _, s in ipairs(self.list) do
		s.t0 = nil
		s.tex:Hide()
	end
	self.active = 0
end

---------------------------------------------------------------------------------------------
-- Rays turning behind a banner, inside a w x h region. Turned by texture coordinates, so
-- neither SetRotation nor clipping is needed.

local Rays = {}
Rays.__index = Rays

function Fx.rays(parent, w, h, layer, sublevel)
	local t = parent:CreateTexture(nil, layer or "BORDER", nil, sublevel)
	t:SetTexture(Theme.tex.rays)
	t:SetAllPoints(parent)
	Skin.add(t)
	t:Hide()
	return setmetatable({ tex = t, w = w, h = h, active = false }, Rays)
end

function Rays:start(now)
	self.t0, self.active = now, true
	self:update(now)
	self.tex:Show()
end

function Rays:update(now)
	if not self.active then
		return
	end
	local a = 2 * math.pi * ((now - self.t0) / Theme.timing.raysTurn % 1)
	self.tex:SetTexCoord(Anim.rays(a, self.w, self.h, Theme.layout.raysSize))
end

function Rays:stop()
	self.active = false
	self.tex:Hide()
end

---------------------------------------------------------------------------------------------
-- Shine sweeping over a banner, cropped to it by texture coordinates (no clipping needed).

local Shine = {}
Shine.__index = Shine

function Fx.shine(banner, w, h)
	local t = banner:CreateTexture(nil, "OVERLAY", nil, 2)
	t:SetTexture(Theme.tex.shine)
	t:SetHeight(h)
	Skin.add(t)
	t:Hide()
	return setmetatable({ tex = t, banner = banner, w = w, active = false }, Shine)
end

function Shine:start(now)
	self.t0, self.active = now, true
	self.tex:Hide()
end

function Shine:update(now)
	if not self.active then
		return
	end
	local tm, sw = Theme.timing, Theme.layout.shineWidth
	local u = ((now - self.t0) % tm.shinePeriod) / tm.shineSweep
	if u > 1 then
		self.tex:Hide()
		return
	end
	local x = -sw + u * (self.w + sw)
	local a, b = Anim.span(x, x + sw, 0, self.w)
	if not a then
		self.tex:Hide()
		return
	end
	self.tex:ClearAllPoints()
	self.tex:SetPoint("TOPLEFT", self.banner, "TOPLEFT", x + a * sw, 0)
	self.tex:SetWidth(math.max(0.01, (b - a) * sw))
	self.tex:SetTexCoord(a, b, 0, 1)
	self.tex:Show()
end

function Shine:stop()
	self.active = false
	self.tex:Hide()
end

---------------------------------------------------------------------------------------------
-- A banner that pops in: an unscaled holder centred on the window rect, the scaled frame
-- inside it anchored with no offset (SetScale also scales anchor offsets).

local Pop = {}
Pop.__index = Pop

function Fx.popper(parent, rel, r, level)
	local holder = CreateFrame("Frame", nil, parent)
	Skin.rect(holder, rel, r)
	holder:SetFrameLevel(level)
	local f = CreateFrame("Frame", nil, holder)
	f:SetSize(r[3], r[4])
	f:SetPoint("CENTER", holder, "CENTER", 0, 0)
	holder:Hide()
	return setmetatable({ holder = holder, frame = f, active = false }, Pop)
end

-- animate false: shown at full size at once (low effects, skipped steps).
function Pop:start(now, animate)
	self.t0, self.active = now, animate and true or false
	self.frame:SetScale(animate and Anim.pop(0, Theme.timing.pop) or 1)
	self.holder:Show()
end

function Pop:update(now)
	if not self.active then
		return
	end
	local t = now - self.t0
	self.frame:SetScale(Anim.pop(t, Theme.timing.pop))
	if t >= Theme.timing.pop then
		self.active = false
	end
end

function Pop:stop()
	self.active = false
	self.frame:SetScale(1)
	self.holder:Hide()
end
