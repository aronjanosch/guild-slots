local addonName, ns = ...

-- The slot machine window. Game rules live in ns.Solo (play money) and in the guild session's
-- game (ns.Guild, tokens); both have the same shape. This file builds the window and plays the
-- rounds they return: ns.Plan turns a round into timed steps, the step handlers below show them.
-- S.solo is the solo game, S.game the one shown. Only lines tables (T2) are rendered.
--
-- Look: the "tavern" design (design/gildenslots-v2). Layout, colours, fonts and timings come from
-- UI/Theme.lua, widgets from UI/Skin.lua, effects from UI/Fx.lua, line geometry from
-- UI/Layout.lua, the paytable from UI/Paytable.lua, the cash-out overlay (guild mode) from
-- UI/Cashout.lua.
--
-- Phases: "idle" (an open take/gamble offer is S.offer), "round" (a plan plays), "pick" (the
-- gamble card waits for red or black), "flip" (the card turns over).
--
-- Engagement pack (v0.7): autoplay (an on/off toggle; UI/Auto.lua decides, a timer here drives it), turbo (a
-- second timing set, Theme.timingTurbo, for the plan and the reels), anticipation sounds, the
-- tiered big win with tick ladder and window shake, the session panel (UI/Session.lua), the
-- guild ticker on the footer line (UI/Ticker.lua) and the bonus buy (solo only).

local L, Theme, Anim, Reel, Plan = ns.L, ns.Theme, ns.Anim, ns.Reel, ns.Plan
local Skin, Fx, Layout, Paytable, Cashout = ns.Skin, ns.Fx, ns.Layout, ns.Paytable, ns.Cashout
local Stats, Auto, Ticker = ns.Stats, ns.Auto, ns.Ticker

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
local S = { now = 0, phase = "idle", counts = {}, offer = false, mode = "solo", cards = {}, lit = {}, litN = 0,
	landAt = {}, baseStops = {}, stats = Stats.new(), auto = false } -- animation state
SlotFrame.widgets, SlotFrame.state = W, S

-- The table the window draws (strips, lines): always T2.
local T2 = ns.Tables.get("T2")

---------------------------------------------------------------------------------------------
-- Helpers

local function fmt(n)
	return Anim.formatNumber(n, L.THOUSANDS)
end

local function chat(text)
	local frame = DEFAULT_CHAT_FRAME
	if frame and frame.AddMessage then
		frame:AddMessage(Theme.esc(Theme.colors.gold) .. L.TITLE .. "|r: " .. tostring(text))
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

-- All effects, or only lines, pulses and count-ups ("/gs fx").
local function fxOn()
	return not db or db.fx ~= false
end

-- The timing set of the running round (fixed when it starts), else the one turbo selects.
local function tm()
	return S.tm or Theme.timingFor(db and db.turbo)
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

-- The tension riser runs while teased reels turn after two tomes.
local riserSound
local function stopRiser()
	if riserSound and type(StopSound) == "function" then
		pcall(StopSound, riserSound, 80)
	end
	riserSound = nil
end

-- Shared with UI/OfficerFrame.lua.
SlotFrame.ui = { fmt = fmt, chat = chat, playSound = playSound }

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
	if db.fx == nil then db.fx = true end
	if db.turbo == nil then db.turbo = false end
	if db.ticker == nil then db.ticker = true end
end

---------------------------------------------------------------------------------------------
-- Window shake (big-win tier steps): the window's own anchor is moved by a few pixels and put
-- back exactly. The window is not a protected frame, but it never shakes in combat anyway.

local shake = { active = false }

local function stopShake()
	if not shake.active then
		return
	end
	shake.active = false
	local f = W.frame
	f:ClearAllPoints()
	f:SetPoint(shake.point, shake.rel, shake.relPoint, shake.x, shake.y)
end

local function startShake()
	local f = W.frame
	if not f or not fxOn() or inCombat() then
		return
	end
	if shake.active then
		shake.t0 = S.now -- a new step while it still shakes: shake on from the same rest point
		return
	end
	local point, rel, relPoint, x, y = f:GetPoint(1)
	if type(point) ~= "string" or (type(f.GetNumPoints) == "function" and f:GetNumPoints() ~= 1) then
		return
	end
	shake.point, shake.rel, shake.relPoint, shake.x, shake.y = point, rel or UIParent, relPoint or point, x or 0, y or 0
	shake.t0, shake.active = S.now, true
end

local function updateShake(now)
	if not shake.active then
		return
	end
	local t = tm()
	local dt = now - shake.t0
	if dt >= t.shake or inCombat() then
		stopShake()
		return
	end
	local dx, dy = Anim.shake(dt, t.shake, Theme.layout.shakeAmp, t.shakeFreq)
	local f = W.frame
	f:ClearAllPoints()
	f:SetPoint(shake.point, shake.rel, shake.relPoint, shake.x + dx, shake.y + dy)
end

local function savePosition()
	local f = W.frame
	if not f or not db then
		return
	end
	stopShake()
	local point, _, relPoint, x, y = f:GetPoint(1)
	if point then
		db.pos = { point, relPoint, x, y }
	end
end

local function applyPosition()
	local f = W.frame
	stopShake()
	f:ClearAllPoints()
	local p = db and db.pos
	if type(p) == "table" and type(p[1]) == "string" then
		f:SetPoint(p[1], UIParent, p[2], tonumber(p[3]) or 0, tonumber(p[4]) or 0)
	else
		f:SetPoint("CENTER", UIParent, "CENTER", Theme.layout.home[1], Theme.layout.home[2])
	end
end

local function saveGame()
	if db and S.solo then
		db.soloBalance = S.solo.balance
	end
end

---------------------------------------------------------------------------------------------
-- Displays

-- The balance to show at rest. The game books a win at once, but while the take / gamble
-- offer is open the amount at risk is held back on screen, so "take" visibly collects it.
local function restBalance()
	local game = S.game
	if game:state() == "gamble" then
		return game.balance - (game.pending or 0)
	end
	return game.balance
end

local function setBalanceShown(v)
	S.balanceShown = v
	W.balance:SetText(fmt(v))
	W.footBalanceValue:SetText(fmt(v))
end

local function setTotalShown(v)
	S.totalShown = v
	local c = Theme.colors
	if v and v > 0 then
		W.winAmount:SetText(fmt(v))
		Skin.color(W.winAmount, c.goldLight)
	else
		W.winAmount:SetText("–")
		Skin.color(W.winAmount, c.empty)
	end
end

local function setFreeWinShown(v)
	S.freeWinShown = v
	W.freeTotal:SetText(fmt(v))
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
	Skin.color(W.win, color or Theme.tones.win)
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
		s = s .. "  " .. Theme.esc(Theme.colors.muted) .. "×" .. multiplierText(amount, stake) .. "|r"
	end
	return s
end

local function message(str, color)
	setWinText(str, color or Theme.tones.muted)
	S.messageUntil = S.now + Theme.timing.message
end

local function supported()
	local tbl = S.game and S.game.tbl
	return tbl ~= nil and tbl.kind == "lines"
end

-- What the window shows while idle in guild mode when the game cannot be played: message line,
-- and title / text of the status panel over the reels.
local STATUS_LINES = { no_account = "ST_NO_ACCOUNT", level = "ST_LEVEL", broken = "ST_BROKEN", payout = "ST_PAYOUT" }

local function statusLine()
	if S.mode ~= "guild" then
		return nil
	end
	local st = S.game:status()
	local key = STATUS_LINES[st]
	if key then
		if st == "no_account" then
			return L[key], L.NO_TOKENS_TITLE, L.ASK_OFFICER
		elseif st == "payout" then
			return L[key], L.PO_LOCK_TITLE, L.PO_LOCK_SUB
		end
		return L[key], L.CANNOT_PLAY, L[key]
	end
	if not supported() then
		return L.UNSUPPORTED_TABLE, L.CANNOT_PLAY, L.UNSUPPORTED_TABLE
	end
	return nil
end

local function idleText()
	local line = statusLine()
	if line then
		setWinText(line, Theme.tones.lose)
	else
		setWinText(string.format(L.IDLE_HINT, #T2.lines), Theme.tones.muted)
	end
end

-- The short line for a code from spin() or gamble().
local CODE_LINES = {
	no_account = "ST_NO_ACCOUNT", level = "ST_LEVEL", broken = "ST_BROKEN", wait = "WAIT",
	send = "SEND_FAILED", payout = "ST_PAYOUT",
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

local function isOfficer()
	return ns.Main and ns.Main.isOfficer() or false
end

-- Buttons, displays and overlays for the current phase.
local function refresh()
	local game, phase = S.game, S.phase
	local Lay = Theme.layout
	local busy = phase ~= "idle"
	local status = phase == "idle" and statusLine() or nil

	local label = L.SPIN
	local auto = S.auto
	if phase == "round" then
		local step = currentStep()
		if step and step.kind == "spin" and step.game == 0 and not S.quick then
			label = L.STOP
		elseif step and step.kind == "intro" then
			label = L.START
		else
			label = L.SKIP
		end
	end
	W.spin.label:SetText(label)
	W.spin:setEnabled(phase == "round" or (phase == "idle" and not status))
	W.auto:setEnabled(auto or (not status and supported()))
	W.auto:setSelected(auto)
	W.turbo:setSelected(db.turbo and true or false)

	-- Stakes, or the take / gamble buttons that replace them.
	local offer = phase == "idle" and S.offer and game:state() == "gamble"
	local card = phase == "pick" or phase == "flip"
	local offerRow = offer or card
	if offerRow then
		W.take.label:SetText(string.format(L.TAKE, fmt(game.pending or 0)))
		Skin.rect(W.take, W.frame, card and Lay.takeWide or Lay.take)
		W.take:setEnabled(phase ~= "flip")
		W.gamble:SetShown(offer)
		W.offerRow:Show()
	else
		W.offerRow:Hide()
	end
	W.stakeRow:SetShown(not offerRow)
	for _, pill in ipairs(W.pills) do
		pill:setSelected(pill.stake == game.stake)
		pill:setEnabled(not busy and not status and not auto)
	end
	W.stakeValue:SetText(fmt(game.stake))
	W.stakeSub:SetText(string.format(L.STAKE_SUB, #T2.lines, fmt(game.stake / #T2.lines)))

	-- Header.
	W.soloBtn:setSelected(S.mode == "solo")
	W.guildBtn:setSelected(S.mode == "guild")
	W.soloBtn:setEnabled(not busy)
	W.guildBtn:setEnabled(not busy)
	W.sound:setIcon(db.sound and Theme.icons.soundOn or Theme.icons.soundOff)
	W.sessionBtn:setSelected(W.sessionPanel:IsShown())

	-- Secondary row: paytable, officer, refill (solo) or cash out (guild), bonus buy (solo), or
	-- the balance (free games). The shown buttons take the slots from the left.
	local officer = isOfficer()
	local solo = S.mode == "solo" and not S.free
	local guild = S.mode == "guild" and not S.free
	local buy = solo and type(game.buy) == "function" and supported() and T2.buyPrice ~= nil
	W.officer:SetShown(officer)
	W.refill:SetShown(solo)
	W.refill:setEnabled(not busy and not auto)
	W.cashout:SetShown(guild)
	W.cashout:setEnabled(guild and phase == "idle" and not auto and Cashout.canOpen(game))
	W.cashout:setSelected(Cashout.isShown())
	W.buy:SetShown(buy)
	W.footBalance:SetShown(S.free and true or false)
	local row = W.rowList
	row[1], row[2], row[3], row[4] = W.payToggle, nil, nil, nil
	if officer then row[#row + 1] = W.officer end
	if solo then row[#row + 1] = W.refill end
	if guild then row[#row + 1] = W.cashout end
	if buy then row[#row + 1] = W.buy end
	local slots = #row > 3 and Lay.row4 or Lay.row3
	for i, b in ipairs(row) do
		Skin.rect(b, W.frame, slots[i])
	end
	if buy then
		local price = T2.buyPrice * game.stake
		local w = slots[#row][3]
		W.buy.label:SetText(string.format(w < Lay.buyWide and L.BUY_SHORT or L.BUY, fmt(price)))
		W.buy:setEnabled(phase == "idle" and not auto and not status)
	end

	-- Guild status over the reels (state 10).
	if status then
		local _, title, sub = statusLine()
		W.statusTitle:SetText(title)
		W.statusSub:SetText(sub)
		W.statusOverlay:Show()
	else
		W.statusOverlay:Hide()
	end
end

---------------------------------------------------------------------------------------------
-- Reel overlays: dimmed and highlighted cells, drawn lines, line markers, expansions.
-- All textures exist from build() on; these only show, hide and colour them.

local function setLine(li, c, a)
	for _, seg in ipairs(W.lineSegs[li]) do
		if W.realLines then
			seg:SetVertexColor(c[1], c[2], c[3], 1)
		else
			seg:SetColorTexture(c[1], c[2], c[3], 1)
		end
		seg:SetAlpha(a)
		seg:Show()
	end
end

local function setLineAlpha(li, a)
	for _, seg in ipairs(W.lineSegs[li]) do
		seg:SetAlpha(a)
	end
end

local function setMarker(li, lit)
	local list = W.markers[li]
	list.lit = lit
	local c = Theme.colors
	for _, m in ipairs(list) do
		m.normal:SetShown(not lit)
		m.glow:SetShown(lit)
		if lit then
			Skin.color(m.glow, c.lines[li])
		end
		Skin.color(m.label, lit and c.dark or c.muted)
		Skin.shadow(m.label, lit and 0 or 1, lit and 0 or -1)
	end
end

-- Hides every highlight, line, marker light and dim.
local function clearShow()
	for r = 1, REELS do
		for row = 1, ROWS do
			local cell = W.cells[r][row]
			cell.dim:Hide()
			cell.win:Hide()
			cell.glow:Hide()
			cell.isLit = false
		end
	end
	for li = 1, #W.lineSegs do
		for _, seg in ipairs(W.lineSegs[li]) do seg:Hide() end
	end
	for li = 1, #W.markers do
		if W.markers[li].lit then setMarker(li, false) end
	end
	S.litN = 0
	W.sparkles:stop()
end

local function dimAll()
	for r = 1, REELS do
		for row = 1, ROWS do
			W.cells[r][row].dim:Show()
		end
	end
end

-- A winning cell: the _win art over the reel, its glow in colour c, not dimmed.
local function markCell(r, row, c)
	local cell = W.cells[r][row]
	cell.dim:Hide()
	local sym = S.window and S.window[r] and S.window[r][row]
	if sym and Theme.symbolsWin[sym] then
		cell.win:SetTexture(Theme.symbolsWin[sym])
		cell.win:Show()
	end
	cell.glow:SetVertexColor(c[1], c[2], c[3], 1)
	cell.glow:SetAlpha(Theme.alpha.cellGlow)
	cell.glow:Show()
	if not cell.isLit then
		cell.isLit = true
		S.litN = S.litN + 1
		S.lit[S.litN] = cell
	end
end

local function sparkleCell(r, row, k)
	if not fxOn() then
		return
	end
	local Lay = Theme.layout
	local f = Lay.reels
	local x = f[1] + r * Lay.cell - Lay.sparkle / 2
	local y = f[2] + (row - 1) * Lay.cell + Lay.sparkle / 2
	W.sparkles:play(x, y, S.now, (k - 1) * Theme.timing.sparkleStagger)
end

-- Line li drawn across the reels, its markers lit, its first `count` cells highlighted.
local function showLine(li, count, alpha, sparkle)
	local c = Theme.colors.lines[li]
	setLine(li, c, alpha or 1)
	setMarker(li, true)
	local rows = T2.lines[li]
	for r = 1, count do
		markCell(r, rows[r] + 1, c)
		if sparkle then
			sparkleCell(r, rows[r] + 1, r)
		end
	end
end

-- Highlights the books in window (a list of 5 columns).
local function markBooks(window)
	local wild = T2.scatter.symbol
	for r = 1, REELS do
		local col = window[r]
		for row = 1, ROWS do
			if col[row] == wild then
				markCell(r, row, Theme.colors.free)
			end
		end
	end
end

-- Pulses the glow of the marked cells.
local function pulseLit(t)
	local a = Theme.alpha.linePulse
	local v = a[1] + (a[2] - a[1]) * Anim.pulse(t, Theme.timing.pulseFreq)
	for i = 1, S.litN do
		S.lit[i].glow:SetAlpha(v)
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
		e.glow:Hide()
		for _, ic in ipairs(e.icons) do ic:Hide() end
		return
	end
	e.bg:SetHeight(math.max(0.01, u * ROWS * Theme.layout.cell))
	e.bg:Show()
	e.glow:SetAlpha(Theme.alpha.expandGlow * u)
	e.glow:Show()
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
			ic:SetTexture(Theme.symbolsWin[sym])
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

local function hideLandFlashes()
	for r = 1, REELS do
		S.landAt[r] = nil
		W.landFlash[r]:Hide()
	end
end

---------------------------------------------------------------------------------------------
-- Banners (free-game intro, retrigger, summary, big win) and their effects

-- kind: "free" (banner_freespins at the top of the reels) or "big" (banner_bigwin in the
-- middle). The banner pops in with all effects on.
local function showBanner(kind, title, animate)
	local Lay, c = Theme.layout, Theme.colors
	local free = kind == "free"
	local r = free and Lay.introBanner or Lay.bigBanner
	local tr = free and Lay.introTitle or Lay.bigTitle
	local pop = W.bannerPop
	Skin.rect(pop.holder, W.frame, r)
	pop.frame:SetSize(r[3], r[4])
	W.bannerArt:SetTexture(free and Theme.tex.bannerFree or Theme.tex.bannerBig)
	Skin.rect(W.bannerTitle, pop.frame, { tr[1] - r[1], tr[2] - r[2], tr[3], tr[4] })
	W.bannerTitle:SetText(title)
	Skin.color(W.bannerTitle, free and c.white or c.bannerGold)
	Skin.shadow(W.bannerTitle, 2, -2, free and c.freeTitleShadow or c.bigTitleShadow)
	W.bannerTitle:SetAlpha(1)
	pop:start(S.now, animate and fxOn())
	if fxOn() and animate then
		W.shine.w = r[3]
		W.shine.tex:SetHeight(r[4])
		W.shine:start(S.now)
	end
end

-- Everything the banners and celebrations show, hidden at once.
local function hideBanner()
	W.bannerPop:stop()
	W.shine:stop()
	W.rays:stop()
	W.rain:stop()
	W.stageShade:Hide()
	W.reelShade:Hide()
	W.introGlow:Hide()
	W.book:Hide()
	W.bookFrom = nil
	W.bannerIcon:Hide()
	W.introPanel:Hide()
	W.bannerSub:SetText("")
	W.bannerAmount:SetText("")
end

local function setBookFrame(i)
	local Lay = Theme.layout
	local l, r, t, b = Anim.gridCoord(i, Theme.sheets.book.cols, Theme.sheets.book.rows)
	-- only the part of the frame inside bookClip (the frames have empty space at the top)
	local h = b - t
	local top = (Lay.bookClip[2] - Lay.book[2]) / Lay.book[4]
	local bottom = top + Lay.bookClip[4] / Lay.book[4]
	W.book:SetTexCoord(l, r, t + h * top, t + h * bottom)
end

---------------------------------------------------------------------------------------------
-- Free-game mode: free strips, the purple look, counter and symbol

local function setFreeLook(free)
	local sl, tex = Theme.slices, Theme.tex
	W.bgTiles:SetTexture(free and tex.bgFree or tex.bg)
	W.windowFrame:SetTexture(free and sl.windowFree.file or sl.window.file)
	W.reelBg:SetTexture(free and tex.reelBgFree or tex.reelBg)
	W.reelFrame:SetTexture(free and sl.reelsFree.file or sl.reels.file)
	W.baseBar:SetShown(not free)
	W.freeBar:SetShown(free)
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
	W.badge:SetTexture(Theme.symbols[symbol])
	W.expName:SetText(symbolName(symbol))
	setExpandSymbol(symbol)
	setCounter(0, of)
	setFreeWinShown(0)
	setFreeLook(true)
end

local function leaveFree()
	if not S.free then
		return
	end
	S.free = false
	hideExpansions()
	for r = 1, REELS do
		W.reels[r]:setStrip(T2.reels[r], S.baseStops[r] or 0)
	end
	setFreeLook(false)
end

---------------------------------------------------------------------------------------------
-- Step handlers. enter(step, silent) starts a step (silent: skipped, no sounds), update(step, t)
-- animates it and returns true when it is over, finish(step) leaves its end state.

local H = {}

local function timed(step, t)
	return t >= step.dur
end

local function countStep(step, silent)
	local d = math.min(step.dur, tm().lineCount)
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
			setWinText(string.format(L.FREE_HINT, step.game, step.freeOf, fmt(S.result.stake)), Theme.tones.free)
		end
		if silent then
			return
		end
		if step.game == 0 then
			sfx("reelStart")
		end
		local t0, timing = S.now + step.delay, tm()
		for r = 1, REELS do
			W.reels[r]:spin(t0, step.stops[r], step.stopAt[r], timing, step.decel and step.decel[r])
		end
		S.teaseState = step.tease and 0 or nil -- 0 waiting, 1 teasing, 2 the last reel landed
		startSpinSound()
	end,
	update = function(step)
		local now, running = S.now, false
		local last = 0
		for r = 1, REELS do
			local reel = W.reels[r]
			local ev, landedToo = reel:update(now)
			if ev == "landed" or landedToo then
				playSound("reelStop")
				if hasBook(step.window[r]) then
					playSound("bookLand")
				end
				if fxOn() then
					S.landAt[r] = now
				end
			end
			if reel:isSpinning() then
				running = true
				if not reel.landedFired then last = r end
			end
		end
		local tease = step.tease
		if tease then
			local on = not W.reels[tease - 1]:isSpinning()
			if on and S.teaseState == 0 then
				-- The teased reels run on alone: the tension rises (two tomes only).
				S.teaseState = 1
				if step.teaseKind == "books" then
					stopRiser()
					riserSound = playSound("teaseRiser")
				end
			end
			if S.teaseState == 1 and last == 0 then
				-- The last reel landed: hit or miss.
				S.teaseState = 2
				stopRiser()
				if step.teaseHit then
					playSound("teaseHit")
				elseif step.teaseKind == "books" then
					playSound("teaseMiss")
				end
			end
			local ta = Theme.alpha.tease
			local a = ta[1] + (ta[2] - ta[1]) * Anim.pulse(now, Theme.timing.flashFreq)
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
		stopRiser()
		S.teaseState = nil
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
			showLine(l.line, l.count, 1, step.amount and not silent)
		end
		if step.scatter.win > 0 then
			markBooks(S.window)
		end
		if step.amount then
			-- All wins at once (turbo): the step counts them up together.
			setWinText(winLine(step.amount, S.result.stake), Theme.tones.win)
			countStep(step, silent)
			sfx("lineWin", silent)
		end
	end,
	update = function(step, t)
		local pa = Theme.alpha.linePulse
		local a = pa[1] + (pa[2] - pa[1]) * Anim.pulse(t, Theme.timing.flashFreq)
		for _, l in ipairs(step.lines) do
			setLineAlpha(l.line, a)
		end
		pulseLit(t)
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
		showLine(l.line, l.count, 1, not silent)
		setWinText(string.format(L.LINE_WIN, l.line, l.count, symbolName(l.symbol), fmt(l.win)), Theme.tones.win)
		countStep(step, silent)
		sfx("lineWin", silent)
	end,
	update = function(step, t)
		pulseLit(t)
		return t >= step.dur
	end,
	finish = function()
		clearShow()
	end,
}

H.scatter = {
	enter = function(step, silent)
		clearShow()
		dimAll()
		markBooks(S.window)
		setWinText(string.format(L.SCATTER_WIN, step.count, symbolName(T2.scatter.symbol), fmt(step.amount)),
			Theme.tones.free)
		countStep(step, silent)
		sfx("lineWin", silent)
	end,
	update = function(step, t)
		pulseLit(t)
		return t >= step.dur
	end,
	finish = function()
		clearShow()
	end,
}

H.retrigger = {
	enter = function(step, silent)
		showBanner("free", string.format(L.FREE_MORE, step.added), not silent)
		setCounter(step.game, step.freeOf)
		sfx("freeStart", silent)
	end,
	update = timed,
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
		local per = tm().expandReel
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
		-- the expanded reels pay on every line: all markers lit, all lines faint, the rest dim
		for r = 1, REELS do
			if not W.expand[r].bg:IsShown() then
				for row = 1, ROWS do W.cells[r][row].dim:Show() end
			end
		end
		for li = 1, #W.markers do
			setLine(li, Theme.colors.lines[li], Theme.alpha.restingLines)
			setMarker(li, true)
		end
		setWinText(string.format(L.EXPAND_WIN, symbolName(step.symbol), step.count, fmt(step.amount)), Theme.tones.win)
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

-- Free-game intro (state 05): books pulse; then the window darkens, the banner pops, the tome
-- opens and the expanding symbol shuffles on it; its name shows in the panel below.
H.intro = {
	enter = function(step, silent)
		clearShow()
		dimAll()
		if step.bought then
			-- A bought series: no tomes on the reels, straight to the banner and the tome.
			setWinText(string.format(L.FREE_BOUGHT, step.freeOf), Theme.tones.free)
		else
			markBooks(S.window)
			local books = 0
			for r = 1, REELS do
				for row = 1, ROWS do
					if S.window[r][row] == T2.scatter.symbol then books = books + 1 end
				end
			end
			setWinText(string.format(L.FREE_TRIGGER, books, step.freeOf), Theme.tones.free)
		end
		S.introStage = 0
		S.introSilent = silent
		sfx("freeStart", silent)
	end,
	update = function(step, t)
		local tm = tm()
		if t < tm.introPulse and not step.bought then
			pulseLit(t)
			return false
		end
		if S.introStage == 0 then
			S.introStage = 1
			W.stageShade:Show()
			if fxOn() then W.introGlow:Show() end
			showBanner("free", string.format(L.FREE_GAMES, step.freeOf), not S.introSilent)
			W.book:Show()
			if fxOn() and not S.introSilent then
				W.bookFrom = S.now
				setBookFrame(1)
			else
				setBookFrame(Theme.sheets.book.frames)
			end
		end
		if t >= tm.introShuffleAt then
			local u = t - tm.introShuffleAt
			local final = expandingIndex(step.symbol)
			local i = Anim.shuffle(u, tm.introShuffle, #T2.expanding, final)
			W.bannerIcon:SetTexture(Theme.symbolsWin[T2.expanding[i]])
			W.bannerIcon:Show()
			if u >= tm.introShuffle and S.introStage == 1 then
				S.introStage = 2
				Skin.rect(W.bannerSub, W.frame, Theme.layout.introPanel)
				W.bannerSub:SetText(string.format(L.EXPANDING,
					Theme.esc(Theme.colors.goldLight) .. symbolName(step.symbol) .. "|r"))
				W.introPanel:Show()
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
		W.reelShade:Show()
		showBanner("free", L.FREE_OVER, not silent)
		Skin.rect(W.bannerSub, W.frame, Theme.layout.summarySub)
		W.bannerSub:SetText(string.format(L.FREE_PLAYED, step.games))
		countTo("banner", 0, step.freeWin, silent and 0 or step.dur * 0.6)
		-- Back to the base game's reels under the shade.
		leaveFree()
		setWinText(winLine(step.freeWin), Theme.tones.win)
	end,
	update = timed,
	finish = function()
		hideBanner()
	end,
}

-- Big win (state 08): rays turn behind the banner, a shine sweeps over it, coins rain.
local TICK_KEYS = {}
for i = 1, 16 do TICK_KEYS[i] = "countTick" .. i end

-- The count-up starts at BIG WIN and steps up (HUGE WIN, LEGENDARY) when the amount passes each
-- threshold: a new title, the tier sound, a short window shake and more coins. A ladder of
-- ticks rises in pitch through the count (fewer effects: one quiet tick, no shake).
H.big = {
	enter = function(step, silent)
		clearShow()
		W.reelShade:Show()
		local first = silent and step.level or step.tiers[1].level
		if not silent and fxOn() then
			W.rays:start(S.now)
			W.rain:start(S.now, Theme.layout.coinsTier[first])
		end
		showBanner("big", L["BIG_WIN_" .. first], not silent)
		countTo("banner", 0, step.total, silent and 0 or step.count)
		S.bigTier, S.bigTick = silent and #step.tiers or 1, silent and #step.ticks or 0
		sfx("bigWin", silent)
		if not silent and not fxOn() then
			playSound("countTickSoft")
		end
	end,
	update = function(step, t)
		local a = Theme.alpha.bigTitle
		W.bannerTitle:SetAlpha(a[1] + (a[2] - a[1]) * Anim.pulse(t, Theme.timing.pulseFreq))
		local tiers = step.tiers
		while S.bigTier < #tiers and t >= tiers[S.bigTier + 1].at do
			S.bigTier = S.bigTier + 1
			local level = tiers[S.bigTier].level
			W.bannerTitle:SetText(L["BIG_WIN_" .. level])
			playSound("tierStep")
			if fxOn() then
				W.bannerPop:start(S.now, true)
				W.rain:setCount(Theme.layout.coinsTier[level])
				startShake()
			end
		end
		local ticks = step.ticks
		while S.bigTick < #ticks and t >= ticks[S.bigTick + 1].at do
			S.bigTick = S.bigTick + 1
			if fxOn() then
				playSound(TICK_KEYS[ticks[S.bigTick].n])
			end
		end
		return t >= step.dur
	end,
	finish = function()
		stopShake()
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
				s = s .. "  " .. Theme.esc(Theme.colors.muted) .. L.CAPPED .. "|r"
			end
			setWinText(s, Theme.tones.win)
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
	S.window = round.window
	dimAll()
	for _, l in ipairs(round.lines) do
		showLine(l.line, l.count, Theme.alpha.restingLines)
	end
	if round.scatter.win > 0 then
		markBooks(round.window)
	end
end

local updateSession -- defined with the session panel below

local function endRound()
	S.phase = "idle"
	S.plan, S.si = nil, nil
	stopSpinSound()
	stopRiser()
	stopShake()
	hideTease()
	leaveFree()
	hideBanner()
	showResting()
	countTo("balance", S.balanceShown, restBalance(), tm().countUp)
	S.tm = nil
	S.offer = S.game:state() == "gamble"
	if S.offer then
		setWinText(string.format(S.auto and L.AUTO_OFFER_HINT or L.OFFER_HINT, fmt(S.game.pending)), Theme.tones.win)
	elseif not (S.result and S.result.win > 0) then
		idleText()
	end
	if S.result and not S.result.counted then
		S.result.counted = true
		S.stats:round(S.mode, S.result)
		updateSession()
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
		S.si = i
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

-- r: a result of game:spin() or game:buy() (a bought series costs r.cost).
local function startRound(r, before)
	S.result, S.offer, S.counts, S.messageUntil = r, false, {}, nil
	setWinText("")
	setTotalShown(nil)
	clearShow()
	hideExpansions()
	setBalanceShown(before - (r.cost or r.stake))
	-- The base reels to come back to after free games: the round's, or (a bought series has no
	-- base game) where they stand now.
	local stops = r.round.stops
	for i = 1, REELS do
		S.baseStops[i] = stops and stops[i] or math.floor(W.reels[i].x + 0.5) % W.reels[i].n
	end
	S.tm = Theme.timingFor(db.turbo)
	S.plan = Plan.build(r.round, S.tm, T2)
	S.si, S.quick = 0, false
	S.phase = "round"
	S.autoNext = nil
	Cashout.conceal()
	if db.paytable then
		db.paytable = false
		SlotFrame.layout()
	end
	saveGame()
	advance()
end

local function quickStop()
	for i = 1, REELS do
		W.reels[i]:quickStop(S.now, (i - 1) * tm().quickStagger)
	end
end

---------------------------------------------------------------------------------------------
-- Autoplay: rounds started by the window's clock, never by a click, so nothing on this path
-- may read the guild info (Roster.refreshInfo runs on clicks only). Rules in UI/Auto.lua.

local AUTO_OFF_LINES = {
	toggle = "AUTO_END_TOGGLE", combat = "AUTO_END_COMBAT", mode = "AUTO_END_MODE", payout = "AUTO_END_PAYOUT",
}

-- Switches autoplay off. why: a key of AUTO_OFF_LINES, "close" (no line), or a refusal code
-- from spin().
local function stopAuto(why)
	if not S.auto then
		return
	end
	S.auto, S.autoNext = false, nil
	if W.frame then
		local key = AUTO_OFF_LINES[why]
		if why ~= "close" and S.phase == "idle" then
			message(key and L[key] or string.format(L.AUTO_END_CODE, codeLine(why)),
				why == "toggle" and Theme.tones.muted or Theme.tones.lose)
		end
		refresh()
	end
end
SlotFrame.stopAuto = stopAuto

-- Takes an open offer without a sound or a message (the bonus buy takes an open win first).
local function quietTake()
	if S.game:state() ~= "gamble" then
		return
	end
	S.game:take()
	S.offer = false
	clearShow()
	countTo("balance", S.balanceShown, S.game.balance, tm().countUp)
end

-- One autoplay round (from onUpdate when S.autoNext is due).
local function autoStep()
	S.autoNext = nil
	local game = S.game
	if S.mode == "guild" and game:status() == "payout" then
		stopAuto("payout")
		return
	end
	if Auto.after(game) == "wait" then
		return -- an offer is open: the player decides first
	end
	local before = game.balance
	local r, err = game:spin()
	if not r then
		if Auto.refused(err) == "retry" then
			S.autoNext = S.now + tm().autoRetry -- guild interval: try again, never faster
			return
		end
		stopAuto(err)
		return
	end
	startRound(r, before)
end

-- Plans the next autoplay round when the window is at rest: after the pause, unless a take /
-- gamble offer waits for the player (autoplay never gambles; it goes on after the take or the
-- gamble).
local function autoTick(now)
	if not S.auto or S.phase ~= "idle" or next(S.counts) ~= nil then
		return
	end
	if not S.autoNext then
		if Auto.after(S.game) == "continue" then
			S.autoNext = now + tm().autoPause
		end
	elseif now >= S.autoNext then
		if not pcall(autoStep) then
			stopAuto("error")
		end
	end
end

-- The Auto toggle (and /gs auto). On while idle: the first round starts at once; on during a
-- round: autoplay goes on after it.
function SlotFrame.toggleAuto()
	if S.auto then
		stopAuto("toggle")
		playSound("click")
		return false
	end
	if not supported() or statusLine() or inCombat() then
		return false
	end
	S.auto, S.autoNext = true, nil
	playSound("click")
	if S.phase == "idle" then
		if S.offer then
			setWinText(string.format(L.AUTO_OFFER_HINT, fmt(S.game.pending)), Theme.tones.win)
		elseif not pcall(autoStep) then
			stopAuto("error")
		end
	end
	refresh()
	return true
end

function SlotFrame.spin()
	if S.phase == "flip" or S.phase == "pick" then
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
		message(statusLine() or L.UNSUPPORTED_TABLE, Theme.tones.lose)
		refresh()
		return
	end
	local game = S.game
	local before = game.balance
	local r, err = game:spin()
	if not r then
		message(codeLine(err), Theme.tones.lose)
		refresh()
		return
	end
	startRound(r, before)
end

-- Bonus buy (solo only): pays tbl.buyPrice x the stake and plays a free-game series. The guild
-- game has no buy() (docs/table-t2-spec.md, "Bought free games (solo only)").
function SlotFrame.buy()
	if S.mode ~= "solo" or S.phase ~= "idle" or S.auto or type(S.game.buy) ~= "function" then
		return
	end
	if S.game:state() == "gamble" then
		quietTake()
	end
	local before = S.game.balance
	local r, err = S.game:buy()
	if not r then
		message(err == "no_funds" and L.NO_FUNDS_BUY or codeLine(err), Theme.tones.lose)
		refresh()
		return
	end
	startRound(r, before)
end

local function hideCard()
	W.cardOverlay:Hide()
end

function SlotFrame.take()
	if not (S.phase == "idle" or S.phase == "pick") or S.game:state() ~= "gamble" then
		return
	end
	local res = S.game:take()
	S.phase = "idle"
	S.offer = false
	hideCard()
	clearShow()
	countTo("balance", S.balanceShown, S.game.balance, Theme.timing.countUp)
	message(L.TAKEN .. " " .. fmt(res.amount), Theme.tones.win)
	playSound("click")
	refresh()
end

---------------------------------------------------------------------------------------------
-- Gamble as a card (state 04): GAMBLE shows a face-down card; the player picks red or black;
-- game:gamble() decides; the card turns over and shows the picked colour when the step was won,
-- the other one when it was lost. The pick itself is presentation only.

local function setCardFace(tex, color)
	local t = Theme.tex
	tex:SetTexture(color == "red" and t.cardRed or color == "black" and t.cardBlack or t.cardBack)
end

local function showLastCards()
	for i, tex in ipairs(W.lastCards) do
		local color = S.cards[i]
		if color then
			setCardFace(tex, color)
			tex:Show()
		else
			tex:Hide()
		end
	end
	W.lastCardsLabel:SetShown(#S.cards > 0)
end

-- Shows the card face down with the amount now at risk. Also used after a won step, so the
-- player can pick again without leaving the card.
local function openCard(silent)
	local p = S.game.pending
	S.phase = "pick"
	S.messageUntil = nil
	setCardFace(W.card, nil)
	W.card:SetWidth(Theme.layout.card[3])
	local c = Theme.colors
	W.gambleLine:SetText(string.format(L.GAMBLE_STAKE, Theme.esc(c.number) .. fmt(p) .. "|r",
		Theme.esc(c.goldLight) .. fmt(2 * p) .. "|r"))
	W.red:Show()
	W.black:Show()
	showLastCards()
	W.cardOverlay:Show()
	if not silent then
		setWinText(L.GAMBLE_HINT, Theme.tones.win)
		playSound("click")
	end
	refresh()
end

function SlotFrame.gamble()
	if S.phase ~= "idle" or S.game:state() ~= "gamble" then
		return
	end
	openCard()
end

-- color: "red" or "black".
function SlotFrame.pick(color)
	if S.phase ~= "pick" or S.game:state() ~= "gamble" then
		return
	end
	local res, err = S.game:gamble()
	if not res then
		S.phase = "idle"
		hideCard()
		S.offer = S.game:state() == "gamble"
		message(codeLine(err), Theme.tones.lose)
		refresh()
		return
	end
	S.counts = {}
	setBalanceShown(S.balanceShown)
	local other = color == "red" and "black" or "red"
	S.flip = { res = res, t0 = S.now, face = res.won and color or other, turned = false, revealed = false }
	S.offer = false
	S.phase = "flip"
	W.red:Hide()
	W.black:Hide()
	playSound("click")
	refresh()
end

local function updateFlip()
	local f, t = S.flip, Theme.timing
	local dt = S.now - f.t0
	local w = Theme.layout.card[3]
	local scale, front = Anim.flip(dt, t.gambleFlip)
	W.card:SetWidth(math.max(0.01, scale * w))
	if front and not f.turned then
		f.turned = true
		setCardFace(W.card, f.face)
	end
	if dt < t.gambleFlip then
		return
	end
	local res = f.res
	if not f.revealed then
		f.revealed = true
		table.insert(S.cards, 1, f.face)
		S.cards[Theme.layout.lastCardsCount + 1] = nil
		showLastCards()
		if res.won then
			setWinText(L.GAMBLE_WON .. "  " .. winLine(res.amount * 2), Theme.tones.win)
			setTotalShown(res.amount * 2) -- the win display follows the gamble
			playSound("gambleWin")
		else
			setWinText(L.GAMBLE_LOST, Theme.tones.lose)
			setTotalShown(nil)
			playSound("gambleLose")
		end
		countTo("balance", S.balanceShown, restBalance(), t.countUp)
		S.stats:gamble(S.mode, res)
		updateSession()
		saveGame()
	end
	if dt >= t.gambleFlip + t.gambleHold then
		S.flip = nil
		if res.won and res.canGamble and S.game:state() == "gamble" then
			-- Won and more steps allowed: the card stays for the next pick.
			openCard(true)
			return
		end
		hideCard()
		S.phase = "idle"
		S.offer = res.canGamble
		if not res.won then
			clearShow()
		end
		refresh()
	end
end

function SlotFrame.refill()
	if S.mode ~= "solo" or S.phase ~= "idle" or S.auto then
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

-- Opens (or re-opens) the cash-out overlay; hides it when it is shown.
function SlotFrame.cashout()
	if S.mode ~= "guild" or S.phase ~= "idle" or S.auto then
		return
	end
	if Cashout.isShown() then
		Cashout.hide()
		return
	end
	if not Cashout.canOpen(S.game) then
		return
	end
	if db.paytable then
		db.paytable = false
		SlotFrame.layout()
	end
	Cashout.show()
	playSound("click")
end

function SlotFrame.setStake(v)
	if S.phase ~= "idle" or S.auto then
		return
	end
	if S.game:state() == "gamble" then
		S.game:take()
		S.offer = false
		clearShow()
		setBalanceShown(S.game.balance)
	end
	S.game:setStake(v)
	SlotFrame.updatePaytable()
	playSound("click")
	refresh()
end

-- Stops every effect at once (window hidden, effects switched off).
local function stopFx()
	W.rain:stop()
	W.rays:stop()
	W.shine:stop()
	W.sparkles:stop()
	W.bannerPop.active = false
	W.bannerPop.frame:SetScale(1)
	W.bookFrom = nil
	if W.book:IsShown() then
		setBookFrame(Theme.sheets.book.frames)
	end
	hideLandFlashes()
	W.spinGlow:Hide()
	stopShake()
	stopRiser()
	SlotFrame.tickerIdle()
end

-- Finishes everything at once (round, card, count-ups) so no result stays hidden.
-- Used when the window closes and before the window changes to another game.
local function settle()
	stopSpinSound()
	stopRiser()
	if S.phase == "round" then
		settleRound()
	end
	if S.phase == "flip" then
		S.flip.t0 = S.now - 100
		updateFlip()
	end
	if S.phase == "pick" then
		S.phase = "idle"
		hideCard()
		S.offer = S.game:state() == "gamble"
	end
	S.counts = {}
	setBalanceShown(restBalance())
end

local function updateEffects(now)
	local t = Theme.timing
	updateShake(now)
	SlotFrame.tickerUpdate(now)
	W.bannerPop:update(now)
	W.shine:update(now)
	W.rays:update(now)
	W.rain:update(now)
	W.sparkles:update(now)
	if W.bookFrom then
		local sheet = Theme.sheets.book
		local dt = now - W.bookFrom
		setBookFrame(Anim.frameAt(dt, sheet.fps, sheet.frames, false))
		if dt >= sheet.frames / sheet.fps then
			W.bookFrom = nil
		end
	end
	for r = 1, REELS do
		local at = S.landAt[r]
		if at then
			local u = (now - at) / t.landFlash
			if u >= 1 then
				S.landAt[r] = nil
				W.landFlash[r]:Hide()
			else
				W.landFlash[r]:SetAlpha(Theme.alpha.landFlash * (1 - u))
				W.landFlash[r]:Show()
			end
		end
	end
	-- The gold button breathes while it waits for a spin.
	if fxOn() and S.phase == "idle" and W.spin.enabled then
		local a = Theme.alpha
		W.spinGlow:SetAlpha(a.breatheMin + (a.breatheMax - a.breatheMin) * Anim.pulse(now, t.breathe))
		W.spinGlow:Show()
	else
		W.spinGlow:Hide()
	end
end

local function onUpdate(_, elapsed)
	-- Absolute-time animation; cap hitches so a long frame does not skip whole phases.
	elapsed = tonumber(elapsed) or 0
	if elapsed > 0.25 then elapsed = 0.25 end
	S.now = S.now + elapsed
	local now = S.now

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

	-- Autoplay: the next round once the last one is fully shown and the pause is over.
	autoTick(now)

	updateEffects(now)
	Cashout.tick(elapsed)

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

local function geometry()
	local Lay = Theme.layout
	return { left = Lay.reels[1], top = Lay.reels[2], cell = Lay.cell, xIn = Lay.lineIn, xOut = Lay.lineOut }
end

-- One pay line: real lines with the glow texture when the client has CreateLine, else the
-- staircase of plain segments. Returns the list of parts and whether they are real lines.
local function buildLine(ov, li, yLeft, yRight)
	local Lay = Theme.layout
	local g = geometry()
	local rows = T2.lines[li]
	if type(ov.CreateLine) == "function" then
		local ok, res = pcall(function()
			local pts = Layout.linePoints(rows, yLeft[li], yRight[li], g)
			local parts = {}
			for i = 1, #pts - 1 do
				local line = ov:CreateLine(nil, "OVERLAY", nil, 1)
				line:SetTexture(Theme.tex.lineGlow)
				line:SetThickness(Lay.lineThickness)
				line:SetStartPoint("TOPLEFT", ov, pts[i][1], -pts[i][2])
				line:SetEndPoint("TOPLEFT", ov, pts[i + 1][1], -pts[i + 1][2])
				Skin.add(line)
				line:Hide()
				parts[i] = line
			end
			return parts
		end)
		if ok and res then
			return res, true
		end
	end
	local lw = Lay.lineFallback
	local parts = {}
	for i, s in ipairs(Layout.staircase(rows, g)) do
		local t = ov:CreateTexture(nil, "OVERLAY", nil, 1)
		local x, y = math.min(s[1], s[3]) - lw / 2, math.min(s[2], s[4]) - lw / 2
		t:SetPoint("TOPLEFT", ov, "TOPLEFT", x, -y)
		t:SetSize(math.abs(s[3] - s[1]) + lw, math.abs(s[4] - s[2]) + lw)
		t:Hide()
		parts[i] = t
	end
	return parts, false
end

-- Line number markers at both sides (Layout.markerY).
local function buildMarkers(ov, yLeft, yRight)
	local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
	for li = 1, #T2.lines do
		local list = { lit = false }
		for side = 1, 2 do
			local x, y = Lay.markerX[side], side == 1 and yLeft[li] or yRight[li]
			local m = {}
			m.normal = ov:CreateTexture(nil, "ARTWORK")
			m.normal:SetTexture(Theme.tex.markerNormal)
			m.normal:SetSize(Lay.marker, Lay.marker)
			m.normal:SetPoint("CENTER", ov, "TOPLEFT", x, -y)
			m.glow = ov:CreateTexture(nil, "ARTWORK", nil, 1)
			m.glow:SetTexture(Theme.tex.markerLit)
			m.glow:SetSize(Lay.markerLit, Lay.markerLit)
			m.glow:SetPoint("CENTER", ov, "TOPLEFT", x, -y)
			m.glow:Hide()
			m.label = Skin.text(ov, "number", fs.marker, c.muted, "CENTER")
			m.label:SetPoint("CENTER", ov, "TOPLEFT", x, -y)
			m.label:SetText(tostring(li))
			list[side] = m
		end
		W.markers[li] = list
	end
end

local function frameAt(parent, level, r)
	local fr = CreateFrame("Frame", nil, parent)
	if r then
		Skin.rect(fr, W.frame, r)
	else
		fr:SetAllPoints(W.frame)
	end
	fr:SetFrameLevel(W.frame:GetFrameLevel() + level)
	return fr
end

local LEVEL = { reels = 2, cells = 5, reelFrame = 7, lines = 8, status = 12, card = 12, stage = 14, banner = 16,
	stageTop = 18, session = 26, paytable = 30, cashout = 32, rain = 40 }

local function buildReels(f)
	local Lay, c = Theme.layout, Theme.colors
	local cell = Lay.cell
	local field = Lay.reels

	local rp = frameAt(f, LEVEL.reels, field)
	W.reelPanel = rp
	W.reelBg = rp:CreateTexture(nil, "BACKGROUND")
	W.reelBg:SetAllPoints(rp)
	W.reelBg:SetTexture(Theme.tex.reelBg)
	W.reels = {}
	for r = 1, REELS do
		local reel = Reel.new(rp, T2.reels[r])
		reel.frame:SetPoint("TOPLEFT", rp, "TOPLEFT", (r - 1) * cell, 0)
		W.reels[r] = reel
	end

	-- Above the reels: expansions, dims, winning art, glows, anticipation, landing flashes.
	local cl = frameAt(f, LEVEL.cells)
	W.cellLayer = cl
	W.expand, W.cells, W.tease, W.landFlash = {}, {}, {}, {}
	for r = 1, REELS do
		local x = field[1] + (r - 1) * cell
		local col = { x, field[2], cell, ROWS * cell }
		local e = { icons = {} }
		e.bg = cl:CreateTexture(nil, "BACKGROUND")
		e.bg:SetTexture(Theme.tex.expandColumn)
		e.bg:SetWidth(cell)
		e.bg:SetPoint("CENTER", W.reels[r].frame, "CENTER", 0, 0)
		local anchor = CreateFrame("Frame", nil, cl)
		Skin.rect(anchor, f, col)
		e.glow = Skin.nine(cl, anchor, Theme.slices.glowCell, "ARTWORK", 3, Lay.cellGlowOut)
		e.glow:SetVertexColor(c.gold[1], c.gold[2], c.gold[3], 1)
		e.glow:SetAdd()
		for row = 1, ROWS do
			local ic = cl:CreateTexture(nil, "BORDER")
			Skin.rect(ic, f, { x, field[2] + (row - 1) * cell, cell, cell })
			e.icons[row] = ic
		end
		W.expand[r] = e
		setExpand(r, 0)

		local tease = Skin.nine(cl, anchor, Theme.slices.glowCell, "OVERLAY", 0, Lay.cellGlowOut)
		tease:SetVertexColor(c.gold[1], c.gold[2], c.gold[3], 1)
		tease:SetAdd()
		tease:Hide()
		W.tease[r] = tease
		local flash = cl:CreateTexture(nil, "OVERLAY", nil, 1)
		flash:SetTexture(Theme.tex.white)
		Skin.rect(flash, f, col)
		Skin.color(flash, c.goldLight)
		Skin.add(flash)
		flash:Hide()
		W.landFlash[r] = flash

		W.cells[r] = {}
		for row = 1, ROWS do
			local rect = { x, field[2] + (row - 1) * cell, cell, cell }
			local ct = {}
			ct.dim = Skin.fill(cl, "ARTWORK", c.dim)
			Skin.rect(ct.dim, f, rect)
			ct.dim:Hide()
			local ca = CreateFrame("Frame", nil, cl)
			Skin.rect(ca, f, rect)
			ct.glow = Skin.nine(cl, ca, Theme.slices.glowCell, "ARTWORK", 1, Lay.cellGlowOut)
			ct.glow:SetAdd()
			ct.glow:Hide()
			ct.win = cl:CreateTexture(nil, "ARTWORK", nil, 2)
			Skin.rect(ct.win, f, rect)
			ct.win:Hide()
			W.cells[r][row] = ct
		end
	end

	-- The reel frame over the edge of the field.
	local rf = frameAt(f, LEVEL.reelFrame, Lay.reelFrame)
	W.reelFrame = Skin.nine(rf, rf, Theme.slices.reels, "BORDER")

	-- Lines and markers above the frame; sparkles on top.
	local ov = frameAt(f, LEVEL.lines)
	W.overlay = ov
	local yLeft = Layout.markerY(T2.lines, 1, field[2], cell)
	local yRight = Layout.markerY(T2.lines, 2, field[2], cell)
	W.lineSegs, W.markers = {}, {}
	for li = 1, #T2.lines do
		W.lineSegs[li], W.realLines = buildLine(ov, li, yLeft, yRight)
	end
	buildMarkers(ov, yLeft, yRight)
	W.sparkles = Fx.sparkles(ov)
end

-- Guild status over the reels (state 10).
local function buildStatus(f)
	local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
	local so = frameAt(f, LEVEL.status, Lay.reels)
	W.statusOverlay = so
	local shade = Skin.fill(so, "BACKGROUND", c.shadeStatus)
	shade:SetAllPoints(so)
	local panel = Skin.panel(so, f, Lay.statusPanel, "overlay")
	panel:SetFrameLevel(so:GetFrameLevel() + 1)
	local icon = panel:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(Theme.icons.officer)
	Skin.rect(icon, f, Lay.statusIcon)
	Skin.color(icon, c.gold)
	W.statusTitle = Skin.textIn(panel, f, Lay.statusTitle, "title", fs.statusTitle, c.text, "CENTER")
	W.statusSub = Skin.text(panel, "label", fs.statusSub, c.muted, "CENTER")
	Skin.rect(W.statusSub, f, Lay.statusSub)
	Skin.call(W.statusSub, "SetJustifyV", "TOP")
	Skin.call(W.statusSub, "SetWordWrap", true)
	so:Hide()
end

-- The gamble card over the reels (state 04).
local function buildCard(f)
	local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
	local co = frameAt(f, LEVEL.card, Lay.reels)
	W.cardOverlay = co
	local shade = Skin.fill(co, "BACKGROUND", c.shade)
	shade:SetAllPoints(co)
	local title = Skin.textIn(co, f, Lay.gambleTitle, "title", fs.gambleTitle, c.gold, "CENTER")
	title:SetText(L.GAMBLE_TITLE)
	W.gambleLine = Skin.textIn(co, f, Lay.gambleLine, "label", fs.gambleLine, c.stakeText, "CENTER")
	local cr = Lay.card
	W.card = co:CreateTexture(nil, "ARTWORK")
	W.card:SetSize(cr[3], cr[4])
	W.card:SetPoint("CENTER", f, "TOPLEFT", cr[1] + cr[3] / 2, -(cr[2] + cr[4] / 2))
	W.red = Skin.button(co, "danger", Lay.red[3], Lay.red[4], function() SlotFrame.pick("red") end,
		{ size = fs.card })
	Skin.rect(W.red, f, Lay.red)
	W.red.label:SetText(L.RED)
	W.black = Skin.button(co, "secondary", Lay.black[3], Lay.black[4], function() SlotFrame.pick("black") end,
		{ face = "number", size = fs.card, color = c.white })
	Skin.rect(W.black, f, Lay.black)
	W.black.label:SetText(L.BLACK)
	W.lastCardsLabel = Skin.textIn(co, f, Lay.lastCardsLabel, "label", fs.cardsLabel, c.muted, "RIGHT")
	W.lastCardsLabel:SetText(L.LAST_CARDS)
	W.lastCards = {}
	local lc = Lay.lastCards
	for i = 1, Lay.lastCardsCount do
		local t = co:CreateTexture(nil, "ARTWORK")
		Skin.rect(t, f, { lc[1] + (i - 1) * Lay.lastCardsStep, lc[2], lc[3], lc[4] })
		t:Hide()
		W.lastCards[i] = t
	end
	co:Hide()
end

-- Banners and celebrations (states 05, 08): shades, glow, the tome, rays, the popping banner,
-- the shuffling symbol, the big amount, coin rain over the whole window.
local function buildStage(f)
	local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
	local st = frameAt(f, LEVEL.stage)
	W.stage = st
	W.stageShade = Skin.fill(st, "BACKGROUND", c.shadeIntro)
	W.stageShade:SetAllPoints(f)
	W.stageShade:Hide()
	W.reelShade = Skin.fill(st, "BACKGROUND", c.shadeBig, 1)
	Skin.rect(W.reelShade, f, Lay.reels)
	W.reelShade:Hide()
	local raysFrame = frameAt(st, LEVEL.stage + 1, Lay.reels)
	W.rays = Fx.rays(raysFrame, Lay.reels[3], Lay.reels[4], "BORDER")
	W.rays.tex:SetAlpha(Theme.alpha.rays)
	W.introGlow = st:CreateTexture(nil, "BORDER", nil, 1)
	W.introGlow:SetTexture(Theme.tex.glowSoft)
	Skin.rect(W.introGlow, f, Lay.introGlow)
	Skin.color(W.introGlow, c.free, Theme.alpha.introGlow)
	Skin.add(W.introGlow)
	W.introGlow:Hide()
	W.book = st:CreateTexture(nil, "ARTWORK")
	W.book:SetTexture(Theme.tex.bookSheet)
	Skin.rect(W.book, f, Lay.bookClip)
	W.book:Hide()

	W.bannerPop = Fx.popper(f, f, Lay.introBanner, f:GetFrameLevel() + LEVEL.banner)
	W.banner = W.bannerPop.holder
	local bf = W.bannerPop.frame
	W.bannerArt = bf:CreateTexture(nil, "ARTWORK")
	W.bannerArt:SetAllPoints(bf)
	W.bannerTitle = Skin.text(bf, "title", fs.banner, c.white, "CENTER")
	Skin.call(W.bannerTitle, "SetJustifyV", "MIDDLE")
	W.shine = Fx.shine(bf, Lay.introBanner[3], Lay.introBanner[4])
	W.shine.tex:SetAlpha(Theme.alpha.shine)

	local top = frameAt(f, LEVEL.stageTop)
	W.stageTop = top
	W.bannerIcon = top:CreateTexture(nil, "ARTWORK")
	Skin.rect(W.bannerIcon, f, Lay.introIcon)
	W.introPanel = Skin.panel(top, f, Lay.introPanel, "overlay")
	W.bannerSub = Skin.textIn(top, f, Lay.introPanel, "label", fs.introSub, c.text, "CENTER")
	W.bannerAmount = Skin.textIn(top, f, Lay.bigAmount, "number", fs.big, c.white, "CENTER")
	Skin.shadow(W.bannerAmount, 3, -3, c.bigShadow)

	local rainFrame = frameAt(f, LEVEL.rain)
	W.rain = Fx.rain(rainFrame, Lay.width, Lay.height)
	hideBanner()
end

-- One display (balance, last win, stake; free games: counter, free win, expanding symbol).
local function buildDisplay(parent, f, r)
	local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
	local p = Skin.panel(parent, f, r, "inset")
	local d = { frame = p }
	d.label = Skin.textIn(p, p, Lay.dLabel, "label", fs.label, c.muted, "LEFT")
	d.value = Skin.textIn(p, p, Lay.dValue, "number", fs.display, c.number, "LEFT")
	return d
end

local function addSub(d)
	local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
	local sub = Skin.textIn(d.frame, d.frame, Lay.dSub, "numberMedium", fs.displaySub, c.muted, "RIGHT")
	return sub
end

local function buildDisplays(f)
	local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
	local base = CreateFrame("Frame", nil, f)
	base:SetAllPoints(f)
	W.baseBar = base
	local d1 = buildDisplay(base, f, Lay.displays[1])
	W.balanceLabel, W.balance = d1.label, d1.value
	W.balanceLabel:SetText(Skin.upper(L.BALANCE))
	local coin = d1.frame:CreateTexture(nil, "ARTWORK")
	coin:SetTexture(Theme.icons.coin)
	Skin.rect(coin, d1.frame, Lay.dIcon)
	Skin.color(coin, c.gold)
	Skin.rect(W.balance, d1.frame, { Lay.dValue[1] + Lay.dIconShift, Lay.dValue[2], Lay.dValue[3] - Lay.dIconShift,
		Lay.dValue[4] })
	local d2 = buildDisplay(base, f, Lay.displays[2])
	d2.label:SetText(Skin.upper(L.LAST_WIN))
	W.winAmount = d2.value
	local d3 = buildDisplay(base, f, Lay.displays[3])
	d3.label:SetText(Skin.upper(L.TOTAL_STAKE))
	W.stakeValue = d3.value
	W.stakeSub = addSub(d3)

	local free = CreateFrame("Frame", nil, f)
	free:SetAllPoints(f)
	W.freeBar = free
	local e1 = buildDisplay(free, f, Lay.displays[1])
	e1.label:SetText(Skin.upper(L.FREE_GAME))
	W.freeCounter = e1.value
	Skin.color(W.freeCounter, c.freeHint)
	local e2 = buildDisplay(free, f, Lay.displays[2])
	e2.label:SetText(Skin.upper(L.FREE_WIN))
	W.freeTotal = e2.value
	Skin.color(W.freeTotal, c.goldLight)
	local e3 = buildDisplay(free, f, Lay.displays[3])
	e3.label:SetText(Skin.upper(L.EXP_SYMBOL))
	W.expName = e3.value
	Skin.font(W.expName, "number", fs.expName)
	W.badge = e3.frame:CreateTexture(nil, "ARTWORK")
	Skin.rect(W.badge, e3.frame, Lay.dBadge)
	free:Hide()
end

function SlotFrame.updatePaytable()
	if not W.paytable then
		return
	end
	Paytable.update(W, S.game:info(), S.game.stake, fmt)
end

-- Stake buttons for the stakes of the current game; one set per stake list, reused.
local function buildPills()
	local stakes = S.game.stakes
	local key = table.concat(stakes, ",")
	local pills = W.pillSets[key]
	if not pills then
		local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
		local r = Lay.stakes
		local n = #stakes
		local w, step = r[3], Lay.stakeStep
		if n * step - (step - w) > Lay.stakeArea then
			step = math.floor((Lay.stakeArea + (step - w)) / n)
			w = step - (Lay.stakeStep - r[3])
		end
		pills = {}
		for i, v in ipairs(stakes) do
			local p = Skin.button(W.stakeRow, "toggle", w, r[4], function() SlotFrame.setStake(v) end,
				{ face = "number", size = fs.stake, color = c.stakeText, selectedColor = c.number })
			p.stake = v
			p.label:SetText(fmt(v))
			Skin.rect(p, W.frame, { r[1] + (i - 1) * step, r[2], w, r[4] })
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

local applyGame -- defined with the modes below

local function iconButton(parent, r, icon, onClick)
	local b = Skin.button(parent, "icon", r[3], r[4], onClick,
		{ icon = icon, iconOnly = true, iconSize = Theme.layout.iconSize })
	Skin.rect(b, W.frame, r)
	return b
end

local function secondary(parent, r, icon, text, onClick)
	local b = Skin.button(parent, "secondary", r[3], r[4], onClick, { icon = icon })
	Skin.rect(b, W.frame, r)
	b.label:SetText(text)
	return b
end

---------------------------------------------------------------------------------------------
-- Session panel (over the reels, toggled by the header button): this session's numbers for
-- the current mode (UI/Session.lua), reset on login and by its reset button.

local SESSION_ROWS = { "rounds", "staked", "won", "net", "best", "streak", "series" }

function updateSession()
	if not W.sessionRows or not W.sessionPanel:IsShown() then
		return
	end
	local s = S.stats:get(S.mode)
	local c = Theme.colors
	W.sessionTitle:SetText(Skin.upper(L.SESSION) .. " · " .. (S.mode == "guild" and L.GUILD or L.SOLO))
	local v = W.sessionRows
	v.rounds:SetText(fmt(s.rounds))
	v.staked:SetText(fmt(s.staked))
	v.won:SetText(fmt(s.won))
	v.net:SetText((s.net > 0 and "+" or "") .. fmt(s.net))
	Skin.color(v.net, s.net > 0 and c.goldLight or s.net < 0 and c.lose or c.number)
	if s.best > 0 then
		local m = s.bestMult % 1 == 0 and string.format("%d", s.bestMult) or string.format("%.1f", s.bestMult)
		v.best:SetText(fmt(s.best) .. "  " .. Theme.esc(c.muted) .. "×" .. m .. "|r")
	else
		v.best:SetText("–")
	end
	if s.streak > 0 then
		v.streak:SetText(string.format(L.STREAK_WIN, s.streak))
	elseif s.streak < 0 then
		v.streak:SetText(string.format(L.STREAK_LOSE, -s.streak))
	else
		v.streak:SetText("–")
	end
	v.series:SetText(fmt(s.series))
end

function SlotFrame.toggleSession()
	W.sessionPanel:SetShown(not W.sessionPanel:IsShown())
	updateSession()
	playSound("click")
	refresh()
end

local function buildSessionPanel(f)
	local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
	local holder = frameAt(f, LEVEL.session)
	W.sessionPanel = holder
	local panel = Skin.panel(holder, f, Lay.sessionPanel, "overlay")
	W.sessionTitle = Skin.textIn(panel, f, Lay.sessionTitle, "label", fs.section, c.gold, "LEFT")
	W.sessionReset = Skin.button(panel, "secondary", Lay.sessionReset[3], Lay.sessionReset[4], function()
		S.stats:reset(S.mode)
		updateSession()
		playSound("click")
	end, { size = fs.smallButton })
	Skin.rect(W.sessionReset, f, Lay.sessionReset)
	W.sessionReset.label:SetText(L.SESSION_RESET)
	W.sessionRows = {}
	local r = Lay.sessionRow
	for i, key in ipairs(SESSION_ROWS) do
		local y = r[2] + (i - 1) * Lay.sessionRowStep
		local name = Skin.textIn(panel, f, { r[1], y, r[3] - Lay.sessionValueW, r[4] }, "label", fs.sessionRow, c.muted,
			"LEFT")
		name:SetText(L["SESSION_" .. string.upper(key)])
		W.sessionRows[key] = Skin.textIn(panel, f, { r[1] + r[3] - Lay.sessionValueW, y, Lay.sessionValueW, r[4] },
			"number", fs.sessionRow + 2, c.number, "RIGHT")
	end
	holder:Hide()
end

---------------------------------------------------------------------------------------------
-- Guild ticker on the footer line: big wins and free games of the guild (session event
-- "ticker", Game/Guild.lua), one after another, level-coloured. Guild mode only, "/gs ticker".

function SlotFrame.tickerIdle()
	S.tickerEntry = nil
	if W.ticker then
		W.ticker:Hide()
		W.footer:Show()
	end
end

function SlotFrame.tickerUpdate(now)
	if not W.ticker then
		return
	end
	local entry, t
	if db.ticker ~= false and S.mode == "guild" then
		entry, t = S.tickerQ:update(now)
	end
	if not entry then
		if S.tickerEntry or W.ticker:IsShown() then
			SlotFrame.tickerIdle()
		end
		return
	end
	local Lay, tim = Theme.layout, Theme.timing
	if entry ~= S.tickerEntry then
		S.tickerEntry = entry
		local ok, text, level = pcall(Ticker.text, entry, L, fmt)
		W.ticker:SetText(ok and text or "")
		Skin.color(W.ticker, ok and Theme.tickerColors[level] or Theme.colors.footer)
		W.footer:Hide()
		W.ticker:Show()
		Skin.rect(W.ticker, W.frame, Lay.ticker)
		W.ticker:SetAlpha(fxOn() and 0 or 1)
		S.tickerRest = false
	end
	if fxOn() then
		-- Slides in from the right and fades in, fades out at the end.
		local fade = tim.tickerFade
		local a = math.min(1, t / fade, (tim.tickerShow - t) / fade)
		W.ticker:SetAlpha(a > 0 and a or 0)
		local u = t / tim.tickerSlide
		if u < 1 then
			Skin.rect(W.ticker, W.frame, Lay.ticker, -Lay.tickerSlide * (1 - Anim.easeOutQuad(u)), 0)
		elseif not S.tickerRest then
			Skin.rect(W.ticker, W.frame, Lay.ticker)
		end
		S.tickerRest = u >= 1
	end
end

local function onTicker(data)
	if db.ticker == false or S.mode ~= "guild" or type(data) ~= "table" then
		return
	end
	S.tickerQ:push(data)
end

-- On entering guild mode: the newest few entries of session:ticker(), when the session has it.
local function seedTicker(session)
	S.tickerQ:clear()
	if db.ticker == false or not session or type(session.ticker) ~= "function" then
		return
	end
	local ok, list = pcall(session.ticker, session)
	if ok and type(list) == "table" then
		for i = math.min(#list, Theme.tickerSeed), 1, -1 do
			if type(list[i]) == "table" then
				S.tickerQ:push(list[i])
			end
		end
	end
end

local function build()
	local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
	S.tickerQ = Ticker.new(Theme.timing.tickerShow, Theme.tickerQueue)

	local f = CreateFrame("Frame", FRAME_NAME, UIParent)
	W.frame = f
	f:SetFrameStrata("HIGH")
	if f.SetToplevel then f:SetToplevel(true) end
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self)
		stopShake()
		self:StartMoving()
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePosition()
	end)
	f:SetSize(Lay.width, Lay.height)

	-- Wood, the window frame, the header.
	W.bgTiles = Skin.tiles(f, Theme.tex.bg, Lay.width, Lay.height, "BACKGROUND")
	W.windowFrame = Skin.nine(f, f, Theme.slices.window, "BORDER")
	local title = Skin.textIn(f, f, Lay.title, "title", fs.title, c.gold, "LEFT")
	Skin.shadow(title, 2, -2, c.titleShadow)
	title:SetText(L.TITLE)
	W.title = title
	local toggleOpts = { size = fs.button }
	W.soloBtn = Skin.button(f, "toggle", Lay.solo[3], Lay.solo[4], function() SlotFrame.setMode("solo") end, toggleOpts)
	Skin.rect(W.soloBtn, f, Lay.solo)
	W.soloBtn.label:SetText(L.SOLO)
	W.guildBtn = Skin.button(f, "toggle", Lay.guild[3], Lay.guild[4], function() SlotFrame.setMode("guild") end,
		toggleOpts)
	Skin.rect(W.guildBtn, f, Lay.guild)
	W.guildBtn.label:SetText(L.GUILD)
	W.sound = iconButton(f, Lay.sound, Theme.icons.soundOn, function()
		db.sound = not db.sound
		refresh()
	end)
	W.close = iconButton(f, Lay.close, Theme.icons.close, function() f:Hide() end)
	W.sessionBtn = iconButton(f, Lay.session, Theme.icons.coin, function() SlotFrame.toggleSession() end)
	local divAnchor = CreateFrame("Frame", nil, f)
	Skin.rect(divAnchor, f, Lay.divider)
	Skin.nine(f, divAnchor, Theme.slices.divider, "ARTWORK")

	buildDisplays(f)
	buildReels(f)

	-- Message line
	W.win = Skin.textIn(f, f, Lay.message, "label", fs.message, c.muted, "CENTER")
	W.win:SetText("")

	-- Stakes, or take / gamble in their place.
	W.stakeRow = CreateFrame("Frame", nil, f)
	W.stakeRow:SetAllPoints(f)
	W.stakeLabel = Skin.textIn(W.stakeRow, f, Lay.stakeLabel, "label", fs.label, c.muted, "LEFT")
	W.stakeLabel:SetText(Skin.upper(string.format(L.STAKE_LINES, #T2.lines)))
	W.pillSets = {}
	buildPills()
	W.offerRow = CreateFrame("Frame", nil, f)
	W.offerRow:SetAllPoints(f)
	W.take = Skin.button(W.offerRow, "secondary", Lay.take[3], Lay.take[4], SlotFrame.take,
		{ face = "number", size = fs.offer, color = c.bannerGold })
	Skin.rect(W.take, f, Lay.take)
	W.gamble = Skin.button(W.offerRow, "danger", Lay.gamble[3], Lay.gamble[4], SlotFrame.gamble, { size = fs.offer })
	Skin.rect(W.gamble, f, Lay.gamble)
	W.gamble.label:SetText(L.GAMBLE)
	W.offerRow:Hide()

	-- The gold button and its breathing glow.
	W.spinGlow = f:CreateTexture(nil, "ARTWORK")
	W.spinGlow:SetTexture(Theme.tex.glowSoft)
	local g = Lay.spinGlowOut
	Skin.rect(W.spinGlow, f, { Lay.spin[1] - g, Lay.spin[2] - g, Lay.spin[3] + 2 * g, Lay.spin[4] + 2 * g })
	Skin.color(W.spinGlow, c.gold)
	Skin.add(W.spinGlow)
	W.spinGlow:Hide()
	W.spin = Skin.button(f, "primary", Lay.spin[3], Lay.spin[4], SlotFrame.spin)
	Skin.rect(W.spin, f, Lay.spin)
	-- Autoplay and turbo between the stakes and the spin button.
	W.auto = Skin.button(f, "toggle", Lay.auto[3], Lay.auto[4], function() SlotFrame.toggleAuto() end,
		{ size = fs.smallButton })
	Skin.rect(W.auto, f, Lay.auto)
	W.auto.label:SetText(L.AUTO)
	W.turbo = Skin.button(f, "toggle", Lay.turbo[3], Lay.turbo[4], function()
		db.turbo = not db.turbo
		playSound("click")
		refresh()
	end, { size = fs.smallButton })
	Skin.rect(W.turbo, f, Lay.turbo)
	W.turbo.label:SetText(L.TURBO)

	-- Secondary row.
	W.payToggle = secondary(f, Lay.paytable, Theme.icons.paytable, L.PAYTABLE, function()
		db.paytable = not db.paytable
		if db.paytable and Cashout.isShown() then
			Cashout.conceal()
			refresh()
		end
		SlotFrame.layout()
	end)
	W.officer = secondary(f, Lay.officer, Theme.icons.officer, L.OFFICER, function()
		if ns.OfficerFrame then ns.OfficerFrame.toggle() end
	end)
	W.refill = secondary(f, Lay.refill, Theme.icons.coin, L.REFILL, SlotFrame.refill)
	W.cashout = secondary(f, Lay.refill, Theme.icons.coin, L.CASHOUT, SlotFrame.cashout)
	W.cashout:Hide()
	W.buy = Skin.button(f, "secondary", Lay.refill[3], Lay.refill[4], SlotFrame.buy, { size = fs.smallButton })
	W.buy:Hide()
	W.rowList = {}
	local fb = CreateFrame("Frame", nil, f)
	Skin.rect(fb, f, Lay.footBalance)
	W.footBalance = fb
	W.footBalanceValue = Skin.text(fb, "number", fs.stake - 4, c.number, "RIGHT")
	W.footBalanceValue:SetPoint("RIGHT", fb, "RIGHT", 0, 0)
	local fbl = Skin.text(fb, "label", fs.small, c.muted, "RIGHT")
	fbl:SetPoint("RIGHT", W.footBalanceValue, "LEFT", -6, 0)
	fbl:SetText(Skin.upper(L.BALANCE))
	W.footBalanceLabel = fbl
	fb:Hide()

	-- Footer
	W.footer = Skin.textIn(f, f, Lay.footer, "label", fs.footer, c.footer, "CENTER")
	W.footer:SetText(L.FOOTER)
	W.ticker = Skin.textIn(f, f, Lay.ticker, "label", fs.ticker, c.footer, "CENTER")
	W.ticker:Hide()

	buildStatus(f)
	buildCard(f)
	buildStage(f)
	local ptf = frameAt(f, LEVEL.paytable)
	Paytable.build(ptf, W, T2, symbolName, function()
		db.paytable = false
		SlotFrame.layout()
	end)
	Cashout.build(frameAt(f, LEVEL.cashout), f, W, {
		session = function() return S.mode == "guild" and ns.Main and ns.Main.session() or nil end,
		fmt = fmt,
		refresh = refresh,
		afterRequest = function(line)
			stopAuto("payout")
			applyGame()
			message(line, Theme.tones.win)
			refresh()
		end,
		allowSelf = function() return db.selfTest == true end,
		guildMode = function() return S.mode == "guild" end,
	})
	buildSessionPanel(f)

	f:SetScript("OnUpdate", onUpdate)
	f:SetScript("OnKeyDown", onKeyDown)
	f:SetScript("OnShow", function()
		updateKeyboard()
		playSound("click")
	end)
	f:SetScript("OnHide", function()
		-- Finish everything at once so a closed window never hides a pending result, and stop
		-- every effect. A round in progress is finished and booked; then autoplay is off.
		settle()
		stopAuto("close")
		stopFx()
		updateKeyboard()
	end)

	if type(UISpecialFrames) == "table" then
		table.insert(UISpecialFrames, FRAME_NAME)
	end

	f:Hide() -- new frames start shown; toggle() decides
	applyPosition()
	setBalanceShown(restBalance())
	setTotalShown(nil)
	SlotFrame.layout()
	refresh()
end

function SlotFrame.layout()
	if db.paytable then
		SlotFrame.updatePaytable()
		W.paytable:Show()
	else
		W.paytable:Hide()
	end
	W.payToggle:setSelected(db.paytable and true or false)
end

---------------------------------------------------------------------------------------------
-- Modes: solo (play money) and guild (tokens of the guild session)

local function currentSession()
	return ns.Main and ns.Main.session() or nil
end

-- Shows the current game: stake buttons, paytable, labels, balance, idle line.
function applyGame()
	buildPills()
	SlotFrame.updatePaytable()
	SlotFrame.layout()
	W.balanceLabel:SetText(Skin.upper(S.mode == "guild" and L.TOKENS or L.BALANCE))
	W.footBalanceLabel:SetText(Skin.upper(S.mode == "guild" and L.TOKENS or L.BALANCE))
	S.counts = {}
	setBalanceShown(restBalance())
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
		stopAuto("mode")
		settle()
		if S.game:state() == "gamble" then
			S.game:take()
		end
		S.offer, S.messageUntil = false, nil
		clearShow()
		Cashout.conceal()
	end
	S.game, S.mode = game, mode
	if W.frame then
		updateSession()
		if mode == "guild" then
			seedTicker(session)
		else
			S.tickerQ:clear()
		end
		applyGame()
		SlotFrame.showLock()
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
			message(L.NO_GUILD, Theme.tones.lose)
			refresh()
		else
			chat(L.NO_GUILD)
		end
		return false
	end
	db.mode = mode
	if W.frame then
		useMode(mode)
		playSound("click")
		refresh()
	end
	return true
end

-- After a reload or a switch to guild mode with an open payout request: show its state.
function SlotFrame.showLock()
	if W.frame and S.mode == "guild" and Cashout.isOpen() then
		Cashout.show()
	end
end

function SlotFrame.toggleMode()
	return SlotFrame.setMode(S.mode == "guild" and "solo" or "guild")
end

-- Session events from Main.
local function onMainEvent(name, data)
	if not W.frame then
		return
	end
	local busy = S.phase ~= "idle"
	if name == "session" then
		local was = S.mode
		useMode(wantedMode())
		if was == "guild" and S.mode ~= "guild" then
			message(L.NO_GUILD, Theme.tones.lose)
		end
		refresh()
	elseif name == "purchase" and S.mode == "guild" and type(data) == "table" and data.role == "player" then
		if data.status == "done" then
			S.credit = data
		elseif (data.status == "failed" or data.status == "timeout") and not busy then
			message(string.format(L.BUY_FAILED, tostring(data.code or data.status)), Theme.tones.lose)
		end
	elseif name == "ticker" then
		onTicker(data)
	elseif name == "payout" then
		if S.auto and S.mode == "guild" and S.game:status() == "payout" then
			stopAuto("payout") -- an open payout request ends autoplay
		end
		if Cashout.onPayout(data) and S.mode == "guild" then
			S.paid = { from = S.balanceShown, amount = data.amount, officer = data.officer }
			playSound("payoutDone")
		end
		refresh()
	elseif name == "account" and S.mode == "guild" then
		local credit, paid = S.credit, S.paid
		S.credit, S.paid = nil, nil
		if busy then
			return -- the running round ends on the new balance
		end
		applyGame()
		if credit then
			message(string.format(L.CREDIT, fmt(credit.tokens or 0), tostring(credit.officer)), Theme.tones.win)
		elseif paid then
			-- The balance counts down by the amount paid out.
			countTo("balance", paid.from or S.balanceShown, restBalance(), Theme.timing.countUp)
			message(string.format(L.PO_PAID, fmt(tonumber(paid.amount) or 0), tostring(paid.officer)), Theme.tones.win)
		end
	elseif name == "roster" then
		if not busy and not S.offer and not S.messageUntil then
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
		SlotFrame.showLock()
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
	if ns.Roster then ns.Roster.refreshInfo() end -- a slash command is a hardware event
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
	elseif msg == "fx" then
		initDB()
		db.fx = not db.fx
		chat(db.fx and L.FX_ON or L.FX_OFF)
		if W.frame and not db.fx then stopFx() end
	elseif msg == "turbo" then
		initDB()
		db.turbo = not db.turbo
		chat(db.turbo and L.TURBO_ON or L.TURBO_OFF)
		if W.frame then refresh() end
	elseif msg == "ticker" then
		initDB()
		db.ticker = not db.ticker
		chat(db.ticker and L.TICKER_ON or L.TICKER_OFF)
		if W.frame and not db.ticker then
			S.tickerQ:clear()
			SlotFrame.tickerIdle()
		end
	elseif msg == "auto" then
		ensure()
		if not W.frame:IsShown() then
			W.frame:Show()
		end
		SlotFrame.toggleAuto()
	elseif msg == "guild" or msg == "solo" then
		ensure()
		SlotFrame.setMode(msg)
		if not W.frame:IsShown() then
			W.frame:Show()
		end
	elseif msg == "payout" then
		ensure()
		if SlotFrame.setMode("guild") then
			if not W.frame:IsShown() then
				W.frame:Show()
			end
			SlotFrame.cashout()
		elseif not W.frame:IsShown() then
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
		-- Combat ends autoplay and any shake.
		if W.frame then
			stopAuto("combat")
			stopShake()
		end
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
