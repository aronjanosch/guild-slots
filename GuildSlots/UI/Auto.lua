local _, ns = ...

-- Autoplay decisions. Pure Lua, no WoW API, no clock; tested by tests/test_session.lua. The slot
-- window holds the on/off switch (never saved), the timer and the switch-off events (toggle,
-- mode switch, combat, closing the window, an open payout request).
--
-- Auto.after(game) -> "continue" | "wait"
--   after a fully shown round, a take, or a finished gamble: "wait" while the game still offers
--   take / gamble (the player decides; autoplay never gambles), else "continue"
-- Auto.refused(code) -> "retry" | "off"
--   a spin refused with `code`: "retry" for "wait" (guild interval), anything else switches
--   autoplay off (no funds, payout open, ...)

local Auto = {}
ns.Auto = Auto

function Auto.after(game)
	if type(game) == "table" and type(game.state) == "function" and game:state() == "gamble" then
		return "wait"
	end
	return "continue"
end

function Auto.refused(code)
	if code == "wait" then
		return "retry"
	end
	return "off"
end
