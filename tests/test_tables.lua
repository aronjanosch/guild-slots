local t, ns = ...
local Tables = ns.Tables

local T1 = Tables.get("T1")

t.test("T1 strip has 34 stops and the expected symbol counts", function()
	t.eq(#T1.reels[1], 34, "stops")
	t.eq(#T1.reels[2], 34, "stops reel 2")
	t.eq(#T1.reels[3], 34, "stops reel 3")
	local counts = {}
	for _, sym in ipairs(T1.reels[1]) do
		counts[sym] = (counts[sym] or 0) + 1
	end
	t.eq(counts.K, 10, "K")
	t.eq(counts.S, 8, "S")
	t.eq(counts.G, 6, "G")
	t.eq(counts.T, 4, "T")
	t.eq(counts.W, 3, "W")
	t.eq(counts.M, 2, "M")
	t.eq(counts.D, 1, "D")
end)

t.test("get returns T1 and nil for unknown or bad ids", function()
	t.eq(T1.id, "T1", "id")
	t.eq(Tables.get("T9"), nil, "unknown id")
	t.eq(Tables.get(""), nil, "empty id")
	t.eq(Tables.get(nil), nil, "nil id")
end)

t.test("symbols returns the three symbols at 0-based stops", function()
	local a, b, c = Tables.symbols(T1, 0, 1, 2)
	t.eq(a, "K", "reel 1")
	t.eq(b, "S", "reel 2")
	t.eq(c, "G", "reel 3")
end)

t.test("symbols rejects bad stops", function()
	local a, code = Tables.symbols(T1, 34, 0, 0)
	t.eq(a, nil, "stop 34")
	t.eq(code, "bad_stop", "code")
	t.eq(Tables.symbols(T1, -1, 0, 0), nil, "stop -1")
	t.eq(Tables.symbols(T1, 1.5, 0, 0), nil, "stop 1.5")
	t.eq(Tables.symbols(T1, "0", 0, 0), nil, "stop as string")
	t.eq(Tables.symbols(nil, 0, 0, 0), nil, "nil table")
end)

t.test("multiplier for a triple", function()
	-- stop 0 is K, stop 19 is D
	t.eq(Tables.multiplier(T1, 0, 0, 0), 5, "triple K")
	t.eq(Tables.multiplier(T1, 19, 19, 19), 500, "triple D")
end)

t.test("multiplier for a pair: reels 1 and 2 equal, reel 3 different", function()
	-- stops 1,1,0 -> S,S,K: pair S pays 2
	t.eq(Tables.multiplier(T1, 1, 1, 0), 2, "pair S")
	-- stops 0,0,1 -> K,K,S: pair K pays 1
	t.eq(Tables.multiplier(T1, 0, 0, 1), 1, "pair K")
end)

t.test("reels 2 and 3 equal only pays nothing", function()
	-- stops 0,1,1 -> K,S,S
	t.eq(Tables.multiplier(T1, 0, 1, 1), 0, "reels 2 and 3 equal")
end)

t.test("nothing pays nothing", function()
	-- stops 0,1,2 -> K,S,G
	t.eq(Tables.multiplier(T1, 0, 1, 2), 0, "all different")
end)

t.test("multiplier rejects bad stops", function()
	local m, code = Tables.multiplier(T1, 0, 0, 40)
	t.eq(m, nil, "stop 40")
	t.eq(code, "bad_stop", "code")
end)

t.test("window at stop 0 wraps to the end of the strip", function()
	-- strip[34] = S, strip[1] = K, strip[2] = S
	local above, centre, below = Tables.window(T1, 1, 0)
	t.eq(above, "S", "above")
	t.eq(centre, "K", "centre")
	t.eq(below, "S", "below")
end)

t.test("window at stop 33 wraps to the start of the strip", function()
	-- strip[33] = K, strip[34] = S, strip[1] = K
	local above, centre, below = Tables.window(T1, 2, 33)
	t.eq(above, "K", "above")
	t.eq(centre, "S", "centre")
	t.eq(below, "K", "below")
end)

t.test("window rejects bad reel and stop", function()
	local a, code = Tables.window(T1, 4, 0)
	t.eq(a, nil, "reel 4")
	t.eq(code, "bad_reel", "code")
	t.eq(Tables.window(T1, 1, 34), nil, "stop 34")
end)

t.test("win without cap is stake times multiplier", function()
	t.eq(Tables.win(T1, 10, 0, 0, 0, 0), 50, "triple K at 10")
	t.eq(Tables.win(T1, 10, 0, 19, 19, 19), 5000, "triple D at 10")
	t.eq(Tables.win(T1, 10, 0, 0, 1, 2), 0, "nothing")
end)

t.test("win with cap is limited to the cap", function()
	t.eq(Tables.win(T1, 100, 1000, 19, 19, 19), 1000, "capped")
	t.eq(Tables.win(T1, 100, 0, 19, 19, 19), 50000, "uncapped")
	t.eq(Tables.win(T1, 100, 1000, 0, 1, 2), 0, "nothing under cap")
end)

t.test("win rejects bad stake and cap", function()
	local w, code = Tables.win(T1, 0, 0, 0, 0, 0)
	t.eq(w, nil, "stake 0")
	t.eq(code, "bad_stake", "code")
	t.eq(Tables.win(T1, 10, -1, 0, 0, 0), nil, "negative cap")
end)

t.test("stats without cap: rtp, hit, variance and combos", function()
	local s = Tables.stats(T1, 10, 0)
	t.near(s.rtp, 4594 / 4913, 1e-12, "rtp")
	t.near(s.hit, 0.19896193771626297, 1e-12, "hit")
	t.near(s.variance, 22.0578643193107, 1e-9, "variance")
	t.eq(s.combos, 39304, "combos")
end)

t.test("stats with a cap has lower rtp and variance", function()
	local open = Tables.stats(T1, 100, 0)
	local capped = Tables.stats(T1, 100, 1000)
	t.ok(capped.rtp < open.rtp, "rtp lowered by cap")
	t.ok(capped.variance < open.variance, "variance lowered by cap")
	t.eq(capped.combos, 39304, "combos")
end)

t.test("stats cap of 1000 at stake 100 limits the effective multiplier to 10", function()
	-- Independent check: effective multiplier = min(m, 10) over all 34^3 combinations.
	local sum, sumSq = 0, 0
	for a = 0, 33 do
		for b = 0, 33 do
			for c = 0, 33 do
				local m = Tables.multiplier(T1, a, b, c)
				local e = math.min(m, 10)
				sum = sum + e
				sumSq = sumSq + e * e
			end
		end
	end
	local rtp = sum / 39304
	local capped = Tables.stats(T1, 100, 1000)
	t.near(capped.rtp, rtp, 1e-12, "rtp")
	t.near(capped.variance, sumSq / 39304 - rtp * rtp, 1e-9, "variance")
	t.ok(capped.rtp < Tables.stats(T1, 100, 0).rtp, "capped rtp below open rtp")
end)

t.test("stats is cached per (id, stake, cap)", function()
	local a = Tables.stats(T1, 100, 1000)
	local b = Tables.stats(T1, 100, 1000)
	t.ok(rawequal(a, b), "same table returned")
	t.ok(not rawequal(a, Tables.stats(T1, 100, 0)), "different cap, different entry")
end)

t.test("stats rejects bad stake and cap", function()
	local s, code = Tables.stats(T1, 0, 0)
	t.eq(s, nil, "stake 0")
	t.eq(code, "bad_stake", "code")
	t.eq(Tables.stats(T1, 10, -5), nil, "negative cap")
end)
