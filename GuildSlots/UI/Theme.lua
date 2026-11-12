local _, ns = ...

-- Everything visual in one place: symbol art, colours, sizes, fonts, timings, sounds.
-- Swap the symbol textures here for custom art later; nothing else needs to change.

local Theme = {}
ns.Theme = Theme

-- Symbol id (see Core/Tables.lua) -> texture path. Built-in client icons for now.
Theme.symbols = {
	K = "Interface\\Icons\\INV_Misc_Coin_05", -- copper coin
	S = "Interface\\Icons\\INV_Misc_Coin_03", -- silver coin
	G = "Interface\\Icons\\INV_Misc_Coin_01", -- gold coin
	T = "Interface\\Icons\\INV_Potion_54", -- potion
	W = "Interface\\Icons\\INV_Sword_27", -- sword
	M = "Interface\\Icons\\INV_Misc_Head_Murloc_01", -- murloc
	D = "Interface\\Icons\\INV_Misc_Head_Dragon_01", -- dragon
}
-- Crops the built-in icon border. Use { 0, 1, 0, 1 } for custom art without a border.
Theme.iconCrop = { 0.08, 0.92, 0.08, 0.92 }

-- Gamble coin faces.
Theme.coin = {
	back = "Interface\\Icons\\INV_Misc_Coin_02",
	win = "Interface\\Icons\\INV_Misc_Coin_01",
	lose = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01",
}

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
	accent = hex("00e701"), -- main button, wins
	accentHover = hex("1fff20"),
	accentText = hex("05121b"), -- text on the accent colour
	text = hex("ffffff"),
	muted = hex("b1bad3"),
	lose = hex("ed4163"),
	payline = hex("00e701", 0.35),
	overlay = hex("0f212e", 0.88),
	disabledAlpha = 0.4,
}

Theme.size = {
	width = 372,
	pad = 20, -- outer padding
	gap = 12, -- vertical gap between blocks
	header = 28,
	cell = 88, -- one symbol slot (reel width and row height)
	iconInset = 10, -- padding of the icon inside its slot
	reelGap = 8,
	reelPad = 10, -- padding of the reel panel
	balance = 56,
	win = 36,
	gambleRow = 40,
	stakeRow = 34,
	spin = 52,
	smallRow = 26,
	paytableRow = 22,
	footer = 30,
}

Theme.fonts = {
	-- Fonts\\ARIALN.TTF and Fonts\\FRIZQT__.TTF ship with every client; a failing SetFont
	-- falls back to the font object.
	face = "Fonts\\ARIALN.TTF",
	fallbackObject = "GameFontNormal",
	title = 15,
	label = 11,
	number = 26,
	win = 24,
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
	-- Landing time per reel; Anim.plan shifts it by at most 1/(2 * speed) s so the reel
	-- travels whole rows.
	stop = { 0.9, 1.3, 1.7 },
	anticipation = 0.8, -- extra time for reel 3 when reels 1 and 2 match
	bounce = 0.22, -- landing bounce duration
	overshoot = 0.18, -- landing overshoot in rows
	quickStagger = 0.07, -- quick stop: delay between reels
	countUp = 0.8, -- win count-up
	bigCountUp = 2.2, -- win count-up for big wins
	bigWin = 30, -- multiplier from which a win is big
	celebrate = 2.5, -- accent flash for big wins
	pulseFreq = 1.6, -- winning symbol pulse (Hz)
	flashFreq = 3, -- big win accent flash (Hz)
	dimAlpha = 0.3, -- non-winning symbols
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
	win = "LOOT_WINDOW_COIN_SOUND",
	bigWin = "READY_CHECK",
	gambleWin = "LOOT_WINDOW_COIN_SOUND",
	gambleLose = "IG_QUEST_FAILED",
}
