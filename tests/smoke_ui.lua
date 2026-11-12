-- Load smoke test for the in-game UI, outside the client:
--   luajit tests/smoke_ui.lua
-- Loads every file in TOC order against tests/wowstub.lua, opens the window via the slash
-- command and plays T2 rounds with stops queued into the injected rng (ns.random): a losing
-- round, line wins with take and gamble, quick stop and skipping, a round with free games, a
-- retrigger and an expansion, closing the window mid free games, keyboard and combat handling,
-- refill, the paytable, effects (/gs fx), and random rounds. Runs once per locale (enUS, deDE),
-- and once more with the optional client API switched off in the stub (no CreateLine,
-- SetRotation, SetClipsChildren, SetBlendMode; the bundled fonts fail to load).
--
-- Stops (strips in docs/table-t2-spec.md), solo rng order: 5 base stops, then (free games
-- only) the expanding symbol 0..8, then 5 stops per free game.
--   0,0,0,0,0          loses (one book on reel 1)
--   1,16,0,0,0         line 5: 3 x M = 30 at stake 10
--   40,35,52,0,0       three books: lines and scatter 110, ten free games
--   symbol 5           M
--   33,55,50,5,29      free game: three books (retrigger) and M on reels 3, 4, 5 (expansion 300)
--   1,1,1,1,1          free game without a win

local failures = 0

local SOUND_BOOK, SOUND_FREE, SOUND_EXPAND, SOUND_BIG = 875, 8959, 31578, 8960

local OPTIONAL = { "CreateLine", "SetRotation", "SetClipsChildren", "SetBlendMode" }

local function scenario(locale, lean)
	-- Fresh globals for every run.
	GuildSlotsDB = nil
	local stub = dofile("tests/wowstub.lua")
	stub.locale = locale
	if lean then
		for _, name in ipairs(OPTIONAL) do stub.off[name] = true end
		stub.fontsFail = true
	end

	local values = {}
	local function queue(...)
		for _, v in ipairs({ ... }) do values[#values + 1] = v end
	end
	local function queueFreeRound(extraGames)
		queue(40, 35, 52, 0, 0, 5, 33, 55, 50, 5, 29)
		for _ = 1, extraGames do queue(1, 1, 1, 1, 1) end
	end
	local seed = 12345
	local function random(n)
		local v = table.remove(values, 1)
		if v == nil then
			seed = (seed * 1103515245 + 12345) % 2147483648
			v = seed % n
		end
		assert(v >= 0 and v < n, "queued rng value out of range")
		return v
	end

	-- ns.random must be set before SlotFrame loads; inject through a preloaded ns.
	local ns = { random = random }
	local _, loaded = stub.loadAddon("GuildSlots", "GuildSlots", ns)
	-- TOC and files must not drift apart: every .lua under GuildSlots/ is listed.
	local listed = {}
	for _, path in ipairs(loaded) do listed[path] = true end
	local find = io.popen("find GuildSlots -name '*.lua' | sort")
	for path in find:lines() do
		assert(listed[path], path .. " is not listed in GuildSlots.toc")
	end
	find:close()
	assert(ns.Engine and ns.Ledger and ns.Plan, "Core and Plan loaded from the TOC")

	stub.fire("ADDON_LOADED", "OtherAddon")
	stub.fire("ADDON_LOADED", "GuildSlots")
	assert(type(GuildSlotsDB) == "table", "GuildSlotsDB created")

	local L, Anim, Theme = ns.L, ns.Anim, ns.Theme
	local T2 = ns.Tables.get("T2")
	local W, S = ns.SlotFrame.widgets, ns.SlotFrame.state
	local function fmt(n) return Anim.formatNumber(n, L.THOUSANDS) end

	local function ticks(n, dt)
		for i = 1, n do
			stub.tick(type(dt) == "function" and dt(i) or dt or 1 / 60)
		end
	end
	local function settle()
		local guard = 0
		repeat
			stub.tick(1 / 60)
			guard = guard + 1
			assert(guard < 20000, "animation never settles (phase " .. S.phase .. ")")
		until S.phase == "idle" and next(S.counts) == nil
	end
	local function step()
		return S.plan and S.plan.steps[S.si] or nil
	end
	-- Ticks until the current step is of `kind` (and of `game`, if given).
	local function untilStep(kind, game)
		local guard = 0
		while true do
			local s = step()
			if s and s.kind == kind and (game == nil or s.game == game) then
				return s
			end
			assert(S.phase == "round", "round ended before step " .. kind)
			stub.tick(1 / 60)
			guard = guard + 1
			assert(guard < 20000, "step " .. kind .. " never came")
		end
	end
	local function shownMatches(where)
		-- An open take / gamble offer holds the amount at risk back on screen.
		local held = S.game:state() == "gamble" and S.game.pending or 0
		local want = fmt(S.game.balance - held)
		assert(W.balance:GetText() == want,
			where .. ": balance shows " .. tostring(W.balance:GetText()) .. ", game has " .. want)
	end
	local function countSound(id)
		local n = 0
		for _, snd in ipairs(stub.sounds) do
			if snd == id then n = n + 1 end
		end
		return n
	end
	local function onBaseStrips()
		for r = 1, 5 do
			if W.reels[r].strip ~= T2.reels[r] then return false end
		end
		return true
	end

	-- Open via slash command.
	stub.slash("/gs")
	assert(W.frame and W.frame:IsShown(), "window open after /gs")
	assert(W.frame:GetWidth() == 600 and W.frame:GetHeight() == 672, "window 600 x 672")
	assert(W.reelPanel:GetWidth() == 480 and W.reelPanel:GetHeight() == 288, "reel field 480 x 288")
	assert(#W.reels == 5, "five reels")

	-- Every texture and font the theme names is a file under GuildSlots/Media (built by
	-- tools/build_media.py); the stub also checks every add-on path at SetTexture / SetFont.
	local function exists(path)
		local rel = path:gsub("^Interface\\AddOns\\", ""):gsub("\\", "/")
		local fh = io.open(rel)
		if fh then fh:close() end
		return fh ~= nil and rel:find("^GuildSlots/Media/") ~= nil
	end
	local function eachPath(t, fn)
		for _, v in pairs(t) do
			if type(v) == "string" and v:find("^Interface\\AddOns\\") then fn(v)
			elseif type(v) == "table" then eachPath(v, fn) end
		end
	end
	local named = 0
	for _, t in ipairs({ Theme.tex, Theme.icons, Theme.symbols, Theme.symbolsWin, Theme.slices, Theme.fonts }) do
		eachPath(t, function(path)
			named = named + 1
			assert(exists(path), "theme path has no file: " .. path)
		end)
	end
	assert(named > 80, "theme names the art")
	local used = 0
	for path in pairs(stub.files) do
		used = used + 1
		assert(exists(path), "used path has no file: " .. path)
	end
	assert(used > 40, "the window uses the delivered art (" .. used .. " files)")

	-- Optional API: real lines and the bundled fonts, or the fallbacks.
	local titleFont = W.title:GetFont()
	if lean then
		assert(W.realLines == false, "staircase lines without CreateLine")
		assert(W.lineSegs[1][1]:GetObjectType() == "Texture", "segments are textures")
		assert(titleFont == "Fonts\\MORPHEUS.TTF", "title falls back to the game font: " .. tostring(titleFont))
		assert(W.balance:GetFont() == "Fonts\\ARIALN.TTF", "numbers fall back to Arial Narrow")
	else
		assert(W.realLines == true, "lines drawn with CreateLine")
		assert(W.lineSegs[1][1]:GetObjectType() == "Line", "line objects")
		assert(titleFont:find("CinzelDecorative%-Black"), "title in Cinzel Decorative")
		assert(W.win:GetFont():find("Marcellus"), "message line in Marcellus")
		assert(W.balance:GetFont():find("ArchivoNarrow%-Bold"), "numbers in Archivo Narrow")
	end
	-- Markers: left at the row a line starts in, right at the row it ends in.
	local function markerY(m) local _, _, _, _, y = m.normal:GetPoint(1) return -y end
	assert(markerY(W.markers[2][1]) == 166 and markerY(W.markers[10][1]) == 238, "left row 0: lines 2 .. 10")
	assert(markerY(W.markers[8][1]) == 426 and markerY(W.markers[8][2]) == 214, "line 8 starts bottom, ends top")
	local found = false
	for _, n in ipairs(UISpecialFrames) do found = found or n == "GuildSlotsFrame" end
	assert(found, "registered for Escape")
	assert(W.frame:IsKeyboardEnabled(), "keyboard enabled out of combat")
	assert(S.game.tbl.id == "T2", "solo plays T2")
	shownMatches("open")

	-- 1. Losing round.
	queue(0, 0, 0, 0, 0)
	local books = countSound(SOUND_BOOK)
	W.spin:Click()
	assert(S.phase == "round", "round running")
	assert(W.spin.label:GetText() == L.STOP, "button reads STOP while the reels turn")
	ticks(30)
	assert(step().kind == "spin", "still spinning after 0.5 s")
	assert(stub.isPlaying("reel_spin"), "reel sound runs while spinning")
	assert(W.balance:GetText() == fmt(990), "stake taken at once")
	settle()
	assert(not stub.isPlaying("reel_spin"), "reel sound stopped after the last reel")
	assert(countSound("Interface\\AddOns\\GuildSlots\\Media\\reel_stop.ogg") == 5, "one stop sound per reel")
	assert(countSound(SOUND_BOOK) == books + 1, "book landing sound for reel 1")
	assert(S.game.balance == 990, "990 after a loss")
	assert(not W.offerRow:IsShown(), "no offer after a loss")
	shownMatches("after loss")
	for r = 1, 5 do
		assert(math.floor(W.reels[r].x + 0.5) == 0, "reel " .. r .. " on its stop")
	end

	-- 2. Line win shown line by line, then take.
	queue(1, 16, 0, 0, 0)
	W.spin:Click()
	local all = untilStep("allLines")
	assert(#all.lines == 1, "one winning line")
	assert(W.lineSegs[5][1]:IsShown(), "line 5 drawn while all lines flash")
	untilStep("line")
	assert(W.win:GetText() == string.format(L.LINE_WIN, 5, 3, L.SYM_M, fmt(30)), "line text: " .. tostring(W.win:GetText()))
	assert(W.markers[5].lit and not W.markers[1].lit, "marker of line 5 lit")
	assert(W.cells[1][3].glow:IsShown(), "line 5 starts bottom left")
	assert(W.cells[3][1].glow:IsShown(), "and reaches the top of reel 3")
	assert(W.cells[1][3].win:IsShown() and W.cells[1][3].win:GetTexture() == Theme.symbolsWin.M, "winning art")
	assert(not W.cells[4][2].glow:IsShown() and not W.cells[4][2].win:IsShown(), "reel 4 is not part of the win")
	assert(W.cells[1][1].dim:IsShown(), "other cells dimmed")
	ticks(2)
	local sparkling = 0
	for _, sp in ipairs(W.sparkles.list) do if sp.tex:IsShown() then sparkling = sparkling + 1 end end
	assert(sparkling >= 1, "sparkles on the winning cells")
	settle()
	assert(S.game.balance == 1010, "990 - 10 + 30")
	assert(W.winAmount:GetText() == fmt(30), "win shows 30")
	assert(W.offerRow:IsShown(), "take/gamble offered")
	assert(W.cells[1][3].glow:IsShown(), "winning cells stay marked")
	assert(W.win:GetText() == string.format(L.OFFER_HINT, fmt(30)), "offer hint")
	shownMatches("after line win")
	W.take:Click()
	assert(not W.offerRow:IsShown(), "offer closed after take")
	assert(S.game:state() == "idle", "idle after take")

	-- 3. Gamble as a card: GAMBLE shows the card face down, the pick draws (rng 0 wins, 1
	-- loses); a won step shows the picked colour, a lost one the other colour.
	local function flipped()
		ticks(math.ceil(Theme.timing.gambleFlip * 60) + 2)
		return W.card:GetTexture()
	end
	queue(1, 16, 0, 0, 0)
	W.spin:Click()
	settle()
	W.gamble:Click()
	assert(S.phase == "pick" and W.cardOverlay:IsShown(), "card shown")
	assert(W.card:GetTexture() == Theme.tex.cardBack, "face down")
	assert(W.red:IsShown() and W.black:IsShown(), "red and black offered")
	assert(W.gambleLine:GetText():find(fmt(60), 1, true), "amount at stake and the double shown")
	assert(W.take:IsShown() and W.take.enabled and not W.gamble:IsShown(), "take stays available")
	assert(not W.spin.enabled, "no spin while the card waits")
	assert(S.game.balance == 1030, "nothing drawn before the pick")
	queue(0)
	W.red:Click()
	assert(S.phase == "flip", "card turns")
	assert(flipped() == Theme.tex.cardRed, "won: the picked colour")
	assert(W.lastCards[1]:IsShown() and W.lastCards[1]:GetTexture() == Theme.tex.cardRed, "last cards")
	settle()
	assert(not W.cardOverlay:IsShown(), "card gone after the hold")
	assert(S.game.balance == 1030 + 30, "won gamble adds 30")
	assert(W.offerRow:IsShown(), "gamble offered again")
	assert(W.take.label:GetText():find(fmt(60), 1, true), "take shows 60")
	shownMatches("after gamble win")
	W.gamble:Click()
	queue(1)
	W.red:Click()
	assert(flipped() == Theme.tex.cardBlack, "lost: the other colour")
	settle()
	assert(S.game.balance == 1060 - 60, "lost gamble")
	assert(not W.offerRow:IsShown(), "no offer after a loss")
	shownMatches("after gamble loss")
	-- Black, won; then take while the card waits.
	queue(1, 16, 0, 0, 0)
	W.spin:Click()
	settle()
	W.gamble:Click()
	queue(0)
	W.black:Click()
	assert(flipped() == Theme.tex.cardBlack, "won with black: black")
	settle()
	W.gamble:Click()
	W.take:Click()
	assert(S.phase == "idle" and not W.cardOverlay:IsShown() and S.game:state() == "idle", "take from the card")
	assert(S.game.balance == 1000 - 10 + 30 + 30, "took 60")
	assert(W.balance:GetText() == fmt(990), "the amount at risk was held back until the take")
	settle()
	shownMatches("after take from the card")

	-- 4. Quick stop, then skipping the presentation, uneven frame times.
	queue(1, 16, 0, 0, 0)
	W.spin:Click()
	ticks(12)
	W.spin:Click() -- quick stop
	assert(W.spin.label:GetText() == L.SKIP, "button reads SKIP after the quick stop")
	ticks(30, function(i) return (i % 3 == 0) and 0.1 or 0.004 end)
	assert(step() == nil or step().kind ~= "spin", "quick stop landed within 0.5 s")
	untilStep("line")
	W.spin:Click() -- skip
	assert(S.phase == "idle", "skipped to the end state")
	assert(W.winAmount:GetText() == fmt(30), "total at its end value")
	assert(W.offerRow:IsShown(), "offer after skipping")
	settle()
	shownMatches("after skip")
	-- A spin during the offer takes the win; a second click while the reels turn stops them,
	-- a third skips everything.
	queue(0, 0, 0, 0, 0)
	W.spin:Click()
	assert(S.game:state() == "idle" and S.game.balance == 1050 + 30 - 10 - 10, "offer taken by the next spin")
	W.spin:Click()
	W.spin:Click()
	assert(S.phase == "idle", "skip during the spin ends the round")
	for r = 1, 5 do
		assert(math.floor(W.reels[r].x + 0.5) == 0, "reel " .. r .. " on its stop after skip")
	end
	settle()
	shownMatches("after take by spin")

	-- 5. Free games with anticipation, intro, retrigger, expansion, skipping, big win.
	local before = S.game.balance
	local freeSounds, expandSounds, bigSounds = countSound(SOUND_FREE), countSound(SOUND_EXPAND), countSound(SOUND_BIG)
	queueFreeRound(19)
	W.spin:Click()
	local spin0 = step()
	assert(spin0.tease == 3, "two books on reels 1 and 2 tease reel 3")
	local guard = 0
	while W.reels[2]:isSpinning() or not W.reels[3]:isSpinning() do
		stub.tick(1 / 60)
		guard = guard + 1
		assert(guard < 600, "reel 2 never landed before reel 3")
	end
	stub.tick(1 / 60)
	assert(W.tease[3]:IsShown() and W.tease[5]:IsShown(), "anticipation glow on the remaining reels")
	assert(not W.tease[1]:IsShown(), "no glow on a landed reel")
	untilStep("scatter")
	assert(W.cells[1][2].glow:IsShown() and W.cells[3][2].glow:IsShown(), "books highlighted")
	assert(W.cells[1][2].win:GetTexture() == Theme.symbolsWin.B, "tome art")
	assert(W.win:GetText() == string.format(L.SCATTER_WIN, 3, L.SYM_B, fmt(20)), "scatter text")
	untilStep("intro")
	assert(W.win:GetText() == string.format(L.FREE_TRIGGER, 3, 10), "tomes hint")
	ticks(math.ceil(Theme.timing.introPulse * 60) + 2)
	assert(W.banner:IsShown() and W.bannerTitle:GetText() == string.format(L.FREE_GAMES, 10), "intro banner")
	ticks(math.ceil((Theme.timing.introShuffleAt - Theme.timing.introPulse) * 60) + 2)
	assert(W.bannerIcon:IsShown(), "expanding symbol shuffles")
	assert(W.book:IsShown(), "the tome opens")
	assert(W.banner:IsShown() and W.bannerArt:GetTexture() == Theme.tex.bannerFree, "free-games banner")
	untilStep("spin", 1)
	assert(S.free and W.freeBar:IsShown(), "free-game mode")
	assert(W.reels[1].strip == T2.freeReels[1], "free strips")
	assert(W.freeCounter:GetText() == string.format(L.FREE_COUNTER, 1, 10), "counter 1 / 10")
	assert(W.badge:GetTexture() == Theme.symbols.M, "badge shows the expanding symbol")
	assert(W.expName:GetText() == L.SYM_M, "expanding symbol named")
	assert(W.bgTiles.tex[1]:GetTexture() == Theme.tex.bgFree and W.reelBg:GetTexture() == Theme.tex.reelBgFree,
		"free-game look")
	assert(W.footBalance:IsShown() and not W.refill:IsShown(), "balance under the buttons in free games")
	assert(W.win:GetText() == string.format(L.FREE_HINT, 1, 10, fmt(10)), "free-game hint")
	assert(W.bannerSub:GetText() == "" and not W.banner:IsShown(), "intro banner gone")
	assert(countSound(SOUND_FREE) == freeSounds + 1, "free-game start sound")
	untilStep("retrigger", 1)
	assert(W.bannerTitle:GetText() == string.format(L.FREE_MORE, 10), "+10 banner")
	assert(W.freeCounter:GetText() == string.format(L.FREE_COUNTER, 1, 20), "counter grows to 20")
	untilStep("expand", 1)
	ticks(10)
	assert(W.expand[3].bg:IsShown() and W.expand[3].bg:GetTexture() == Theme.tex.expandColumn, "reel 3 expands first")
	untilStep("expandWin", 1)
	assert(W.expand[3].bg:IsShown() and W.expand[5].bg:IsShown(), "expanded reels stay")
	assert(W.expand[5].icons[1]:GetAlpha() == 1, "expansion fills the reel")
	assert(countSound(SOUND_EXPAND) >= expandSounds + 3, "expansion sound per reel")
	assert(W.markers[1].lit and W.markers[10].lit, "expansion pays on all lines")
	untilStep("spin", 2)
	assert(not W.expand[3].bg:IsShown(), "expansion cleared for the next game")
	assert(W.freeTotal:GetText() == fmt(1075), "free total after game 1")
	W.spin:Click() -- skip game 2
	assert(step().game == 3 and step().kind == "spin", "skip jumps to the next free game")
	assert(W.freeCounter:GetText() == string.format(L.FREE_COUNTER, 3, 20), "counter 3 / 20")
	for _ = 3, 19 do W.spin:Click() end
	assert(step().game == 20, "at the last free game")
	untilStep("summary")
	assert(W.bannerTitle:GetText() == L.FREE_OVER, "summary banner")
	assert(onBaseStrips() and not S.free and not W.freeBar:IsShown(), "back to the base reels")
	assert(W.bgTiles.tex[1]:GetTexture() == Theme.tex.bg, "wood again")
	local big = untilStep("big")
	assert(big.level == 3, "118x is legendary")
	ticks(5)
	assert(W.bannerTitle:GetText() == L.BIG_WIN_3, "big win banner")
	assert(W.bannerArt:GetTexture() == Theme.tex.bannerBig, "big win banner art")
	assert(W.rain.coins[1]:IsShown() and W.rays.tex:IsShown(), "coin rain and rays")
	assert(W.bannerPop.frame:GetScale() < 1.12 + 1e-9, "banner pops")
	local raysCoord = W.rays.tex._coord[1]
	ticks(30)
	assert(W.rays.tex._coord[1] ~= raysCoord, "rays turn")
	local onScreen = 0
	for _, coin in ipairs(W.rain.coins) do if coin:IsShown() then onScreen = onScreen + 1 end end
	assert(onScreen > 5 and #W.rain.coins <= 30, "coins fall, at most 30")
	assert(countSound(SOUND_BIG) == bigSounds + 1, "big win sound")
	settle()
	assert(not W.rain.coins[1]:IsShown() and not W.rays.tex:IsShown(), "celebration over")
	assert(S.game.balance == before - 10 + 1185, "free-game round paid")
	assert(W.winAmount:GetText() == fmt(1185), "total 1185")
	for r = 1, 5 do
		assert(math.floor(W.reels[r].x + 0.5) == S.result.round.stops[r], "base window shown again")
	end
	assert(W.offerRow:IsShown(), "offer after free games")
	shownMatches("after free games")
	W.take:Click()

	-- 6. Closing the window mid free games settles the whole round.
	before = S.game.balance
	queueFreeRound(19)
	W.spin:Click()
	untilStep("spin", 2)
	local soundCount = #stub.sounds
	stub.slash("/gslots")
	assert(not W.frame:IsShown(), "closed")
	assert(#stub.sounds == soundCount, "settling plays no sounds")
	assert(S.phase == "idle", "settled on close")
	assert(not S.free and onBaseStrips(), "base reels after settling")
	assert(not W.banner:IsShown(), "no banner left")
	for _, coin in ipairs(W.rain.coins) do assert(not coin:IsShown(), "no coin left after closing") end
	assert(not W.spinGlow:IsShown(), "no glow left after closing")
	assert(S.game.balance == before - 10 + 1185, "balance after settling")
	shownMatches("after close")
	assert(W.winAmount:GetText() == fmt(1185), "settled total")
	stub.slash("/gs")
	W.take:Click()

	-- 7. Space key: only with the mouse over the window; other keys propagate.
	local onKey = W.frame:GetScript("OnKeyDown")
	stub.mouseOver = false
	queue(0, 0, 0, 0, 0)
	onKey(W.frame, "SPACE")
	assert(S.phase == "idle", "space ignored without the mouse over the window")
	stub.mouseOver = true
	onKey(W.frame, "W")
	assert(W.frame._propagate == true, "other keys propagate")
	onKey(W.frame, "SPACE")
	assert(S.phase == "round", "space spins")
	assert(W.frame._propagate == false, "space consumed")
	onKey(W.frame, "SPACE") -- quick stop
	onKey(W.frame, "SPACE") -- skip
	assert(S.phase == "idle", "space skips")
	settle()
	shownMatches("after space spin")

	-- 8. Combat: keyboard released, space does nothing.
	stub.fire("PLAYER_REGEN_DISABLED")
	stub.combat = true
	assert(not W.frame:IsKeyboardEnabled(), "keyboard released in combat")
	onKey(W.frame, "SPACE")
	assert(S.phase == "idle", "no spin from keys in combat")
	W.spin:Click() -- mouse still works
	settle()
	stub.combat = false
	stub.fire("PLAYER_REGEN_ENABLED")
	assert(W.frame:IsKeyboardEnabled(), "keyboard back after combat")
	if W.offerRow:IsShown() then W.take:Click() end

	-- 9. No funds, refill.
	S.game.balance = 5
	W.spin:Click()
	assert(S.phase == "idle", "no spin without funds")
	assert(W.win:GetText() == L.NO_FUNDS, "no funds message")
	W.refill:Click()
	assert(S.game.balance == 1000, "refilled")
	shownMatches("after refill")

	-- 10. Paytable overlay with pays at the current stake.
	local h = W.frame:GetHeight()
	W.payToggle:Click()
	assert(W.paytable:IsShown() and W.frame:GetHeight() == h, "paytable opens over the reels")
	assert(W.ptContent:IsShown() and not W.ptUnsupported:IsShown(), "lines paytable")
	assert(W.ptRows.M[2]:GetText() == "5" and W.ptRows.M[5]:GetText() == "750", "M pays at stake 10")
	assert(W.ptRows.K[2]:GetText() == "–", "K pays nothing for two")
	assert(W.ptRows.B[3]:GetText() == "20" and W.ptRows.B[2]:GetText() == "–", "tome pays times the stake")
	assert(W.ptRtp:GetText() == string.format(L.RTP, 94.99910643248847), "return rate")
	W.pills[3]:Click()
	assert(S.game.stake == 100, "stake 100")
	assert(W.pills[3].selected and not W.pills[1].selected, "pill selected")
	assert(W.ptRows.L[5]:GetText() == fmt(50000), "L pays at stake 100")
	assert(W.ptRows.B[5]:GetText() == fmt(20000), "five tomes at stake 100")
	assert(W.ptBook:GetText():find(fmt(100), 1, true), "note names the stake")
	assert(W.stakeValue:GetText() == fmt(100) and W.stakeSub:GetText() == string.format(L.STAKE_SUB, 10, fmt(10)),
		"stake display")
	W.payToggle:Click()
	assert(not W.paytable:IsShown(), "paytable closes")
	W.payToggle:Click()
	queue(0, 0, 0, 0, 0)
	W.spin:Click()
	assert(not W.paytable:IsShown(), "a spin closes the paytable")
	settle()
	W.pills[1]:Click()

	-- 11. Sound toggle, slash options, saved state.
	local played = #stub.sounds
	assert(played > 0, "sounds played")
	W.sound:Click()
	assert(GuildSlotsDB.sound == false, "sound off saved")
	queue(1, 16, 0, 0, 0)
	W.spin:Click()
	settle()
	assert(#stub.sounds == played, "no sounds when off")
	W.take:Click()
	stub.slash("/gs", "sound")
	assert(GuildSlotsDB.sound == true, "sound on via slash")
	stub.slash("/gs", "space")
	assert(GuildSlotsDB.space == false and not W.frame:IsKeyboardEnabled(), "space option off")
	stub.slash("/gs", "space")
	stub.slash("/gs", "help")
	W.frame:GetScript("OnDragStop")(W.frame)
	assert(type(GuildSlotsDB.pos) == "table", "position saved")
	stub.slash("/gs", "reset")
	assert(GuildSlotsDB.pos == nil, "position reset")
	assert(GuildSlotsDB.soloBalance == S.game.balance, "balance saved")
	assert(W.footer:GetText() == L.FOOTER, "footer text")

	-- 11b. Effects: the gold button breathes while idle; /gs fx keeps only lines, pulses and
	-- count-ups.
	if W.offerRow:IsShown() then W.take:Click() end
	ticks(2)
	assert(W.spinGlow:IsShown(), "spin button breathes while idle")
	stub.slash("/gs", "fx")
	assert(GuildSlotsDB.fx == false, "fewer effects saved")
	ticks(2)
	assert(not W.spinGlow:IsShown(), "no breathing with fewer effects")
	queue(1, 16, 0, 0, 0)
	W.spin:Click()
	untilStep("line")
	ticks(3)
	for _, sp in ipairs(W.sparkles.list) do assert(not sp.tex:IsShown(), "no sparkles with fewer effects") end
	assert(W.lineSegs[5][1]:IsShown(), "lines still drawn")
	settle()
	if W.offerRow:IsShown() then W.take:Click() end
	queueFreeRound(19)
	W.spin:Click()
	untilStep("big")
	ticks(5)
	assert(W.banner:IsShown() and W.bannerAmount:GetText() ~= "", "banner and count-up still shown")
	assert(not W.rain.coins[1]:IsShown() and not W.rays.tex:IsShown(), "no coin rain, no rays")
	assert(W.bannerPop.frame:GetScale() == 1, "no pop")
	settle()
	if W.offerRow:IsShown() then W.take:Click() end
	stub.slash("/gs", "fx")
	assert(GuildSlotsDB.fx == true, "all effects again")

	-- 12. Random rounds with gambles, skips, frame times 5..60 ms.
	for i = 1, 80 do
		W.spin:Click()
		ticks(20, function(k) return 0.005 + ((k * 7 + i) % 12) * 0.005 end)
		if i % 5 == 0 and S.phase == "round" then
			W.spin:Click()
		end
		settle()
		if W.offerRow:IsShown() and i % 2 == 0 then
			W.gamble:Click()
			if i % 4 == 0 then W.red:Click() else W.black:Click() end
			settle()
		end
		if S.game.balance < 100 then W.refill:Click() end
		shownMatches("random round " .. i)
	end

	-- /gs demo scripts the next solo spin to a free-game round.
	if W.offerRow:IsShown() then W.take:Click() end
	W.refill:Click()
	stub.slash("/gs", "demo")
	W.spin:Click()
	assert(S.result and S.result.round and S.result.round.free, "demo round has free games")
	settle()
	shownMatches("demo round")

	local unknown = {}
	for k in pairs(stub.unknown) do unknown[#unknown + 1] = k end
	table.sort(unknown)
	return unknown
end

for _, run in ipairs({ { "enUS" }, { "deDE" }, { "enUS", true } }) do
	local locale, lean = run[1], run[2]
	local name = locale .. (lean and " without optional API" or "")
	local ok, res = xpcall(function() return scenario(locale, lean) end, debug.traceback)
	if ok then
		io.write("smoke ", name, ": ok")
		if #res > 0 then io.write(" (unmodelled methods, no-ops: ", table.concat(res, ", "), ")") end
		io.write("\n")
	else
		failures = failures + 1
		io.write("smoke ", name, ": FAIL\n", res, "\n")
	end
end
os.exit(failures == 0 and 0 or 1)
