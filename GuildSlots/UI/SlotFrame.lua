local addonName, ns = ...

-- The slot machine window (solo mode, play money). Game rules live in ns.Solo; this file
-- builds the window and animates the plain result tables Solo returns.

local L, Theme, Anim, Reel = ns.L, ns.Theme, ns.Anim, ns.Reel

local SlotFrame = {}
ns.SlotFrame = SlotFrame

local FRAME_NAME = "GuildSlotsFrame"
local REELS = 3

-- Injectable for tests: rng(n) -> 0..n-1.
ns.random = ns.random or function(n)
	return math.random(n) - 1
end

local db -- GuildSlotsDB, set on ADDON_LOADED (or on first use)
local W = {} -- widgets
local S = { now = 0, phase = "idle", counts = {}, offer = false } -- animation state
SlotFrame.widgets, SlotFrame.state = W, S

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

local function playSound(key)
	if not db or db.sound == false then
		return
	end
	local s = Theme.sounds[key]
	local id = s
	if type(s) == "string" then
		id = type(SOUNDKIT) == "table" and SOUNDKIT[s] or nil
	end
	if id and type(PlaySound) == "function" then
		pcall(PlaySound, id, "SFX")
	end
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
	if db and S.game then
		db.soloBalance = S.game.balance
	end
end

---------------------------------------------------------------------------------------------
-- Display

local function setBalanceShown(v)
	S.balanceShown = v
	W.balance:SetText(fmt(v))
end

local function countTo(key, from, to, dur)
	S.counts[key] = { from = from, to = to, t0 = S.now, dur = dur }
end

local function setWinText(str, color)
	W.win:SetText(str or "")
	W.win:SetTextColor(rgb(color or Theme.colors.accent))
end

local function winLine(amount, multiplier)
	local s = L.WIN .. " " .. fmt(amount)
	if multiplier then
		s = s .. "  |cffb1bad3x" .. multiplier .. "|r"
	end
	return s
end

local function message(str, color)
	setWinText(str, color or Theme.colors.muted)
	S.messageUntil = S.now + Theme.timing.message
end

local function setReelModes(modes)
	for i = 1, REELS do
		W.reels[i]:setMode(modes and modes[i] or nil)
	end
end

local function refresh()
	local game, phase = S.game, S.phase
	local busy = phase == "spinning" or phase == "flip"
	W.spin.label:SetText(phase == "spinning" and L.STOP or L.SPIN)
	W.spin:setEnabled(phase ~= "flip")
	for _, pill in ipairs(W.pills) do
		pill:setSelected(pill.stake == game.stake)
		pill:setEnabled(not busy)
	end
	W.refill:setEnabled(not busy)
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
-- Game flow

-- Jumps a running win presentation to its end.
local function finishPresentation()
	if S.phase ~= "present" then
		return
	end
	S.counts = {}
	setBalanceShown(S.game.balance)
	if S.result and S.result.win > 0 then
		setWinText(winLine(S.result.win, S.result.multiplier))
	end
	S.celebrateUntil = nil
	S.phase = "idle"
	S.offer = S.game:state() == "gamble"
end

local function present()
	local r, t = S.result, Theme.timing
	S.counts = {}
	if r.win > 0 then
		local big = r.multiplier >= t.bigWin
		local dur = big and t.bigCountUp or t.countUp
		local modes = {}
		for i = 1, REELS do
			modes[i] = r.winReels[i] and "win" or "dim"
		end
		setReelModes(modes)
		S.pulseStart = S.now
		countTo("win", 0, r.win, dur)
		countTo("balance", S.balanceShown, r.balance, dur)
		if big then
			S.celebrateUntil = S.now + t.celebrate
			playSound("bigWin")
		else
			playSound("win")
		end
		S.big = big
		S.phase = "present"
		S.presentEnd = S.now + dur
	else
		setBalanceShown(r.balance)
		S.phase = "idle"
		S.offer = false
	end
	saveGame()
	refresh()
end

local function quickStop()
	for i = 1, REELS do
		W.reels[i]:quickStop(S.now, (i - 1) * Theme.timing.quickStagger)
	end
end

function SlotFrame.spin()
	if S.phase == "spinning" then
		quickStop()
		return
	end
	if S.phase == "flip" then
		return
	end
	finishPresentation()
	local game = S.game
	local before = game.balance
	local r, err = game:spin()
	if not r then
		if err == "no_funds" then
			message(L.NO_FUNDS, Theme.colors.lose)
		end
		refresh()
		return
	end
	S.result, S.offer, S.counts, S.messageUntil = r, false, {}, nil
	setWinText("")
	setReelModes(nil)
	setBalanceShown(before - r.stake)
	local t = Theme.timing
	for i = 1, REELS do
		local stopAt = t.stop[i]
		if i == REELS and r.anticipation then
			stopAt = stopAt + t.anticipation
		end
		W.reels[i]:spin(S.now, r.stops[i], stopAt)
	end
	S.phase = "spinning"
	playSound("reelStart")
	saveGame()
	refresh()
end

function SlotFrame.take()
	finishPresentation()
	if S.phase ~= "idle" or S.game:state() ~= "gamble" then
		return
	end
	local res = S.game:take()
	S.offer = false
	setReelModes(nil)
	message(L.TAKEN .. " " .. fmt(res.amount), Theme.colors.accent)
	playSound("click")
	refresh()
end

function SlotFrame.gamble()
	finishPresentation()
	if S.phase ~= "idle" or S.game:state() ~= "gamble" then
		return
	end
	local res = S.game:gamble()
	S.flip = { res = res, t0 = S.now, revealed = false }
	S.offer = false
	S.messageUntil = nil
	S.phase = "flip"
	setReelModes({ "dim", "dim", "dim" })
	setWinText("")
	W.coin:SetTexture(Theme.coin.back)
	W.coinResult:SetText("")
	W.coinOverlay:Show()
	playSound("click")
	refresh()
end

function SlotFrame.refill()
	if S.phase == "spinning" or S.phase == "flip" then
		return
	end
	finishPresentation()
	local res = S.game:refill()
	S.offer, S.counts = false, {}
	setReelModes(nil)
	setBalanceShown(res.balance)
	message(L.REFILLED)
	saveGame()
	playSound("click")
	refresh()
end

function SlotFrame.setStake(v)
	if S.phase == "spinning" or S.phase == "flip" then
		return
	end
	finishPresentation()
	if S.game:state() == "gamble" then
		S.game:take()
		S.offer = false
		setReelModes(nil)
	end
	S.game:setStake(v)
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
		countTo("balance", S.balanceShown, res.balance, t.countUp)
		saveGame()
	end
	if dt >= t.gambleFlip + t.gambleHold then
		W.coinOverlay:Hide()
		S.flip = nil
		S.phase = "idle"
		S.offer = res.canGamble
		if res.won and S.result then
			setReelModes((function()
				local m = {}
				for i = 1, REELS do
					m[i] = S.result.winReels[i] and "win" or "dim"
				end
				return m
			end)())
		else
			setReelModes(nil)
		end
		refresh()
	end
end

local function onUpdate(_, elapsed)
	-- Absolute-time animation; cap hitches so a long frame does not skip whole phases.
	elapsed = tonumber(elapsed) or 0
	if elapsed > 0.25 then elapsed = 0.25 end
	S.now = S.now + elapsed
	local now, t = S.now, Theme.timing

	if S.phase == "spinning" then
		local running = false
		for i = 1, REELS do
			local reel = W.reels[i]
			local ev, landedToo = reel:update(now)
			if ev == "landed" or landedToo then
				playSound("reelStop")
			end
			if reel:isSpinning() then
				running = true
			end
		end
		local r = S.result
		local tease = r and r.anticipation and not W.reels[2]:isSpinning() and W.reels[3]:isSpinning()
		if tease then
			W.tease:SetAlpha(0.3 + 0.7 * Anim.pulse(now, t.flashFreq))
			W.tease:Show()
		else
			W.tease:Hide()
		end
		if not running then
			W.tease:Hide()
			present()
		end
	end

	for key, c in pairs(S.counts) do
		local v = Anim.countUp(c.from, c.to, now - c.t0, c.dur)
		if key == "balance" then
			setBalanceShown(v)
		else
			local prefix = S.big and (L.BIG_WIN .. "  ") or ""
			setWinText(prefix .. winLine(v, S.result and S.result.multiplier))
		end
		if now - c.t0 >= c.dur then
			S.counts[key] = nil
		end
	end

	if S.phase == "present" and now >= S.presentEnd then
		S.phase = "idle"
		S.offer = S.game:state() == "gamble"
		refresh()
	end

	if S.phase == "flip" then
		updateFlip()
	end

	if S.pulseStart then
		local level = Anim.pulse(now - S.pulseStart, t.pulseFreq)
		for i = 1, REELS do
			if W.reels[i].mode == "win" then
				W.reels[i]:setLevel(level)
			end
		end
	end

	if S.celebrateUntil and now < S.celebrateUntil then
		W.flash:SetAlpha(Anim.pulse(now, t.flashFreq))
		W.flash:Show()
	else
		S.celebrateUntil = nil
		W.flash:Hide()
	end

	if S.messageUntil and now >= S.messageUntil then
		S.messageUntil = nil
		if S.phase == "idle" and not S.offer then
			setWinText("")
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

local function buildPaytable(parent, width)
	local size, c = Theme.size, Theme.colors
	local info = S.game:info()
	local rowH = size.paytableRow
	local pt = CreateFrame("Frame", nil, parent)
	local y = 0
	local function row(icon, a, b, color)
		if icon then
			local tex = pt:CreateTexture(nil, "ARTWORK")
			tex:SetSize(rowH - 4, rowH - 4)
			tex:SetPoint("TOPLEFT", pt, "TOPLEFT", 8, y - 2)
			tex:SetTexture(icon)
			local crop = Theme.iconCrop
			tex:SetTexCoord(crop[1], crop[2], crop[3], crop[4])
		end
		local fa = text(pt, Theme.fonts.small, color or c.text)
		fa:SetPoint("TOPRIGHT", pt, "TOPLEFT", width * 0.62, y - 5)
		fa:SetText(a)
		local fb = text(pt, Theme.fonts.small, color or c.text)
		fb:SetPoint("TOPRIGHT", pt, "TOPRIGHT", -12, y - 5)
		fb:SetText(b)
		y = y - rowH
	end
	row(nil, L.PAIR, L.TRIPLE, c.muted)
	for _, sym in ipairs(info.order) do
		row(Theme.symbols[sym], "x" .. info.pair[sym], "x" .. info.triple[sym])
	end
	local function line(str)
		local fs = text(pt, Theme.fonts.small, c.muted)
		fs:SetPoint("TOPLEFT", pt, "TOPLEFT", 8, y - 5)
		fs:SetPoint("RIGHT", pt, "RIGHT", -8, 0)
		fs:SetJustifyH("LEFT")
		fs:SetText(str)
		y = y - rowH
	end
	line(string.format(L.RTP, info.rtp * 100))
	line(L.PAIR_RULE)
	line(string.format(L.GAMBLE_RULE, info.maxGamble))
	pt:SetSize(width, -y + 8)
	return pt
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

	-- Window: accent flash (big wins) behind a 1 px border and the background.
	W.flash = f:CreateTexture(nil, "BACKGROUND")
	W.flash:SetPoint("TOPLEFT", f, "TOPLEFT", -3, 3)
	W.flash:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 3, -3)
	paint(W.flash, c.accent)
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
	title:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y - 6)
	title:SetText(L.TITLE)
	local mode = text(f, fonts.small, c.muted)
	mode:SetPoint("LEFT", title, "RIGHT", 8, 0)
	mode:SetText(L.SOLO)
	W.close = button(f, size.header, size.header, "ghost", fonts.title, function() f:Hide() end)
	W.close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pad + 8, y)
	W.close.label:SetText("X")
	W.sound = button(f, 90, size.header, "ghost", fonts.small, function()
		db.sound = not db.sound
		refresh()
	end)
	W.sound:SetPoint("RIGHT", W.close, "LEFT", -4, 0)
	y = y - size.header - gap

	-- Balance
	local bal = panel(f, c.panel, c.border)
	bal:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y)
	bal:SetSize(inner, size.balance)
	local balLabel = text(bal, fonts.label, c.muted)
	balLabel:SetPoint("TOPLEFT", bal, "TOPLEFT", 12, -8)
	balLabel:SetText(string.upper(L.BALANCE))
	W.balance = text(bal, fonts.number, c.text)
	W.balance:SetPoint("BOTTOMLEFT", bal, "BOTTOMLEFT", 12, 6)
	W.refill = button(bal, 84, 28, "panel", fonts.small, SlotFrame.refill)
	W.refill:SetPoint("RIGHT", bal, "RIGHT", -12, 0)
	W.refill.label:SetText(L.REFILL)
	y = y - size.balance - gap

	-- Reels
	local cell = size.cell
	local reelsW = REELS * cell + (REELS - 1) * size.reelGap + 2 * size.reelPad
	local reelsH = 3 * cell + 2 * size.reelPad
	local rp = panel(f, c.panel, c.border)
	rp:SetPoint("TOP", f, "TOP", 0, y)
	rp:SetSize(reelsW, reelsH)
	W.reelPanel = rp
	local strip = ns.Tables.get("T1").reels
	W.reels = {}
	for i = 1, REELS do
		local reel = Reel.new(rp, strip[i])
		reel.frame:SetPoint("TOPLEFT", rp, "TOPLEFT", size.reelPad + (i - 1) * (cell + size.reelGap), -size.reelPad)
		W.reels[i] = reel
	end
	-- Anticipation glow around reel 3.
	W.tease = rp:CreateTexture(nil, "BACKGROUND", nil, 2)
	W.tease:SetPoint("TOPLEFT", W.reels[REELS].frame, "TOPLEFT", -3, 3)
	W.tease:SetPoint("BOTTOMRIGHT", W.reels[REELS].frame, "BOTTOMRIGHT", 3, -3)
	paint(W.tease, c.accent)
	W.tease:Hide()

	-- Payline: thin lines above and below the middle row plus end markers, drawn over the reels.
	local over = CreateFrame("Frame", nil, rp)
	over:SetAllPoints(rp)
	over:SetFrameLevel(rp:GetFrameLevel() + 10)
	for _, dy in ipairs({ -size.reelPad - cell, -size.reelPad - 2 * cell }) do
		local line = over:CreateTexture(nil, "OVERLAY")
		line:SetPoint("TOPLEFT", rp, "TOPLEFT", 1, dy)
		line:SetPoint("TOPRIGHT", rp, "TOPRIGHT", -1, dy)
		line:SetHeight(1)
		paint(line, c.payline)
	end
	for _, side in ipairs({ "LEFT", "RIGHT" }) do
		local m = over:CreateTexture(nil, "OVERLAY")
		m:SetSize(3, cell * 0.5)
		m:SetPoint(side, rp, side, side == "LEFT" and 3 or -3, 0)
		paint(m, c.accent)
	end

	-- Gamble coin, over the reels.
	local co = CreateFrame("Frame", nil, rp)
	co:SetAllPoints(rp)
	co:SetFrameLevel(rp:GetFrameLevel() + 20)
	local shade = co:CreateTexture(nil, "BACKGROUND")
	shade:SetAllPoints(co)
	paint(shade, c.overlay)
	W.coinSize = cell * 1.3
	W.coin = co:CreateTexture(nil, "ARTWORK")
	W.coin:SetSize(W.coinSize, W.coinSize)
	W.coin:SetPoint("CENTER", co, "CENTER", 0, 14)
	local crop = Theme.iconCrop
	W.coin:SetTexCoord(crop[1], crop[2], crop[3], crop[4])
	W.coinResult = text(co, fonts.win, c.accent)
	W.coinResult:SetPoint("TOP", W.coin, "BOTTOM", 0, -10)
	co:Hide()
	W.coinOverlay = co
	y = y - reelsH - gap

	-- Win display
	W.win = text(f, fonts.win, c.accent)
	W.win:SetPoint("TOP", f, "TOP", 0, y - 6)
	W.win:SetText("")
	y = y - size.win - gap

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

	-- Stake pills
	local stakeLabel = text(f, fonts.label, c.muted)
	stakeLabel:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y - 11)
	stakeLabel:SetText(string.upper(L.STAKE))
	W.pills = {}
	local stakes = S.game.stakes
	local pillW = 64
	for i = #stakes, 1, -1 do
		local v = stakes[i]
		local p = button(f, pillW, size.stakeRow, "pill", fonts.button, function() SlotFrame.setStake(v) end)
		p.stake = v
		p.label:SetText(fmt(v))
		p:SetPoint("TOPRIGHT", f, "TOPRIGHT", -pad - (#stakes - i) * (pillW + 8), y)
		W.pills[i] = p
	end
	y = y - size.stakeRow - gap

	-- SPIN
	W.spin = button(f, inner, size.spin, "accent", fonts.spin, SlotFrame.spin)
	W.spin:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y)
	y = y - size.spin - gap

	-- Paytable toggle and panel
	W.payToggle = button(f, 120, size.smallRow, "ghost", fonts.small, function()
		db.paytable = not db.paytable
		SlotFrame.layout()
	end)
	W.payToggle:SetPoint("TOPLEFT", f, "TOPLEFT", pad - 8, y)
	y = y - size.smallRow
	W.paytable = buildPaytable(f, inner)
	W.paytable:SetPoint("TOPLEFT", f, "TOPLEFT", pad, y)
	W.baseHeight = -y

	-- Footer
	W.footer = text(f, fonts.small, c.muted)
	W.footer:SetPoint("BOTTOM", f, "BOTTOM", 0, pad / 2 + 4)
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
		if S.phase == "spinning" then
			for i = 1, REELS do
				W.reels[i]:setStop(S.result.stops[i])
			end
			present()
		end
		if S.phase == "flip" then
			S.flip.t0 = S.now - 100
			updateFlip()
		end
		finishPresentation()
		S.counts = {}
		setBalanceShown(S.game.balance)
		updateKeyboard()
	end)

	if type(UISpecialFrames) == "table" then
		table.insert(UISpecialFrames, FRAME_NAME)
	end

	f:Hide() -- new frames start shown; toggle() decides
	f:SetWidth(width)
	applyPosition()
	setBalanceShown(S.game.balance)
	SlotFrame.layout()
	refresh()
end

function SlotFrame.layout()
	local size = Theme.size
	local h = W.baseHeight + size.footer + size.pad / 2
	if db.paytable then
		W.paytable:Show()
		h = h + W.paytable:GetHeight()
		W.payToggle.label:SetText(L.PAYTABLE .. " -")
	else
		W.paytable:Hide()
		W.payToggle.label:SetText(L.PAYTABLE .. " +")
	end
	W.frame:SetHeight(h)
end

local function ensure()
	initDB()
	if not S.game then
		S.game = ns.Solo.new({ rng = ns.random, balance = db.soloBalance })
	end
	if not W.frame then
		build()
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
