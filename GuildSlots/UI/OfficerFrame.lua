local _, ns = ...

-- The officer window (docs/guild-spec.md section 1): settings status, a form that builds the
-- settings line for the guild info, granting tokens, recent purchases and the self test switch.
-- Officers see everything; other members see the settings status only.

local L, Theme, Settings, Roster = ns.L, ns.Theme, ns.Settings, ns.Roster
local ui = ns.SlotFrame.ui
local fmt, rgb, paint, font, text, panel, button = ui.fmt, ui.rgb, ui.paint, ui.font, ui.text, ui.panel, ui.button

local OfficerFrame = {}
ns.OfficerFrame = OfficerFrame

local FRAME_NAME = "GuildSlotsOfficerFrame"
local WIDTH = 440
local ONLINE_ROWS = 6
local PURCHASE_ROWS = 6
local REFRESH_EVERY = 5 -- seconds, while shown (the online list ages out)

local FIELDS = { "L", "W", "R", "E", "G", "C", "T", "X" }
-- Settings.parse code -> form field.
local CODE_FIELD = {
	bad_level = "L", bad_witnesses = "W", bad_rank = "R", bad_stakes = "E", bad_gamble = "G",
	bad_cap = "C", bad_table = "T", bad_rate = "X",
}

local W = { fields = {}, onlineRows = {}, purchaseRows = {} }
OfficerFrame.widgets = W

local function main()
	return ns.Main
end

local function session()
	return ns.Main and ns.Main.session() or nil
end

local function trim(s)
	return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A localized line for a code, or the code itself.
local function lookup(prefix, code)
	return rawget(L, prefix .. tostring(code)) or tostring(code)
end

---------------------------------------------------------------------------------------------
-- Widgets

local function editBox(parent, w, h)
	local c = Theme.colors
	local holder = panel(parent, c.bg, c.border)
	holder:SetSize(w, h)
	local e = CreateFrame("EditBox", nil, holder)
	e:SetPoint("TOPLEFT", holder, "TOPLEFT", 6, 0)
	e:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -6, 0)
	e:SetAutoFocus(false)
	font(e, Theme.fonts.small + 1)
	e:SetTextColor(rgb(c.text))
	e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
	e.holder = holder
	return e
end

local function heading(parent, str)
	local fs = text(parent, Theme.fonts.label, Theme.colors.muted)
	fs:SetText(string.upper(str))
	return fs
end

local function wrapped(parent, width, color)
	local fs = text(parent, Theme.fonts.small, color or Theme.colors.muted)
	fs:SetWidth(width)
	fs:SetJustifyH("LEFT")
	return fs
end

local function note(fs, str, color)
	fs:SetText(str or "")
	fs:SetTextColor(rgb(color or Theme.colors.muted))
end

---------------------------------------------------------------------------------------------
-- Settings form

-- Builds the line from the form. Returns line, settings or nil, field, code.
local function formLine()
	local parts = { "GSLOTS1" }
	for _, k in ipairs(FIELDS) do
		local v = (W.fields[k]:GetText() or ""):gsub("%s", "")
		if v == "" or v:find("[;=|%c]") then
			return nil, k
		end
		parts[#parts + 1] = k .. "=" .. v
	end
	local s, code = Settings.parse(table.concat(parts, ";"))
	if not s then
		return nil, CODE_FIELD[code], code
	end
	local line
	line, code = Settings.format(s)
	if not line then
		return nil, nil, code
	end
	return line, s
end

local function updateForm()
	local line, s, code = formLine()
	if not line then
		local field = s
		W.currentLine = ""
		W.line:SetText("")
		if field then
			note(W.formNote, string.format(L.FIELD_BAD, L["F_" .. field]), Theme.colors.lose)
		else
			note(W.formNote, string.format(L.LINE_BAD, tostring(code)), Theme.colors.lose)
		end
		return
	end
	W.currentLine = line
	W.line:SetText(line)
	if s.L ~= 0 then
		note(W.formNote, L.NOTE_LEVEL)
	elseif s.E[#s.E] > 10 * s.E[1] then
		note(W.formNote, L.WARN_SPREAD, Theme.colors.lose)
	else
		note(W.formNote, "")
	end
end

-- Fills the form from the guild info, or the defaults.
local function prefill()
	local s = Roster.settings() or Settings.defaults()
	W.filling = true
	for _, k in ipairs(FIELDS) do
		local v = s[k]
		if k == "E" then
			v = table.concat(v, ",")
		end
		W.fields[k]:SetText(tostring(v))
	end
	W.filling = false
	updateForm()
end

---------------------------------------------------------------------------------------------
-- Refresh

local function statusText()
	if not session() then
		return L.NOT_IN_GUILD
	end
	local line = Roster.line()
	if not line then
		return L.SET_MISSING
	end
	local s, code = Settings.parse(line)
	if not s then
		return string.format(L.SET_INVALID, tostring(code))
	end
	local canonical = Settings.format(s) or line
	return string.format(L.SET_OK, (canonical:gsub("^GSLOTS1;", ""):gsub(";", "  ")))
end

local function purchaseText(p)
	local status = p.status == "failed" and string.format(L.P_failed, tostring(p.code or "?"))
		or lookup("P_", p.status)
	local who = p.player
	if p.role == "player" then
		who = who .. " <- " .. tostring(p.officer)
	end
	return string.format("%s  %s  %s", tostring(who), fmt(tonumber(p.tokens) or 0), status)
end

local function layout()
	local size = Theme.size
	local pad, gap = size.pad, size.gap
	local y = W.topY
	local function place(frame, h)
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", W.frame, "TOPLEFT", pad, y)
		y = y - h - gap
	end
	place(W.status, 28)
	if W.nonOfficer:IsShown() then
		place(W.nonOfficer, 16)
	end
	if W.formPart:IsShown() then
		place(W.formPart, W.formPart:GetHeight())
	end
	if W.grantPart:IsShown() then
		place(W.grantPart, W.grantPart:GetHeight())
	end
	W.frame:SetHeight(-y + pad / 2)
end

function OfficerFrame.refresh()
	if not W.frame then
		return
	end
	local s = session()
	local officer = s ~= nil and main().isOfficer()
	local valid = Roster.settings() ~= nil
	note(W.status, statusText(), (s and valid) and Theme.colors.text or Theme.colors.lose)
	W.nonOfficer:SetShown(s ~= nil and not officer)
	-- Without a valid line nobody is an officer yet, so the form is how the first line is made.
	W.formPart:SetShown(s ~= nil and (officer or not valid))
	W.grantPart:SetShown(officer)

	if officer then
		local online = s:online()
		for i, row in ipairs(W.onlineRows) do
			local o = online[i]
			if o then
				row.name = o.name
				row.label:SetText(o.name)
				row:setSelected(o.name == trim(W.player:GetText()))
				row:Show()
			else
				row:Hide()
			end
		end
		W.onlineNone:SetShown(#online == 0)
		local list = s:purchases()
		for i, fs in ipairs(W.purchaseRows) do
			local p = list[i]
			if p then
				fs:SetText(purchaseText(p))
				fs:Show()
			else
				fs:Hide()
			end
		end
		W.noPurchases:SetShown(#list == 0)
		W.selfTest:setSelected(GuildSlotsDB and GuildSlotsDB.selfTest == true)
	end
	layout()
end

---------------------------------------------------------------------------------------------
-- Actions

local function grant()
	local s = session()
	if not s then
		note(W.grantNote, L.NOT_IN_GUILD, Theme.colors.lose)
		return
	end
	local player = trim(W.player:GetText())
	local raw = trim(W.tokens:GetText())
	local tokens = raw:match("^%d+$") and tonumber(raw) or nil
	local id, code = s:grant(player, tokens)
	if id then
		note(W.grantNote, string.format(L.GRANT_SENT, player), Theme.colors.accent)
	else
		note(W.grantNote, lookup("ERR_", code), Theme.colors.lose)
	end
	OfficerFrame.refresh()
end

---------------------------------------------------------------------------------------------
-- Building

local function buildForm(parent, inner)
	local fonts, c = Theme.fonts, Theme.colors
	local part = CreateFrame("Frame", nil, parent)
	local y = 0
	local h1 = heading(part, L.SETTINGS)
	h1:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	y = y - 18
	local cols, colGap = 4, 8
	local colW = (inner - (cols - 1) * colGap) / cols
	for i, k in ipairs(FIELDS) do
		local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
		local x, top = col * (colW + colGap), y - row * 46
		local label = text(part, fonts.small, c.muted)
		label:SetPoint("TOPLEFT", part, "TOPLEFT", x, top)
		label:SetText(L["F_" .. k])
		local e = editBox(part, colW, 24)
		e.holder:SetPoint("TOPLEFT", part, "TOPLEFT", x, top - 15)
		e:SetScript("OnTextChanged", function()
			if not W.filling then
				updateForm()
			end
		end)
		W.fields[k] = e
	end
	y = y - 2 * 46 - 4

	W.line = editBox(part, inner, 26)
	W.line.holder:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	-- Read-only: user typing puts the line back; focus selects all for Ctrl+C.
	W.line:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(W.currentLine or "")
			self:HighlightText()
		end
	end)
	W.line:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
	y = y - 30
	local hint = wrapped(part, inner)
	hint:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	hint:SetText(L.LINE_HINT)
	y = y - 18
	W.formNote = wrapped(part, inner)
	W.formNote:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	y = y - 28
	part:SetSize(inner, -y)
	return part
end

local function buildGrant(parent, inner)
	local fonts, c, gap = Theme.fonts, Theme.colors, 8
	local part = CreateFrame("Frame", nil, parent)
	local y = 0
	local h = heading(part, L.GRANT_TITLE)
	h:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	y = y - 18

	-- Addon users heard online: click selects one.
	local cols = 3
	local rowW = (inner - (cols - 1) * gap) / cols
	for i = 1, ONLINE_ROWS do
		local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
		local b
		b = button(part, rowW, 22, "pill", fonts.small, function()
			W.player:SetText(b.name or "")
			OfficerFrame.refresh()
		end)
		b:SetPoint("TOPLEFT", part, "TOPLEFT", col * (rowW + gap), y - row * 26)
		b:Hide()
		W.onlineRows[i] = b
	end
	W.onlineNone = wrapped(part, inner)
	W.onlineNone:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y - 4)
	W.onlineNone:SetText(L.ONLINE_NONE)
	y = y - 2 * 26 - 4

	-- Player, tokens, Grant.
	local label = text(part, fonts.small, c.muted)
	label:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	label:SetText(L.PLAYER)
	local label2 = text(part, fonts.small, c.muted)
	label2:SetPoint("TOPLEFT", part, "TOPLEFT", 200 + gap, y)
	label2:SetText(L.TOKENS)
	y = y - 15
	W.player = editBox(part, 200, 26)
	W.player.holder:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	W.player:SetScript("OnTextChanged", function(_, userInput)
		if userInput then OfficerFrame.refresh() end
	end)
	W.tokens = editBox(part, 100, 26)
	W.tokens.holder:SetPoint("TOPLEFT", part, "TOPLEFT", 200 + gap, y)
	W.tokens:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
		grant()
	end)
	W.grant = button(part, inner - 300 - 2 * gap, 26, "accent", fonts.button, grant)
	W.grant:SetPoint("TOPLEFT", part, "TOPLEFT", 300 + 2 * gap, y)
	W.grant.label:SetText(L.GRANT)
	y = y - 30
	W.grantNote = wrapped(part, inner)
	W.grantNote:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	y = y - 20

	-- Self test.
	W.selfTest = button(part, 110, 22, "pill", fonts.small, function()
		local on = not (GuildSlotsDB and GuildSlotsDB.selfTest == true)
		main().setSelfTest(on)
		OfficerFrame.refresh()
	end)
	W.selfTest:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	W.selfTest.label:SetText(L.SELF_TEST)
	local hint = wrapped(part, inner - 110 - gap)
	hint:SetPoint("TOPLEFT", part, "TOPLEFT", 110 + gap, y)
	hint:SetText(L.SELF_TEST_HINT)
	y = y - 34

	-- Recent purchases.
	local h2 = heading(part, L.PURCHASES)
	h2:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	y = y - 18
	W.noPurchases = wrapped(part, inner)
	W.noPurchases:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y)
	W.noPurchases:SetText(L.NO_PURCHASES)
	for i = 1, PURCHASE_ROWS do
		local fs = wrapped(part, inner, c.text)
		fs:SetPoint("TOPLEFT", part, "TOPLEFT", 0, y - (i - 1) * 16)
		fs:Hide()
		W.purchaseRows[i] = fs
	end
	y = y - PURCHASE_ROWS * 16
	part:SetSize(inner, -y)
	return part
end

local function build()
	local size, c, fonts = Theme.size, Theme.colors, Theme.fonts
	local pad = size.pad
	local inner = WIDTH - 2 * pad

	local f = CreateFrame("Frame", FRAME_NAME, UIParent)
	W.frame = f
	f:SetFrameStrata("HIGH")
	if f.SetToplevel then f:SetToplevel(true) end
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	local border = f:CreateTexture(nil, "BACKGROUND")
	border:SetAllPoints(f)
	paint(border, c.border)
	local bg = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	bg:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
	bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
	paint(bg, c.bg)

	local y = -pad
	local title = text(f, fonts.title, c.text)
	title:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y - 6)
	title:SetText(L.TITLE .. " - " .. L.OFFICER)
	W.close = button(f, size.header, size.header, "ghost", fonts.title, function() f:Hide() end)
	W.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pad + 8, y)
	W.close.label:SetText("X")
	W.topY = y - size.header - size.gap

	W.status = wrapped(f, inner, c.text)
	W.nonOfficer = wrapped(f, inner)
	W.nonOfficer:SetText(L.NEED_OFFICER)
	W.formPart = buildForm(f, inner)
	W.grantPart = buildGrant(f, inner)

	local acc = 0
	f:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + (tonumber(elapsed) or 0)
		if acc >= REFRESH_EVERY then
			acc = 0
			OfficerFrame.refresh()
		end
	end)
	f:SetScript("OnShow", function()
		prefill()
		OfficerFrame.refresh()
	end)

	if type(UISpecialFrames) == "table" then
		table.insert(UISpecialFrames, FRAME_NAME)
	end
	f:Hide()
	f:SetWidth(WIDTH)
	f:SetPoint("CENTER", UIParent, "CENTER", 420, 40)

	if main() then
		main().subscribe(function(name)
			if f:IsShown() then
				OfficerFrame.refresh()
			end
		end)
	end
end

function OfficerFrame.toggle()
	if not W.frame then
		build()
	end
	if W.frame:IsShown() then
		W.frame:Hide()
	else
		W.frame:Show()
	end
end
