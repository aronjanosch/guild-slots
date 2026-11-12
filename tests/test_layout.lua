local t, ns = ...
local Layout, Tables = ns.Layout, ns.Tables

-- Window geometry from design/gildenslots-v2/SPEC.md: reel field at 60, 154, cells 96, markers
-- centred at x 33 and 567, lines drawn from x 44 to 556. The lines are the game's (T2), not the
-- design's example lines.
local G = { left = 60, top = 154, cell = 96, xIn = 44, xOut = 556 }
local LINES = Tables.get("T2").lines

t.test("left markers sit at the row where a line starts, stacked in line order", function()
	local y = Layout.markerY(LINES, 1, G.top, G.cell)
	-- row 0 starts lines 2, 4, 9, 10; row 1 lines 1, 6, 7; row 2 lines 3, 5, 8
	t.eq(y[2], 166) t.eq(y[4], 190) t.eq(y[9], 214) t.eq(y[10], 238)
	t.eq(y[1], 266) t.eq(y[6], 298) t.eq(y[7], 330)
	t.eq(y[3], 362) t.eq(y[5], 394) t.eq(y[8], 426)
end)

t.test("right markers sit at the row where a line ends on reel 5", function()
	local y = Layout.markerY(LINES, 2, G.top, G.cell)
	-- row 0 ends lines 2, 4, 8, 10; row 1 lines 1, 6, 7; row 2 lines 3, 5, 9
	t.eq(y[2], 166) t.eq(y[4], 190) t.eq(y[8], 214) t.eq(y[10], 238)
	t.eq(y[1], 266) t.eq(y[6], 298) t.eq(y[7], 330)
	t.eq(y[3], 362) t.eq(y[5], 394) t.eq(y[9], 426)
end)

t.test("a line runs from its left marker through the cell centres to its right marker", function()
	local left, right = Layout.markerY(LINES, 1, G.top, G.cell), Layout.markerY(LINES, 2, G.top, G.cell)
	local p = Layout.linePoints(LINES[4], left[4], right[4], G) -- 0 1 2 1 0
	t.eq(#p, 7, "marker, five centres, marker")
	t.eq(p[1][1], 44) t.eq(p[1][2], 190)
	t.eq(p[2][1], 108) t.eq(p[2][2], 202)
	t.eq(p[3][1], 204) t.eq(p[3][2], 298)
	t.eq(p[4][1], 300) t.eq(p[4][2], 394)
	t.eq(p[6][1], 492) t.eq(p[6][2], 202)
	t.eq(p[7][1], 556) t.eq(p[7][2], 190)
end)

t.test("fallback staircase: axis-parallel segments through the reel borders", function()
	local s = Layout.staircase(LINES[1], G) -- straight through the middle
	t.eq(#s, 1, "one straight segment")
	t.eq(s[1][1], 44) t.eq(s[1][2], 298) t.eq(s[1][3], 556) t.eq(s[1][4], 298)
	s = Layout.staircase(LINES[7], G) -- 1 0 0 0 1
	-- middle row to the border of reels 1 and 2, up, top row to the border of reels 4 and 5, down
	t.eq(#s, 5)
	t.eq(s[1][1], 44) t.eq(s[1][3], 156) t.eq(s[1][2], 298)
	t.eq(s[2][1], 156) t.eq(s[2][2], 298) t.eq(s[2][4], 202)
	t.eq(s[3][1], 156) t.eq(s[3][3], 444) t.eq(s[3][2], 202)
	t.eq(s[4][1], 444) t.eq(s[4][4], 298)
	t.eq(s[5][3], 556)
	for _, seg in ipairs(s) do
		t.ok(seg[1] == seg[3] or seg[2] == seg[4], "axis-parallel")
	end
end)
