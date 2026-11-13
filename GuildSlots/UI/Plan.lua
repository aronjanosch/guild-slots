local _, ns = ...

-- Presentation plan: turns a round of a lines table (docs/table-t2-spec.md section 6) into a
-- timed list of steps the slot window plays one after another. Pure Lua, no WoW API; tested by
-- tests/test_plan.lua.
--
-- Plan.build(round, timing, tbl) -> { steps = { step, ... }, duration }
-- Every step has
--   kind      "spin" | "allLines" | "line" | "scatter" | "retrigger" | "expand" | "expandWin"
--             | "intro" | "summary" | "big" | "end"
--   t, dur    start and length in seconds (a spin ends when its reels are done; dur is the plan)
--   group     0 base game, 1 free-game intro, 1 + i free game i, then the closing steps (which
--             belong to group 0 when there are no free games); skipping jumps to the next group
--   game      0 base game, i free game i
--   total     round total shown after the step (never above round.win)
--   freeOf    free games known after the step (0 in the base game)
--   freeWin   sum of the free-game wins shown after the step
--   amount    the win this step adds (line, scatter, expandWin only); amounts sum to
--             round.base + free.win, before the cap
--   from      total shown before the step (steps with an amount)
-- Kind fields:
--   spin      stops, window, free (boolean: free strips), stopAt (landing time per reel, tease
--             included), tease (first teased reel or nil), delay (pause before the reels start)
--   allLines  lines (winning lines of the game), scatter (the game's scatter table)
--   line      line (entry { line, symbol, count, win })
--   scatter   count
--   retrigger added
--   expand    reels, symbol
--   expandWin count, symbol
--   intro     symbol
--   summary   games
--   big       level (1..#timing.bigWin)
--   end       capped (true when the cap lowered the round win)

local Plan = {}
ns.Plan = Plan

-- First reel that gets anticipation: the reel after the one that brings the second book, if
-- there is one. window[r] = { top, mid, bottom }.
function Plan.tease(window, wild)
	local books = 0
	for r = 1, #window do
		local col = window[r]
		for row = 1, 3 do
			if col[row] == wild then books = books + 1 end
		end
		if books >= 2 then
			return r < #window and r + 1 or nil
		end
	end
	return nil
end

local function lineDur(timing, amount, stake)
	local d = timing.lineMin + timing.linePerStake * amount / stake
	if d > timing.lineMax then d = timing.lineMax end
	return d
end

function Plan.build(round, timing, tbl)
	tbl = tbl or ns.Tables.get("T2")
	local wild, award, maxFree = tbl.scatter.symbol, tbl.scatter.games, tbl.maxFree
	local stake, cap = round.stake, round.win
	local steps, at = {}, 0
	local state = { group = 0, game = 0, running = 0, freeOf = 0, freeWin = 0 }

	local function add(step, dur)
		step.t, step.dur = at, dur
		step.group, step.game = state.group, state.game
		if step.amount then
			step.from = state.running < cap and state.running or cap
			state.running = state.running + step.amount
			if state.game > 0 then
				state.freeWin = state.freeWin + step.amount
			end
		end
		step.total = state.running < cap and state.running or cap
		step.freeOf, step.freeWin = state.freeOf, state.freeWin
		steps[#steps + 1] = step
		at = at + dur
		return step
	end

	local function spin(game, free, delay)
		local times = free and timing.freeStop or timing.stop
		local tease = Plan.tease(game.window, wild)
		local stopAt, last = {}, 0
		for r = 1, #times do
			local s = times[r]
			if tease and r >= tease then
				s = s + timing.anticipation * (r - tease + 1)
			end
			stopAt[r] = s
			if s > last then last = s end
		end
		add({ kind = "spin", stops = game.stops, window = game.window, free = free, stopAt = stopAt,
			tease = tease, delay = delay }, delay + last + timing.bounce)
	end

	-- Line wins, scatter, retrigger and expansion of one window.
	local function wins(game)
		if #game.lines > 0 or game.scatter.win > 0 then
			add({ kind = "allLines", lines = game.lines, scatter = game.scatter }, timing.allLines)
		end
		for _, l in ipairs(game.lines) do
			add({ kind = "line", line = l, amount = l.win }, lineDur(timing, l.win, stake))
		end
		if game.scatter.win > 0 then
			add({ kind = "scatter", count = game.scatter.count, amount = game.scatter.win }, timing.scatterShow)
		end
	end

	spin(round, false, 0)
	wins(round)

	local free = round.free
	if free then
		state.group, state.freeOf = 1, award
		add({ kind = "intro", symbol = free.symbol }, timing.intro)
		for i, game in ipairs(free.games) do
			state.group, state.game = 1 + i, i
			spin(game, true, timing.freePause)
			wins(game)
			if game.retrigger then
				local known = state.freeOf + award
				if known > maxFree then known = maxFree end
				local added = known - state.freeOf
				if added > 0 then
					state.freeOf = known
					add({ kind = "retrigger", added = added }, timing.retrigger)
				end
			end
			if game.expand then
				local e = game.expand
				add({ kind = "expand", reels = e.reels, symbol = free.symbol },
					timing.expandReel * #e.reels + timing.expandHold)
				add({ kind = "expandWin", count = e.count, symbol = free.symbol, amount = e.win },
					lineDur(timing, e.win, stake))
			end
		end
		state.group, state.game = 2 + #free.games, 0
		add({ kind = "summary", games = free.awarded }, timing.summary)
	end

	local level = 0
	for i, x in ipairs(timing.bigWin) do
		if round.win >= x * stake then level = i end
	end
	if level > 0 then
		add({ kind = "big", level = level }, timing.bigCountUp[level])
	end
	add({ kind = "end", capped = state.running > round.win }, 0)
	return { steps = steps, duration = at }
end
