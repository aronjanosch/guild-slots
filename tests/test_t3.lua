local t, ns = ...
local Tables, Settings, Solo = ns.Tables, ns.Settings, ns.Solo

-- Table T3 (docs/table-t3-spec.md): every rule of T2 with retuned strips and a return of about
-- 92 %. The rules are T2's (tests/test_t2.lua); here: the definition, the statistics, Settings
-- and the solo default.

local T2, T3 = Tables.get("T2"), Tables.get("T3")

local function strip(list)
	return table.concat(list)
end

t.test("T3 is a lines table with T2's rules", function()
	t.ok(T3, "T3 exists")
	t.eq(T3.id, "T3", "id")
	t.eq(T3.kind, "lines", "kind")
	for _, k in ipairs({ "rows", "lineCount", "maxFree", "buyPrice" }) do
		t.eq(T3[k], T2[k], k)
	end
	-- One definition of the rules serves both tables.
	for _, k in ipairs({ "lines", "pays", "scatter", "expanding", "order" }) do
		t.eq(T3[k], T2[k], k .. " shared with T2")
	end
end)

t.test("T3 strips: T2's lengths and tome positions, two stops differ", function()
	local changed = {}
	for _, which in ipairs({ "reels", "freeReels" }) do
		for r = 1, 5 do
			local a, b = T2[which][r], T3[which][r]
			t.eq(#b, #a, which .. " " .. r .. " length")
			for i = 1, #a do
				t.eq(b[i] == "B", a[i] == "B", which .. " " .. r .. " tome at stop " .. (i - 1))
				if a[i] ~= b[i] then
					changed[#changed + 1] = which .. r .. ":" .. (i - 1) .. ":" .. a[i] .. b[i]
				end
			end
		end
	end
	t.eq(table.concat(changed, " "), "reels2:37:DK freeReels1:30:DK", "changed stops")
	t.eq(strip(T3.reels[2]), "KTGWSKWGKTWGKSWGMKSTWGSMGKTDSLCWKMTBCKWG", "base reel 2")
	t.eq(strip(T3.freeReels[1]), "SKGTWGKSTWKGWKSMTKGWDSMKDTGMSWKTKBTWLSGKC", "free reel 1")
	-- T2 is untouched.
	t.eq(T2.reels[2][38], "D", "T2 base reel 2 stop 37")
	t.eq(T2.freeReels[1][31], "D", "T2 free reel 1 stop 30")
end)

t.test("T3 statistics: about 92 %, free games as often as in T2", function()
	local s3, s2 = Tables.stats(T3, 10, 0), Tables.stats(T2, 10, 0)
	t.near(s3.rtp, 0.92, 0.002, "rtp")
	t.eq(s3.freeRate, s2.freeRate, "free-game rate unchanged")
	t.ok(math.abs(s3.hit - s2.hit) <= 0.02, "hit rate within 0.02 of T2")
	t.ok(s3.variance > 0, "variance")
	t.eq(Tables.stats(T3, 100, 500), s3, "same constants for every stake and cap")
end)

t.test("T3 rounds use the shared lines code", function()
	-- Base stops whose window includes base reel 2 stop 37: the D there is a K now.
	local a = Tables.evaluate(T3, { 0, 37, 0, 0, 0 }, 10)
	local b = Tables.evaluate(T2, { 0, 37, 0, 0, 0 }, 10)
	t.eq(a.window[2][2], "K", "T3 middle")
	t.eq(b.window[2][2], "D", "T2 middle")
	t.eq(a.window[1][1], b.window[1][1], "other reels equal")
end)

t.test("Settings: T=T3 is valid, its stakes are multiples of 10", function()
	local s = assert(Settings.parse("GSLOTS1;E=10,50,100;T=T3"))
	t.eq(s.T, "T3", "table")
	local _, code = Settings.parse("GSLOTS1;E=10,15;T=T3")
	t.eq(code, "bad_stakes", "stake 15")
	t.eq(Settings.parse("GSLOTS1").T, "T1", "the default table stays T1 (pinned by the vectors)")
end)

t.test("Solo plays T3 by default", function()
	local g = Solo.new({ rng = function() return 0 end })
	t.eq(g.tbl.id, "T3", "default table")
	local info = g:info()
	t.near(info.rtp, 0.92, 0.002, "info rtp")
	t.eq(info.buy.price, T3.buyPrice, "buy price from the table")
	t.eq(Solo.new({ table = "T2", rng = function() return 0 end }).tbl.id, "T2", "T2 on request")
end)
