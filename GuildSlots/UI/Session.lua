local _, ns = ...

-- Session statistics of the slot window, per mode (solo, guild): pure bookkeeping, no WoW API;
-- tested by tests/test_session.lua. Not saved: a new login starts at zero, and the panel's
-- reset button clears one mode.
--
-- Stats.new() -> book
-- book:round(mode, result)    a round result from game:spin() or game:buy() (stake or cost, win,
--                             round.free)
-- book:gamble(mode, result)   a gamble step from game:gamble() (won, amount)
-- book:get(mode)              { rounds, staked, won, gamble, net, best, bestMult, streak, series }
--                             streak > 0: winning rounds in a row, < 0: losing rounds in a row;
--                             net = won - staked + gamble (gamble: what gamble steps added or lost)
-- book:reset(mode)

local Stats = {}
ns.Stats = Stats

local Book = {}
Book.__index = Book

local function blank()
	return { rounds = 0, staked = 0, won = 0, gamble = 0, net = 0, best = 0, bestMult = 0, streak = 0, series = 0 }
end

function Stats.new()
	return setmetatable({ modes = {} }, Book)
end

function Book:get(mode)
	local s = self.modes[mode]
	if not s then
		s = blank()
		self.modes[mode] = s
	end
	return s
end

function Book:reset(mode)
	self.modes[mode] = blank()
end

local function number(v)
	return type(v) == "number" and v == v and v or 0
end

function Book:round(mode, result)
	if type(result) ~= "table" then
		return
	end
	local s = self:get(mode)
	local stake = number(result.stake)
	local cost = result.cost and number(result.cost) or stake
	local win = number(result.win)
	s.rounds = s.rounds + 1
	s.staked = s.staked + cost
	s.won = s.won + win
	if win > s.best then
		s.best = win
		s.bestMult = stake > 0 and win / stake or 0
	end
	if win > 0 then
		s.streak = s.streak > 0 and s.streak + 1 or 1
	else
		s.streak = s.streak < 0 and s.streak - 1 or -1
	end
	local round = result.round
	if type(round) == "table" and round.free then
		s.series = s.series + 1
	end
	s.net = s.won - s.staked + s.gamble
end

function Book:gamble(mode, result)
	if type(result) ~= "table" then
		return
	end
	local s = self:get(mode)
	local amount = number(result.amount)
	s.gamble = s.gamble + (result.won and amount or -amount)
	s.net = s.won - s.staked + s.gamble
end
