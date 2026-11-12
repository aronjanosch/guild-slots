local addonName, ns = ...

-- Everything visual in one place: art, colours, fonts, 9-slice margins, layout, timings, sounds.
-- The look is the "tavern" design in design/gildenslots-v2 (SPEC.md and the state images).
-- All sizes are pixels at UI scale 1; window coordinates are { x, y, w, h } from the window's
-- top left corner, y downwards (UI/Skin.lua turns them into anchors).

local Theme = {}
ns.Theme = Theme

local MEDIA = "Interface\\AddOns\\" .. (addonName or "GuildSlots") .. "\\Media\\"
local ART = MEDIA .. "Art\\"
local FONTS = MEDIA .. "Fonts\\"

-- Path of a part built by tools/build_media.py.
local function art(name)
	return ART .. name .. ".tga"
end
Theme.art = art

local function hex(s, a)
	return {
		tonumber(s:sub(1, 2), 16) / 255,
		tonumber(s:sub(3, 4), 16) / 255,
		tonumber(s:sub(5, 6), 16) / 255,
		a or 1,
	}
end
Theme.hex = hex

---------------------------------------------------------------------------------------------
-- Symbols. Symbol id (Core/Tables.lua) -> design name; display names are in the locales
-- (L.SYM_<id>). M is the design's deep-sea kraken.

Theme.symbolArt = {
	K = "copper", S = "silver", G = "gold", T = "potion", W = "sword",
	M = "kraken", D = "dragon", C = "crown", L = "legendary", B = "tome",
}
Theme.symbols, Theme.symbolsWin = {}, {}
for id, name in pairs(Theme.symbolArt) do
	Theme.symbols[id] = art("symbol_" .. name)
	Theme.symbolsWin[id] = art("symbol_" .. name .. "_win")
end
-- The art has a transparent margin and fills the whole cell.
Theme.iconCrop = { 0, 1, 0, 1 }

---------------------------------------------------------------------------------------------
-- Textures

Theme.tex = {
	bg = art("bg_window_wood"),
	bgFree = art("bg_window_freespin"),
	reelBg = art("bg_reels"),
	reelBgFree = art("bg_reels_freespin"),
	reelShade = art("reel_shade"),
	expandColumn = art("expand_column"),
	glowCell = art("glow_cell"),
	glowSoft = art("glow_soft"),
	lineGlow = art("line_glow"),
	markerNormal = art("linemarker_normal"),
	markerLit = art("linemarker_lit"),
	bannerBig = art("banner_bigwin"),
	bannerFree = art("banner_freespins"),
	rays = art("rays"),
	shine = art("shine"),
	cardBack = art("card_back"),
	cardRed = art("card_front_red"),
	cardBlack = art("card_front_black"),
	coinSheet = art("sprite_coin_spin_8x1"),
	sparkleSheet = art("sprite_sparkle_8x1"),
	bookSheet = art("sprite_book_open_4x2"),
	white = art("glow_soft"), -- tinted flashes
}
Theme.reelShadeAlpha = 0.8
Theme.alpha = {
	introGlow = 0.55, rays = 0.85, shine = 0.6, cellGlow = 0.9, expandGlow = 0.95,
	breatheMin = 0.15, breatheMax = 0.6, landFlash = 0.7, tease = { 0.3, 1 },
	linePulse = { 0.55, 1 }, restingLines = 0.55,
}

Theme.icons = {
	soundOn = art("icon_sound_on"), soundOff = art("icon_sound_off"), close = art("icon_close"),
	coin = art("icon_coin"), officer = art("icon_officer"), paytable = art("icon_paytable"),
	copy = art("icon_copy"),
}

-- Sprite sheets: columns, rows, frames per second, frames.
Theme.sheets = {
	coin = { cols = 8, rows = 1, fps = 12, frames = 8 },
	sparkle = { cols = 8, rows = 1, fps = 14, frames = 8 },
	book = { cols = 4, rows = 2, fps = 10, frames = 8 }, -- 8 frames in 0.8 s, hold the last
}

-- 9-slices: file (or files per state), texture size, margin in texture pixels (mx, my) and
-- shown margin (dx, dy). my = 0 is a 3-slice (only left and right caps).
local function slice(file, w, h, m, d, my, dy)
	return { file = file, w = w, h = h, mx = m, my = my or m, dx = d, dy = dy or (my == 0 and 0 or d) }
end
local function buttonFiles(kind)
	return {
		normal = art("button_" .. kind .. "_normal"), hover = art("button_" .. kind .. "_hover"),
		pressed = art("button_" .. kind .. "_pressed"), disabled = art("button_" .. kind .. "_disabled"),
		selected = kind == "toggle" and art("button_toggle_selected") or nil,
	}
end
Theme.slices = {
	window = slice(art("frame_window"), 256, 256, 48, 48),
	windowFree = slice(art("frame_window_freespin"), 256, 256, 48, 48),
	reels = slice(art("frame_reels"), 256, 256, 32, 24),
	reelsFree = slice(art("frame_reels_freespin"), 256, 256, 32, 24),
	inset = slice(art("panel_inset"), 64, 64, 16, 12),
	overlay = slice(art("panel_overlay"), 64, 64, 16, 12),
	glowCell = slice(art("glow_cell"), 128, 128, 32, 22),
	divider = slice(art("divider"), 256, 16, 32, 32, 0),
	badge = slice(art("badge_status"), 64, 32, 15, 11),
	field = slice({
		normal = art("input_field_normal"), focus = art("input_field_focus"),
		disabled = art("input_field_disabled"),
	}, 64, 64, 16, 10),
	primary = slice(buttonFiles("primary"), 256, 128, 40, 20),
	secondary = slice(buttonFiles("secondary"), 128, 64, 20, 10),
	danger = slice(buttonFiles("danger"), 128, 64, 20, 10),
	toggle = slice(buttonFiles("toggle"), 128, 64, 20, 10),
	icon = slice(buttonFiles("icon"), 64, 64, 16, 8),
}
Theme.tileSize = 256 -- bg_window_* tiles seamlessly at this size

---------------------------------------------------------------------------------------------
-- Colours

Theme.colors = {
	wood = hex("2c1b0e"),
	field = hex("0d0805"),
	frameDark = hex("6b4a1f"),
	gold = hex("f2c14e"),
	goldLight = hex("ffd76a"),
	goldDark = hex("8f5c10"),
	text = hex("f3e2b8"), -- parchment
	number = hex("fff1cc"),
	muted = hex("c9ad7c"),
	footer = hex("a88e62"),
	empty = hex("7d6a4c"),
	stakeText = hex("e2cfa3"),
	red = hex("c23345"),
	redDark = hex("5e0f1a"),
	lose = hex("ff8a9a"),
	free = hex("7b3fe0"),
	freeHint = hex("c6fbff"),
	white = hex("ffffff"),
	black = hex("000000"),
	dark = hex("1a0f05"), -- digits on a lit marker
	buttonDark = hex("2a1606"), -- text on the gold button
	buttonDisabled = hex("d8cbb2"),
	titleShadow = hex("1a0d05"),
	bannerGold = hex("ffe08a"),
	bigShadow = hex("5a2a00"),
	freeTitleShadow = hex("1a0630"),
	bigTitleShadow = hex("3a0610"),
	payNone = hex("6b5a40"),
	diagramOff = hex("3a2a1a"),
	rowBand = hex("ffd76a", 0.05),
	rowSelected = hex("4a3218"),
	dim = hex("000000", 0.6), -- covers cells that are not part of the shown win
	shade = hex("0a0603", 0.88), -- behind the gamble card
	shadeStatus = hex("0a0603", 0.78), -- behind the guild status panel
	shadeIntro = hex("05020a", 0.55), -- window during the free-game intro
	shadeBig = hex("0a0402", 0.45), -- reels during a big win
	statusOk = hex("2f9e44"),
	statusOpen = hex("e8a33a"),
	statusBad = hex("c0283a"),
	disabledAlpha = 0.45, -- text of a disabled button
	-- One colour per line number, 1..10 (SPEC.md; the lines themselves are the game's).
	lines = {
		hex("ffd23f"), hex("ff6b6b"), hex("4dabf7"), hex("69db7c"), hex("da77f2"),
		hex("ffa94d"), hex("38d9a9"), hex("f783ac"), hex("a9e34b"), hex("74c0fc"),
	},
}
-- Message line tones.
Theme.tones = {
	muted = Theme.colors.muted, win = Theme.colors.goldLight, lose = Theme.colors.lose,
	free = Theme.colors.freeHint,
}

---------------------------------------------------------------------------------------------
-- Fonts: the delivered OFL fonts, with the game font SPEC.md names as fallback when SetFont
-- fails, and a font object as the last resort.

Theme.fonts = {
	title = { file = FONTS .. "CinzelDecorative-Black.ttf", fallback = "Fonts\\MORPHEUS.TTF" },
	label = { file = FONTS .. "Marcellus-Regular.ttf", fallback = "Fonts\\FRIZQT__.TTF" },
	number = { file = FONTS .. "ArchivoNarrow-Bold.ttf", fallback = "Fonts\\ARIALN.TTF" },
	numberMedium = { file = FONTS .. "ArchivoNarrow-Medium.ttf", fallback = "Fonts\\ARIALN.TTF" },
	fallbackObject = "GameFontNormal",
}
Theme.fontSize = {
	title = 28, banner = 34, spin = 28, heading = 20, gambleTitle = 22, officerTitle = 22,
	label = 11, message = 15, button = 14, display = 24, displaySub = 13, expName = 22,
	stake = 20, offer = 17, card = 20, big = 72, footer = 11, marker = 11, markerLit = 12,
	gambleLine = 14, gambleNumber = 18, introSub = 16, statusTitle = 22, statusSub = 16,
	payHead = 12, payName = 15, payValue = 16, payNote = 11, payLine = 13,
	section = 12, listHead = 10, listName = 14, listNumber = 15, formLabel = 13, field = 17,
	lineField = 14, badge = 13, small = 12, cardsLabel = 10,
}

---------------------------------------------------------------------------------------------
-- Slot window layout (SPEC.md, window 600 x 672)

Theme.layout = {
	width = 600, height = 672,
	title = { 30, 22, 260, 44 },
	solo = { 318, 29, 78, 32 },
	guild = { 398, 29, 78, 32 },
	sound = { 492, 29, 34, 32 },
	close = { 534, 29, 34, 32 },
	iconSize = 17,
	divider = { 22, 70, 556, 12 },
	displays = { { 22, 86, 180, 50 }, { 210, 86, 180, 50 }, { 398, 86, 180, 50 } },
	-- inside a display: label, value, coin icon, sub value, symbol badge (free games)
	dLabel = { 12, 5, 156, 14 },
	dValue = { 12, 20, 156, 26 },
	dIcon = { 12, 24, 18, 18 },
	dIconShift = 24,
	dSub = { 88, 26, 80, 18 },
	dBadge = { 128, 1, 48, 48 },
	reelFrame = { 48, 142, 504, 312 },
	reels = { 60, 154, 480, 288 },
	cell = 96,
	cellGlowOut = 4, -- glow_cell reaches this far outside a cell
	markerX = { 33, 567 },
	marker = 22, markerLit = 28,
	lineIn = 44, lineOut = 556, -- drawn lines run from the left to the right marker
	lineThickness = 16,
	lineFallback = 4, -- width of the staircase segments without CreateLine
	message = { 22, 460, 556, 24 },
	stakeLabel = { 22, 488, 300, 14 },
	stakes = { 22, 506, 96, 46 }, stakeStep = 102, stakeArea = 302,
	take = { 22, 494, 148, 58 },
	gamble = { 176, 494, 148, 58 },
	takeWide = { 22, 494, 300, 58 }, -- while the gamble card is shown
	spin = { 334, 488, 244, 64 },
	spinGlowOut = 18,
	paytable = { 22, 562, 156, 38 },
	officer = { 184, 562, 156, 38 },
	refill = { 346, 562, 156, 38 }, -- solo only; moves to the officer slot without that button
	footBalance = { 360, 562, 218, 38 }, -- balance during free games
	footer = { 22, 616, 556, 16 },
	buttonIcon = 18, buttonIconX = 12, buttonTextX = 34,
	-- Overlays over the reel field, in window coordinates.
	gambleTitle = { 60, 160, 480, 30 },
	gambleLine = { 60, 190, 480, 24 },
	card = { 230, 214, 140, 140 },
	red = { 92, 262, 120, 52 },
	black = { 388, 262, 120, 52 },
	lastCardsLabel = { 60, 360, 130, 16 },
	lastCards = { 196, 352, 44, 44 }, lastCardsStep = 44, lastCardsCount = 5,
	statusPanel = { 150, 226, 300, 144 },
	statusIcon = { 280, 240, 40, 40 },
	statusTitle = { 150, 284, 300, 34 },
	statusSub = { 150, 318, 300, 26 },
	introGlow = { 150, 170, 300, 300 },
	introBanner = { 64, 132, 472, 118 },
	introTitle = { 64, 150, 472, 66 },
	book = { 172, 216, 256, 256 },
	bookClip = { 172, 246, 256, 200 }, -- the book frames have empty space at the top
	introIcon = { 240, 226, 120, 120 },
	introPanel = { 190, 448, 220, 34 },
	bigBanner = { 54, 196, 492, 123 },
	bigTitle = { 54, 214, 492, 70 },
	bigAmount = { 60, 318, 480, 80 },
	summarySub = { 60, 398, 480, 30 },
	raysSize = 600,
	shineWidth = 40,
	sparkle = 40, -- one sparkle at a winning cell's corner
	coinSizes = { 26, 32, 40 },
	coins = 30, -- pooled coin textures (at most)
	sparkles = 15,
	-- Paytable overlay (state 09).
	ptPanel = { 22, 84, 556, 520 },
	ptTitle = { 40, 92, 300, 32 },
	ptClose = { 536, 94, 30, 28 },
	ptInfo = { 250, 96, 276, 26 }, -- return rate and gamble rule
	ptSymbolHead = { 82, 126, 120, 16 },
	ptCols = { 330, 390, 450, 510 }, ptColW = 52, ptHeadY = 126,
	ptRowY = 144, ptRowH = 31, ptBand = { 32, 536 }, ptIcon = 40, ptName = { 82, 200 },
	ptNote = { 32, 456, 536, 34 },
	ptDiagram = { 40, 498 }, ptDiagramStep = { 106, 50 }, ptDiagramCell = { 12, 10 },
	ptDiagramPitch = { 15, 13 }, ptDiagramOff = { 18, 4 }, ptDiagramNum = { 0, 8, 14, 18 },
}

-- Officer window (state 11, 448 wide; the height follows what is shown, 728 for an officer).
Theme.officer = {
	width = 448, maxHeight = 728, pad = 22,
	title = { 30, 22, 300, 42 },
	close = { 384, 29, 34, 32 },
	divider = { 22, 68, 404, 12 },
	top = 86, -- first section
	sectionGap = 4,
	-- Sections, stacked from `top` (rects: x in the window, y from the section's top).
	grant = {
		height = 378,
		heading = { 26, 0, 300, 16 },
		list = { 22, 18, 404, 110 },
		listHead = { 36, 24, 380, 14 },
		row = { 30, 42, 192, 27 }, rowStep = { 196, 27 }, cols = 2, rows = 6, rowText = 8,
		none = { 36, 42, 380, 27 },
		playerLabel = { 26, 136, 166, 14 }, tokensLabel = { 198, 136, 80, 14 },
		player = { 22, 152, 170, 36 }, tokens = { 198, 152, 80, 36 }, button = { 286, 148, 140, 44 },
		note = { 26, 194, 400, 16 },
		selfTest = { 22, 214, 110, 28 }, selfHint = { 140, 212, 286, 32 },
		purchasesHead = { 26, 250, 300, 16 },
		purchases = { 22, 268, 404, 104 },
		pRow = 275, pRowH = 30, pRows = 3,
		pName = { 36, 150 }, pAmount = { 186, 60 }, pBadge = { 256, 4, 160, 22 },
	},
	status = {
		height = 50,
		heading = { 26, 0, 300, 16 },
		text = { 26, 18, 400, 30 },
	},
	nonOfficer = { 26, 0, 400, 16 },
	form = {
		height = 180,
		cols = 4, colW = 95, colStep = 103, rowStep = 48, x = 22,
		label = { 4, 0, 95, 14 }, field = { 0, 14, 95, 30 },
		line = { 22, 98, 360, 32 }, copy = { 390, 98, 36, 32 },
		hint = { 26, 134, 400, 14 },
		note = { 26, 150, 400, 28 },
	},
}

-- Line markers and buttons that are drawn without a texture use these sizes.
Theme.size = {
	width = Theme.layout.width,
	cell = Theme.layout.cell,
	iconInset = 0,
}

---------------------------------------------------------------------------------------------
-- Timings, all in seconds.

Theme.timing = {
	-- Every spin of a reel has the same shape: nudge, ramp, cruise, braking, bounce.
	-- Cruise speed: 28 rows/s is 0.47 rows per frame at 60 fps, a blur that still reads as
	-- moving down. Above 30 rows/s (0.5 rows per frame) the evenly spaced icon gaps alias and
	-- seem to run backwards at 60 fps.
	speed = 28,
	nudgeTime = 0.1, -- short backwards nudge before the start
	nudge = 0.12, -- nudge depth in rows
	accel = 0.2, -- ramp up to full speed
	decel = 0.4, -- braking before a reel lands
	quickDecel = 0.2, -- braking after a quick stop (SPIN while running)
	minReseatSpeed = 20, -- strip re-seats only at or above this speed
	-- Landing time per reel, left to right (each at least nudgeTime + accel + decel); Anim.plan
	-- shifts it by at most 1/(2 * speed) s so the reel travels whole rows.
	stop = { 0.8, 1.05, 1.3, 1.55, 1.8 },
	freeStop = { 0.75, 0.95, 1.15, 1.35, 1.55 }, -- free games
	freePause = 0.35, -- pause before each free game's reels start
	anticipation = 0.7, -- extra time per reel after two books (cumulative)
	bounce = 0.22, -- landing bounce duration
	overshoot = 0.18, -- landing overshoot in rows
	quickStagger = 0.07, -- quick stop: delay between reels
	-- Win presentation (UI/Plan.lua builds the steps from these).
	allLines = 1.0, -- all winning lines flash together
	lineMin = 0.9, -- one line shown: lineMin + linePerStake * (win / stake), at most lineMax
	linePerStake = 0.04,
	lineMax = 2.2,
	lineCount = 0.6, -- count-up of the total within a step (at most the step)
	scatterShow = 1.4, -- books pay
	intro = 4.0, -- free-game intro, in total:
	introPulse = 1.0, --   books pulse, then the banner pops and the tome opens
	introShuffleAt = 1.6, --   the expanding symbol shuffles from here ...
	introShuffle = 1.6, --   ... for this long, then holds until the intro ends
	retrigger = 1.6, -- "+10 free games"
	expandReel = 0.35, -- expansion reveal per reel
	expandHold = 0.4, -- after the last reel expanded
	summary = 3.0, -- free-game summary banner
	bigWin = { 20, 50, 100 }, -- round win / stake for "Big", "Huge", "Legendary"
	bigCountUp = { 3.0, 4.5, 6.0 }, -- celebration and count-up per level
	countUp = 0.8, -- balance count-up after a round
	pulseFreq = 1.6, -- winning cell pulse (Hz)
	flashFreq = 3, -- line flash, tease glow (Hz)
	gambleFlip = 0.6, -- the card turns over
	gambleHold = 0.9, -- result shown before the buttons come back
	message = 2.5, -- short messages (no funds, ...)
	-- Effects from the design.
	pop = 0.45, -- banner 0.2 -> 1.12 -> 1
	raysTurn = 9, -- one full turn of the rays
	shinePeriod = 1.8, shineSweep = 0.7, -- shine sweep over a banner: every period, this long
	coinLife = 2.2, -- one coin's fall through the window
	coinBurst = 1.2, -- coins start spread over this time
	breathe = 0.45, -- primary button glow while idle (Hz)
	landFlash = 0.3, -- flash on a reel when it lands
}

---------------------------------------------------------------------------------------------
-- Sounds

-- PLACEHOLDERS: soundkit names looked up in the client's SOUNDKIT table at runtime; a
-- missing name plays nothing. Replace with better fitting kits after testing in the client.
-- A number instead of a name is played as a soundkit id directly. A path ending in .ogg or
-- .mp3 is a file of our own under the addon folder (built by tools/gen_sounds.py).
Theme.sounds = {
	click = "IG_MAINMENU_OPTION_CHECKBOX_ON",
	reelStart = "IG_MAINMENU_OPEN",
	reelSpin = "Media\\reel_spin.ogg", -- stopped when the last reel lands
	reelStop = "Media\\reel_stop.ogg",
	lineWin = "LOOT_WINDOW_COIN_SOUND", -- one winning line shown
	bookLand = "IG_QUEST_LOG_OPEN", -- a reel lands with a book
	freeStart = "RAID_WARNING", -- free games awarded or retriggered
	expand = "UI_EPICLOOT_TOAST", -- one reel expands
	bigWin = "READY_CHECK",
	gambleWin = "LOOT_WINDOW_COIN_SOUND",
	gambleLose = "IG_QUEST_FAILED",
}
