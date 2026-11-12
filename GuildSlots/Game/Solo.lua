local _, ns = ...

-- Solo game with play money: no networking, no WoW API.
-- Randomness is injected: rng(n) returns an integer 0..n-1.
--
-- States: "idle" (may spin) and "gamble" (a win is at stake: take, gamble or spin again).
-- Every action returns a plain result table so the UI only has to animate it.
-- Like the ledger, the balance includes a win at once; a gamble step then risks `pending`.

local Solo = {}
ns.Solo = Solo

local START = 1000
local REELS = 3
local SYMBOL_ORDER = { "D", "M", "W", "T", "G", "S", "K" } -- T1

local Game = {}
Game.__index = Game

local function isAmount(v)
	return type(v) == "number" and v % 1 == 0 and v >= 0
end

-- opts: rng (required), table ("T2"), start (1000), stakes ({10,50,100}),
-- maxGamble (3), cap (0 = none), balance (restore a saved balance).
function Solo.new(opts)
	assert(type(opts) == "table" and type(opts.rng) == "function", "Solo.new needs opts.rng")
	local tbl = assert(ns.Tables.get(opts.table or "T2"), "unknown table")
	local start = opts.start or START
	local g = setmetatable({
		rng = opts.rng,
		tbl = tbl,
		start = start,
		stakes = opts.stakes or { 10, 50, 100 },
		maxGamble = opts.maxGamble or 3,
		cap = opts.cap or 0,
		balance = isAmount(opts.balance) and opts.balance or start,
		pending = 0,
		step = 0,
	}, Game)
	g.stake = g.stakes[1]
	return g
end

function Game:state()
	return self.pending > 0 and "gamble" or "idle"
end

function Game:setStake(v)
	if self:state() ~= "idle" then
		return nil, "busy"
	end
	for _, s in ipairs(self.stakes) do
		if s == v then
			self.stake = v
			return true
		end
	end
	return nil, "bad_stake"
end

function Game:spin()
	if self:state() == "gamble" then
		self:take()
	end
	local stake = self.stake
	if self.balance < stake then
		return nil, "no_funds"
	end
	if self.tbl.kind == "lines" then
		return self:spinRound(stake)
	end
	local tbl, stops, window = self.tbl, {}, {}
	for r = 1, REELS do
		stops[r] = self.rng(#tbl.reels[r])
		window[r] = { ns.Tables.window(tbl, r, stops[r]) }
	end
	local a, b, c = ns.Tables.symbols(tbl, stops[1], stops[2], stops[3])
	local m = ns.Tables.multiplier(tbl, stops[1], stops[2], stops[3])
	local win = ns.Tables.win(tbl, stake, self.cap, stops[1], stops[2], stops[3])

	self.balance = self.balance - stake + win
	self.step = 0
	self.pending = (win > 0 and self.maxGamble > 0) and win or 0

	return {
		kind = "spin",
		stake = stake,
		stops = stops,
		symbols = { a, b, c },
		window = window,
		multiplier = m,
		win = win,
		balance = self.balance,
		pending = self.pending,
		canGamble = self.pending > 0,
		winReels = { win > 0, win > 0, win > 0 and a == c },
		anticipation = a == b,
	}
end

-- A round of a lines table (T2), stops from rng: base stops, then the expanding symbol only
-- when free games are awarded, then the stops of each free game.
function Game:spinRound(stake)
	local tbl, rng = self.tbl, self.rng
	local function stopsOf(strips)
		local stops = {}
		for r = 1, #strips do
			stops[r] = rng(#strips[r])
		end
		return stops
	end
	local round = ns.Tables.playRound(tbl, stake, self.cap, {
		base = function() return stopsOf(tbl.reels) end,
		symbol = function() return rng(#tbl.expanding) end,
		free = function() return stopsOf(tbl.freeReels) end,
	})
	local win = round.win
	self.balance = self.balance - stake + win
	self.step = 0
	self.pending = (win > 0 and self.maxGamble > 0) and win or 0
	return {
		kind = "spin",
		stake = stake,
		win = win,
		balance = self.balance,
		pending = self.pending,
		canGamble = self.pending > 0,
		round = round,
	}
end

function Game:take()
	if self:state() ~= "gamble" then
		return nil, "no_gamble"
	end
	-- The amount that was at stake (the win, doubled once per won gamble step).
	local amount = self.pending
	self.pending = 0
	return { kind = "take", amount = amount, balance = self.balance }
end

function Game:gamble()
	if self:state() ~= "gamble" then
		return nil, "no_gamble"
	end
	local amount = self.pending
	self.step = self.step + 1
	local won = self.rng(2) == 0
	if won then
		self.balance = self.balance + amount
		local p = 2 * amount
		if self.step >= self.maxGamble or (self.cap > 0 and 2 * p > self.cap) then
			p = 0
		end
		self.pending = p
	else
		self.balance = self.balance - amount
		self.pending = 0
	end
	return {
		kind = "gamble",
		won = won,
		step = self.step,
		amount = amount,
		pending = self.pending,
		balance = self.balance,
		canGamble = self.pending > 0,
	}
end

function Game:refill()
	self.pending = 0
	self.step = 0
	self.balance = self.start
	return { kind = "refill", balance = self.balance }
end

-- Paytable data for display, shared with the guild game. A lines table gives
-- { kind = "lines", pays, lines, scatter, order, lineBet, rtp, hit, maxGamble }; the classic
-- table { kind = "classic", pair, triple, order, rtp, hit, maxGamble }.
function Solo.info(tbl, stake, cap, maxGamble)
	local stats = ns.Tables.stats(tbl, stake, cap)
	local info = {
		kind = tbl.kind,
		rtp = stats and stats.rtp or 0,
		hit = stats and stats.hit or 0,
		maxGamble = maxGamble,
	}
	if tbl.kind == "lines" then
		info.pays, info.lines, info.scatter, info.order = tbl.pays, tbl.lines, tbl.scatter, tbl.order
		info.lineBet = stake / tbl.lineCount
	else
		info.pair, info.triple, info.order = tbl.pair, tbl.triple, SYMBOL_ORDER
	end
	return info
end

function Game:info()
	return Solo.info(self.tbl, self.stake, self.cap, self.maxGamble)
end
