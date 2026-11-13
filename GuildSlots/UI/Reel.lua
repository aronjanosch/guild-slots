local _, ns = ...

-- One reel: a column of three visible symbol slots that scrolls through the real strip.
-- Motion comes from ns.Anim; this file only places textures. Highlights (winning cells, dimming,
-- expansions) are drawn by the slot window on top of the reels.
--
-- Clipping is done by hand (cropping each icon's height and texture coordinates), so it
-- works without SetClipsChildren. SetClipsChildren is still enabled where it exists.
-- setPosition runs every frame while the reel turns and builds no tables.

local Reel = {}
Reel.__index = Reel
ns.Reel = Reel

local Anim, Theme = ns.Anim, ns.Theme
local HALF = 1.5 -- visible rows above and below the middle row centre
local ICONS = 5 -- icons placed around the position (rows -2..2)

-- parent: frame; strip: list of symbol ids (1-based, stop i is strip[i + 1]).
function Reel.new(parent, strip)
	local size = Theme.size
	local cell = size.cell
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(cell, cell * 3)
	if f.SetClipsChildren then
		pcall(f.SetClipsChildren, f, true)
	end

	-- The reel background is one texture behind all reels (slot window); each reel only adds
	-- its shade (darker at the top and bottom) over the symbols.
	local shade = f:CreateTexture(nil, "OVERLAY")
	shade:SetAllPoints(f)
	shade:SetTexture(Theme.tex.reelShade)
	shade:SetAlpha(Theme.reelShadeAlpha or 0.8)

	local self = setmetatable({
		frame = f,
		shade = shade,
		strip = strip,
		n = #strip,
		icons = {},
		x = 0, -- current position (float stop index)
		plan = nil,
	}, Reel)

	for i = 1, ICONS do
		local tex = f:CreateTexture(nil, "ARTWORK")
		tex:SetWidth(cell - 2 * size.iconInset)
		self.icons[i] = tex
	end
	self:setPosition(0)
	return self
end

-- Places the five icons for position x (see Anim.cell) and crops them to the window.
function Reel:setPosition(x)
	self.x = x
	local cell, inset = Theme.size.cell, Theme.size.iconInset
	local crop = Theme.iconCrop
	local symbols, strip, n = Theme.symbols, self.strip, self.n
	local iconH = (cell - 2 * inset) / cell -- icon height in rows
	local u0, u1, v0, v1 = crop[1], crop[2], crop[3], crop[4]
	for i = 1, ICONS do
		local index, row = Anim.cell(x, n, i - 3)
		local tex = self.icons[i]
		local top, bottom = Anim.clip(row / iconH, HALF / iconH)
		if top then
			-- float noise must not push the coordinates past the art's edge
			if top < 0 then top = 0 end
			if bottom > 1 then bottom = 1 end
			tex:SetTexture(symbols[strip[index + 1]])
			tex:SetTexCoord(u0, u1, v0 + (v1 - v0) * top, v0 + (v1 - v0) * bottom)
			-- Rows from the window top (row -HALF) to the visible top edge of the icon.
			local visTop = row - iconH / 2 + top * iconH + HALF
			tex:ClearAllPoints()
			tex:SetPoint("TOP", self.frame, "TOP", 0, -visTop * cell)
			tex:SetHeight(math.max(0.01, (bottom - top) * iconH * cell))
			tex:Show()
		else
			tex:Hide()
		end
	end
end

-- Sets the current stop without animation.
function Reel:setStop(stop)
	self.plan = nil
	self:setPosition(stop)
end

-- Changes the strip (base or free games) and shows `stop` on it.
function Reel:setStrip(strip, stop)
	self.strip = strip
	self.n = #strip
	self:setStop((stop or 0) % self.n)
end

-- Starts a spin to `target` at window time `t0` (may lie a little in the future); stopAt is
-- the landing time relative to t0. timing: the timing set of the round (Theme.timing or
-- Theme.timingTurbo, the one Plan.build got); decel: braking time of this reel (the plan's,
-- longer under anticipation), default timing.decel.
function Reel:spin(t0, target, stopAt, timing, decel)
	local t = timing or Theme.timing
	self.t0 = t0
	self.landedFired = false
	self.plan = Anim.plan({
		start = math.floor(self.x + 0.5) % self.n,
		target = target,
		n = self.n,
		stopAt = stopAt,
		nudgeTime = t.nudgeTime,
		nudge = t.nudge,
		accel = t.accel,
		decel = decel or t.decel,
		quickDecel = t.quickDecel,
		speed = t.speed,
		minReseatSpeed = t.minReseatSpeed,
		bounce = t.bounce,
		overshoot = t.overshoot,
	})
end

function Reel:quickStop(now, delay)
	if self.plan then
		Anim.quickStop(self.plan, now - self.t0 + delay)
	end
end

-- Advances the reel. Returns "landed" once when it lands, "done" once the bounce ends (with
-- true as second value when the landing happened in the same frame).
function Reel:update(now)
	local p = self.plan
	if not p then
		return nil
	end
	local t = now - self.t0
	self:setPosition(Anim.position(p, t))
	local event
	if not self.landedFired and Anim.landed(p, t) then
		self.landedFired = true
		event = "landed"
	end
	if Anim.done(p, t) then
		self.plan = nil
		self:setPosition(p.target)
		return "done", event == "landed"
	end
	return event
end

function Reel:isSpinning()
	return self.plan ~= nil
end
