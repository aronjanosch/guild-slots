local _, ns = ...

-- Geometry of the pay lines and their markers in the slot window. Pure Lua, no WoW API; tested
-- by tests/test_layout.lua. Coordinates are window pixels from the top left, y downwards.
--
-- g (geometry): left, top = top left of the reel field; cell = cell size; xIn, xOut = x where a
-- drawn line leaves the left marker and reaches the right one.

local Layout = {}
ns.Layout = Layout

-- Centre y of every line's marker on one side (1 left: the row the line starts in on reel 1,
-- 2 right: the row it ends in on the last reel). Markers that share a row split it evenly, in
-- line order. Returns { [line] = y }.
function Layout.markerY(lines, side, top, cell)
	local groups = {}
	for li, rows in ipairs(lines) do
		local row = side == 1 and rows[1] or rows[#rows]
		groups[row] = groups[row] or {}
		local g = groups[row]
		g[#g + 1] = li
	end
	local y = {}
	for row, ids in pairs(groups) do
		local n = #ids
		for j, li in ipairs(ids) do
			y[li] = top + row * cell + (j - 0.5) * cell / n
		end
	end
	return y
end

local function centreX(g, r)
	return g.left + (r - 1) * g.cell + g.cell / 2
end

local function centreY(g, row)
	return g.top + row * g.cell + g.cell / 2
end

-- Points of a line: left marker, the centre of its cell on every reel, right marker.
function Layout.linePoints(rows, yLeft, yRight, g)
	local p = { { g.xIn, yLeft } }
	for r = 1, #rows do
		p[#p + 1] = { centreX(g, r), centreY(g, rows[r]) }
	end
	p[#p + 1] = { g.xOut, yRight }
	return p
end

-- The same line as axis-parallel segments { x1, y1, x2, y2 } (for clients without lines):
-- horizontal through the cell centres, a vertical step on the border between two reels.
-- Neighbouring horizontal parts are merged.
function Layout.staircase(rows, g)
	local segs = {}
	local x, y = g.xIn, centreY(g, rows[1])
	local function to(nx, ny)
		local last = segs[#segs]
		if ny == y and last and last[2] == y and last[4] == y then
			last[3] = nx
		elseif nx ~= x or ny ~= y then
			segs[#segs + 1] = { x, y, nx, ny }
		end
		x, y = nx, ny
	end
	for r = 1, #rows - 1 do
		local ny = centreY(g, rows[r + 1])
		if ny ~= y then
			local border = g.left + r * g.cell
			to(border, y)
			to(border, ny)
		end
	end
	to(g.xOut, y)
	return segs
end
