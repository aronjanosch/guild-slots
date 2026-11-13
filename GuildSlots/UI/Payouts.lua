local _, ns = ...

-- The Payouts tab of the officer window (docs/payout-spec.md, officer side): the payout requests
-- addressed to this officer, newest first, and the review of the selected one: the traffic light
-- of the recalculation (Core/Verify.lua report), the balance, the findings, the luck index and the
-- look-ahead. The officer pays gold by hand in the game, then confirms here (two clicks), or
-- rejects. The add-on never moves gold or items. Statuses and codes it does not know are shown
-- raw. Layout in Theme.officer.payouts.

local L, Theme, Skin, Roster = ns.L, ns.Theme, ns.Skin, ns.Roster

local Payouts = {}
ns.Payouts = Payouts

-- Officer statuses still open (Game/Guild.lua OFFICER_OPEN).
local OPEN = { fetching = true, checking = true, ready = true }
Payouts.OPEN = OPEN

local LUCK = { "total", "timing", "risk" }
local LEVEL_COLOR = { red = "statusBad", yellow = "statusOpen" }

local W, host
-- sel: selected reqId. mode: "review", "confirm" (asked once more) or "reject" (choosing a
-- reason). note/noteColor: the line above the buttons. seen: reqIds already announced.
local P = { sel = nil, mode = "review", note = nil, noteColor = nil, seen = {}, acc = 0 }
Payouts.state = P

local function lookup(prefix, code)
	return rawget(L, prefix .. tostring(code))
end

local function clock(s)
	local env = s and s.env
	if env and type(env.now) == "function" then
		local ok, t = pcall(env.now)
		if ok and type(t) == "number" then
			return t
		end
	end
	return 0
end

local function num(v)
	return tonumber(v) or 0
end

-- "1g 20s 5c" for an amount of tokens at X tokens per gold (display only, core-spec section 3).
local function goldText(tokens)
	local s = Roster.settings()
	local rate = s and tonumber(s.X) or 1000
	if rate < 1 then rate = 1 end
	local copper = math.floor(num(tokens) * 10000 / rate + 0.5)
	local parts = {}
	local g, sv, cp = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	if g > 0 then parts[#parts + 1] = string.format(L.COIN_G, g) end
	if sv > 0 then parts[#parts + 1] = string.format(L.COIN_S, sv) end
	if cp > 0 or #parts == 0 then parts[#parts + 1] = string.format(L.COIN_C, cp) end
	return table.concat(parts, " ")
end
Payouts.goldText = goldText

-- Badge text of a request status.
local function badgeText(r)
	local st = r.status
	if st == "fetching" then
		return string.format(L.PAY_B_fetching, num(r.received), num(r.total))
	elseif st == "checking" then
		return string.format(L.PAY_B_checking, math.floor(num(r.progress) * 100))
	elseif st == "failed" then
		return string.format(L.PAY_B_failed, tostring(r.code or "?"))
	end
	return lookup("PAY_B_", st) or tostring(st)
end
Payouts.badgeText = badgeText

local function setBadge(b, status, text)
	local spec = Theme.payout.badge[status]
	if spec then
		b:setStatus(spec[1], spec[2], text)
	else
		b:setStatus("statusNone", "white", text)
	end
end

local function secondsLeft(s, r)
	local left = Theme.payout.lifetime - (clock(s) - num(r.time))
	if left < 0 then left = 0 end
	return math.ceil(left)
end

-- Number of open requests (the count on the tab).
function Payouts.openCount(s)
	local n = 0
	if s then
		for _, r in ipairs(s:requests()) do
			if OPEN[r.status] then n = n + 1 end
		end
	end
	return n
end

-- A "request" event: true when it is a new open request this window has not seen yet.
function Payouts.isNew(data)
	if type(data) ~= "table" or not data.reqId or P.seen[data.reqId] then
		return false
	end
	P.seen[data.reqId] = true
	if OPEN[data.status] then
		-- A new request is selected on the next refresh unless a decision is being made.
		P.next = data.reqId
		return true
	end
	return false
end

local function setNote(str, color)
	P.note, P.noteColor = str, color
end

---------------------------------------------------------------------------------------------
-- Refresh

local function selected(list)
	for _, r in ipairs(list) do
		if r.reqId == P.sel then
			return r
		end
	end
end

local function fillList(s, list)
	local fmt = host.fmt
	for i, row in ipairs(W.payRows) do
		local r = list[i]
		if r then
			row.reqId = r.reqId
			row.label:SetText(tostring(r.player))
			row.amount:SetText(fmt(num(r.amount)))
			setBadge(row.badge, r.status, badgeText(r))
			row.secs:SetText(OPEN[r.status] and string.format(L.PAY_SECS, secondsLeft(s, r)) or "")
			row:setSelected(r.reqId == P.sel)
			row:Show()
		else
			row.reqId = nil
			row:Hide()
		end
	end
	W.payNone:SetShown(#list == 0)
end

local function fillFindings(report)
	local c = Theme.colors
	local list = type(report.findings) == "table" and report.findings or {}
	local rows = W.payFindingRows
	local n = #rows
	for i, row in ipairs(rows) do
		local f = list[i]
		if f and i == n and #list > n then
			row.dot:Hide()
			row.text:SetText(string.format(L.PAY_MORE, #list - n + 1))
			Skin.color(row.text, c.muted)
			row.text:Show()
		elseif f then
			local text = lookup("FIND_", f.code) or string.format(L.FIND_UNKNOWN, tostring(f.code))
			if type(f.index) == "number" then
				text = text .. string.format(L.FIND_ENTRY, f.index)
			end
			row.text:SetText(text)
			Skin.color(row.text, f.level == "red" and c.lose or c.text)
			Skin.color(row.dot, c[LEVEL_COLOR[f.level] or "statusNone"])
			row.dot:Show()
			row.text:Show()
		else
			row.dot:Hide()
			row.text:Hide()
		end
	end
	W.payNoFindings:SetShown(#list == 0)
end

local function zText(v)
	if type(v) == "table" and type(v.z) == "number" then
		return string.format("%.2f", v.z)
	end
	return "–"
end

local function fillLuck(report)
	local luck = type(report.luck) == "table" and report.luck or {}
	for i, key in ipairs(LUCK) do
		local row, v = W.payLuckRows[i], luck[key]
		row.z:SetText(zText(v))
		if type(v) ~= "table" then
			row.badge:setStatus("statusNone", "white", L.LUCK_NA)
		elseif not v.enough then
			row.badge:setStatus("statusNone", "white", L.LUCK_LOW)
		else
			local key2 = Theme.payout.light[v.light]
			row.badge:setStatus(key2 or "statusNone", "white", lookup("LIGHT_", v.light) or tostring(v.light))
		end
	end
	W.paySpins:SetText(string.format(L.LUCK_SPINS, num(luck.spins), host.fmt(num(luck.maxWin))))
	local la = report.lookahead
	if type(la) == "table" then
		W.payLookahead:SetText(string.format(L.PAY_LOOKAHEAD, num(la.count), string.format("%.1f", num(la.sum)),
			string.format("%.1f", num(la.expected))))
	else
		W.payLookahead:SetText(L.PAY_LOOKAHEAD_NA)
	end
end

local function fillReport(r, report)
	local c, fmt = Theme.colors, host.fmt
	local light = report.light
	local key = Theme.payout.light[light]
	W.payLight:setStatus(key or "statusNone", "white", lookup("LIGHT_", light) or tostring(light))
	local lc = c[key or "statusNone"]
	W.payLightGlow:SetVertexColor(lc[1], lc[2], lc[3], 1)
	local balance = type(report.balance) == "number" and report.balance or nil
	W.payBalance:SetText(balance and fmt(balance) or "–")
	W.payAmount:SetText(fmt(num(r.amount)))
	if balance then
		local after = balance - num(r.amount)
		W.payAfter:SetText(after < 0 and ("-" .. fmt(-after)) or fmt(after))
		Skin.color(W.payAfter, after < 0 and c.lose or c.number)
	else
		W.payAfter:SetText("–")
		Skin.color(W.payAfter, c.number)
	end
	fillFindings(report)
	fillLuck(report)
end

local function fillButtons(r, red)
	local open, ready = r and OPEN[r.status], r and r.status == "ready"
	-- A mode that no longer fits the request's status falls back to the review.
	if (P.mode == "confirm" and not ready) or (P.mode == "reject" and not open) then
		P.mode = "review"
	end
	local mode = P.mode
	W.payConfirm:SetShown(mode ~= "reject")
	W.payConfirm.label:SetText(mode == "confirm" and L.PAY_CONFIRM2 or L.PAY_CONFIRM)
	W.payConfirm:setEnabled(ready and true or false)
	W.payReject:SetShown(mode == "review")
	W.payReject:setEnabled(open and true or false)
	W.payBack:SetShown(mode ~= "review")
	W.payDeclined:SetShown(mode == "reject")
	W.payMismatch:SetShown(mode == "reject" and red)
end

function Payouts.refresh(s)
	if not W or not W.payoutsPart then
		return
	end
	local c = Theme.colors
	local list = s and s:requests() or {}
	if P.next and P.mode == "review" then
		for _, r in ipairs(list) do
			if r.reqId == P.next then
				P.sel = r.reqId
				setNote(nil)
			end
		end
		P.next = nil
	end
	if P.sel and not selected(list) then
		P.sel, P.mode = nil, "review"
	end
	if not P.sel then
		-- The newest open request, else the newest one.
		for _, r in ipairs(list) do
			if OPEN[r.status] then
				P.sel = r.reqId
				break
			end
		end
	end
	fillList(s, list)

	local r = selected(list)
	local report = r and type(r.report) == "table" and r.report or nil
	W.payReviewHead:SetText(r and Skin.upper(string.format(L.PAY_REVIEW, tostring(r.player))) or "")
	if report then
		W.payHint:Hide()
		W.payReport:Show()
		fillReport(r, report)
	else
		W.payReport:Hide()
		if not r then
			W.payHint:SetText(L.PAY_SELECT)
		elseif OPEN[r.status] then
			W.payHint:SetText(L.PAY_WAIT_REPORT)
		else
			W.payHint:SetText(string.format(L.PAY_NO_REPORT, badgeText(r)))
		end
		W.payHint:Show()
	end
	local red = report and report.light == "red" or false
	W.payActions:SetShown(r ~= nil)
	fillButtons(r, red)
	if P.mode == "confirm" and r then
		local ask = string.format(L.PAY_ASK, goldText(r.amount), tostring(r.player), host.fmt(num(r.amount)))
		W.payNote:SetText((red and L.PAY_ASK_RED or "") .. ask)
		Skin.color(W.payNote, red and c.lose or c.goldLight)
	elseif P.mode == "reject" then
		W.payNote:SetText(L.PAY_ASK_REASON)
		Skin.color(W.payNote, c.muted)
	else
		W.payNote:SetText(P.note or "")
		Skin.color(W.payNote, P.noteColor or c.muted)
	end
end

-- From the officer window's OnUpdate while the tab is shown: countdowns and progress.
function Payouts.tick(elapsed, s)
	P.acc = P.acc + elapsed
	if P.acc < Theme.payout.refresh then
		return false
	end
	P.acc = 0
	Payouts.refresh(s)
	return true
end

---------------------------------------------------------------------------------------------
-- Actions

local function confirm()
	local s, c = host.session(), Theme.colors
	if not s or not P.sel then
		return
	end
	if P.mode ~= "confirm" then
		P.mode = "confirm"
		setNote(nil)
		host.refresh()
		return
	end
	local sel
	for _, r in ipairs(s:requests()) do
		if r.reqId == P.sel then sel = r end
	end
	local id, code = s:confirm(P.sel)
	P.mode = "review"
	if id then
		setNote(string.format(L.PAY_DONE, host.fmt(num(sel and sel.amount)), tostring(sel and sel.player)), c.goldLight)
	else
		setNote(lookup("PAYERR_", code) or string.format(L.PAYERR, tostring(code)), c.lose)
	end
	host.refresh()
end

local function reject()
	if not P.sel then
		return
	end
	P.mode = "reject"
	setNote(nil)
	host.refresh()
end

local function reason(why, label)
	local s, c = host.session(), Theme.colors
	if not s or not P.sel then
		return
	end
	local ok, code = s:reject(P.sel, why)
	P.mode = "review"
	if ok then
		setNote(string.format(L.PAY_REJECTED, label), c.lose)
	else
		setNote(lookup("PAYERR_", code) or string.format(L.PAYERR, tostring(code)), c.lose)
	end
	host.refresh()
end

local function back()
	P.mode = "review"
	setNote(nil)
	host.refresh()
end

---------------------------------------------------------------------------------------------
-- Building

-- part: the tab's section frame (window x, y from the section top). widgets: the officer
-- window's widget table (gets payoutsPart, payRows, payNone, payReviewHead, payHint, payReport,
-- payLight, payLightGlow, payBalance, payAmount, payAfter, payFindingRows, payNoFindings,
-- payLuckRows, paySpins, payLookahead, payNote, payActions, payConfirm, payReject, payBack,
-- payDeclined, payMismatch). callbacks: session(), fmt(n), refresh().
function Payouts.build(part, widgets, callbacks)
	W, host = widgets, callbacks
	W.payoutsPart = part
	local Pp, c, fs = Theme.officer.payouts, Theme.colors, Theme.fontSize

	local function heading(r, str)
		local h = Skin.textIn(part, part, r, "label", fs.section, c.goldLight, "LEFT")
		h:SetText(Skin.upper(str))
		return h
	end
	local function wrapped(parent, r, color, size)
		local t = Skin.text(parent, "label", size or fs.small, color or c.muted, "LEFT")
		Skin.rect(t, part, r)
		Skin.call(t, "SetJustifyV", "TOP")
		Skin.call(t, "SetWordWrap", true)
		return t
	end

	-- Requests.
	heading(Pp.heading, L.PAY_LIST)
	local list = Skin.panel(part, part, Pp.list, "inset")
	W.payRows = {}
	local rr = Pp.row
	for i = 1, Pp.rows do
		local row
		row = Skin.listRow(list, part, { rr[1], rr[2] + (i - 1) * rr[4], rr[3], rr[4] }, function()
			if row.reqId and row.reqId ~= P.sel then
				P.sel, P.mode = row.reqId, "review"
				setNote(nil)
				host.refresh()
			end
		end, Pp.rName[1])
		row.label:SetWidth(Pp.rName[2])
		row.amount = Skin.textIn(row, row, { Pp.rAmount[1], 0, Pp.rAmount[2], rr[4] }, "number", fs.listNumber, c.number,
			"RIGHT")
		row.badge = Skin.badge(row, row, Pp.rBadge, fs.small)
		row.secs = Skin.textIn(row, row, { Pp.rSecs[1], 0, Pp.rSecs[2], rr[4] }, "numberMedium", fs.small, c.muted,
			"RIGHT")
		row:Hide()
		W.payRows[i] = row
	end
	W.payNone = Skin.textIn(list, part, Pp.none, "label", fs.small, c.muted, "LEFT")
	W.payNone:SetText(L.PAY_NONE)

	-- Review.
	W.payReviewHead = Skin.textIn(part, part, Pp.reviewHead, "label", fs.section, c.goldLight, "LEFT")
	W.payHint = wrapped(part, Pp.hint, c.muted, fs.small)

	local rep = CreateFrame("Frame", nil, part)
	rep:SetAllPoints(part)
	W.payReport = rep
	local g, out = Pp.light, Pp.lightGlowOut
	W.payLightGlow = rep:CreateTexture(nil, "BACKGROUND")
	W.payLightGlow:SetTexture(Theme.tex.glowSoft)
	Skin.rect(W.payLightGlow, part, { g[1] - out, g[2] - out, g[3] + 2 * out, g[4] + 2 * out })
	Skin.add(W.payLightGlow)
	W.payLight = Skin.badge(rep, part, Pp.light, fs.heading)
	Skin.font(W.payLight.text, "title", fs.heading)
	local labels = { L.PAY_BALANCE, L.PAY_REQUESTED, L.PAY_AFTER }
	local values = {}
	for i, str in ipairs(labels) do
		local y = Pp.numY + (i - 1) * Pp.numH
		local l = Skin.textIn(rep, part, { Pp.numLabel[1], y, Pp.numLabel[2], Pp.numH }, "label", fs.small, c.muted, "LEFT")
		l:SetText(str)
		values[i] = Skin.textIn(rep, part, { Pp.numValue[1], y, Pp.numValue[2], Pp.numH }, "number", fs.listNumber,
			c.number, "RIGHT")
	end
	W.payBalance, W.payAmount, W.payAfter = values[1], values[2], values[3]

	local fh = Skin.textIn(rep, part, Pp.findingsHead, "label", fs.section, c.goldLight, "LEFT")
	fh:SetText(Skin.upper(L.PAY_FINDINGS))
	local fp = Skin.panel(rep, part, Pp.findings, "inset")
	W.payFindingRows = {}
	for i = 1, Pp.fRows do
		local y = Pp.fRowY + (i - 1) * Pp.fRowH
		local row = {}
		row.dot = Skin.fill(fp, "ARTWORK", c.statusNone)
		Skin.rect(row.dot, part, { Pp.fDot[1], y + Pp.fDot[2], Pp.fDot[3], Pp.fDot[4] })
		row.text = Skin.textIn(fp, part, { Pp.fText[1], y, Pp.fText[2], Pp.fRowH }, "label", fs.small, c.text, "LEFT")
		row.dot:Hide()
		row.text:Hide()
		W.payFindingRows[i] = row
	end
	W.payNoFindings = Skin.textIn(fp, part, { Pp.fText[1] - 16, Pp.fRowY, Pp.fText[2], Pp.fRowH }, "label", fs.small,
		c.muted, "LEFT")
	W.payNoFindings:SetText(L.PAY_NO_FINDINGS)

	local lh = Skin.textIn(rep, part, Pp.luckHead, "label", fs.section, c.goldLight, "LEFT")
	lh:SetText(Skin.upper(L.PAY_LUCK))
	local lp = Skin.panel(rep, part, Pp.luck, "inset")
	W.payLuckRows = {}
	for i, key in ipairs(LUCK) do
		local y = Pp.lRowY + (i - 1) * Pp.lRowH
		local row = {}
		local name = Skin.textIn(lp, part, { Pp.lName[1], y, Pp.lName[2], Pp.lRowH }, "label", fs.small, c.text, "LEFT")
		name:SetText(L["LUCK_" .. key])
		row.z = Skin.textIn(lp, part, { Pp.lZ[1], y, Pp.lZ[2], Pp.lRowH }, "number", fs.listNumber, c.number, "RIGHT")
		row.badge = Skin.badge(lp, part, { Pp.lBadge[1], y + Pp.lBadge[2], Pp.lBadge[3], Pp.lBadge[4] }, fs.small)
		W.payLuckRows[i] = row
	end
	W.paySpins = Skin.textIn(lp, part, Pp.spins, "label", fs.small, c.muted, "LEFT")
	local ln = wrapped(rep, Pp.luckNote, c.muted, fs.label)
	ln:SetText(L.LUCK_NOTE)
	W.payLookahead = Skin.textIn(rep, part, Pp.lookahead, "label", fs.small, c.text, "LEFT")

	-- Note and buttons.
	local actions = CreateFrame("Frame", nil, part)
	actions:SetAllPoints(part)
	W.payActions = actions
	W.payNote = wrapped(actions, Pp.note, c.muted, fs.small)
	local function button(style, r, label, fn, opts)
		local b = Skin.button(actions, style, r[3], r[4], fn, opts)
		Skin.rect(b, part, r)
		b.label:SetText(label)
		return b
	end
	W.payConfirm = button("primary", Pp.confirm, L.PAY_CONFIRM, confirm, { size = fs.gambleNumber })
	W.payReject = button("danger", Pp.reject, L.PAY_REJECT, reject, { size = fs.button })
	W.payBack = button("secondary", Pp.back, L.PAY_BACK, back)
	W.payDeclined = button("danger", Pp.reason1, L.PAY_DECLINED, function() reason("declined", L.PAY_DECLINED) end,
		{ size = fs.button })
	W.payMismatch = button("danger", Pp.reason2, L.PAY_MISMATCH, function() reason("mismatch", L.PAY_MISMATCH) end,
		{ size = fs.button })
	W.payBack:Hide()
	W.payDeclined:Hide()
	W.payMismatch:Hide()
	rep:Hide()
	return part
end
