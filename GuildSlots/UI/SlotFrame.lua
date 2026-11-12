local addonName, ns = ...

-- The slot machine window. Game rules live in ns.Solo (play money) and in the guild session's
-- game (ns.Guild, tokens); both have the same shape. This file builds the window and plays the
-- rounds they return: ns.Plan turns a round into timed steps, the step handlers below show them.
-- S.solo is the solo game, S.game the one shown. Only lines tables (T2) are rendered.
--
-- Layout: header, top bar (balance, free-game counter, win), reel panel (5 x 3 with line
-- markers left and right), message line, take/gamble row, stake pills and SPIN, paytable
-- toggle, footer. Every size, colour and time comes from UI/Theme.lua.

local L, Theme, Anim, Reel, Plan = ns.L, ns.Theme, ns.Anim, ns.Reel, ns.Plan

local SlotFrame = {}
ns.SlotFrame = SlotFrame

local FRAME_NAME = "GuildSlotsFrame"
local REELS, ROWS = 5, 3

-- Injectable for tests: rng(n) -> 0..n-1.
ns.random = ns.random or function(n)
	return math.random(n) - 1
end

local db -- GuildSlotsDB, set on ADDON_LOADED (or on first use)
local W = {} -- widgets
local S = { now = 0, phase = "idle", counts = {}, offer = false, mode = "solo" } -- animation state
SlotFrame.widgets, SlotFrame.state = W, S

-- The table the window draws (strips, lines): always T2.
local T2 = ns.Tables.get("T2")

---------------------------------------------------------------------------------------------
-- Helpers

local function fmt(n)
	return Anim.formatNumber(n, L.THOUSANDS)
end

local function rgb(c)
	return c[1], c[2], c[3]
end

local function paint(tex, c, a)
	tex:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1)
end

local function chat(text)
	local chat = DEFAULT_CHAT_FRAME
	if chat and chat.AddMessage then
		chat:AddMessage("|cff00e701" .. L.TITLE .. "|r: " .. tostring(text))
	end
end

local function inCombat()
	return type(InCombatLockdown) == "function" and InCombatLockdown() and true or false
end

local function clamp01(u)
	if u < 0 then return 0 end
	if u > 1 then return 1 end
	return u
end

-- A Theme.sounds entry is a soundkit name, a soundkit id, or a file under the addon folder
-- (anything ending in .ogg or .mp3). Returns the sound handle, if the client gave one.
local function playSound(key)
	if not db or db.sound == false then
		return
	end
	local s = Theme.sounds[key]
	if type(s) == "string" and s:find("%.[om][gp][g3]$") then
		if type(PlaySoundFile) == "function" then
			local ok, willPlay, handle = pcall(PlaySoundFile, "Interface\\AddOns\\" .. addonName .. "\\" .. s, "SFX")
			return ok and willPlay and handle or nil
		end
		return
	end
	local id = s
	if type(s) == "string" then
		id = type(SOUNDKIT) == "table" and SOUNDKIT[s] or nil
	end
	if id and type(PlaySound) == "function" then
		local ok, willPlay, handle = pcall(PlaySound, id, "SFX")
		return ok and willPlay and handle or nil
	end
end

-- Sounds of a step; a skipped (silent) step plays none.
local function sfx(key, silent)
	if not silent then
		playSound(key)
	end
end

-- The reel sound runs for as long as any reel turns.
local spinSound
local function stopSpinSound()
	if spinSound and type(StopSound) == "function" then
		pcall(StopSound, spinSound, 120)
	end
	spinSound = nil
end

local function startSpinSound()
	stopSpinSound()
	spinSound = playSound("reelSpin")
end

local function font(fs, size, flags)
	local ok, res = pcall(fs.SetFont, fs, Theme.fonts.face, size, flags or "")
	if not ok or res == false then
		local obj = _G[Theme.fonts.fallbackObject]
		if obj then
			fs:SetFontObject(obj)
		end
	end
end

local function text(parent, size, color, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	font(fs, size)
	fs:SetTextColor(rgb(color or Theme.colors.text))
	return fs
end

-- A flat panel: 1 px border colour, inner fill.
local function panel(parent, fill, border)
	local f = CreateFrame("Frame", nil, parent)
	f.border = f:CreateTexture(nil, "BACKGROUND")
	f.border:SetAllPoints(f)
	paint(f.border, border or fill)
	f.fill = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	f.fill:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
	f.fill:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
	paint(f.fill, fill)
	return f
end

-- Button styles: "accent" (main action), "panel", "outline" (accent border), "pill", "ghost".
local function paintButton(b)
	local c = Theme.colors
	local style, hover = b.style, b.hover and b.enabled
	local fill, border, label
	if style == "accent" then
		fill, border, label = hover and c.accentHover or c.accent, c.accent, c.accentText
	elseif style == "outline" then
		fill, border, label = hover and c.panelHover or c.panel, c.accent, c.accent
	elseif style == "pill" then
		if b.selected then
			fill, border, label = c.border, c.accent, c.text
		else
			fill, border, label = hover and c.panelHover or c.panel, c.border, c.muted
		end
	elseif style == "ghost" then
		fill, border, label = nil, nil, hover and c.text or c.muted
	else
		fill, border, label = hover and c.panelHover or c.panel, c.border, c.text
	end
	if fill then
		paint(b.border, border)
		paint(b.fill, fill)
		b.border:Show()
		b.fill:Show()
	else
		b.border:Hide()
		b.fill:Hide()
	end
	b.label:SetTextColor(rgb(label))
	b:SetAlpha(b.enabled and 1 or c.disabledAlpha)
end

local function button(parent, w, h, style, size, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, h)
	b.style, b.enabled, b.hover, b.selected, b.onClick = style, true, false, false, onClick
	b.border = b:CreateTexture(nil, "BACKGROUND")
	b.border:SetAllPoints(b)
	b.fill = b:CreateTexture(nil, "BACKGROUND", nil, 1)
	b.fill:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
	b.fill:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
	b.label = text(b, size or Theme.fonts.button)
	b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
	b:SetScript("OnEnter", function()
		b.hover = true
		paintButton(b)
	end)
	b:SetScript("OnLeave", function()
		b.hover = false
		paintButton(b)
	end)
	b:SetScript("OnClick", function()
		if b.enabled and b.onClick then
			b.onClick()
		end
	end)
	b.setEnabled = function(_, on)
		b.enabled = on and true or false
		paintButton(b)
	end
	b.setSelected = function(_, on)
		b.selected = on and true or false
		paintButton(b)
	end
	paintButton(b)
	return b
end

-- Shared with UI/OfficerFrame.lua so both windows look the same.
SlotFrame.ui = {
	fmt = fmt, rgb = rgb, paint = paint, font = font, text = text, panel = panel, button = button,
	chat = chat, playSound = playSound,
}

---------------------------------------------------------------------------------------------
-- Saved state

local function initDB()
	if db then
		return
	end
	if type(GuildSlotsDB) ~= "table" then
		GuildSlotsDB = {}
	end
	db = GuildSlotsDB
	if db.sound == nil then db.sound = true end
	if db.space == nil then db.space = true end
end

local function savePosition()
	local f = W.frame
	if not f or not db then
		return
	end
	local point, _, relPoint, x, y = f:GetPoint(1)
	if point then
		db.pos = { point, relPoint, x, y }
	end
end

local function applyPosition()
	local f = W.frame
	f:ClearAllPoints()
	local p = db and db.pos
	if type(p) == "table" and type(p[1]) == "string" then
		f:SetPoint(p[1], UIParent, p[2], tonumber(p[3]) or 0, tonumber(p[4]) or 0)
	else
		f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
	end
end

local function saveGame()
	if db and S.solo then
		db.soloBalance = S.solo.balance
	end
end

---------------------------------------------------------------------------------------------
-- Display

local function setBalanceShown(v)
	S.balanceShown = v
	W.balance:SetText(fmt(v))
end

local function setTotalShown(v)
	S.totalShown = v
	W.winAmount:SetText(v and fmt(v) or "")
end

local function setFreeWinShown(v)
	S.freeWinShown = v
	W.freeTotal:SetText(string.format(L.FREE_TOTAL, fmt(v)))
end

local function setBannerAmount(v)
	W.bannerAmount:SetText(fmt(v))
end

local SETTERS = {
	balance = setBalanceShown, total = setTotalShown, freeWin = setFreeWinShown, banner = setBannerAmount,
}

local function countTo(key, from, to, dur)
	S.counts[key] = { from = from, to = to, t0 = S.now, dur = dur }
	SETTERS[key](from)
end

local function setWinText(str, color)
	W.win:SetText(str or "")
	W.win:SetTextColor(rgb(color or Theme.colors.accent))
end

local function multiplierText(win, stake)
	local m = win / stake
	if m % 1 == 0 then
		return string.format("%d", m)
	end
	return string.format("%.1f", m)
end

local function winLine(amount, stake)
	local s = L.WIN .. " " .. fmt(amount)
	if stake then
		s = s .. "  |cffb1bad3x" .. multiplierText(amount, stake) .. "|r"
	end
	return s
end

local function message(str, color)
	setWinText(str, color or Theme.colors.muted)
	S.messageUntil = S.now + Theme.timing.message
end

local function supported()
	local tbl = S.game and S.game.tbl
	return tbl ~= nil and tbl.kind == "lines"
end

-- What the window shows while idle in guild mode when the game cannot be played.
local STATUS_LINES = { no_account = "ST_NO_ACCOUNT", level = "ST_LEVEL", broken = "ST_BROKEN" }

local function statusLine()
	if S.mode ~= "guild" then
		return nil
	end
	local key = STATUS_LINES[S.game:status()]
	if key then
		return L[key]
	end
	if not supported() then
		return L.UNSUPPORTED_TABLE
	end
	return nil
end

local function idleText()
	setWinText(statusLine() or "", Theme.colors.muted)
end

-- The short line for a code from spin() or gamble().
local CODE_LINES = {
	no_account = "ST_NO_ACCOUNT", level = "ST_LEVEL", broken = "ST_BROKEN", wait = "WAIT",
	send = "SEND_FAILED",
}

local function codeLine(code)
	if code == "no_funds" then
		return S.mode == "guild" and L.NO_TOKENS or L.NO_FUNDS
	end
	local key = CODE_LINES[code]
	return key and L[key] or string.format(L.SPIN_FAILED, tostring(code))
end

local function symbolName(sym)
	return L["SYM_" .. tostring(sym)]
end

local function currentStep()
	return S.plan and S.plan.steps[S.si] or nil
end

local function refresh()
	local game, phase = S.game, S.phase
	local busy = phase == "round" or phase == "flip"
	local label = L.SPIN
	if phase == "round" then
		local step = currentStep()
		label = (step and step.kind == "spin" and step.game == 0 and not S.quick) and L.STOP or L.SKIP
	end
	W.spin.label:SetText(label)
	W.spin:setEnabled(phase ~= "flip")
	for _, pill in ipairs(W.pills) do
		pill:setSelected(pill.stake == game.stake)
		pill:setEnabled(not busy)
	end
	W.refill:setEnabled(not busy)
	W.refill:SetShown(S.mode == "solo")
	W.mode.label:SetText(S.mode == "guild" and L.GUILD or L.SOLO)
	local officer = ns.Main and ns.Main.isOfficer() or false
	W.officer:SetShown(officer)
	local offer = S.offer and game:state() == "gamble" and not busy
	if offer then
		W.take.label:SetText(string.format(L.TAKE, fmt(game.pending)))
		W.gamble.label:SetText(string.format(L.GAMBLE, fmt(game.pending)))
		W.offerRow:Show()
	else
		W.offerRow:Hide()
	end
	W.sound.label:SetText(db.sound and L.SOUND_ON or L.SOUND_OFF)
end

---------------------------------------------------------------------------------------------
-- Reel overlays: dimmed and highlighted cells, drawn lines, line markers, expansions.
-- All textures exist from build() on; these only show, hide and colour them.

local function setEdges(cell, c)
	for _, e in ipairs(cell.edges) do
		paint(e, c)
		e:Show()
	end
end

-- Hides every highlight, line, marker light and dim.
local function clearShow()
	for r = 1, REELS do
		for row = 1, ROWS do
			local cell = W.cells[r][row]
			cell.dim:Hide()
			for _, e in ipairs(cell.edges) do e:Hide() end
		end
	end
	for li = 1, #W.lineSegs do
		for _, seg in ipairs(W.lineSegs[li]) do seg:Hide() end
	end
	for li = 1, #W.markers do
		W.markers[li].lit = false
		for _, m in ipairs(W.markers[li]) do
			paint(m.bg, Theme.colors.border)
			m.label:SetTextColor(rgb(Theme.colors.muted))
		end
	end
	W.overlay:SetAlpha(1)
end

local function dimAll()
	for r = 1, REELS do
		for row = 1, ROWS do
			W.cells[r][row].dim:Show()
		end
	end
end

local function markCell(r, row, c)
	local cell = W.cells[r][row]
	cell.dim:Hide()
	setEdges(cell, c)
end

local function lightMarker(li, c)
	W.markers[li].lit = true
	for _, m in ipairs(W.markers[li]) do
		paint(m.bg, c)
		m.label:SetTextColor(rgb(Theme.colors.accentText))
	end
end

-- Line li drawn across the reels, its markers lit, its first `count` cells highlighted.
local function showLine(li, count)
	local c = Theme.colors.lines[li]
	for _, seg in ipairs(W.lineSegs[li]) do
		paint(seg, c)
		seg:SetAlpha(1)
		seg:Show()
	end
	lightMarker(li, c)
	local rows = T2.lines[li]
	for r = 1, count do
		markCell(r, rows[r] + 1, c)
	end
end

-- Highlights the books in window (a list of 5 columns).
local function markBooks(window)
	local wild = T2.scatter.symbol
	for r = 1, REELS do
		local col = window[r]
		for row = 1, ROWS do
			if col[row] == wild then
				markCell(r, row, Theme.colors.gold)
			end
		end
	end
end

local function hasBook(col)
	local wild = T2.scatter.symbol
	return col[1] == wild or col[2] == wild or col[3] == wild
end

-- Expansion of reel r: u 0 (hidden) .. 1 (the symbol fills the reel).
local function setExpand(r, u)
	local e = W.expand[r]
	if u <= 0 then
		e.bg:Hide()
		for _, ic in ipairs(e.icons) do ic:Hide() end
		return
	end
	e.bg:SetHeight(math.max(0.01, u * ROWS * Theme.size.cell))
	e.bg:Show()
	for row, ic in ipairs(e.icons) do
		-- the middle cell first, then top and bottom
		local a = clamp01(row == 2 and u * 2 or u * 2 - 1)
		ic:SetAlpha(a)
		ic:SetShown(a > 0)
	end
end

local function setExpandSymbol(sym)
	for r = 1, REELS do
		for _, ic in ipairs(W.expand[r].icons) do
			ic:SetTexture(Theme.symbols[sym])
		end
	end
end

local function hideExpansions()
	for r = 1, REELS do
		setExpand(r, 0)
	end
end

local function hideTease()
	for r = 1, REELS do
		W.tease[r]:Hide()
	end
end

---------------------------------------------------------------------------------------------
-- Banner (free-game intro, retrigger, summary, big win), particles, window flash

local function hideBanner()
	W.banner:Hide()
	W.bannerShade:Hide()
	W.bannerIcon:Hide()
	W.bannerSub:SetText("")
	W.bannerAmount:SetText("")
	W.bannerTitle:SetAlpha(1)
end

local function showBanner(title, color, shade)
	W.banner:Show()
	W.bannerShade:SetShown(shade and true or false)
	W.bannerTitle:SetText(title)
	W.bannerTitle:SetTextColor(rgb(color or Theme.colors.gold))
end

local function hideParticles()
	S.particlesFrom = nil
	for _, p in ipairs(W.particles) do p:Hide() end
end

local function updateParticles()
	local t0 = S.particlesFrom
	if not t0 then
		return
	end
	local life, list = Theme.timing.particleLife, W.particles
	local n = #list
	local t = S.now - t0
	local size = Theme.size
	local spreadX, spreadY = size.width * 0.42, size.cell * 2
	for i = 1, n do
		local p = list[i]
		local shifted = t + (i - 1) * life / n
		local cycle = math.floor(shifted / life)
		local x, y, a = Anim.particle(i + cycle * 37, shifted - cycle * life, life)
		p:ClearAllPoints()
		p:SetPoint("CENTER", W.reelPanel, "CENTER", x * spreadX, y * spreadY)
		p:SetAlpha(a)
		p:Show()
	end
end

local function setFlash(on)
	S.flashing = on
	if not on then
		W.flash:Hide()
	end
end

---------------------------------------------------------------------------------------------
-- Free-game mode: free strips, tint, counter and badge

local function setTint(free)
	local c = Theme.colors
	paint(W.reelPanel.fill, free and c.freePanel or c.panel)
	for r = 1, REELS do
		W.reels[r]:setTint(free and c.freeCell or c.cell)
	end
end

local function setCounter(i, of)
	W.freeCounter:SetText(string.format(L.FREE_COUNTER, i, of))
end

local function enterFree(symbol, of)
	if S.free then
		return
	end
	S.free = true
	for r = 1, REELS do
		W.reels[r]:setStrip(T2.freeReels[r], 0)
	end
	setTint(true)
	W.badge:SetTexture(Theme.symbols[symbol])
	setExpandSymbol(symbol)
	setCounter(0, of)
	setFreeWinShown(0)
	W.freeBar:Show()
end

local function leaveFree()
	if not S.free then
		return
	end
	S.free = false
	hideExpansions()
	local stops = S.result and S.result.round.stops
	for r = 1, REELS do
		W.reels[r]:setStrip(T2.reels[r], stops and stops[r] or 0)
	end
	setTint(false)
	W.freeBar:Hide()
end

---------------------------------------------------------------------------------------------
-- Step handlers. enter(step, silent) starts a step (silent: skipped, no sounds), update(step, t)
-- animates it and returns true when it is over, finish(step) leaves its end state.

local H = {}

local function timed(step, t)
	return t >= step.dur
end

local function countStep(step, silent)
	local d = math.min(step.dur, Theme.timing.lineCount)
	countTo("total", step.from, step.total, silent and 0 or d)
	if step.game > 0 then
		countTo("freeWin", step.freeWin - step.amount, step.freeWin, silent and 0 or d)
	end
end

H.spin = {
	enter = function(step, silent)
		clearShow()
		hideExpansions()
		S.window = step.window
		if step.free then
			setCounter(step.game, step.freeOf)
		end
		if silent then
			return
		end
		if step.game == 0 then
			sfx("reelStart")
		end
		local t0 = S.now + step.delay
		for r = 1, REELS do
			W.reels[r]:spin(t0, step.stops[r], step.stopAt[r])
		end
		startSpinSound()
	end,
	update = function(step)
		local now, running = S.now, false
		for r = 1, REELS do
			local reel = W.reels[r]
			local ev, landedToo = reel:update(now)
			if ev == "landed" or landedToo then
				playSound("reelStop")
				if hasBook(step.window[r]) then
					playSound("bookLand")
				end
			end
			if reel:isSpinning() then
				running = true
			end
		end
		local tease = step.tease
		if tease then
			local on = not W.reels[tease - 1]:isSpinning()
			local a = 0.3 + 0.7 * Anim.pulse(now, Theme.timing.flashFreq)
			for r = 1, REELS do
				local glow = W.tease[r]
				if on and r >= tease and W.reels[r]:isSpinning() then
					glow:SetAlpha(a)
					glow:Show()
				else
					glow:Hide()
				end
			end
		end
		if not running then
			stopSpinSound()
			return true
		end
		return false
	end,
	finish = function(step)
		stopSpinSound()
		hideTease()
		for r = 1, REELS do
			W.reels[r]:setStop(step.stops[r])
		end
	end,
}

H.allLines = {
	enter = function(step, silent)
		clearShow()
		dimAll()
		for _, l in ipairs(step.lines) do
			showLine(l.line, l.count)
		end
		if step.scatter.win > 0 then
			markBooks(S.window)
		end
	end,
	update = function(step, t)
		local a = 0.35 + 0.65 * Anim.pulse(t, Theme.timing.flashFreq)
		for _, l in ipairs(step.lines) do
			for _, seg in ipairs(W.lineSegs[l.line]) do
				seg:SetAlpha(a)
			end
		end
		return t >= step.dur
	end,
	finish = function()
		clearShow()
	end,
}

H.line = {
	enter = function(step, silent)
		local l = step.line
		clearShow()
		dimAll()
		showLine(l.line, l.count)
		setWinText(string.format(L.LINE_WIN, l.line, l.count, symbolName(l.symbol), fmt(l.win)), Theme.colors.lines[l.line])
		countStep(step, silent)
		sfx("lineWin", silent)
	end,
	update = timed,
	finish = function()
		clearShow()
	end,
}

H.scatter = {
	enter = function(step, silent)
		clearShow()
		dimAll()
		markBooks(S.window)
		setWinText(string.format(L.SCATTER_WIN, step.count, symbolName(T2.scatter.symbol), fmt(step.amount)), Theme.colors.gold)
		countStep(step, silent)
		sfx("lineWin", silent)
	end,
	update = function(step, t)
		W.overlay:SetAlpha(0.6 + 0.4 * Anim.pulse(t, Theme.timing.pulseFreq))
		return t >= step.dur
	end,
	finish = function()
		clearShow()
	end,
}

H.retrigger = {
	enter = function(step, silent)
		showBanner(string.format(L.FREE_MORE, step.added), Theme.colors.gold, false)
		setCounter(step.game, step.freeOf)
		sfx("freeStart", silent)
	end,
	update = function(step, t)
		W.bannerTitle:SetAlpha(0.4 + 0.6 * Anim.pulse(t, Theme.timing.flashFreq))
		return t >= step.dur
	end,
	finish = function()
		hideBanner()
	end,
}

H.expand = {
	enter = function(step)
		clearShow()
		hideExpansions()
		setExpandSymbol(step.symbol)
		S.expandFired = 0
	end,
	update = function(step, t)
		local per = Theme.timing.expandReel
		for k, r in ipairs(step.reels) do
			local u = clamp01((t - (k - 1) * per) / per)
			if u > 0 and k > S.expandFired then
				S.expandFired = k
				playSound("expand")
			end
			setExpand(r, u)
		end
		return t >= step.dur
	end,
	finish = function(step)
		for _, r in ipairs(step.reels) do
			setExpand(r, 1)
		end
	end,
}

H.expandWin = {
	enter = function(step, silent)
		clearShow()
		for li = 1, #W.markers do
			lightMarker(li, Theme.colors.gold)
		end
		setWinText(string.format(L.EXPAND_WIN, symbolName(step.symbol), step.count, fmt(step.amount)), Theme.colors.gold)
		countStep(step, silent)
		sfx("lineWin", silent)
	end,
	update = timed,
	finish = function()
		clearShow()
	end,
}

local function expandingIndex(sym)
	for i, s in ipairs(T2.expanding) do
		if s == sym then return i end
	end
	return 1
end

H.intro = {
	enter = function(step, silent)
		clearShow()
		dimAll()
		markBooks(S.window)
		setWinText("")
		S.introStage = 0
		sfx("freeStart", silent)
	end,
	update = function(step, t)
		local tm = Theme.timing
		if t < tm.introPulse then
			W.overlay:SetAlpha(0.4 + 0.6 * Anim.pulse(t, tm.flashFreq))
			return false
		end
		if S.introStage == 0 then
			S.introStage = 1
			W.overlay:SetAlpha(1)
			showBanner(string.format(L.FREE_GAMES, step.freeOf), Theme.colors.gold, true)
		end
		if t >= tm.introShuffleAt then
			local u = t - tm.introShuffleAt
			local final = expandingIndex(step.symbol)
			local i = Anim.shuffle(u, tm.introShuffle, #T2.expanding, final)
			W.bannerIcon:SetTexture(Theme.symbols[T2.expanding[i]])
			W.bannerIcon:Show()
			if u >= tm.introShuffle and S.introStage == 1 then
				S.introStage = 2
				W.bannerSub:SetText(string.format(L.EXPANDING, symbolName(step.symbol)))
				playSound("expand")
			end
		end
		return t >= step.dur
	end,
	finish = function(step)
		hideBanner()
		clearShow()
		enterFree(step.symbol, step.freeOf)
	end,
}

H.summary = {
	enter = function(step, silent)
		clearShow()
		showBanner(L.FREE_OVER, Theme.colors.gold, true)
		W.bannerSub:SetText(string.format(L.FREE_PLAYED, step.games))
		countTo("banner", 0, step.freeWin, silent and 0 or step.dur * 0.6)
		-- Back to the base game's reels under the shade.
		leaveFree()
		setWinText(winLine(step.freeWin))
	end,
	update = timed,
	finish = function()
		hideBanner()
	end,
}

H.big = {
	enter = function(step, silent)
		clearShow()
		showBanner(L["BIG_WIN_" .. step.level], Theme.colors.gold, true)
		countTo("banner", 0, step.total, silent and 0 or step.dur * 0.8)
		if not silent then
			S.particlesFrom = S.now
			setFlash(true)
		end
		sfx("bigWin", silent)
	end,
	update = function(step, t)
		updateParticles()
		W.bannerTitle:SetAlpha(0.6 + 0.4 * Anim.pulse(t, Theme.timing.pulseFreq))
		return t >= step.dur
	end,
	finish = function()
		hideParticles()
		setFlash(false)
		hideBanner()
	end,
}

H["end"] = {
	enter = function(step)
		S.counts.total = nil
		setTotalShown(step.total)
		if step.total > 0 then
			local s = winLine(step.total, S.result.stake)
			if step.capped then
				s = s .. "  |cffb1bad3" .. L.CAPPED .. "|r"
			end
			setWinText(s)
		end
	end,
	update = function()
		return true
	end,
	finish = function() end,
}

---------------------------------------------------------------------------------------------
-- Round flow

-- The base game's winning cells stay marked after a round without free games.
local function showResting()
	clearShow()
	local round = S.result and S.result.round
	if not round or round.free or round.win <= 0 then
		return
	end
	dimAll()
	for _, l in ipairs(round.lines) do
		showLine(l.line, l.count)
	end
	if round.scatter.win > 0 then
		markBooks(round.window)
	end
end

local function endRound()
	S.phase = "idle"
	S.plan, S.si = nil, nil
	stopSpinSound()
	hideTease()
	leaveFree()
	hideBanner()
	hideParticles()
	setFlash(false)
	showResting()
	countTo("balance", S.balanceShown, S.game.balance, Theme.timing.countUp)
	S.offer = S.game:state() == "gamble"
	if not (S.result and S.result.win > 0) then
		idleText()
	end
	saveGame()
	refresh()
end

-- silent: the round is being settled; the next step starts without sounds or reel motion.
local function advance(silent)
	S.si = S.si + 1
	local step = S.plan.steps[S.si]
	if not step then
		endRound()
		return
	end
	S.st0 = S.now
	H[step.kind].enter(step, silent)
	refresh()
end

-- Jumps to the end of the current group (base game, intro, one free game, closing steps).
local function skip(silent)
	local steps = S.plan.steps
	local cur = steps[S.si]
	local group = cur.group
	H[cur.kind].finish(cur)
	local i = S.si + 1
	while steps[i] and steps[i].group == group do
		local step = steps[i]
		H[step.kind].enter(step, true)
		H[step.kind].finish(step)
		i = i + 1
	end
	local last = steps[i - 1]
	S.counts.total, S.counts.freeWin, S.counts.banner = nil, nil, nil
	setTotalShown(last.total)
	if S.free then
		setFreeWinShown(last.freeWin)
	end
	S.si = i - 1
	advance(silent)
end

-- Finishes the whole round at once.
local function settleRound()
	local guard = 0
	while S.phase == "round" and guard < 1000 do
		guard = guard + 1
		skip(true)
	end
end

local function startRound(r, before)
	S.result, S.offer, S.counts, S.messageUntil = r, false, {}, nil
	setWinText("")
	setTotalShown(0)
	clearShow()
	hideExpansions()
	setBalanceShown(before - r.stake)
	S.plan = Plan.build(r.round, Theme.timing, T2)
	S.si, S.quick = 0, false
	S.phase = "round"
	if db.paytable then
		db.paytable = false
		SlotFrame.layout()
	end
	saveGame()
	advance()
end

local function quickStop()
	for i = 1, REELS do
		W.reels[i]:quickStop(S.now, (i - 1) * Theme.timing.quickStagger)
	end
end

function SlotFrame.spin()
	if S.phase == "flip" then
		return
	end
	if S.phase == "round" then
		local step = currentStep()
		if step.kind == "spin" and step.game == 0 and not S.quick then
			S.quick = true
			quickStop()
			refresh()
		else
			skip()
		end
		return
	end
	if not supported() then
		message(statusLine() or L.UNSUPPORTED_TABLE, Theme.colors.lose)
		refresh()
		return
	end
	local game = S.game
	local before = game.balance
	local r, err = game:spin()
	if not r then
		message(codeLine(err), Theme.colors.lose)
		refresh()
		return
	end
	startRound(r, before)
end

function SlotFrame.take()
	if S.phase ~= "idle" or S.game:state() ~= "gamble" then
		return
	end
	local res = S.game:take()
	S.offer = false
	clearShow()
	message(L.TAKEN .. " " .. fmt(res.amount), Theme.colors.accent)
	playSound("click")
	refresh()
end

function SlotFrame.gamble()
	if S.phase ~= "idle" or S.game:state() ~= "gamble" then
		return
	end
	local res, err = S.game:gamble()
	if not res then
		message(codeLine(err), Theme.colors.lose)
		refresh()
		return
	end
	S.counts = {}
	setBalanceShown(S.balanceShown)
	S.flip = { res = res, t0 = S.now, revealed = false }
	S.offer = false
	S.messageUntil = nil
	S.phase = "flip"
	setWinText("")
	W.coin:SetTexture(Theme.coin.back)
	W.coinResult:SetText("")
	W.coinOverlay:Show()
	playSound("click")
	refresh()
end

function SlotFrame.refill()
	if S.mode ~= "solo" or S.phase ~= "idle" then
		return
	end
	local res = S.game:refill()
	S.offer, S.counts = false, {}
	clearShow()
	setBalanceShown(res.balance)
	message(L.REFILLED)
	saveGame()
	playSound("click")
	refresh()
end

function SlotFrame.setStake(v)
	if S.phase ~= "idle" then
		return
	end
	if S.game:state() == "gamble" then
		S.game:take()
		S.offer = false
		clearShow()
	end
	S.game:setStake(v)
	SlotFrame.updatePaytable()
	playSound("click")
	refresh()
end

local function updateFlip()
	local f, t = S.flip, Theme.timing
	local dt = S.now - f.t0
	local size = W.coinSize
	if dt < t.gambleFlip then
		-- Coin turns around its vertical axis: width follows |cos|.
		local w = math.abs(math.cos(math.pi * t.gambleFlipFreq * dt)) * size
		W.coin:SetWidth(math.max(1, w))
		return
	end
	local res = f.res
	if not f.revealed then
		f.revealed = true
		W.coin:SetWidth(size)
		W.coin:SetTexture(res.won and Theme.coin.win or Theme.coin.lose)
		if res.won then
			W.coinResult:SetText(L.GAMBLE_WON)
			W.coinResult:SetTextColor(rgb(Theme.colors.accent))
			setWinText(winLine(res.amount * 2))
			playSound("gambleWin")
		else
			W.coinResult:SetText(L.GAMBLE_LOST)
			W.coinResult:SetTextColor(rgb(Theme.colors.lose))
			setWinText(L.GAMBLE_LOST, Theme.colors.lose)
			playSound("gambleLose")
		end
		countTo("balance", S.balanceShown, S.game.balance, t.countUp)
		saveGame()
	end
	if dt >= t.gambleFlip + t.gambleHold then
		W.coinOverlay:Hide()
		S.flip = nil
		S.phase = "idle"
		S.offer = res.canGamble
		if not res.won then
			clearShow()
		end
		refresh()
	end
end

-- Finishes everything at once (round, coin flip, count-ups) so no result stays hidden.
-- Used when the window closes and before the window changes to another game.
local function settle()
	stopSpinSound()
	if S.phase == "round" then
		settleRound()
	end
	if S.phase == "flip" then
		S.flip.t0 = S.now - 100
		updateFlip()
	end
	S.counts = {}
	setBalanceShown(S.game.balance)
end

local function onUpdate(_, elapsed)
	-- Absolute-time animation; cap hitches so a long frame does not skip whole phases.
	elapsed = tonumber(elapsed) or 0
	if elapsed > 0.25 then elapsed = 0.25 end
	S.now = S.now + elapsed
	local now, t = S.now, Theme.timing

	if S.phase == "round" then
		local step = S.plan.steps[S.si]
		local h = H[step.kind]
		if h.update(step, now - S.st0) then
			h.finish(step)
			advance()
		end
	end

	for key, c in pairs(S.counts) do
		SETTERS[key](Anim.countUp(c.from, c.to, now - c.t0, c.dur))
		if now - c.t0 >= c.dur then
			S.counts[key] = nil
		end
	end

	if S.phase == "flip" then
		updateFlip()
	end

	if S.flashing then
		W.flash:SetAlpha(Anim.pulse(now, t.flashFreq))
		W.flash:Show()
	end

	if S.messageUntil and now >= S.messageUntil then
		S.messageUntil = nil
		if S.phase == "idle" and not S.offer then
			idleText()
		end
	end
end

---------------------------------------------------------------------------------------------
-- Keyboard: only Space is consumed, only with the mouse over the window, never in combat.

local function setPropagate(f, on)
	if f.SetPropagateKeyboardInput and not inCombat() then
		pcall(f.SetPropagateKeyboardInput, f, on)
	end
end

local function updateKeyboard()
	local f = W.frame
	if not f or not f.EnableKeyboard then
		return
	end
	local want = db.space and f:IsShown() and not inCombat()
	if not inCombat() then
		setPropagate(f, true)
		pcall(f.EnableKeyboard, f, want and true or false)
	end
end

local function onKeyDown(f, key)
	if inCombat() then
		return
	end
	local over = f.IsMouseOver and f:IsMouseOver()
	if key == "SPACE" and db.space and over then
		setPropagate(f, false)
		SlotFrame.spin()
	else
		setPropagate(f, true)
	end
end

---------------------------------------------------------------------------------------------
-- Building the window

-- Geometry of the reel panel, in pixels from its top left corner (y negative downwards).
local function reelLeft(r)
	local size = Theme.size
	return size.reelPad + size.marker + (r - 1) * (size.cell + size.reelGap)
end

local function cellX(r)
	return reelLeft(r) + Theme.size.cell / 2
end

local function cellY(row0)
	local size = Theme.size
	return -(size.reelPad + row0 * size.cell + size.cell / 2)
end

-- An axis-parallel line segment texture from (x1, y1) to (x2, y2).
local function segment(parent, x1, y1, x2, y2)
	local lw = Theme.size.lineWidth
	-- Above the dims (ARTWORK) and the cell edges (OVERLAY 0).
	local tex = parent:CreateTexture(nil, "OVERLAY", nil, 1)
	local left, top = math.min(x1, x2) - lw / 2, math.max(y1, y2) + lw / 2
	tex:SetPoint("TOPLEFT", parent, "TOPLEFT", left, top)
	tex:SetSize(math.abs(x2 - x1) + lw, math.abs(y2 - y1) + lw)
	tex:Hide()
	return tex
end

-- Line li as segments: from the left marker to reel 1, then per reel gap a step through the
-- middle of the gap, to the right marker.
local function buildLine(parent, li)
	local size = Theme.size
	local rows = T2.lines[li]
	local segs = {}
	local function add(x1, y1, x2, y2)
		segs[#segs + 1] = segment(parent, x1, y1, x2, y2)
	end
	add(size.reelPad + size.marker - 2, cellY(rows[1]), cellX(1), cellY(rows[1]))
	for r = 1, REELS - 1 do
		local y1, y2 = cellY(rows[r]), cellY(rows[r + 1])
		if y1 == y2 then
			add(cellX(r), y1, cellX(r + 1), y1)
		else
			local gx = reelLeft(r) + size.cell + size.reelGap / 2
			add(cellX(r), y1, gx, y1)
			add(gx, y1, gx, y2)
			add(gx, y2, cellX(r + 1), y2)
		end
	end
	local yEnd = cellY(rows[REELS])
	add(cellX(REELS), yEnd, reelLeft(REELS) + size.cell + 2, yEnd)
	return segs
end

-- Line number markers: left at the row where a line starts, right where it ends; lines that
-- share a row are stacked in it.
local function buildMarkers(parent)
	local size, c, fonts = Theme.size, Theme.colors, Theme.fonts
	local box = size.markerBox
	for li = 1, #T2.lines do
		W.markers[li] = {}
	end
	for side = 1, 2 do
		local reelIndex = side == 1 and 1 or REELS
		local x = side == 1 and size.reelPad + (size.marker - box) / 2
			or reelLeft(REELS) + size.cell + (size.marker - box) / 2
		for row0 = 0, ROWS - 1 do
			local group = {}
			for li, rows in ipairs(T2.lines) do
				if rows[reelIndex] == row0 then group[#group + 1] = li end
			end
			local step = box + 2
			local top = -(size.reelPad + row0 * size.cell + (size.cell - #group * step) / 2)
			for k, li in ipairs(group) do
				local m = {}
				m.bg = parent:CreateTexture(nil, "ARTWORK")
				m.bg:SetSize(box, box)
				m.bg:SetPoint("TOPLEFT", parent, "TOPLEFT", x, top - (k - 1) * step)
				paint(m.bg, c.border)
				m.label = text(parent, fonts.marker, c.muted)
				m.label:SetPoint("CENTER", m.bg, "CENTER", 0, 0)
				m.label:SetText(tostring(li))
				local list = W.markers[li]
				list[#list + 1] = m
			end
		end
	end
end

local function buildReels(f, y)
	local size, c, fonts = Theme.size, Theme.colors, Theme.fonts
	local cell = size.cell
	local reelsW = 2 * size.reelPad + 2 * size.marker + REELS * cell + (REELS - 1) * size.reelGap
	local reelsH = ROWS * cell + 2 * size.reelPad
	local rp = panel(f, c.panel, c.border)
	rp:SetPoint("TOP", f, "TOP", 0, y)
	rp:SetSize(reelsW, reelsH)
	W.reelPanel = rp

	W.reels, W.tease = {}, {}
	for r = 1, REELS do
		local reel = Reel.new(rp, T2.reels[r])
		reel.frame:SetPoint("TOPLEFT", rp, "TOPLEFT", reelLeft(r), -size.reelPad)
		W.reels[r] = reel
		-- Anticipation glow behind the reel.
		local glow = rp:CreateTexture(nil, "BACKGROUND", nil, 2)
		glow:SetPoint("TOPLEFT", reel.frame, "TOPLEFT", -3, 3)
		glow:SetPoint("BOTTOMRIGHT", reel.frame, "BOTTOMRIGHT", 3, -3)
		paint(glow, c.gold)
		glow:Hide()
		W.tease[r] = glow
	end

	-- Overlay above the reels: expansions, dims, cell edges, lines, markers.
	local ov = CreateFrame("Frame", nil, rp)
	ov:SetAllPoints(rp)
	ov:SetFrameLevel(rp:GetFrameLevel() + 10)
	W.overlay = ov
	local inset = size.iconInset
	local crop = Theme.iconCrop
	W.expand = {}
	for r = 1, REELS do
		local e = { icons = {} }
		e.bg = ov:CreateTexture(nil, "BACKGROUND")
		e.bg:SetWidth(cell)
		e.bg:SetPoint("CENTER", W.reels[r].frame, "CENTER", 0, 0)
		paint(e.bg, c.expand)
		for row = 1, ROWS do
			local ic = ov:CreateTexture(nil, "BORDER")
			ic:SetSize(cell - 2 * inset, cell - 2 * inset)
			ic:SetPoint("TOPLEFT", rp, "TOPLEFT", reelLeft(r) + inset, -(size.reelPad + (row - 1) * cell + inset))
			ic:SetTexCoord(crop[1], crop[2], crop[3], crop[4])
			e.icons[row] = ic
		end
		W.expand[r] = e
		setExpand(r, 0)
	end
	W.cells = {}
	local edge = size.cellEdge
	for r = 1, REELS do
		W.cells[r] = {}
		for row = 1, ROWS do
			local x, top = reelLeft(r), -(size.reelPad + (row - 1) * cell)
			local cellT = { edges = {} }
			cellT.dim = ov:CreateTexture(nil, "ARTWORK")
			cellT.dim:SetPoint("TOPLEFT", rp, "TOPLEFT", x, top)
			cellT.dim:SetSize(cell, cell)
			paint(cellT.dim, c.dim)
			cellT.dim:Hide()
			local parts = {
				{ x, top, cell, edge }, { x, top - cell + edge, cell, edge },
				{ x, top, edge, cell }, { x + cell - edge, top, edge, cell },
			}
			for k, p in ipairs(parts) do
				local e = ov:CreateTexture(nil, "OVERLAY")
				e:SetPoint("TOPLEFT", rp, "TOPLEFT", p[1], p[2])
				e:SetSize(p[3], p[4])
				e:Hide()
				cellT.edges[k] = e
			end
			W.cells[r][row] = cellT
		end
	end
	W.lineSegs, W.markers = {}, {}
	for li = 1, #T2.lines do
		W.lineSegs[li] = buildLine(ov, li)
	end
	buildMarkers(ov)

	-- Banner over the reels.
	local bn = CreateFrame("Frame", nil, rp)
	bn:SetAllPoints(rp)
	bn:SetFrameLevel(rp:GetFrameLevel() + 30)
	W.banner = bn
	W.bannerShade = bn:CreateTexture(nil, "BACKGROUND")
	W.bannerShade:SetAllPoints(bn)
	paint(W.bannerShade, c.overlay)
	W.bannerTitle = text(bn, fonts.banner, c.gold)
	W.bannerTitle:SetPoint("TOP", bn, "TOP", 0, -cell * 0.45)
	W.bannerIcon = bn:CreateTexture(nil, "ARTWORK")
	W.bannerIcon:SetSize(size.bannerIcon, size.bannerIcon)
	W.bannerIcon:SetPoint("CENTER", bn, "CENTER", 0, -8)
	W.bannerIcon:SetTexCoord(crop[1], crop[2], crop[3], crop[4])
	W.bannerSub = text(bn, fonts.message, c.text)
	W.bannerSub:SetPoint("BOTTOM", bn, "BOTTOM", 0, cell * 0.45)
	W.bannerAmount = text(bn, fonts.banner, c.text)
	W.bannerAmount:SetPoint("CENTER", bn, "CENTER", 0, -6)
	hideBanner()

	-- Gamble coin, over the reels.
	local co = CreateFrame("Frame", nil, rp)
	co:SetAllPoints(rp)
	co:SetFrameLevel(rp:GetFrameLevel() + 40)
	local shade = co:CreateTexture(nil, "BACKGROUND")
	shade:SetAllPoints(co)
	paint(shade, c.overlay)
	W.coinSize = cell * 1.3
	W.coin = co:CreateTexture(nil, "ARTWORK")
	W.coin:SetSize(W.coinSize, W.coinSize)
	W.coin:SetPoint("CENTER", co, "CENTER", 0, 14)
	W.coin:SetTexCoord(crop[1], crop[2], crop[3], crop[4])
	W.coinResult = text(co, fonts.win, c.accent)
	W.coinResult:SetPoint("TOP", W.coin, "BOTTOM", 0, -10)
	co:Hide()
	W.coinOverlay = co

	-- Particles for big wins (pooled, above everything in the panel).
	local pf = CreateFrame("Frame", nil, rp)
	pf:SetAllPoints(rp)
	pf:SetFrameLevel(rp:GetFrameLevel() + 35)
	W.particles = {}
	for i = 1, size.particles do
		local p = pf:CreateTexture(nil, "OVERLAY")
		p:SetSize(size.particle, size.particle)
		p:SetTexture(Theme.particle)
		p:SetTexCoord(crop[1], crop[2], crop[3], crop[4])
		p:Hide()
		W.particles[i] = p
	end
	return reelsH
end

-- Paytable overlay: built once for T2, numbers follow the stake (updatePaytable).
local function buildPaytable(f, y, height)
	local size, c, fonts = Theme.size, Theme.colors, Theme.fonts
	local inner = size.width - 2 * size.pad
	local pt = panel(f, c.bg, c.border)
	pt:SetPoint("TOPLEFT", f, "TOPLEFT", size.pad, y)
	pt:SetSize(inner, height)
	pt:SetFrameLevel(f:GetFrameLevel() + 60)
	W.paytable = pt
	local crop = Theme.iconCrop
	local rowH = size.paytableRow
	local py = -10

	local function line(str, color, h)
		local fs = text(pt, fonts.small, color or c.muted)
		fs:SetPoint("TOPLEFT", pt, "TOPLEFT", 12, py)
		fs:SetWidth(inner - 24)
		fs:SetJustifyH("LEFT")
		fs:SetText(str or "")
		py = py - (h or 18)
		return fs
	end

	W.ptUnsupported = text(pt, fonts.message, c.muted)
	W.ptUnsupported:SetPoint("CENTER", pt, "CENTER", 0, 0)
	W.ptUnsupported:SetText(L.UNSUPPORTED_TABLE)

	local content = CreateFrame("Frame", nil, pt)
	content:SetAllPoints(pt)
	W.ptContent = content
	local heading = text(content, fonts.label, c.muted)
	heading:SetPoint("TOPLEFT", content, "TOPLEFT", 12, py)
	heading:SetText(string.upper(L.PAYS))
	py = py - 20

	-- Symbols in two columns of five; B last.
	W.ptRows = {}
	local colW = (inner - 24) / 2
	for i, sym in ipairs(T2.order) do
		local col = i <= 5 and 0 or 1
		local rowY = py - ((i - 1) % 5) * rowH
		local x = 12 + col * colW
		local icon = content:CreateTexture(nil, "ARTWORK")
		icon:SetSize(rowH - 4, rowH - 4)
		icon:SetPoint("TOPLEFT", content, "TOPLEFT", x, rowY - 2)
		icon:SetTexture(Theme.symbols[sym])
		icon:SetTexCoord(crop[1], crop[2], crop[3], crop[4])
		local name = text(content, fonts.small, c.text)
		name:SetPoint("TOPLEFT", content, "TOPLEFT", x + rowH + 2, rowY - 5)
		name:SetText(symbolName(sym))
		local cells = {}
		for k = 2, 5 do
			local fs = text(content, fonts.small, c.text)
			fs:SetPoint("TOPRIGHT", content, "TOPLEFT", x + 100 + (k - 1) * 38, rowY - 5)
			cells[k] = fs
		end
		W.ptRows[sym] = cells
	end
	py = py - 5 * rowH - 8

	W.ptBook = text(content, fonts.small, c.gold)
	W.ptBook:SetPoint("TOPLEFT", content, "TOPLEFT", 12, py)
	W.ptBook:SetWidth(inner - 24)
	W.ptBook:SetJustifyH("LEFT")
	if W.ptBook.SetWordWrap then W.ptBook:SetWordWrap(true) end
	py = py - 46

	local linesHead = text(content, fonts.label, c.muted)
	linesHead:SetPoint("TOPLEFT", content, "TOPLEFT", 12, py)
	linesHead:SetText(string.upper(L.LINES))
	py = py - 18
	local dot = size.lineDot
	local diagW = REELS * (dot + 1)
	local stepX = (inner - 24) / #T2.lines
	for li, rows in ipairs(T2.lines) do
		local x = 12 + (li - 1) * stepX + (stepX - diagW) / 2
		local num = text(content, fonts.marker, c.lines[li])
		num:SetPoint("TOP", content, "TOPLEFT", x + diagW / 2, py)
		num:SetText(tostring(li))
		for r = 1, REELS do
			for row0 = 0, ROWS - 1 do
				local d = content:CreateTexture(nil, "ARTWORK")
				d:SetSize(dot, dot)
				d:SetPoint("TOPLEFT", content, "TOPLEFT", x + (r - 1) * (dot + 1), py - 14 - row0 * (dot + 1))
				paint(d, rows[r] == row0 and c.lines[li] or c.border)
			end
		end
	end
	py = py - 14 - ROWS * (dot + 1) - 10

	content.rtp = text(content, fonts.small, c.muted)
	content.rtp:SetPoint("TOPLEFT", content, "TOPLEFT", 12, py)
	content.gamble = text(content, fonts.small, c.muted)
	content.gamble:SetPoint("TOPLEFT", content, "TOPLEFT", 12, py - 18)
	W.ptRtp, W.ptGamble = content.rtp, content.gamble
	pt:Hide()
end

function SlotFrame.updatePaytable()
	if not W.paytable then
		return
	end
	local info = S.game:info()
	if info.kind ~= "lines" then
		W.ptContent:Hide()
		W.ptUnsupported:Show()
		return
	end
	W.ptUnsupported:Hide()
	W.ptContent:Show()
	for _, sym in ipairs(T2.order) do
		local cells, pays = W.ptRows[sym], info.pays[sym]
		for k = 2, 5 do
			local p = pays and pays[k]
			cells[k]:SetText(p and fmt(p * info.lineBet) or "-")
		end
	end
	local sp, stake = info.scatter.pays, S.game.stake
	W.ptBook:SetText(string.format(L.BOOK_RULE, fmt(sp[3] * stake), fmt(sp[4] * stake), fmt(sp[5] * stake)))
	W.ptRtp:SetText(string.format(L.RTP, info.rtp * 100))
	W.ptGamble:SetText(string.format(L.GAMBLE_RULE, info.maxGamble))
end

-- Stake pills for the stakes of the current game; one set per stake list, reused.
local function buildPills()
	local stakes = S.game.stakes
	local key = table.concat(stakes, ",")
	local pills = W.pillSets[key]
	if not pills then
		local size, fonts = Theme.size, Theme.fonts
		pills = {}
		for i, v in ipairs(stakes) do
			local p = button(W.frame, size.pill, size.controls - 10, "pill", fonts.button, function() SlotFrame.setStake(v) end)
			p.stake = v
			p.label:SetText(fmt(v))
			p:SetPoint("LEFT", W.stakeLabel, "RIGHT", 10 + (i - 1) * (size.pill + 6), 0)
			pills[i] = p
		end
		W.pillSets[key] = pills
	end
	if W.pills and W.pills ~= pills then
		for _, p in ipairs(W.pills) do p:Hide() end
	end
	for _, p in ipairs(pills) do p:Show() end
	W.pills = pills
end

local function build()
	local size, c, fonts = Theme.size, Theme.colors, Theme.fonts
	local pad, gap, width = size.pad, size.gap, size.width
	local inner = width - 2 * pad

	local f = CreateFrame("Frame", FRAME_NAME, UIParent)
	W.frame = f
	f:SetFrameStrata("HIGH")
	if f.SetToplevel then f:SetToplevel(true) end
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self) self:StartMoving() end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePosition()
	end)

	-- Window: gold flash (big wins) behind a 1 px border and the background.
	W.flash = f:CreateTexture(nil, "BACKGROUND")
	W.flash:SetPoint("TOPLEFT", f, "TOPLEFT", -4, 4)
	W.flash:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 4, -4)
	paint(W.flash, c.gold)
	W.flash:Hide()
	local border = f:CreateTexture(nil, "BACKGROUND", nil, 1)
	border:SetAllPoints(f)
	paint(border, c.border)
	local bg = f:CreateTexture(nil, "BACKGROUND", nil, 2)
	bg:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
	bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
	paint(bg, c.bg)

	local y = -pad

	-- Header
	local title = text(f, fonts.title, c.text)
	title:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y - 5)
	title:SetText(L.TITLE)
	W.mode = button(f, 64, 20, "pill", fonts.small, function() SlotFrame.toggleMode() end)
	W.mode:SetPoint("LEFT", title, "RIGHT", 8, 0)
	W.close = button(f, size.header, size.header, "ghost", fonts.title, function() f:Hide() end)
	W.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pad + 8, y)
	W.close.label:SetText("X")
	W.sound = button(f, 90, size.header, "ghost", fonts.small, function()
		db.sound = not db.sound
		refresh()
	end)
	W.sound:SetPoint("RIGHT", W.close, "LEFT", -4, 0)
	W.officer = button(f, 64, size.header, "ghost", fonts.small, function()
		if ns.OfficerFrame then ns.OfficerFrame.toggle() end
	end)
	W.officer:SetPoint("RIGHT", W.sound, "LEFT", -4, 0)
	W.officer.label:SetText(L.OFFICER)
	y = y - size.header - gap

	-- Top bar: balance (and refill), free-game counter with the expanding symbol, win.
	local topY = y
	local top = panel(f, c.panel, c.border)
	top:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y)
	top:SetSize(inner, size.topBar)
	W.balanceLabel = text(top, fonts.label, c.muted)
	W.balanceLabel:SetPoint("TOPLEFT", top, "TOPLEFT", 12, -6)
	W.balanceLabel:SetText(string.upper(L.BALANCE))
	W.balance = text(top, fonts.number, c.text)
	W.balance:SetPoint("BOTTOMLEFT", top, "BOTTOMLEFT", 12, 4)
	W.refill = button(top, 70, 24, "panel", fonts.small, SlotFrame.refill)
	W.refill:SetPoint("LEFT", top, "LEFT", 150, 0)
	W.refill.label:SetText(L.REFILL)
	local winLabel = text(top, fonts.label, c.muted)
	winLabel:SetPoint("TOPRIGHT", top, "TOPRIGHT", -12, -6)
	winLabel:SetText(string.upper(L.WIN))
	W.winAmount = text(top, fonts.number, c.accent)
	W.winAmount:SetPoint("BOTTOMRIGHT", top, "BOTTOMRIGHT", -12, 4)
	W.winAmount:SetText("")
	local fb = CreateFrame("Frame", nil, top)
	fb:SetPoint("LEFT", top, "LEFT", 236, 0)
	fb:SetSize(180, size.topBar)
	W.freeBar = fb
	W.badge = fb:CreateTexture(nil, "ARTWORK")
	W.badge:SetSize(size.badge, size.badge)
	W.badge:SetPoint("LEFT", fb, "LEFT", 0, 0)
	local crop = Theme.iconCrop
	W.badge:SetTexCoord(crop[1], crop[2], crop[3], crop[4])
	W.freeCounter = text(fb, fonts.message, c.gold)
	W.freeCounter:SetPoint("TOPLEFT", W.badge, "TOPRIGHT", 8, 0)
	W.freeTotal = text(fb, fonts.small, c.text)
	W.freeTotal:SetPoint("BOTTOMLEFT", W.badge, "BOTTOMRIGHT", 8, 0)
	fb:Hide()
	y = y - size.topBar - gap

	-- Reels
	local reelsH = buildReels(f, y)
	y = y - reelsH - gap / 2

	-- Message line (line wins, short messages)
	W.win = text(f, fonts.message, c.accent)
	W.win:SetPoint("TOP", f, "TOP", 0, y - 4)
	W.win:SetWidth(inner)
	W.win:SetText("")
	y = y - size.message - gap / 2

	-- Gamble offer: TAKE / GAMBLE (space reserved so nothing jumps)
	local half = (inner - gap) / 2
	W.offerRow = CreateFrame("Frame", nil, f)
	W.offerRow:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y)
	W.offerRow:SetSize(inner, size.gambleRow)
	W.take = button(W.offerRow, half, size.gambleRow, "panel", fonts.button, SlotFrame.take)
	W.take:SetPoint("LEFT", W.offerRow, "LEFT", 0, 0)
	W.gamble = button(W.offerRow, half, size.gambleRow, "outline", fonts.button, SlotFrame.gamble)
	W.gamble:SetPoint("RIGHT", W.offerRow, "RIGHT", 0, 0)
	W.offerRow:Hide()
	y = y - size.gambleRow - gap

	-- Controls: stake pills left, SPIN right
	W.stakeLabel = text(f, fonts.label, c.muted)
	W.stakeLabel:SetPoint("LEFT", f, "TOPLEFT", pad, y - size.controls / 2)
	W.stakeLabel:SetText(string.upper(L.STAKE))
	W.pillSets = {}
	buildPills()
	W.spin = button(f, size.spinWidth, size.controls, "accent", fonts.spin, SlotFrame.spin)
	W.spin:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pad, y)
	y = y - size.controls - gap / 2

	-- Paytable toggle; the paytable covers the top bar and the reels.
	W.payToggle = button(f, 120, size.smallRow, "ghost", fonts.small, function()
		db.paytable = not db.paytable
		SlotFrame.layout()
	end)
	W.payToggle:SetPoint("TOPLEFT", f, "TOPLEFT", pad - 8, y)
	y = y - size.smallRow
	buildPaytable(f, topY, size.topBar + gap + reelsH)

	-- Footer
	W.footer = text(f, fonts.small, c.muted)
	W.footer:SetPoint("BOTTOM", f, "BOTTOM", 0, pad / 2 + 2)
	W.footer:SetWidth(inner)
	W.footer:SetText(L.FOOTER)

	f:SetScript("OnUpdate", onUpdate)
	f:SetScript("OnKeyDown", onKeyDown)
	f:SetScript("OnShow", function()
		updateKeyboard()
		playSound("click")
	end)
	f:SetScript("OnHide", function()
		-- Finish everything at once so a closed window never hides a pending result.
		settle()
		updateKeyboard()
	end)

	if type(UISpecialFrames) == "table" then
		table.insert(UISpecialFrames, FRAME_NAME)
	end

	f:Hide() -- new frames start shown; toggle() decides
	f:SetSize(width, -y + size.footer + pad / 2)
	applyPosition()
	setBalanceShown(S.game.balance)
	SlotFrame.layout()
	refresh()
end

function SlotFrame.layout()
	if db.paytable then
		SlotFrame.updatePaytable()
		W.paytable:Show()
		W.payToggle.label:SetText(L.PAYTABLE .. " -")
	else
		W.paytable:Hide()
		W.payToggle.label:SetText(L.PAYTABLE .. " +")
	end
end

---------------------------------------------------------------------------------------------
-- Modes: solo (play money) and guild (tokens of the guild session)

local function currentSession()
	return ns.Main and ns.Main.session() or nil
end

-- Shows the current game: stake pills, paytable, labels, balance, idle line.
local function applyGame()
	buildPills()
	SlotFrame.updatePaytable()
	SlotFrame.layout()
	W.balanceLabel:SetText(string.upper(S.mode == "guild" and L.TOKENS or L.BALANCE))
	S.counts = {}
	setBalanceShown(S.game.balance)
	setTotalShown(nil)
	clearShow()
	S.offer = S.game:state() == "gamble"
	idleText()
	refresh()
end

-- Switches the window to a mode; guild mode only with a session. Settles first, and closes an
-- open gamble offer (the win is already in the balance, so nothing is lost).
local function useMode(mode)
	local session = currentSession()
	if mode == "guild" and not session then
		mode = "solo"
	end
	local game = mode == "guild" and session:game() or S.solo
	if game == S.game and mode == S.mode then
		return false
	end
	if W.frame then
		settle()
		if S.game:state() == "gamble" then
			S.game:take()
		end
		S.offer, S.messageUntil = false, nil
		clearShow()
	end
	S.game, S.mode = game, mode
	if W.frame then
		applyGame()
	end
	return true
end

-- The mode the player asked for, as far as a session allows it.
local function wantedMode()
	return db.mode == "guild" and currentSession() and "guild" or "solo"
end

function SlotFrame.setMode(mode)
	initDB()
	if mode == "guild" and not currentSession() then
		if W.frame then
			useMode("solo")
			message(L.NO_GUILD, Theme.colors.lose)
		else
			chat(L.NO_GUILD)
		end
		return false
	end
	db.mode = mode
	if W.frame then
		useMode(mode)
		playSound("click")
	end
	return true
end

function SlotFrame.toggleMode()
	return SlotFrame.setMode(S.mode == "guild" and "solo" or "guild")
end

-- Session events from Main.
local function onMainEvent(name, data)
	if not W.frame then
		return
	end
	local busy = S.phase == "round" or S.phase == "flip"
	if name == "session" then
		local was = S.mode
		useMode(wantedMode())
		if was == "guild" and S.mode ~= "guild" then
			message(L.NO_GUILD, Theme.colors.lose)
		end
	elseif name == "purchase" and S.mode == "guild" and type(data) == "table" and data.role == "player" then
		if data.status == "done" then
			S.credit = data
		elseif (data.status == "failed" or data.status == "timeout") and not busy then
			message(string.format(L.BUY_FAILED, tostring(data.code or data.status)), Theme.colors.lose)
		end
	elseif name == "account" and S.mode == "guild" then
		local credit = S.credit
		S.credit = nil
		if busy then
			return -- the running round ends on the new balance
		end
		applyGame()
		if credit then
			message(string.format(L.CREDIT, fmt(credit.tokens or 0), tostring(credit.officer)), Theme.colors.accent)
		end
	elseif name == "roster" then
		if not busy and S.phase == "idle" and not S.offer and not S.messageUntil then
			idleText()
		end
		refresh()
	end
end

-- Scripted draws for the next solo spin ("/gs demo"): a way to look at rare rounds without
-- waiting for them. Solo is play money, so this changes nothing that matters.
local demoDraws = {}
local DEMOS = {
	-- three books, expanding symbol M, first free game retriggers and expands (docs/table-t2-spec.md)
	free = { 40, 35, 52, 0, 0, 5, 33, 55, 50, 5, 29 },
}

local function soloRng(n)
	local v = table.remove(demoDraws, 1)
	if v then
		return v % n
	end
	return ns.random(n)
end

local function ensure()
	initDB()
	if not S.solo then
		S.solo = ns.Solo.new({ rng = soloRng, balance = db.soloBalance })
		S.game, S.mode = S.solo, "solo"
	end
	if not S.subscribed and ns.Main then
		S.subscribed = true
		ns.Main.subscribe(onMainEvent)
	end
	if not W.frame then
		useMode(wantedMode())
		build()
		applyGame()
	end
end

function SlotFrame.toggle()
	ensure()
	if W.frame:IsShown() then
		W.frame:Hide()
	else
		W.frame:Show()
	end
end

---------------------------------------------------------------------------------------------
-- Slash commands and events

local function slash(msg)
	msg = string.lower(tostring(msg or "")):gsub("^%s+", ""):gsub("%s+$", "")
	if msg == "" then
		SlotFrame.toggle()
	elseif msg == "sound" then
		initDB()
		db.sound = not db.sound
		chat(db.sound and L.SOUND_ON or L.SOUND_OFF)
		if W.frame then refresh() end
	elseif msg == "space" then
		initDB()
		db.space = not db.space
		chat(db.space and L.SPACE_ON or L.SPACE_OFF)
		updateKeyboard()
	elseif msg == "guild" or msg == "solo" then
		ensure()
		SlotFrame.setMode(msg)
		if not W.frame:IsShown() then
			W.frame:Show()
		end
	elseif msg == "officer" then
		if ns.OfficerFrame then
			ns.OfficerFrame.toggle()
		end
	elseif msg == "demo" then
		ensure()
		SlotFrame.setMode("solo")
		demoDraws = {}
		for i, v in ipairs(DEMOS.free) do demoDraws[i] = v end
		chat(L.DEMO_READY)
		if not W.frame:IsShown() then
			W.frame:Show()
		end
	elseif msg == "reset" then
		initDB()
		db.pos = nil
		if W.frame then applyPosition() end
		chat(L.RESET_DONE)
	else
		chat(L.HELP)
	end
end

SLASH_GUILDSLOTS1 = "/gslots"
SLASH_GUILDSLOTS2 = "/gs"
SlashCmdList = SlashCmdList or {}
SlashCmdList.GUILDSLOTS = slash

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_REGEN_DISABLED")
events:RegisterEvent("PLAYER_REGEN_ENABLED")
events:RegisterEvent("PLAYER_LOGOUT")
events:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 == addonName then
		initDB()
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- Fires just before combat lockdown starts: release the keyboard while still allowed.
		local f = W.frame
		if f and f.EnableKeyboard then
			if f.SetPropagateKeyboardInput then pcall(f.SetPropagateKeyboardInput, f, true) end
			pcall(f.EnableKeyboard, f, false)
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if W.frame then updateKeyboard() end
	elseif event == "PLAYER_LOGOUT" then
		saveGame()
	end
end)
