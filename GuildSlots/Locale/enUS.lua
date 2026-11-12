local _, ns = ...

-- English strings; also the fallback for every other client language.
-- Missing keys show the key itself instead of raising.

local L = setmetatable({}, { __index = function(_, k) return k end })
ns.L = L

L.THOUSANDS = ","
L.TITLE = "Guild Slots"
L.SOLO = "Solo"
L.BALANCE = "Balance"
L.STAKE = "Stake"
L.SPIN = "SPIN"
L.STOP = "STOP"
L.WIN = "Win"
L.TAKE = "TAKE %s"
L.GAMBLE = "GAMBLE %s"
L.REFILL = "Refill"
L.PAYTABLE = "Paytable"
L.PAIR = "Pair"
L.TRIPLE = "Triple"
L.PAIR_RULE = "Pair = reels 1 and 2 on the middle line"
L.GAMBLE_RULE = "Gamble: double or nothing, 50 %%, up to %d times"
L.RTP = "Return to player: %.1f %%"
L.FOOTER = "Play money only. No payout claim. The house always wins."
L.NO_FUNDS = "Not enough balance. Refill to play on."
L.BIG_WIN = "BIG WIN"
L.GAMBLE_WON = "Doubled!"
L.GAMBLE_LOST = "Lost"
L.TAKEN = "Taken"
L.REFILLED = "Balance refilled"
L.SOUND_ON = "Sound on"
L.SOUND_OFF = "Sound off"
L.SPACE_ON = "Space spins while the mouse is over the window"
L.SPACE_OFF = "Space key off"
L.HELP = "/gslots or /gs: open/close. /gs sound, /gs space, /gs reset (window position)"
L.RESET_DONE = "Window position reset"
