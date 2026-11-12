local _, ns = ...

-- Paytable overlay of the slot window (state 09 of the design): the real pays of the shown
-- table at the current stake, and the ten lines of the game as small diagrams in their
-- colours. Built once for a lines table; update() fills in the numbers.

local L, Theme, Skin = ns.L, ns.Theme, ns.Skin

local Paytable = {}
ns.Paytable = Paytable

local NONE = "–"

-- f: the slot window. W: its widget table (gets paytable, ptContent, ptUnsupported, ptRows,
-- ptBook, ptRtp, ptGamble, ptClose). tbl: the lines table whose order and lines are drawn.
function Paytable.build(f, W, tbl, symbolName, onClose)
	local Lay, c, fs = Theme.layout, Theme.colors, Theme.fontSize
	local r = Lay.ptPanel
	local ox, oy = r[1], r[2]
	local pt = Skin.panel(f, f, r, "overlay")
	pt:EnableMouse(true) -- nothing under the overlay takes clicks
	W.paytable = pt

	local title = Skin.textIn(pt, pt, Lay.ptTitle, "title", fs.heading, c.gold, "LEFT", ox, oy)
	title:SetText(L.PAYTABLE_TITLE)
	W.ptClose = Skin.button(pt, "icon", Lay.ptClose[3], Lay.ptClose[4], onClose,
		{ icon = Theme.icons.close, iconOnly = true, iconSize = Lay.iconSize - 2 })
	Skin.rect(W.ptClose, pt, Lay.ptClose, ox, oy)

	W.ptUnsupported = Skin.text(pt, "label", fs.message, c.muted, "CENTER")
	W.ptUnsupported:SetPoint("CENTER", pt, "CENTER", 0, 0)
	W.ptUnsupported:SetText(L.UNSUPPORTED_TABLE)

	local content = CreateFrame("Frame", nil, pt)
	content:SetAllPoints(pt)
	W.ptContent = content

	local info = Lay.ptInfo
	W.ptRtp = Skin.textIn(content, pt, { info[1], info[2], info[3], info[4] / 2 }, "label", fs.payNote, c.muted,
		"RIGHT", ox, oy)
	W.ptGamble = Skin.textIn(content, pt, { info[1], info[2] + info[4] / 2, info[3], info[4] / 2 }, "label",
		fs.payNote, c.muted, "RIGHT", ox, oy)

	local head = Skin.textIn(content, pt, Lay.ptSymbolHead, "label", fs.label, c.muted, "LEFT", ox, oy)
	head:SetText(L.PT_SYMBOL)
	local cols = Lay.ptCols
	for j = 1, 4 do
		local h = Skin.textIn(content, pt, { cols[j], Lay.ptHeadY, Lay.ptColW, 16 }, "label", fs.payHead, c.muted,
			"RIGHT", ox, oy)
		h:SetText((6 - j) .. "×")
	end

	-- One row per symbol, best first; columns 5x, 4x, 3x, 2x.
	W.ptRows = {}
	local rowH = Lay.ptRowH
	for i, sym in ipairs(tbl.order) do
		local y = Lay.ptRowY + (i - 1) * rowH
		if i % 2 == 1 then
			local band = Skin.fill(content, "BACKGROUND", c.rowBand, 1)
			Skin.rect(band, pt, { Lay.ptBand[1], y, Lay.ptBand[2], rowH }, ox, oy)
		end
		local icon = content:CreateTexture(nil, "ARTWORK")
		icon:SetTexture(Theme.symbols[sym])
		Skin.rect(icon, pt, { Lay.ptIcon, y, rowH, rowH }, ox, oy)
		local high = i <= 4 or sym == tbl.scatter.symbol
		local name = Skin.textIn(content, pt, { Lay.ptName[1], y, Lay.ptName[2], rowH }, "label", fs.payName,
			high and c.goldLight or c.text, "LEFT", ox, oy)
		name:SetText(symbolName(sym))
		local cells = {}
		for j = 1, 4 do
			cells[6 - j] = Skin.textIn(content, pt, { cols[j], y, Lay.ptColW, rowH }, "number", fs.payValue,
				c.number, "RIGHT", ox, oy)
		end
		W.ptRows[sym] = cells
	end

	local note = Lay.ptNote
	W.ptBook = Skin.text(content, "label", fs.payNote, c.muted, "LEFT")
	Skin.rect(W.ptBook, pt, note, ox, oy)
	Skin.call(W.ptBook, "SetJustifyV", "TOP")
	Skin.call(W.ptBook, "SetWordWrap", true)

	-- The game's lines as 5 x 3 diagrams in their colours.
	local d, step, cell, pitch, off, num = Lay.ptDiagram, Lay.ptDiagramStep, Lay.ptDiagramCell,
		Lay.ptDiagramPitch, Lay.ptDiagramOff, Lay.ptDiagramNum
	for li, rows in ipairs(tbl.lines) do
		local bx = d[1] + ((li - 1) % 5) * step[1]
		local by = d[2] + math.floor((li - 1) / 5) * step[2]
		local color = c.lines[li]
		local n = Skin.textIn(content, pt, { bx + num[1], by + num[2], num[3], num[4] }, "number", fs.payLine, color,
			"LEFT", ox, oy)
		n:SetText(tostring(li))
		for row = 0, 2 do
			for reel = 1, #rows do
				local on = rows[reel] == row
				local t = Skin.fill(content, "ARTWORK", on and color or c.diagramOff)
				Skin.rect(t, pt, { bx + off[1] + (reel - 1) * pitch[1], by + off[2] + row * pitch[2], cell[1], cell[2] },
					ox, oy)
			end
		end
	end
	pt:Hide()
	return pt
end

-- info: game:info() of the shown game; stake: its current stake.
function Paytable.update(W, info, stake, fmt)
	if info.kind ~= "lines" then
		W.ptContent:Hide()
		W.ptUnsupported:Show()
		return
	end
	W.ptUnsupported:Hide()
	W.ptContent:Show()
	local c = Theme.colors
	local wild = info.scatter.symbol
	for sym, cells in pairs(W.ptRows) do
		for k = 2, 5 do
			local p
			if sym == wild then
				local sp = info.scatter.pays[k]
				p = sp and sp * stake
			else
				local pays = info.pays[sym]
				p = pays and pays[k] and pays[k] * info.lineBet
			end
			cells[k]:SetText(p and fmt(p) or NONE)
			Skin.color(cells[k], p and c.number or c.payNone)
		end
	end
	W.ptBook:SetText(string.format(L.PAY_NOTE, fmt(stake), fmt(info.lineBet)))
	W.ptRtp:SetText(string.format(L.RTP, info.rtp * 100))
	W.ptGamble:SetText(string.format(L.GAMBLE_RULE, info.maxGamble))
end
