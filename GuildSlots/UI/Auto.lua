local _, ns = ...

-- Autoplay rules: how many rounds, when to stop. Pure Lua, no WoW API, no clock; tested by
-- tests/test_auto.lua. The slot window drives it (timer, take of an open offer, presentation)
-- and never saves it: a reload ends autoplay.
--
-- Auto.new(opts) -> run; opts:
--   rounds     number of rounds (Auto.ROUNDS), 0 or nil = until stopped
--   stopFree   stop after a round with free games
--   stopWin    stop after a round win of at least stopWin x the stake (nil = off)
--   stopBelow  stop when the balance falls below this (nil = off)
-- run:take()                  the next round may start: true (counts it) or false, "done"
-- run:after(result, balance)  after a round is fully shown: nil to go on, or a stop reason
--                             "free" | "win" | "below" | "done"
-- run:refused(code)           a spin refused with `code`: "retry" for "wait" (guild interval),
--                             else "stop"
-- run.left                    rounds left (nil = until stopped)

local Auto = {}
ns.Auto = Auto

Auto.ROUNDS = { 10, 25, 50, 100, 0 } -- 0: until stopped
Auto.WINS = { 20, 50, 100, 0 } -- 0: off

local Run = {}
Run.__index = Run

local function positive(v)
	return type(v) == "number" and v == v and v > 0 and v or nil
end

function Auto.new(opts)
	opts = opts or {}
	local rounds = positive(opts.rounds)
	return setmetatable({
		left = rounds and math.floor(rounds) or nil,
		played = 0,
		stopFree = opts.stopFree and true or false,
		stopWin = positive(opts.stopWin),
		stopBelow = positive(opts.stopBelow),
	}, Run)
end

function Run:take()
	if self.left then
		if self.left <= 0 then
			return false, "done"
		end
		self.left = self.left - 1
	end
	self.played = self.played + 1
	return true
end

function Run:after(result, balance)
	local round = type(result) == "table" and result.round or nil
	local stake = type(result) == "table" and tonumber(result.stake) or nil
	local win = type(result) == "table" and tonumber(result.win) or 0
	if self.stopFree and type(round) == "table" and round.free then
		return "free"
	end
	if self.stopWin and stake and stake > 0 and win >= self.stopWin * stake then
		return "win"
	end
	if self.stopBelow and type(balance) == "number" and balance < self.stopBelow then
		return "below"
	end
	if self.left and self.left <= 0 then
		return "done"
	end
	return nil
end

function Run:refused(code)
	if code == "wait" then
		return "retry"
	end
	return "stop"
end
