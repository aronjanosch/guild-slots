local _, ns = ...

-- Everything visual in one place: symbol art, colours, sizes, fonts, timings, sounds.
-- Swap the symbol textures here for custom art later; nothing else needs to change.

local Theme = {}
ns.Theme = Theme

-- Symbol id (see Core/Tables.lua) -> texture path. Built-in client icons as PLACEHOLDERS until
-- the designer's art arrives. Display names are in the locales (L.SYM_<id>).
Theme.symbols = {
	K = "Interface\\Icons\\INV_Misc_Coin_05", -- copper coin
	S = "Interface\\Icons\\INV_Misc_Coin_03", -- silver coin
	G = "Interface\\Icons\\INV_Misc_Coin_01", -- gold coin
	T = "Interface\\Icons\\INV_Potion_54", -- potion
	W = "Interface\\Icons\\INV_Sword_27", -- sword
	M = "Interface\\Icons\\INV_Misc_Head_Murloc_01", -- murloc
	D = "Interface\\Icons\\INV_Misc_Head_Dragon_01", -- dragon
	C = "Interface\\Icons\\INV_Crown_01", -- crown
	L = "Interface\\Icons\\INV_Sword_39", -- legendary weapon (Thunderfury)
	B = "Interface\\Icons\\INV_Misc_Book_09", -- book: wild and scatter
}
-- Crops the built-in icon border. Use { 0, 1, 0, 1 } for custom art without a border.
Theme.iconCrop = { 0.08, 0.92, 0.08, 0.92 }

-- Gamble coin faces.
Theme.coin = {
	back = "Interface\\Icons\\INV_Misc_Coin_02",
	win = "Interface\\Icons\\INV_Misc_Coin_01",
	lose = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
}

-- Big win particles.
Theme.particle = "Interface\\Icons\\INV_Misc_Coin_01"

local function hex(s, a)
	return {
		tonumber(s:sub(1, 2), 16) / 255,
		tonumber(s:sub(3, 4), 16) / 255,
		tonumber(s:sub(5, 6), 16) / 255,
		a or 1,
	}
end
Theme.hex = hex

Theme.colors = {
	bg = hex("0f212e"), -- window background
	panel = hex("1a2c38"), -- panels, reel background
	panelHover = hex("213743"),
	border = hex("2f4553"),
	cell = hex("213743"), -- one symbol slot
	freePanel = hex("2a1846"), -- reel panel during free games
	freeCell = hex("3a2160"), -- symbol slot during free games
	accent = hex("00e701"), -- main button, wins
	accentHover = hex("1fff20"),
	accentText = hex("05121b"), -- text on the accent colour
	gold = hex("ffc83d"), -- big wins, free-game banners, books
	text = hex("ffffff"),
	muted = hex("b1bad3"),
	lose = hex("ed4163"),
	overlay = hex("0f212e", 0.88),
	dim = hex("0f212e", 0.7), -- covers cells that are not part of the shown win
	expand = hex("3a2160", 0.92), -- background of an expanded reel
	disabledAlpha = 0.4,
	-- One colour per line, 1..10.
	lines = {
		hex("00e701"), hex("ffc83d"), hex("4fc3f7"), hex("ff7043"), hex("ba68c8"),
		hex("f06292"), hex("aed581"), hex("ffee58"), hex("26c6da"), hex("ff8a65"),
	},
}

-- Sizes in pixels. The reel panel is 2 * reelPad + 2 * marker + 5 * cell + 4 * reelGap wide
-- (528) and fills the inner width (width - 2 * pad).
Theme.size = {
	width = 560,
	pad = 16, -- outer padding
	gap = 8, -- vertical gap between blocks
	header = 24,
	topBar = 48, -- balance, free-game counter, win
	cell = 92, -- one symbol slot (reel width and row height)
	iconInset = 10, -- padding of the icon inside its slot
	reelGap = 4,
	reelPad = 6, -- padding of the reel panel
	marker = 20, -- column of the line number markers left and right of the reels
	markerBox = 18,
	lineWidth = 3, -- drawn pay line
	cellEdge = 3, -- border of a highlighted cell
	message = 24, -- line text under the reels
	gambleRow = 34,
	controls = 44, -- stake pills and SPIN
	pill = 56,
	spinWidth = 200,
	smallRow = 22,
	footer = 24,
	badge = 36, -- expanding symbol in the top bar
	bannerIcon = 72, -- symbol shown in the free-game intro
	particle = 22,
	particles = 24, -- pooled particle textures
	paytableRow = 22,
	lineDot = 7, -- one cell of a line diagram in the paytable
}

Theme.fonts = {
	-- Fonts\\ARIALN.TTF and Fonts\\FRIZQT__.TTF ship with every client; a failing SetFont
	-- falls back to the font object.
	face = "Fonts\\ARIALN.TTF",
	fallbackObject = "GameFontNormal",
	title = 15,
	label = 11,
	number = 24,
	win = 24,
	message = 15,
	banner = 30,
	marker = 10,
	button = 15,
	spin = 20,
	small = 11,
}

-- All times in seconds.
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
	introPulse = 1.0, --   books pulse, then the banner
	introShuffleAt = 1.6, --   the expanding symbol shuffles from here ...
	introShuffle = 1.6, --   ... for this long, then holds until the intro ends
	retrigger = 1.6, -- "+10 free games"
	expandReel = 0.35, -- expansion reveal per reel
	expandHold = 0.4, -- after the last reel expanded
	summary = 3.0, -- free-game summary banner
	bigWin = { 20, 50, 100 }, -- round win / stake for "Big", "Huge", "Legendary"
	bigCountUp = { 3.0, 4.5, 6.0 }, -- celebration and count-up per level
	particleLife = 1.4, -- one particle flight
	countUp = 0.8, -- balance count-up after a round
	pulseFreq = 1.6, -- winning cell pulse (Hz)
	flashFreq = 3, -- line flash, tease glow, big win flash (Hz)
	dimAlpha = 0.3, -- coin overlay: reels behind it
	gambleFlip = 0.8, -- coin flip before the reveal
	gambleFlipFreq = 3, -- coin turns per second
	gambleHold = 0.9, -- result shown before buttons come back
	message = 2.5, -- short messages (no funds, ...)
}

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
