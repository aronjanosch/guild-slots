local t, ns = ...
local Plan, Tables = ns.Plan, ns.Tables

-- Presentation plans for T2 rounds built from fixed stops (strips in docs/table-t2-spec.md).
-- Base 1,16,0,0,0: line 5 M M M (30 at stake 10). Base 40,35,52,0,0: three books, four line
-- wins and a scatter win. Free 33,55,50,5,29 with M: retrigger and an expansion. Free 1,1,1,1,1
-- with M: nothing.

local T2 = Tables.get("T2")
local M_INDEX = 5

local TIMING = {
	stop = { 0.8, 1.05, 1.3, 1.55, 1.8 }, freeStop = { 0.75, 0.95, 1.15, 1.35, 1.55 },
	anticipation = 0.7, bounce = 0.22, allLines = 1.0, lineMin = 0.9, lineMax = 2.2,
	linePerStake = 0.04, scatterShow = 1.4, intro = 4.0, freePause = 0.35, retrigger = 1.6,
	expandReel = 0.35, expandHold = 0.4, summary = 3.0, bigWin = { 20, 50, 100 },
	bigCountUp = { 3.0, 4.5, 6.0 },
}

local function round(base, freeList, cap, stake)
	return Tables.playRound(T2, stake or 10, cap or 0, {
		base = function() return base end,
		symbol = function() return M_INDEX end,
		free = function(i) return freeList and freeList[i] or { 1, 1, 1, 1, 1 } end,
	})
end

local function sumAmounts(plan)
	local sum = 0
	for _, s in ipairs(plan.steps) do sum = sum + (s.amount or 0) end
	return sum
end

local function ofKind(plan, kind)
	local list = {}
	for _, s in ipairs(plan.steps) do
		if s.kind == kind then list[#list + 1] = s end
	end
	return list
end

local function checkTimes(plan)
	local at = 0
	for i, s in ipairs(plan.steps) do
		t.near(s.t, at, 1e-9, "step " .. i .. " starts where the last ended")
		t.ok(s.dur >= 0 and s.dur < 60, "step " .. i .. " has a finite duration")
		at = at + s.dur
	end
	t.near(plan.duration, at, 1e-9, "duration is the sum")
	t.ok(plan.duration < 1e4, "finite")
end

t.test("a losing round is one spin and an end with total 0", function()
	local p = Plan.build(round({ 0, 0, 0, 0, 0 }), TIMING)
	t.eq(p.steps[1].kind, "spin", "spin first")
	t.eq(p.steps[1].game, 0, "base game")
	t.eq(#ofKind(p, "line"), 0, "no lines")
	t.eq(p.steps[#p.steps].kind, "end", "end last")
	t.eq(p.steps[#p.steps].total, 0, "total 0")
	checkTimes(p)
end)

t.test("a line win: all lines flash, then the line, total counts to the win", function()
	local p = Plan.build(round({ 1, 16, 0, 0, 0 }), TIMING)
	local kinds = {}
	for i, s in ipairs(p.steps) do kinds[i] = s.kind end
	t.eq(table.concat(kinds, ","), "spin,allLines,line,end", "steps")
	local line = ofKind(p, "line")[1]
	t.eq(line.line.line, 5, "line 5")
	t.eq(line.amount, 30, "amount")
	t.eq(line.from, 0, "counts from 0")
	t.eq(line.total, 30, "to 30")
	t.eq(p.steps[#p.steps].total, 30, "end total")
	checkTimes(p)
end)

t.test("a bigger line win is shown longer, within the limits", function()
	local small = ofKind(Plan.build(round({ 1, 16, 0, 0, 0 }), TIMING), "line")[1]
	local big = ofKind(Plan.build(round({ 2, 16, 4, 4, 10 }), TIMING), "line")[1]
	t.ok(big.dur > small.dur, "longer")
	t.ok(small.dur >= TIMING.lineMin and big.dur <= TIMING.lineMax, "within limits")
end)

t.test("every win of a round with free games is shown and the amounts sum to the win", function()
	local r = round({ 40, 35, 52, 0, 0 }, { { 33, 55, 50, 5, 29 } })
	local p = Plan.build(r, TIMING)
	-- every line of the base game and of every free game has a line step
	local shown = {}
	for _, s in ipairs(ofKind(p, "line")) do shown[s.game .. ":" .. s.line.line] = true end
	for _, l in ipairs(r.lines) do t.ok(shown["0:" .. l.line], "base line " .. l.line) end
	for i, g in ipairs(r.free.games) do
		for _, l in ipairs(g.lines) do t.ok(shown[i .. ":" .. l.line], "game " .. i .. " line " .. l.line) end
	end
	t.eq(#ofKind(p, "scatter"), 2, "base and game 1 scatter wins")
	t.eq(#ofKind(p, "expand"), 1, "one expansion")
	t.eq(#ofKind(p, "expandWin"), 1, "its win")
	t.eq(ofKind(p, "expandWin")[1].amount, 300, "expansion amount")
	t.eq(sumAmounts(p), r.base + r.free.win, "amounts sum to the round win")
	t.eq(p.steps[#p.steps].total, r.win, "final total")
	t.eq(#ofKind(p, "spin"), 1 + r.free.awarded, "one spin per game")
	checkTimes(p)
end)

t.test("free-game steps: intro, counter grows on a retrigger, summary", function()
	local r = round({ 40, 35, 52, 0, 0 }, { { 33, 55, 50, 5, 29 } })
	local p = Plan.build(r, TIMING)
	local intro = ofKind(p, "intro")[1]
	t.ok(intro, "intro")
	t.eq(intro.freeOf, 10, "ten games announced")
	t.eq(intro.symbol, "M", "expanding symbol")
	local spins = ofKind(p, "spin")
	t.eq(spins[2].game, 1, "first free game")
	t.eq(spins[2].freeOf, 10, "of 10")
	t.eq(spins[2].free, true, "free strips")
	local re = ofKind(p, "retrigger")
	t.eq(#re, 1, "one retrigger")
	t.eq(re[1].added, 10, "+10")
	t.eq(re[1].freeOf, 20, "counter grows")
	t.eq(spins[3].freeOf, 20, "next game of 20")
	t.eq(spins[#spins].game, 20, "last game")
	local summary = ofKind(p, "summary")[1]
	t.eq(summary.amount, nil, "summary shows, adds nothing")
	t.eq(summary.freeWin, r.free.win, "summary total")
	t.eq(summary.games, 20, "games played")
	-- free running total never falls
	local last = 0
	for _, s in ipairs(p.steps) do
		t.ok(s.freeWin >= last, "free total grows")
		last = s.freeWin
	end
end)

t.test("groups: base, intro, each free game, end; ascending", function()
	local p = Plan.build(round({ 40, 35, 52, 0, 0 }, { { 33, 55, 50, 5, 29 } }), TIMING)
	local last = 0
	for _, s in ipairs(p.steps) do
		t.ok(s.group >= last, "groups ascend")
		last = s.group
	end
	t.eq(ofKind(p, "intro")[1].group, 1, "intro group")
	t.eq(ofKind(p, "spin")[2].group, 2, "free game 1 group")
	t.eq(p.steps[#p.steps].group, 22, "end group after 20 games")
	-- without free games the end belongs to the base group
	local q = Plan.build(round({ 1, 16, 0, 0, 0 }), TIMING)
	t.eq(q.steps[#q.steps].group, 0, "one group")
end)

t.test("with a cap no total exceeds the round win and the final total equals it", function()
	local r = round({ 40, 35, 52, 0, 0 }, { { 33, 55, 50, 5, 29 } }, 500)
	t.eq(r.win, 500, "capped round")
	local p = Plan.build(r, TIMING)
	for _, s in ipairs(p.steps) do t.ok(s.total <= 500, "total within the cap") end
	t.eq(p.steps[#p.steps].total, 500, "final total")
	t.eq(p.steps[#p.steps].capped, true, "end says capped")
	t.eq(sumAmounts(p), r.base + r.free.win, "amounts are the uncapped wins")
end)

t.test("big win thresholds pick the level", function()
	-- line 1 M M M M M: 750 at stake 10 = 75x -> level 2 (50x)
	local p = Plan.build(round({ 2, 16, 4, 4, 10 }), TIMING)
	local big = ofKind(p, "big")
	t.eq(#big, 1, "big win step")
	t.eq(big[1].level, 2, "huge")
	t.eq(big[1].dur, TIMING.bigCountUp[2], "longer count-up")
	t.eq(#ofKind(Plan.build(round({ 1, 16, 0, 0, 0 }), TIMING), "big"), 0, "3x is not big")
end)

t.test("tease starts after the reel that brings the second book", function()
	t.eq(Plan.tease({ { "B", "K", "S" }, { "K", "B", "S" }, { "K", "K", "K" }, { "K", "K", "K" }, { "K", "K", "K" } }, "B"), 3, "reels 1 and 2")
	t.eq(Plan.tease({ { "B", "K", "S" }, { "K", "S", "S" }, { "K", "K", "K" }, { "B", "K", "K" }, { "K", "K", "K" } }, "B"), 5, "reels 1 and 4")
	t.eq(Plan.tease({ { "B", "K", "S" }, { "K", "S", "S" }, { "K", "K", "K" }, { "K", "K", "K" }, { "B", "K", "K" } }, "B"), nil, "no reel left")
	t.eq(Plan.tease({ { "K", "K", "S" }, { "K", "S", "S" }, { "K", "K", "K" }, { "K", "K", "K" }, { "B", "K", "K" } }, "B"), nil, "one book")
	local p = Plan.build(round({ 40, 35, 52, 0, 0 }), TIMING)
	local spin = p.steps[1]
	t.eq(spin.tease, 3, "base window of the trigger teases from reel 3")
	t.near(spin.stopAt[2], 1.05, 1e-9, "reel 2 unchanged")
	t.near(spin.stopAt[3], 1.3 + 0.7, 1e-9, "reel 3 longer")
	t.near(spin.stopAt[5], 1.8 + 2.1, 1e-9, "reel 5 longest")
end)

local function window(cols)
	return { stake = 10, win = 0, base = 0, stops = { 0, 0, 0, 0, 0 }, window = cols, lines = {},
		scatter = { count = 0, win = 0 } }
end

t.test("tease kinds: two books, or reels 1-3 matching a top symbol on a line", function()
	local K = { "K", "K", "K" }
	local reel, kind = Plan.tease({ { "B", "K", "S" }, { "K", "B", "S" }, K, K, K }, "B", T2.lines, { "L", "C" })
	t.eq(reel, 3, "books from reel 3")
	t.eq(kind, "books", "books")
	local sym
	reel, kind, sym = Plan.tease({ { "K", "L", "S" }, { "K", "L", "S" }, { "K", "B", "S" }, K, K }, "B", T2.lines,
		{ "L", "C" })
	t.eq(reel, 4, "line tease from reel 4")
	t.eq(kind, "line", "line")
	t.eq(sym, "L", "on L, the book substitutes")
	reel, kind, sym = Plan.tease({ { "C", "K", "S" }, { "K", "C", "S" }, { "K", "K", "C" }, K, K }, "B", T2.lines,
		{ "L", "C" })
	t.eq(sym, "C", "line 4 (0,1,2) of crowns")
	t.eq(Plan.tease({ { "M", "K", "S" }, { "M", "K", "S" }, { "M", "K", "S" }, K, K }, "B", T2.lines, { "L", "C" }), nil,
		"only the top symbols")
	t.eq(Plan.tease({ { "L", "K", "S" }, { "L", "K", "S" }, { "L", "K", "S" }, K, K }, "B"), nil, "no line tease without lines")
end)

t.test("anticipation after two books: longer braking, hit or miss known in the plan", function()
	local timing = ns.Theme.timing
	local hit = Plan.build(round({ 40, 35, 52, 0, 0 }), timing).steps[1]
	t.eq(hit.teaseKind, "books", "books")
	t.eq(hit.teaseHit, true, "the third book came")
	t.eq(hit.decel[2], timing.decel, "reel 2 brakes as usual")
	t.ok(hit.decel[3] > timing.decel and hit.decel[5] > timing.decel, "teased reels brake longer")
	t.ok(hit.decel[3] <= hit.stopAt[3] - timing.nudgeTime - timing.accel, "braking fits the reel motion")
	local miss = Plan.build(round({ 40, 35, 0, 0, 0 }), timing).steps[1]
	t.eq(miss.tease, 3, "two books tease")
	t.eq(miss.teaseHit, false, "no third book")
	local none = Plan.build(round({ 0, 0, 0, 0, 0 }), timing).steps[1]
	t.eq(none.tease, nil, "no tease")
	t.eq(none.teaseHit, nil, "nothing to hit")
end)

t.test("line tease: reels 4 and 5 get a short extra delay", function()
	local timing = ns.Theme.timing
	local K = { "K", "K", "K" }
	local p = Plan.build(window({ { "K", "L", "S" }, { "K", "L", "S" }, { "K", "L", "S" }, K, K }), timing)
	local s = p.steps[1]
	t.eq(s.tease, 4, "from reel 4")
	t.eq(s.teaseKind, "line", "line")
	t.eq(s.teaseHit, false, "no four of a kind")
	t.near(s.stopAt[3], timing.stop[3], 1e-9, "reel 3 as usual")
	t.near(s.stopAt[4], timing.stop[4] + timing.lineTease, 1e-9, "reel 4 later")
	t.near(s.stopAt[5], timing.stop[5] + 2 * timing.lineTease, 1e-9, "reel 5 later still")
	t.eq(s.decel[5], timing.decel, "normal braking")
end)

t.test("turbo: shorter, all line wins at once, same amounts and end state", function()
	local r = round({ 40, 35, 52, 0, 0 }, { { 33, 55, 50, 5, 29 } })
	local normal = Plan.build(r, ns.Theme.timing)
	local turbo = Plan.build(r, ns.Theme.timingTurbo)
	t.ok(turbo.duration < normal.duration * 0.6, "clearly shorter: " .. turbo.duration .. " vs " .. normal.duration)
	t.eq(#ofKind(turbo, "line"), 0, "no single line steps")
	t.eq(#ofKind(turbo, "scatter"), 0, "scatter inside the all-lines step")
	t.eq(ofKind(turbo, "allLines")[1].amount, r.base, "base game wins in one step")
	t.eq(sumAmounts(turbo), r.base + r.free.win, "amounts still sum to the round win")
	t.eq(turbo.steps[#turbo.steps].total, normal.steps[#normal.steps].total, "same final total")
	t.ok(ofKind(turbo, "intro")[1].dur > 0 and ofKind(turbo, "big")[1].dur > 0, "intro and big win kept")
	t.ok(ofKind(turbo, "intro")[1].dur < ofKind(normal, "intro")[1].dur, "intro shorter")
	checkTimes(turbo)
	local s = turbo.steps[1]
	for i = 1, 5 do
		t.ok(s.decel[i] <= s.stopAt[i] - ns.Theme.timingTurbo.nudgeTime - ns.Theme.timingTurbo.accel,
			"turbo braking fits reel " .. i)
	end
end)

t.test("big win: the banner steps up through the tiers, ticks rise in pitch", function()
	local r = round({ 40, 35, 52, 0, 0 }, { { 33, 55, 50, 5, 29 } }) -- 1185 at stake 10: 118.5x
	local timing = ns.Theme.timing
	local big = ofKind(Plan.build(r, timing), "big")[1]
	t.eq(big.level, 3, "legendary")
	t.eq(#big.tiers, 3, "three tier steps")
	t.eq(big.tiers[1].at, 0, "BIG WIN at once")
	t.ok(big.tiers[2].at > 0 and big.tiers[3].at > big.tiers[2].at and big.tiers[3].at < big.count, "then up")
	-- the count reaches the threshold at the tier step
	for i = 2, 3 do
		local v = ns.Anim.countUp(0, 1185, big.tiers[i].at + 1e-6, big.count)
		t.ok(math.abs(v - timing.bigWin[i] * 10) <= 1, "tier " .. i .. " when the count passes it: " .. v)
	end
	t.near(big.count, timing.bigCountUp[3] * timing.bigCount, 1e-9, "count length")
	t.ok(#big.ticks >= 10, "ticks through the count")
	t.eq(big.ticks[1].n, 1, "lowest tick first")
	local last = 0
	for _, k in ipairs(big.ticks) do
		t.ok(k.n >= last and k.n <= timing.tickLadder, "pitch rises")
		t.ok(k.at < big.count, "within the count")
		last = k.n
	end
	t.eq(last, timing.tickLadder, "ends on the highest tick")
	local huge = ofKind(Plan.build(round({ 2, 16, 4, 4, 10 }), timing), "big")[1]
	t.eq(#huge.tiers, 2, "75x steps to HUGE only")
end)
