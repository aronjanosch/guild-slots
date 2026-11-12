local _, ns = ...

-- Cash-out overlay of the slot window in guild mode (docs/payout-spec.md): the player asks an
-- officer for a payout of tokens. While no request is open it shows a form (amount, officers
-- online with the add-on); while a request is open, and once it has ended until the player closes
-- it, the request's state. The officer pays by hand in the game; the add-on only records it.
-- Statuses and codes it does not know are shown raw in a generic line.
-- Look: the paytable / no-tokens panels; layout in Theme.layout.cashout.

local L, Theme, Skin, Roster = ns.L, ns.Theme, ns.Skin, ns.Roster

local Cashout = {}
ns.Cashout = Cashout

-- Player statuses that lock the game (Game/Guild.lua PLAYER_OPEN).
local OPEN = { wait_officer = true, sending = true, wait_decision = true }
Cashout.OPEN = OPEN

local W -- the slot window's widgets
local host -- callbacks into the slot window, see Cashout.build
-- shown: overlay visible. tracked: reqIds this window followed. starts: reqId -> session clock
-- at the request (for the countdown). acked: the finished request the player closed.
local C = { shown = false, tracked = {}, starts = {}, acked = nil, officer = nil, acc = 0, names = {} }
Cashout.state = C

local function lookup(prefix, code)
	return rawget(L, prefix .. tostring(code))
end

local function session()
	return host and host.session() or nil
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

-- The request the overlay shows: an open one, or a finished one this window followed and the
-- player has not closed yet. nil: the form.
function Cashout.current()
	local s = session()
	local p = s and s:payout()
	if type(p) ~= "table" then
		return nil
	end
	if OPEN[p.status] then
		return p
	end
	if p.reqId and C.tracked[p.reqId] and p.reqId ~= C.acked then
		return p
	end
	return nil
end

function Cashout.isOpen()
	local s = session()
	local p = s and s:payout()
	return type(p) == "table" and OPEN[p.status] == true
end

-- The Cash out button: re-opens a shown request, else needs a playable account with tokens.
function Cashout.canOpen(game)
	if Cashout.current() then
		return true
	end
	local st = game:status()
	return (st == "ok" or st == "no_funds") and (game.balance or 0) > 0
end

function Cashout.isShown()
	return C.shown
end

-- Officers heard online with the add-on; the own name only with the self test.
local function officers(s)
	local names = C.names
	for i = #names, 1, -1 do
		names[i] = nil
	end
	local self = host.allowSelf()
	for _, o in ipairs(s:online()) do
		if (o.name ~= s.me or self) and Roster.isOfficer(o.name) then
			names[#names + 1] = o.name
		end
	end
	return names
end

local function setError(str)
	W.coError:SetText(str or "")
end

---------------------------------------------------------------------------------------------
-- Refresh

local function fillForm(s)
	local names = officers(s)
	local keep = false
	for _, n in ipairs(names) do
		if n == C.officer then keep = true end
	end
	if not keep then
		C.officer = names[1]
	end
	for i, row in ipairs(W.coOfficerRows) do
		local n = names[i]
		if n then
			row.name = n
			row.label:SetText(n)
			row:setSelected(n == C.officer)
			row:Show()
		else
			row.name = nil
			row:Hide()
		end
	end
	W.coNoOfficer:SetShown(#names == 0)
	W.coRequest:setEnabled(#names > 0)
end

local function secondsLeft(s, p)
	local start = C.starts[p.reqId] or p.started or p.time
	if type(start) ~= "number" then
		start = clock(s)
		C.starts[p.reqId] = start
	end
	local left = Theme.payout.lifetime - (clock(s) - start)
	if left < 0 then left = 0 end
	return math.ceil(left)
end

local function subLine(p)
	local fmt = host.fmt
	local st, code = p.status, p.code
	if OPEN[st] then
		return string.format(L.PO_REQ_SUB, fmt(tonumber(p.amount) or 0), tostring(p.officer))
	elseif st == "paid" then
		return string.format(L.PO_PAID, fmt(tonumber(p.amount) or 0), tostring(p.officer))
	elseif st == "expired" then
		return L.PO_EXPIRED
	elseif st == "rejected" then
		return string.format(L.PO_REASON, lookup("REASON_", code) or string.format(L.PO_FAIL_CODE, tostring(code)))
	end
	return string.format(L.PO_REASON, lookup("PO_FAIL_", code) or string.format(L.PO_FAIL_CODE, tostring(code or st)))
end

local function fillState(s, p)
	local c, Lay = Theme.colors, Theme.layout.cashout
	local st = p.status
	local open = OPEN[st] == true
	W.coStateTitle:SetText(lookup("PO_S_", st) or tostring(st))
	Skin.color(W.coStateTitle, st == "paid" and c.goldLight or open and c.text or c.lose)
	W.coStateSub:SetText(subLine(p))

	local frac
	if st == "sending" then
		local total = tonumber(p.total) or 0
		frac = total > 0 and (tonumber(p.sent) or 0) / total or 0
	elseif st == "wait_decision" or st == "paid" then
		frac = 1
	end
	if frac then
		local w = Lay.bar[3] - 2 * Lay.barInset
		W.coBarFill:SetWidth(math.max(0.01, math.min(1, frac) * w))
		W.coBarFill:SetShown(frac > 0)
		W.coBar:Show()
	else
		W.coBar:Hide()
	end

	if open then
		local left = string.format(L.PO_LEFT, secondsLeft(s, p))
		if st == "sending" then
			left = string.format(L.PO_SENT, tonumber(p.sent) or 0, tonumber(p.total) or 0) .. " · " .. left
		end
		W.coTimer:SetText(left)
		W.coLock:SetText(L.PO_LOCKED)
		W.coHide.label:SetText(L.PO_HIDE)
	else
		W.coTimer:SetText("")
		W.coLock:SetText("")
		W.coHide.label:SetText(L.PO_CLOSE)
	end
end

function Cashout.update()
	if not W or not W.cashoutPanel then
		return
	end
	if not C.shown then
		W.cashoutPanel:Hide()
		return
	end
	local s = session()
	if not s then
		C.shown = false
		W.cashoutPanel:Hide()
		return
	end
	W.cashoutPanel:Show()
	local p = Cashout.current()
	if p then
		W.coForm:Hide()
		W.coState:Show()
		fillState(s, p)
	else
		W.coState:Hide()
		W.coForm:Show()
		fillForm(s)
	end
end

---------------------------------------------------------------------------------------------
-- Actions

function Cashout.show()
	local s = session()
	if not s or not W then
		return
	end
	C.shown = true
	if not Cashout.current() then
		local game = s:game()
		W.coAmount:SetText(tostring(game.balance or 0))
		setError("")
	end
	C.acc = 0
	Cashout.update()
	host.refresh()
end

-- Hides the overlay; a finished request counts as seen and the form comes back next time.
function Cashout.hide()
	local p = Cashout.current()
	if p and not OPEN[p.status] then
		C.acked = p.reqId
	end
	C.shown = false
	if W and W.cashoutPanel then
		W.cashoutPanel:Hide()
		if W.coAmount.ClearFocus then W.coAmount:ClearFocus() end
	end
	if host then host.refresh() end
end

function Cashout.toggle()
	if C.shown then
		Cashout.hide()
	else
		Cashout.show()
	end
end

-- Hides without counting a finished request as seen (mode switch, round start).
function Cashout.conceal()
	C.shown = false
	if W and W.cashoutPanel then
		W.cashoutPanel:Hide()
	end
end

local function request()
	local s = session()
	if not s then
		return
	end
	local game = s:game()
	local raw = (W.coAmount:GetText() or ""):gsub("%s", "")
	local amount = raw:match("^%d+$") and tonumber(raw) or nil
	if not amount or amount < 1 or amount > (game.balance or 0) then
		setError(string.format(L.PO_ERR_bad_amount, host.fmt(game.balance or 0)))
		return
	end
	if not C.officer then
		setError(L.PO_PICK_OFFICER)
		return
	end
	local reqId, code = s:requestPayout(C.officer, amount)
	if not reqId then
		if code == "bad_amount" then
			setError(string.format(L.PO_ERR_bad_amount, host.fmt(game.balance or 0)))
		else
			setError(lookup("PO_ERR_", code) or string.format(L.PO_ERR, tostring(code)))
		end
		return
	end
	C.tracked[reqId] = true
	C.starts[reqId] = C.starts[reqId] or clock(s)
	setError("")
	host.afterRequest(string.format(L.PO_REQUESTED, C.officer))
	Cashout.update()
end

-- "payout" event from the session. Returns true when the request was just paid out.
function Cashout.onPayout(data)
	if type(data) ~= "table" or not data.reqId then
		return false
	end
	local s = session()
	if OPEN[data.status] then
		if not C.starts[data.reqId] then
			C.starts[data.reqId] = data.started or data.time or clock(s)
		end
		C.tracked[data.reqId] = true
	elseif C.tracked[data.reqId] or C.starts[data.reqId] then
		-- The end of a followed request is shown even when the overlay was hidden.
		if host.guildMode() and data.reqId ~= C.acked then
			C.shown = true
		end
	end
	Cashout.update()
	return data.status == "paid"
end

-- From the slot window's OnUpdate: refreshes countdown and progress once per Theme.payout.refresh.
function Cashout.tick(elapsed)
	if not C.shown then
		return
	end
	C.acc = C.acc + elapsed
	if C.acc < Theme.payout.refresh then
		return
	end
	C.acc = 0
	Cashout.update()
end

---------------------------------------------------------------------------------------------
-- Building

-- parent: a frame over the reels at the overlay's level; f: the slot window (coordinates);
-- widgets: its widget table (gets cashoutPanel, coForm, coState, coAmount, coMax, coOfficerRows,
-- coNoOfficer, coNote, coError, coRequest, coCancel, coClose, coStateTitle, coStateSub, coBar,
-- coBarFill, coTimer, coLock, coHide).
-- callbacks: session(), fmt(n), refresh(), afterRequest(line), allowSelf(), guildMode().
function Cashout.build(parent, f, widgets, callbacks)
	W, host = widgets, callbacks
	local Lay, c, fs = Theme.layout.cashout, Theme.colors, Theme.fontSize

	-- The overlay: a shade over the reels and the panel on it.
	local overlay = CreateFrame("Frame", nil, parent)
	overlay:SetAllPoints(parent)
	W.cashoutPanel = overlay
	local shade = Skin.fill(overlay, "BACKGROUND", c.shadeStatus)
	Skin.rect(shade, f, Theme.layout.reels)
	local panel = Skin.panel(overlay, f, Lay.panel, "overlay")
	panel:SetFrameLevel(parent:GetFrameLevel() + 1)
	panel:EnableMouse(true) -- nothing under the overlay takes clicks

	local title = Skin.textIn(panel, f, Lay.title, "title", fs.heading, c.gold, "LEFT")
	title:SetText(L.PO_TITLE)
	W.coClose = Skin.button(panel, "icon", Lay.close[3], Lay.close[4], Cashout.hide,
		{ icon = Theme.icons.close, iconOnly = true, iconSize = Theme.layout.iconSize - 2 })
	Skin.rect(W.coClose, f, Lay.close)

	-- Form.
	local form = CreateFrame("Frame", nil, panel)
	form:SetAllPoints(panel)
	W.coForm = form
	local al = Skin.textIn(form, f, Lay.amountLabel, "label", fs.label, c.muted, "LEFT")
	al:SetText(Skin.upper(L.PO_AMOUNT))
	W.coAmount = Skin.editBox(form, Lay.amount[3], Lay.amount[4], "number", fs.field)
	Skin.rect(W.coAmount.holder, f, Lay.amount)
	Skin.call(W.coAmount, "SetMaxLetters", 10)
	W.coAmount:SetScript("OnTextChanged", function(self, userInput)
		if not userInput then
			return
		end
		local text = self:GetText() or ""
		local clean = text:gsub("%D", ""):sub(1, 10)
		if clean ~= text then
			self:SetText(clean)
		end
		setError("")
	end)
	W.coAmount:SetScript("OnEnterPressed", function(self)
		self:ClearFocus()
		request()
	end)
	W.coMax = Skin.button(form, "secondary", Lay.max[3], Lay.max[4], function()
		local s = session()
		if s then
			W.coAmount:SetText(tostring(s:game().balance or 0))
			setError("")
		end
	end, { size = fs.small })
	Skin.rect(W.coMax, f, Lay.max)
	W.coMax.label:SetText(L.PO_MAX)

	local ol = Skin.textIn(form, f, Lay.officerLabel, "label", fs.label, c.muted, "LEFT")
	ol:SetText(Skin.upper(L.PO_OFFICERS))
	local list = Skin.panel(form, f, Lay.officers, "inset")
	W.coOfficerRows = {}
	for i = 1, Lay.oRows do
		local r = Lay.oRow
		local row
		row = Skin.listRow(list, f, { r[1], r[2] + (i - 1) * Lay.oRowStep, r[3], r[4] }, function()
			if row.name then
				C.officer = row.name
				setError("")
				Cashout.update()
			end
		end, Lay.rowText)
		row:Hide()
		W.coOfficerRows[i] = row
	end
	W.coNoOfficer = Skin.text(list, "label", fs.small, c.muted, "LEFT")
	Skin.rect(W.coNoOfficer, f, Lay.oNone)
	Skin.call(W.coNoOfficer, "SetJustifyV", "TOP")
	Skin.call(W.coNoOfficer, "SetWordWrap", true)
	W.coNoOfficer:SetText(L.PO_NO_OFFICER)

	W.coNote = Skin.text(form, "label", fs.small, c.muted, "LEFT")
	Skin.rect(W.coNote, f, Lay.note)
	Skin.call(W.coNote, "SetJustifyV", "TOP")
	Skin.call(W.coNote, "SetWordWrap", true)
	W.coNote:SetText(L.PO_NOTE)
	W.coError = Skin.text(form, "label", fs.small, c.lose, "LEFT")
	Skin.rect(W.coError, f, Lay.error)
	Skin.call(W.coError, "SetJustifyV", "TOP")
	Skin.call(W.coError, "SetWordWrap", true)

	W.coRequest = Skin.button(form, "primary", Lay.request[3], Lay.request[4], request, { size = fs.gambleTitle })
	Skin.rect(W.coRequest, f, Lay.request)
	W.coRequest.label:SetText(L.PO_REQUEST)
	W.coCancel = Skin.button(form, "secondary", Lay.cancel[3], Lay.cancel[4], Cashout.hide)
	Skin.rect(W.coCancel, f, Lay.cancel)
	W.coCancel.label:SetText(L.PO_CANCEL)

	-- State of the request.
	local state = CreateFrame("Frame", nil, panel)
	state:SetAllPoints(panel)
	W.coState = state
	W.coStateTitle = Skin.textIn(state, f, Lay.sTitle, "title", fs.statusTitle, c.text, "CENTER")
	W.coStateSub = Skin.text(state, "label", fs.statusSub, c.muted, "CENTER")
	Skin.rect(W.coStateSub, f, Lay.sSub)
	Skin.call(W.coStateSub, "SetJustifyV", "TOP")
	Skin.call(W.coStateSub, "SetWordWrap", true)
	local bar = Skin.panel(state, f, Lay.bar, "inset")
	W.coBar = bar
	local inset = Lay.barInset
	W.coBarFill = Skin.fill(bar, "ARTWORK", c.barFill)
	W.coBarFill:SetPoint("TOPLEFT", bar, "TOPLEFT", inset, -inset)
	W.coBarFill:SetSize(0.01, Lay.bar[4] - 2 * inset)
	W.coTimer = Skin.textIn(state, f, Lay.timer, "numberMedium", fs.small + 1, c.number, "CENTER")
	W.coLock = Skin.text(state, "label", fs.small, c.muted, "CENTER")
	Skin.rect(W.coLock, f, Lay.lock)
	Skin.call(W.coLock, "SetJustifyV", "TOP")
	Skin.call(W.coLock, "SetWordWrap", true)
	W.coHide = Skin.button(state, "primary", Lay.hide[3], Lay.hide[4], Cashout.hide, { size = fs.gambleTitle })
	Skin.rect(W.coHide, f, Lay.hide)
	W.coHide.label:SetText(L.PO_HIDE)

	state:Hide()
	overlay:Hide()
	return overlay
end
