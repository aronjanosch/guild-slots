local _, ns = ...

-- Presentation plan: turns a round of a lines table (docs/table-t2-spec.md section 6) into a
-- timed list of steps the slot window plays one after another. Pure Lua, no WoW API; tested by
-- tests/test_plan.lua.
--
-- Plan.build(round, timing, tbl) -> { steps = { step, ... }, duration }
-- timing is a timing set from UI/Theme.lua (Theme.timing, or Theme.timingTurbo in turbo mode);
-- the same set drives the reels, so a spin step's stopAt and decel fit the reel motion.
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
--   amount    the win this step adds (line, scatter, expandWin, and allLines when the timing set
--             shows all line wins at once); amounts sum to round.base + free.win, before the cap
--   from      total shown before the step (steps with an amount)
-- Kind fields:
--   spin      stops, window, free (boolean: free strips), stopAt (landing time per reel, tease
--             included), decel (braking time per reel), tease (first teased reel or nil),
--             teaseKind ("books": two tomes down; "line": reels 1-3 match a top symbol on a
--             line), teaseHit (the tease came true: a third tome, or four of a kind of that
--             symbol), delay (pause before the reels start)
--   allLines  lines (winning lines of the game), scatter (the game's scatter table)
--   line      line (entry { line, symbol, count, win })
--   scatter   count
--   retrigger added
--   expand    reels, symbol
--   expandWin count, symbol
--   intro     symbol, bought (true: a bought series, no tomes on the reels)
--   summary   games
--   big       level (1..#timing.bigWin, the final one), count (length of the count-up), tiers
--             ({ at, level } from level 1 at 0 up to `level`: when the counted amount passes
--             each threshold), ticks ({ at, n }: a count tick every timing.tierTick, n =
--             1..timing.tickLadder rising with the counted amount)
--   end       capped (true when the cap lowered the round win)
--
-- A bought series (round.bought, Tables.playBought) has no base game: the plan starts with the
-- intro.

local Plan = {}
ns.Plan = Plan

-- Symbol of reels 1..last on line `rows` when they all match (wild substitutes), else nil.
local function lineStart(window, rows, last, wild)
	local target
	for r = 1, last do
		local sym = window[r][rows[r] + 1]
		if sym ~= wild then
			if target == nil then
				target = sym
			elseif sym ~= target then
				return nil
			end
		end
	end
	return target
end

-- First reel that gets anticipation, and why. window[r] = { top, mid, bottom }.
--   "books": the reel after the one that brings the second book, if there is one.
--   "line":  only with `lines` and `symbols`: reels 1-3 match one of `symbols` on a line (wild
--            substitutes), so reels 4 and 5 may bring four or five of a kind. Returns 4, "line"
--            and the symbol (the first of `symbols` that matches).
-- Books win over a line.
function Plan.tease(window, wild, lines, symbols)
	local books = 0
	for r = 1, #window do
		local col = window[r]
		for row = 1, 3 do
			if col[row] == wild then books = books + 1 end
		end
		if books >= 2 then
			if r < #window then
				return r + 1, "books"
			end
			break
		end
	end
	if lines and symbols and #window > 3 then
		for _, want in ipairs(symbols) do
			for _, rows in ipairs(lines) do
				if lineStart(window, rows, 3, wild) == want then
					return 4, "line", want
				end
			end
		end
	end
	return nil
end

-- Whether a tease came true: books - the game has `trigger` or more books; line - a line of
-- `symbol` with four or more.
local function teaseHit(game, kind, symbol, trigger)
	if kind == "books" then
		return game.scatter.count >= trigger
	end
	for _, l in ipairs(game.lines) do
		if l.symbol == symbol and l.count >= 4 then
			return true
		end
	end
	return false
end

local function lineDur(timing, amount, stake)
	local d = timing.lineMin + timing.linePerStake * amount / stake
	if d > timing.lineMax then d = timing.lineMax end
	return d
end

-- The big-win step for a round total `total` at `level` (Plan.build adds t, dur and the rest).
-- The count-up runs over timing.bigCount of the step with Anim.countUp's ease-out, so the
-- amount v is reached at u = 1 - sqrt(1 - v / total) of the count. The banner starts at level 1
-- and steps up when the amount passes each further threshold.
function Plan.big(level, total, stake, timing)
	local dur = timing.bigCountUp[level]
	local count = dur * (timing.bigCount or 0.8)
	local tiers = { { at = 0, level = 1 } }
	for i = 2, level do
		local f = total > 0 and timing.bigWin[i] * stake / total or 1
		if f > 1 then f = 1 end
		tiers[i] = { at = count * (1 - math.sqrt(1 - f)), level = i }
	end
	local ticks, every, ladder = {}, timing.tierTick or 0.1, timing.tickLadder or 8
	local i = 0
	while i * every < count - 1e-9 do
		local u = i * every / count
		local v = 1 - (1 - u) * (1 - u) -- share of the amount counted so far
		local n = 1 + math.floor(v * ladder)
		if n > ladder then n = ladder end
		ticks[#ticks + 1] = { at = i * every, n = n }
		i = i + 1
	end
	return { kind = "big", level = level, count = count, tiers = tiers, ticks = ticks }
end

function Plan.build(round, timing, tbl)
	tbl = tbl or ns.Tables.get("T2")
	local wild, award, maxFree = tbl.scatter.symbol, tbl.scatter.games, tbl.maxFree
	local trigger = tbl.scatter.trigger
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

	-- A reel needs nudge + ramp + braking before it lands, and Anim.plan may move the landing up
	-- to half a row earlier: a longer braking never takes more than that leaves.
	local lead = (timing.nudgeTime or 0) + (timing.accel or 0) + 1 / (timing.speed or 28)

	local function spin(game, free, delay)
		local times = free and timing.freeStop or timing.stop
		local tease, kind, symbol = Plan.tease(game.window, wild, tbl.lines, timing.teaseSymbols)
		local stopAt, decel, last = {}, {}, 0
		for r = 1, #times do
			local s, d = times[r], timing.decel
			if tease and r >= tease then
				local k = r - tease + 1
				if kind == "books" then
					s = s + timing.anticipation * k
					if timing.teaseDecel then
						local long = math.min(timing.teaseDecel, s - lead)
						if d == nil or long > d then d = long end
					end
				else
					s = s + (timing.lineTease or 0) * k
				end
			end
			stopAt[r], decel[r] = s, d
			if s > last then last = s end
		end
		local hit
		if tease then
			hit = teaseHit(game, kind, symbol, trigger)
		end
		add({ kind = "spin", stops = game.stops, window = game.window, free = free, stopAt = stopAt, decel = decel,
			tease = tease, teaseKind = kind, teaseHit = hit, delay = delay }, delay + last + timing.bounce)
	end

	-- Line wins and scatter of one window: all lines flash, then one by one; or, when the timing
	-- set says so (turbo), everything at once in one step.
	local function wins(game)
		if #game.lines == 0 and game.scatter.win <= 0 then
			return
		end
		if timing.linesAtOnce then
			local sum = game.scatter.win
			for _, l in ipairs(game.lines) do sum = sum + l.win end
			add({ kind = "allLines", lines = game.lines, scatter = game.scatter, amount = sum }, timing.allLines)
			return
		end
		add({ kind = "allLines", lines = game.lines, scatter = game.scatter }, timing.allLines)
		for _, l in ipairs(game.lines) do
			add({ kind = "line", line = l, amount = l.win }, lineDur(timing, l.win, stake))
		end
		if game.scatter.win > 0 then
			add({ kind = "scatter", count = game.scatter.count, amount = game.scatter.win }, timing.scatterShow)
		end
	end

	if not round.bought then
		spin(round, false, 0)
		wins(round)
	end

	local free = round.free
	if free then
		state.group, state.freeOf = 1, award
		add({ kind = "intro", symbol = free.symbol, bought = round.bought or nil }, timing.intro)
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
		add(Plan.big(level, round.win, stake, timing), timing.bigCountUp[level])
	end
	add({ kind = "end", capped = state.running > round.win }, 0)
	return { steps = steps, duration = at }
end
