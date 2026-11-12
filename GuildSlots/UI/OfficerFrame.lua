local _, ns = ...

-- The officer window (docs/guild-spec.md section 1): granting tokens to addon users heard
-- online, recent purchases, the self test switch, the settings status and a form that builds
-- the settings line for the guild info. Officers see everything; other members see the
-- settings status only. Look: state 11 of the tavern design (UI/Theme.lua, Theme.officer).

local L, Theme, Settings, Roster, Skin = ns.L, ns.Theme, ns.Settings, ns.Roster, ns.Skin
local ui = ns.SlotFrame.ui
local fmt = ui.fmt

local OfficerFrame = {}
ns.OfficerFrame = OfficerFrame

local FRAME_NAME = "GuildSlotsOfficerFrame"
local REFRESH_EVERY = 5 -- seconds, while shown (the online list ages out)

local FIELDS = { "L", "W", "R", "E", "G", "C", "T", "X" }
-- Settings.parse code -> form field.
local CODE_FIELD = {
	bad_level = "L", bad_witnesses = "W", bad_rank = "R", bad_stakes = "E", bad_gamble = "G",
	bad_cap = "C", bad_table = "T", bad_rate = "X",
}

-- Purchase status -> badge colour key (Theme.colors) and text colour key.
local BADGE = {
	done = { "statusOk", "white" }, wait_nonce = { "statusOpen", "dark" }, wait_seed = { "statusOpen", "dark" },
	failed = { "statusBad", "white" }, timeout = { "statusBad", "white" },
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

local function heading(parent, r, str)
	local fs = Skin.textIn(parent, parent, r, "label", Theme.fontSize.section, Theme.colors.goldLight, "LEFT")
	fs:SetText(Skin.upper(str))
	return fs
end

local function wrapped(parent, r, color, size)
	local fs = Skin.text(parent, "label", size or Theme.fontSize.small, color or Theme.colors.muted, "LEFT")
	Skin.rect(fs, parent, r)
	Skin.call(fs, "SetJustifyV", "TOP")
	Skin.call(fs, "SetWordWrap", true)
	return fs
end

local function note(fs, str, color)
	fs:SetText(str or "")
	Skin.color(fs, color or Theme.colors.muted)
end

-- A list row: name, highlighted with a band and two gold lines when selected.
local function listRow(parent, rel, r, onClick)
	local c = Theme.colors
	local b = CreateFrame("Button", nil, parent)
	Skin.rect(b, rel, r)
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
	b.label:SetPoint("LEFT", b, "LEFT", Theme.officer.grant.rowText, 0)
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
	local c = Theme.colors
	local line, s, code = formLine()
	if not line then
		local field = s
		W.currentLine = ""
		W.line:SetText("")
		if field then
			note(W.formNote, string.format(L.FIELD_BAD, L["F_" .. field]), c.lose)
		else
			note(W.formNote, string.format(L.LINE_BAD, tostring(code)), c.lose)
		end
		return
	end
	W.currentLine = line
	W.line:SetText(line)
	if s.L ~= 0 then
		note(W.formNote, L.NOTE_LEVEL)
	elseif s.E[#s.E] > 10 * s.E[1] then
		note(W.formNote, L.WARN_SPREAD, c.lose)
	else
		note(W.formNote, "")
	end
end

-- Fills the form from the guild info, or the defaults with table T2 (the table this version
-- plays).
local function prefill()
	local s = Roster.settings()
	if not s then
		s = Settings.defaults()
		s.T = "T2"
	end
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

-- One short line per purchase: who gets tokens (officer side) or who they came from.
local function who(p)
	if p.role == "player" then
		return string.format(L.P_FROM, tostring(p.officer))
	end
	return string.format(L.P_TO, tostring(p.player))
end

local function statusLabel(p)
	if p.status == "failed" then
		return string.format(L.P_failed, tostring(p.code or "?"))
	end
	return lookup("P_", p.status)
end

local function layout()
	local O = Theme.officer
	local y = O.top
	local function place(frame, h)
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", W.frame, "TOPLEFT", 0, -y)
		y = y + h + O.sectionGap
	end
	if W.grantPart:IsShown() then
		place(W.grantPart, O.grant.height)
	end
	place(W.statusPart, O.status.height)
	if W.nonOfficer:IsShown() then
		place(W.nonOfficer, O.nonOfficer[4])
	end
	if W.formPart:IsShown() then
		place(W.formPart, O.form.height)
	end
	local h = math.min(O.maxHeight, y - O.sectionGap + O.pad)
	W.frame:SetHeight(h)
	W.bgTiles:setHeight(h)
end

function OfficerFrame.refresh()
	if not W.frame then
		return
	end
	local c = Theme.colors
	local s = session()
	local officer = s ~= nil and main().isOfficer()
	local valid = Roster.settings() ~= nil
	note(W.status, statusText(), (s and valid) and c.text or c.lose)
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
		for i, row in ipairs(W.purchaseRows) do
			local p = list[i]
			if p then
				row.name:SetText(who(p))
				row.amount:SetText(fmt(tonumber(p.tokens) or 0))
				local b = BADGE[p.status] or BADGE.failed
				local bc = c[b[1]]
				row.badge:SetVertexColor(bc[1], bc[2], bc[3], 1)
				row.status:SetText(statusLabel(p))
				Skin.color(row.status, c[b[2]])
				row:Show()
			else
				row:Hide()
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
	local c = Theme.colors
	local s = session()
	if not s then
		note(W.grantNote, L.NOT_IN_GUILD, c.lose)
		return
	end
	local player = trim(W.player:GetText())
	local raw = trim(W.tokens:GetText())
	local tokens = raw:match("^%d+$") and tonumber(raw) or nil
	local id, code = s:grant(player, tokens)
	if id then
		W.grantId = id
		note(W.grantNote, string.format(L.GRANT_SENT, player), c.goldLight)
	else
		note(W.grantNote, lookup("ERR_", code), c.lose)
	end
	OfficerFrame.refresh()
end

---------------------------------------------------------------------------------------------
-- Building

local function section(parent, height)
	local part = CreateFrame("Frame", nil, parent)
	part:SetSize(Theme.officer.width, height)
	return part
end

local function buildGrant(parent)
	local G, c, fs = Theme.officer.grant, Theme.colors, Theme.fontSize
	local part = section(parent, G.height)
	heading(part, G.heading, L.GRANT_TITLE)

	-- Addon users heard online: click selects one.
	local list = Skin.panel(part, part, G.list, "inset")
	local head = Skin.textIn(list, part, G.listHead, "label", fs.listHead, c.muted, "LEFT")
	head:SetText(L.ONLINE_HEAD)
	for i = 1, G.rows do
		local col, row = (i - 1) % G.cols, math.floor((i - 1) / G.cols)
		local b
		b = listRow(list, part, { G.row[1] + col * G.rowStep[1], G.row[2] + row * G.rowStep[2], G.row[3], G.row[4] },
			function()
				W.player:SetText(b.name or "")
				OfficerFrame.refresh()
			end)
		b:Hide()
		W.onlineRows[i] = b
	end
	W.onlineNone = Skin.textIn(list, part, G.none, "label", fs.small, c.muted, "LEFT")
	W.onlineNone:SetText(L.ONLINE_NONE)

	-- Player, tokens, Grant.
	local pl = Skin.textIn(part, part, G.playerLabel, "label", fs.label, c.muted, "LEFT")
	pl:SetText(Skin.upper(L.PLAYER))
	local tl = Skin.textIn(part, part, G.tokensLabel, "label", fs.label, c.muted, "LEFT")
	tl:SetText(Skin.upper(L.TOKENS))
	W.player = Skin.editBox(part, G.player[3], G.player[4], "label", fs.listName)
	Skin.rect(W.player.holder, part, G.player)
	W.player:SetScript("OnTextChanged", function(_, userInput)
		if userInput then OfficerFrame.refresh() end
	end)
	W.tokens = Skin.editBox(part, G.tokens[3], G.tokens[4], "number", fs.field)
	Skin.rect(W.tokens.holder, part, G.tokens)
	W.tokens:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
		grant()
	end)
	W.grant = Skin.button(part, "primary", G.button[3], G.button[4], grant, { size = fs.gambleNumber })
	Skin.rect(W.grant, part, G.button)
	W.grant.label:SetText(L.GRANT)
	W.grantNote = wrapped(part, G.note, c.footer)

	-- Self test.
	W.selfTest = Skin.button(part, "toggle", G.selfTest[3], G.selfTest[4], function()
		local on = not (GuildSlotsDB and GuildSlotsDB.selfTest == true)
		main().setSelfTest(on)
		OfficerFrame.refresh()
	end, { size = fs.small })
	Skin.rect(W.selfTest, part, G.selfTest)
	W.selfTest.label:SetText(L.SELF_TEST)
	local hint = wrapped(part, G.selfHint, c.muted, fs.label)
	hint:SetText(L.SELF_TEST_HINT)

	-- Recent purchases with status badges.
	heading(part, G.purchasesHead, L.PURCHASES)
	local pp = Skin.panel(part, part, G.purchases, "inset")
	W.noPurchases = Skin.textIn(pp, part, { G.none[1], G.pRow, G.none[3], G.pRowH }, "label", fs.small, c.muted, "LEFT")
	W.noPurchases:SetText(L.NO_PURCHASES)
	for i = 1, G.pRows do
		local y = G.pRow + (i - 1) * G.pRowH
		local row = CreateFrame("Frame", nil, pp)
		Skin.rect(row, part, { G.purchases[1], y, G.purchases[3], G.pRowH })
		local ox = G.purchases[1]
		row.name = Skin.textIn(row, row, { G.pName[1] - ox, 0, G.pName[2], G.pRowH }, "label", fs.listName, c.text,
			"LEFT")
		row.amount = Skin.textIn(row, row, { G.pAmount[1] - ox, 0, G.pAmount[2], G.pRowH }, "number", fs.listNumber,
			c.number, "RIGHT")
		local br = { G.pBadge[1] - ox, G.pBadge[2], G.pBadge[3], G.pBadge[4] }
		local anchor = CreateFrame("Frame", nil, row)
		Skin.rect(anchor, row, br)
		row.badge = Skin.nine(row, anchor, Theme.slices.badge, "ARTWORK")
		row.status = Skin.textIn(row, row, br, "number", fs.badge, c.white, "CENTER")
		Skin.shadow(row.status, 0, 0)
		row:Hide()
		W.purchaseRows[i] = row
	end
	return part
end

local function buildStatus(parent)
	local St, c = Theme.officer.status, Theme.colors
	local part = section(parent, St.height)
	heading(part, St.heading, L.GUILD_SETTINGS)
	W.status = wrapped(part, St.text, c.text)
	return part
end

local function buildForm(parent)
	local F, c, fs = Theme.officer.form, Theme.colors, Theme.fontSize
	local part = section(parent, F.height)
	for i, k in ipairs(FIELDS) do
		local col, row = (i - 1) % F.cols, math.floor((i - 1) / F.cols)
		local x, top = F.x + col * F.colStep, row * F.rowStep
		local label = Skin.textIn(part, part, { x + F.label[1], top + F.label[2], F.label[3], F.label[4] }, "label",
			fs.label, c.muted, "LEFT")
		label:SetText(L["F_" .. k])
		local e = Skin.editBox(part, F.field[3], F.field[4], "number", fs.lineField + 1)
		Skin.rect(e.holder, part, { x + F.field[1], top + F.field[2], F.field[3], F.field[4] })
		e:SetScript("OnTextChanged", function()
			if not W.filling then
				updateForm()
			end
		end)
		W.fields[k] = e
	end

	W.line = Skin.editBox(part, F.line[3], F.line[4], "numberMedium", fs.lineField)
	Skin.rect(W.line.holder, part, F.line)
	Skin.color(W.line, c.stakeText)
	W.line:setReadOnlyLook(true)
	-- Read-only: user typing puts the line back; focus selects all for Ctrl+C.
	W.line:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(W.currentLine or "")
			self:HighlightText()
		end
	end)
	W.line:HookScript("OnEditFocusGained", function(self) self:HighlightText() end)
	W.copy = Skin.button(part, "icon", F.copy[3], F.copy[4], function()
		W.line:SetFocus()
		W.line:HighlightText()
	end, { icon = Theme.icons.copy, iconOnly = true, iconSize = Theme.layout.iconSize })
	Skin.rect(W.copy, part, F.copy)
	local hint = wrapped(part, F.hint, c.muted, fs.label)
	hint:SetText(L.LINE_HINT)
	W.formNote = wrapped(part, F.note, c.muted, fs.label)
	return part
end

local function build()
	local O, c, fs = Theme.officer, Theme.colors, Theme.fontSize

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
	f:SetSize(O.width, O.maxHeight)
	W.bgTiles = Skin.tiles(f, Theme.tex.bg, O.width, O.maxHeight, "BACKGROUND")
	W.windowFrame = Skin.nine(f, f, Theme.slices.window, "BORDER")

	local title = Skin.textIn(f, f, O.title, "title", fs.officerTitle, c.gold, "LEFT")
	Skin.shadow(title, 2, -2, c.titleShadow)
	title:SetText(L.OFFICER_TITLE)
	W.close = Skin.button(f, "icon", O.close[3], O.close[4], function() f:Hide() end,
		{ icon = Theme.icons.close, iconOnly = true, iconSize = Theme.layout.iconSize })
	Skin.rect(W.close, f, O.close)
	local divAnchor = CreateFrame("Frame", nil, f)
	Skin.rect(divAnchor, f, O.divider)
	Skin.nine(f, divAnchor, Theme.slices.divider, "ARTWORK")

	W.grantPart = buildGrant(f)
	W.statusPart = buildStatus(f)
	W.nonOfficer = Skin.text(f, "label", fs.small, c.muted, "LEFT")
	W.nonOfficer:SetSize(O.nonOfficer[3], O.nonOfficer[4])
	W.nonOfficer:SetText(L.NEED_OFFICER)
	W.formPart = buildForm(f)

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
	f:SetPoint("CENTER", UIParent, "CENTER", O.home[1], O.home[2])

	if main() then
		main().subscribe(function(name, data)
			-- The note under the grant button follows the purchase it started.
			if name == "purchase" and type(data) == "table" and data.role == "officer"
				and data.buyId == W.grantId and W.grantNote then
				local c = Theme.colors
				if data.status == "done" then
					note(W.grantNote, string.format(L.GRANT_DONE, tostring(data.player), tostring(data.tokens)), c.goldLight)
				elseif data.status == "timeout" or data.status == "failed" then
					note(W.grantNote, string.format(L.GRANT_FAILED, tostring(data.player), statusLabel(data)), c.lose)
				end
			end
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
