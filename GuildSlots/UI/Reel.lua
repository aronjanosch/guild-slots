local _, ns = ...

-- One reel: a column of three visible symbol slots that scrolls through the real strip.
-- Motion comes from ns.Anim; this file only places textures.
--
-- Clipping is done by hand (cropping each icon's height and texture coordinates), so it
-- works without SetClipsChildren. SetClipsChildren is still enabled where it exists.

local Reel = {}
Reel.__index = Reel
ns.Reel = Reel

local Anim, Theme = ns.Anim, ns.Theme
local HALF = 1.5 -- visible rows above and below the payline row centre

-- parent: frame; strip: list of symbol ids (1-based, stop i is strip[i + 1]).
function Reel.new(parent, strip)
	local size, colors = Theme.size, Theme.colors
	local cell = size.cell
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(cell, cell * 3)
	if f.SetClipsChildren then
		pcall(f.SetClipsChildren, f, true)
	end

	local bg = f:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(f)
	bg:SetColorTexture(colors.cell[1], colors.cell[2], colors.cell[3], 1)

	-- Highlight behind the payline symbol, shown on a win.
	local glow = f:CreateTexture(nil, "BORDER")
	glow:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -cell - 2)
	glow:SetSize(cell - 4, cell - 4)
	glow:SetColorTexture(colors.accent[1], colors.accent[2], colors.accent[3], 0.25)
	glow:Hide()

	local self = setmetatable({
		frame = f,
		strip = strip,
		n = #strip,
		glow = glow,
		icons = {},
		x = 0, -- current position (float stop index)
		plan = nil,
		mode = nil, -- nil, "win" or "dim"
		level = 0, -- highlight strength 0..1
	}, Reel)

	for i = 1, 5 do
		local tex = f:CreateTexture(nil, "ARTWORK")
		tex:SetWidth(cell - 2 * size.iconInset)
		self.icons[i] = tex
	end
	self:setPosition(0)
	return self
end

-- Places the five icons for position x (see Anim.cells) and crops them to the window.
function Reel:setPosition(x)
	self.x = x
	local cell, inset = Theme.size.cell, Theme.size.iconInset
	local crop = Theme.iconCrop
	local iconH = (cell - 2 * inset) / cell -- icon height in rows
	local cells = Anim.cells(x, self.n)
	for i, c in ipairs(cells) do
		local tex = self.icons[i]
		local top, bottom = Anim.clip(c.row / iconH, HALF / iconH)
		if top then
			tex:SetTexture(Theme.symbols[self.strip[c.index + 1]])
			local u0, u1, v0, v1 = crop[1], crop[2], crop[3], crop[4]
			tex:SetTexCoord(u0, u1, v0 + (v1 - v0) * top, v0 + (v1 - v0) * bottom)
			-- Rows from the window top (row -HALF) to the visible top edge of the icon.
			local visTop = c.row - iconH / 2 + top * iconH + HALF
			tex:ClearAllPoints()
			tex:SetPoint("TOP", self.frame, "TOP", 0, -visTop * cell)
			tex:SetHeight(math.max(0.01, (bottom - top) * iconH * cell))
			tex.row = c.row
			tex:Show()
		else
			tex.row = nil
			tex:Hide()
		end
	end
	self:applyHighlight()
end

-- Sets the current stop without animation.
function Reel:setStop(stop)
	self.plan = nil
	self:setPosition(stop)
end

-- Starts a spin to `target`; times are relative to `now` (seconds of the window clock).
function Reel:spin(now, target, stopAt)
	local t = Theme.timing
	self.t0 = now
	self.landedFired = false
	self.plan = Anim.plan({
		start = math.floor(self.x + 0.5) % self.n,
		target = target,
		n = self.n,
		stopAt = stopAt,
		accel = t.accel,
		decel = t.decel,
		speed = t.speed,
		bounce = t.bounce,
		overshoot = t.overshoot,
	})
	self:setMode(nil)
end

function Reel:quickStop(now, delay)
	if self.plan then
		Anim.quickStop(self.plan, now - self.t0 + delay)
	end
end

-- Advances the reel. Returns "landed" once when it lands, "done" once the bounce ends.
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

-- mode nil: normal; "win": payline symbol glows; "dim": everything dimmed.
function Reel:setMode(mode)
	self.mode = mode
	self.level = 0
	self:applyHighlight()
end

-- level 0..1 drives the win pulse.
function Reel:setLevel(level)
	self.level = level
	self:applyHighlight()
end

function Reel:applyHighlight()
	local mode, dim = self.mode, Theme.timing.dimAlpha
	for _, tex in ipairs(self.icons) do
		local a = 1
		if mode == "dim" then
			a = dim
		elseif mode == "win" and tex.row and math.abs(tex.row) > 0.5 then
			a = dim
		end
		tex:SetAlpha(a)
	end
	if mode == "win" then
		self.glow:SetAlpha(0.35 + 0.65 * self.level)
		self.glow:Show()
	else
		self.glow:Hide()
	end
end
