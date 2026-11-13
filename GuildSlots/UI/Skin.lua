local _, ns = ...

-- Widgets in the tavern look, shared by the slot window and the officer window: 9-slices built
-- from nine textures with SetTexCoord (works in every client), tiled backgrounds, fonts with a
-- fallback, buttons in the design's styles, panels and input fields.
--
-- Optional client API (not confirmed for the Forever client in docs/forever-api-probe.md) is only
-- called through Skin.call, which checks that the method exists and never raises.

local Theme = ns.Theme

local Skin = {}
ns.Skin = Skin

-- Calls obj:method(...) when the client has it. Returns true when it ran without an error.
function Skin.call(obj, method, ...)
	local f = obj and obj[method]
	if type(f) ~= "function" then
		return false
	end
	return (pcall(f, obj, ...))
end

-- Additive blending for glows; without SetBlendMode they blend normally (dimmer, still right).
function Skin.add(tex)
	return Skin.call(tex, "SetBlendMode", "ADD")
end

-- string.upper for labels: Lua only upper-cases ASCII, so the German umlauts are mapped by hand
-- (UTF-8).
local UMLAUTS = { ["\195\164"] = "\195\132", ["\195\182"] = "\195\150", ["\195\188"] = "\195\156" }
function Skin.upper(s)
	return (string.upper(s):gsub("\195[\164\182\188]", UMLAUTS))
end

function Skin.color(region, c, a)
	local kind = region:GetObjectType()
	if kind == "Texture" or kind == "Line" then
		region:SetVertexColor(c[1], c[2], c[3], a or c[4] or 1)
	else
		region:SetTextColor(c[1], c[2], c[3])
	end
end

-- Places a region by a rect { x, y, w, h } given in the coordinates of `rel`'s top left corner
-- (y downwards). ox, oy shift the rect's origin (for rects given in window coordinates while
-- `rel` sits at ox, oy in the window).
function Skin.rect(region, rel, r, ox, oy)
	region:ClearAllPoints()
	region:SetPoint("TOPLEFT", rel, "TOPLEFT", r[1] - (ox or 0), -(r[2] - (oy or 0)))
	region:SetSize(r[3], r[4])
end

---------------------------------------------------------------------------------------------
-- Fonts

local failedFonts = {}

local function tryFont(fs, file, size, flags)
	if not file or failedFonts[file] then
		return false
	end
	local ok, res = pcall(fs.SetFont, fs, file, size, flags)
	-- Some clients return nothing from SetFont; then the font must read back.
	local good = ok and res ~= false and (res == true or fs:GetFont() ~= nil)
	if not good then
		failedFonts[file] = true
	end
	return good
end

-- Sets one of Theme.fonts (title, label, number, numberMedium): the delivered file, else the
-- game font SPEC.md names, else the fallback font object. Returns "custom", "game" or "object".
function Skin.font(fs, face, size, flags)
	local f = Theme.fonts[face] or Theme.fonts.label
	flags = flags or ""
	if tryFont(fs, f.file, size, flags) then
		return "custom"
	end
	if tryFont(fs, f.fallback, size, flags) then
		return "game"
	end
	local obj = _G[Theme.fonts.fallbackObject]
	if obj then
		pcall(fs.SetFontObject, fs, obj)
	end
	return "object"
end

function Skin.shadow(fs, x, y, c)
	Skin.call(fs, "SetShadowOffset", x, y)
	c = c or Theme.colors.black
	Skin.call(fs, "SetShadowColor", c[1], c[2], c[3], 1)
end

-- A font string; every text has a 1/-1 black shadow unless noShadow.
function Skin.text(parent, face, size, color, justify, layer, noShadow)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	Skin.font(fs, face, size)
	Skin.color(fs, color or Theme.colors.text)
	if noShadow then
		Skin.shadow(fs, 0, 0)
	else
		Skin.shadow(fs, 1, -1)
	end
	if justify then
		fs:SetJustifyH(justify)
	end
	return fs
end

-- A font string in a box (window rect), vertically centred like the design's line boxes.
function Skin.textIn(parent, rel, r, face, size, color, justify, ox, oy)
	local fs = Skin.text(parent, face, size, color, justify or "LEFT")
	Skin.rect(fs, rel, r, ox, oy)
	Skin.call(fs, "SetJustifyV", "MIDDLE")
	return fs
end

---------------------------------------------------------------------------------------------
-- 9-slice: nine textures (three for a 3-slice) anchored to the edges of `anchor`.

local Nine = {}
Nine.__index = Nine

local function firstFile(file)
	return type(file) == "table" and file.normal or file
end

-- spec: an entry of Theme.slices. out: how far the slice reaches outside the anchor.
function Skin.nine(parent, anchor, spec, layer, sublevel, out)
	local o = setmetatable({ tex = {}, spec = spec, shown = true }, Nine)
	out = out or 0
	local W, H, dx, dy = spec.w, spec.h, spec.dx, spec.dy
	local us = { 0, spec.mx / W, 1 - spec.mx / W, 1 }
	local vs = { 0, spec.my / H, 1 - spec.my / H, 1 }
	local xs = { { "LEFT", -out }, { "LEFT", dx - out }, { "RIGHT", out - dx }, { "RIGHT", out } }
	local ys = { { "TOP", out }, { "TOP", out - dy }, { "BOTTOM", dy - out }, { "BOTTOM", -out } }
	local rows = spec.my == 0 and { { 1, 4, 0, 1 } } or { { 1, 2, vs[1], vs[2] }, { 2, 3, vs[2], vs[3] }, { 3, 4, vs[3], vs[4] } }
	local file = firstFile(spec.file)
	o.file = file
	for _, row in ipairs(rows) do
		local top, bottom = ys[row[1]], ys[row[2]]
		for col = 1, 3 do
			local left, right = xs[col], xs[col + 1]
			local t = parent:CreateTexture(nil, layer or "BORDER", nil, sublevel)
			t:SetTexture(file)
			t:SetPoint("TOPLEFT", anchor, top[1] .. left[1], left[2], top[2])
			t:SetPoint("BOTTOMRIGHT", anchor, bottom[1] .. right[1], right[2], bottom[2])
			t:SetTexCoord(us[col], us[col + 1], row[3], row[4])
			o.tex[#o.tex + 1] = t
		end
	end
	return o
end

function Nine:SetTexture(file)
	if file == self.file then
		return
	end
	self.file = file
	for _, t in ipairs(self.tex) do t:SetTexture(file) end
end

function Nine:SetVertexColor(r, g, b, a)
	for _, t in ipairs(self.tex) do t:SetVertexColor(r, g, b, a or 1) end
end

function Nine:SetAlpha(a)
	for _, t in ipairs(self.tex) do t:SetAlpha(a) end
end

function Nine:SetAdd()
	for _, t in ipairs(self.tex) do Skin.add(t) end
end

function Nine:Show()
	self.shown = true
	for _, t in ipairs(self.tex) do t:Show() end
end

function Nine:Hide()
	self.shown = false
	for _, t in ipairs(self.tex) do t:Hide() end
end

function Nine:SetShown(on)
	if on then self:Show() else self:Hide() end
end

function Nine:IsShown()
	return self.shown
end

---------------------------------------------------------------------------------------------
-- Tiled background: a grid of textures, the last row and column cropped by texture
-- coordinates. Exact at every UI scale and needs no SetHorizTile / SetVertTile.

local Tiles = {}
Tiles.__index = Tiles

function Skin.tiles(parent, file, w, h, layer, sublevel)
	local size = Theme.tileSize
	local o = setmetatable({ tex = {}, file = file }, Tiles)
	for y = 0, h - 1, size do
		for x = 0, w - 1, size do
			local tw, th = math.min(size, w - x), math.min(size, h - y)
			local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel)
			t:SetTexture(file)
			t:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -y)
			t:SetSize(tw, th)
			t:SetTexCoord(0, tw / size, 0, th / size)
			o.tex[#o.tex + 1] = t
			t.tileY, t.tileW = y, tw
		end
	end
	return o
end

-- Shows only the top h pixels (for windows whose height changes).
function Tiles:setHeight(h)
	local size = Theme.tileSize
	for _, t in ipairs(self.tex) do
		local th = math.min(size, h - t.tileY)
		if th <= 0 then
			t:Hide()
		else
			t:SetHeight(th)
			t:SetTexCoord(0, t.tileW / size, 0, th / size)
			t:Show()
		end
	end
end

function Tiles:SetTexture(file)
	if file == self.file then
		return
	end
	self.file = file
	for _, t in ipairs(self.tex) do t:SetTexture(file) end
end

---------------------------------------------------------------------------------------------
-- Panels

-- A frame with a 9-slice background ("inset" or "overlay"), placed by a window rect.
function Skin.panel(parent, rel, r, kind, ox, oy)
	local f = CreateFrame("Frame", nil, parent)
	Skin.rect(f, rel, r, ox, oy)
	f.bg = Skin.nine(f, f, Theme.slices[kind or "inset"], "BACKGROUND")
	return f
end

-- A solid colour fill (dims, shades, list bands): a white texture tinted. SetColorTexture is in
-- every retail client.
function Skin.fill(parent, layer, c, sublevel)
	local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sublevel)
	t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
	return t
end

---------------------------------------------------------------------------------------------
-- Buttons: "primary" (gold), "secondary", "danger", "toggle" (has a selected state), "icon".
-- opts: face, size, color (label), selectedColor, icon (path), iconColor, iconSize.
-- Keeps the fields the windows and tests use: label, enabled, selected, setEnabled,
-- setSelected, onClick.

local LABEL = {
	primary = { "title", "spin", "buttonDark" },
	secondary = { "label", "button", "goldLight" },
	danger = { "number", "offer", "white" },
	toggle = { "label", "button", "muted" },
	icon = { "label", "button", "goldLight" },
}

local function paintButton(b)
	local files = Theme.slices[b.style].file
	local state = "normal"
	if not b.enabled then
		state = "disabled"
	elseif b.pressed then
		state = "pressed"
	elseif b.selected and files.selected then
		state = "selected"
	elseif b.hover then
		state = "hover"
	end
	b.bg:SetTexture(files[state] or files.normal)
	local c = Theme.colors
	local color = b.selected and b.selectedColor or b.color
	if not b.enabled and b.style == "primary" then
		color = c.buttonDisabled
	end
	Skin.color(b.label, color)
	local a = b.enabled and 1 or c.disabledAlpha
	b.label:SetAlpha(a)
	local dy = (b.pressed and b.enabled) and -2 or 0
	b.label:ClearAllPoints()
	if b.icon then
		b.icon:SetAlpha(a)
		b.icon:ClearAllPoints()
		if b.iconOnly then
			b.icon:SetPoint("CENTER", b, "CENTER", 0, dy)
		else
			local L = Theme.layout
			b.icon:SetPoint("LEFT", b, "LEFT", L.buttonIconX, dy)
			b.label:SetPoint("LEFT", b, "LEFT", L.buttonTextX, dy)
			return
		end
	end
	b.label:SetPoint("CENTER", b, "CENTER", 0, dy)
end

function Skin.button(parent, style, w, h, onClick, opts)
	opts = opts or {}
	local def = LABEL[style]
	local c = Theme.colors
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h)
	b.style, b.onClick = style, onClick
	b.enabled, b.hover, b.pressed, b.selected = true, false, false, false
	b.color = opts.color or c[def[3]]
	b.selectedColor = opts.selectedColor or (style == "toggle" and c.number) or b.color
	b.bg = Skin.nine(b, b, Theme.slices[style], "BACKGROUND")
	b.label = Skin.text(b, opts.face or def[1], opts.size or Theme.fontSize[def[2]], b.color, "CENTER", "OVERLAY",
		style == "primary")
	if opts.icon then
		local L = Theme.layout
		b.icon = b:CreateTexture(nil, "ARTWORK")
		local s = opts.iconSize or L.buttonIcon
		b.icon:SetSize(s, s)
		b.icon:SetTexture(opts.icon)
		Skin.color(b.icon, opts.iconColor or b.color)
		b.iconOnly = opts.iconOnly
	end
	b:SetScript("OnEnter", function()
		b.hover = true
		paintButton(b)
	end)
	b:SetScript("OnLeave", function()
		b.hover, b.pressed = false, false
		paintButton(b)
	end)
	b:SetScript("OnMouseDown", function()
		b.pressed = true
		paintButton(b)
	end)
	b:SetScript("OnMouseUp", function()
		b.pressed = false
		paintButton(b)
	end)
	b:SetScript("OnClick", function()
		-- A click is a hardware event: the one place the guild info may be read.
		if ns.Roster then ns.Roster.refreshInfo() end
		if b.enabled and b.onClick then
			b.onClick()
		end
	end)
	b.setEnabled = function(_, on)
		on = on and true or false
		if on ~= b.enabled then
			b.enabled = on
			paintButton(b)
		end
	end
	b.setSelected = function(_, on)
		on = on and true or false
		if on ~= b.selected then
			b.selected = on
			paintButton(b)
		end
	end
	b.setIcon = function(_, file)
		if b.icon then b.icon:SetTexture(file) end
	end
	paintButton(b)
	return b
end

---------------------------------------------------------------------------------------------
-- List row: a button with a name label, highlighted with a band and two gold lines when
-- selected, a fainter band on hover. Fields: label, selected, setSelected.

function Skin.listRow(parent, rel, r, onClick, textX, ox, oy)
	local c = Theme.colors
	local b = CreateFrame("Button", nil, parent)
	Skin.rect(b, rel, r, ox, oy)
	b.band = Skin.fill(b, "BACKGROUND", c.rowSelected)
	b.band:SetAllPoints(b)
	b.lineTop = Skin.fill(b, "BORDER", c.goldLight)
	b.lineTop:SetPoint("TOPLEFT", b, "TOPLEFT", 0, 0)
	b.lineTop:SetPoint("TOPRIGHT", b, "TOPRIGHT", 0, 0)
	b.lineTop:SetHeight(1)
	b.lineBottom = Skin.fill(b, "BORDER", c.goldLight)
	b.lineBottom:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", 0, 0)
	b.lineBottom:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 0, 0)
	b.lineBottom:SetHeight(1)
	b.label = Skin.text(b, "label", Theme.fontSize.listName, c.text, "LEFT")
	b.label:SetPoint("LEFT", b, "LEFT", textX or 8, 0)
	b.selected = false
	local function paint()
		b.band:SetShown(b.selected or b.hover)
		b.band:SetAlpha(b.selected and 1 or Theme.alpha.rowHover)
		b.lineTop:SetShown(b.selected)
		b.lineBottom:SetShown(b.selected)
		Skin.color(b.label, b.selected and c.number or c.text)
	end
	b.setSelected = function(_, on)
		b.selected = on and true or false
		paint()
	end
	b:SetScript("OnEnter", function() b.hover = true; paint() end)
	b:SetScript("OnLeave", function() b.hover = false; paint() end)
	b:SetScript("OnClick", onClick)
	paint()
	return b
end

---------------------------------------------------------------------------------------------
-- Status badge: badge_status tinted, with a centred text. setStatus(colorKey, textColorKey, text)
-- takes keys of Theme.colors; an unknown key shows the neutral colour.

function Skin.badge(parent, rel, r, size, ox, oy)
	local holder = CreateFrame("Frame", nil, parent)
	Skin.rect(holder, rel, r, ox, oy)
	local o = { holder = holder }
	o.bg = Skin.nine(holder, holder, Theme.slices.badge, "ARTWORK")
	o.text = Skin.text(holder, "number", size or Theme.fontSize.badge, Theme.colors.white, "CENTER")
	o.text:SetAllPoints(holder)
	Skin.shadow(o.text, 0, 0)
	o.setStatus = function(_, colorKey, textKey, str)
		local c = Theme.colors
		local bc = c[colorKey] or c.statusNone
		o.bg:SetVertexColor(bc[1], bc[2], bc[3], 1)
		Skin.color(o.text, c[textKey] or c.white)
		o.text:SetText(str or "")
	end
	o.Show = function() holder:Show() end
	o.Hide = function() holder:Hide() end
	o.SetShown = function(_, on) holder:SetShown(on) end
	o.IsShown = function() return holder:IsShown() end
	return o
end

---------------------------------------------------------------------------------------------
-- Input field: an edit box on a 9-slice holder with the normal / focus / disabled textures.

function Skin.editBox(parent, w, h, face, size)
	local spec = Theme.slices.field
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(w, h)
	holder.bg = Skin.nine(holder, holder, spec, "BACKGROUND")
	local e = CreateFrame("EditBox", nil, holder)
	e:SetPoint("TOPLEFT", holder, "TOPLEFT", 10, 0)
	e:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -10, 0)
	e:SetAutoFocus(false)
	Skin.font(e, face or "number", size or Theme.fontSize.field)
	Skin.color(e, Theme.colors.number)
	Skin.shadow(e, 1, -1)
	e.holder = holder
	e.readOnly = false
	local function look(focus)
		holder.bg:SetTexture(e.readOnly and spec.file.disabled or (focus and spec.file.focus or spec.file.normal))
	end
	e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	e:SetScript("OnEditFocusGained", function() look(true) end)
	e:SetScript("OnEditFocusLost", function() look(false) end)
	e.setReadOnlyLook = function(_, on)
		e.readOnly = on and true or false
		look(false)
	end
	return e
end
