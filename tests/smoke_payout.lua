-- Smoke test for payouts in the UI (UI/Cashout.lua in the slot window, UI/Payouts.lua in the
-- officer window) against tests/wowstub.lua, outside the client:
--   luajit tests/smoke_payout.lua
-- One officer character with the self test plays both sides over the GUILD echo, like the
-- in-game test. Runs once per locale (enUS, deDE).

local failures = 0

local LINE = "GSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T2"

-- Fresh globals and a loaded addon. opts: rank, db (a GuildSlotsDB to keep, as after /reload),
-- serverTime.
local function boot(locale, opts)
	GuildSlotsDB = opts.db
	local stub = dofile("tests/wowstub.lua")
	stub.locale = locale
	stub.serverTime = opts.serverTime or stub.serverTime
	stub.infoText = "Welcome to the guild\n" .. LINE .. "\nRaids on Friday"
	stub.roster = {
		{ name = "Alice Smith", rankIndex = opts.rank or 0, online = true },
		{ name = "Bob Jones", rankIndex = 4, online = true },
	}

	-- The server echoes every GUILD message back to the sender (delivered by pump()).
	local echo = {}
	local send = C_ChatInfo.SendAddonMessage
	C_ChatInfo.SendAddonMessage = function(prefix, text, channel, target)
		local code = send(prefix, text, channel, target)
		if channel == "GUILD" then
			echo[#echo + 1] = { prefix, text, channel, stub.playerName }
		end
		return code
	end

	local ns = { random = function(n) return math.random(n) - 1 end }
	stub.loadAddon("GuildSlots", "GuildSlots", ns)
	stub.fire("ADDON_LOADED", "GuildSlots")
	stub.fire("PLAYER_LOGIN")
	stub.fire("GUILD_ROSTER_UPDATE")
	stub.slash("/gs", "help") -- reads the guild info (hardware event)

	local env = { stub = stub, ns = ns, L = ns.L }
	function env.pump(n, dt)
		for _ = 1, n or 1 do
			stub.tick(dt or 1 / 60)
			while #echo > 0 do
				local m = table.remove(echo, 1)
				stub.deliver(m[1], m[2], m[3], m[4])
			end
		end
	end
	function env.count(kind)
		local n = 0
		for _, s in ipairs(stub.sent) do
			if s.text:match("^1|(%u+%d?)|") == kind then n = n + 1 end
		end
		return n
	end
	-- Pumps frames until cond() holds.
	function env.pumpUntil(cond, what, limit, dt)
		for _ = 1, limit or 2000 do
			if cond() then return end
			env.pump(1, dt)
		end
		error("never: " .. what, 2)
	end
	return env
end

local function fmt(ns, n)
	return ns.Anim.formatNumber(n, ns.L.THOUSANDS)
end

local function settle(env)
	local S = env.ns.SlotFrame.state
	local guard = 0
	repeat
		env.pump(1)
		guard = guard + 1
		assert(guard < 30000, "animation never settles (phase " .. S.phase .. ")")
	until (S.phase == "idle" or S.phase == "pick") and next(S.counts) == nil
end

local function resting(game)
	return game.balance - (game:state() == "gamble" and game.pending or 0)
end

local function chatHas(stub, text)
	for _, line in ipairs(stub.chat) do
		if line:find(text, 1, true) then return true end
	end
	return false
end

local function unknownMethods(stub, into)
	for k in pairs(stub.unknown) do into[k] = true end
end

-- Officer with the self test and 500 tokens, a few spins played, slot window in guild mode.
local function prepare(locale)
	local env = boot(locale, {})
	local ns, stub = env.ns, env.stub
	local W, S = ns.SlotFrame.widgets, ns.SlotFrame.state
	local session = ns.Main.session()
	env.pump(20)
	stub.slash("/gs", "officer")
	local O = ns.OfficerFrame.widgets
	assert(O.tabTokens:IsShown() and O.tabPayouts:IsShown() and O.tabSettings:IsShown(), "officer sees three tabs")
	assert(O.tab == "tokens" and O.tabTokens.selected, "tokens tab first")
	assert(O.grantPart:IsVisible() and not O.formPart:IsVisible() and not O.payoutsPart:IsVisible(), "tokens tab content")
	O.selfTest:Click()
	stub.type(O.player, "Alice Smith")
	stub.type(O.tokens, "500")
	O.grant:Click()
	env.pump(30)
	assert(session:game().balance == 500, "500 tokens")
	-- Settings tab keeps the existing widgets.
	O.tabSettings:Click()
	assert(O.tabSettings.selected and O.formPart:IsVisible() and O.statusPart:IsVisible(), "settings tab content")
	assert(not O.grantPart:IsVisible(), "grant part hidden on the settings tab")
	assert(O.status:GetText():find("E=10,50,100", 1, true), "settings status kept")
	assert(O.frame:GetHeight() <= 728, "officer window fits")
	O.tabTokens:Click()
	assert(O.purchaseRows[1]:IsVisible(), "purchases on the tokens tab")
	O.close:Click()

	stub.slash("/gs", "guild")
	assert(S.mode == "guild", "guild mode")
	for _ = 1, 4 do
		stub.serverTime = stub.serverTime + 2
		env.pump(120)
		W.spin:Click()
		settle(env)
		if W.offerRow:IsShown() then
			W.take:Click()
			settle(env)
		end
	end
	assert(W.balance:GetText() == fmt(ns, resting(session:game())), "balance shown after spins")
	return env, session, W, S, O
end

local function payoutFlow(locale, unknown)
	local env, session, W, S, O = prepare(locale)
	local ns, stub, L = env.ns, env.stub, env.L
	local game = session:game()

	-- Cash out: in the refill slot, guild mode only.
	assert(W.cashout:IsShown() and not W.refill:IsShown(), "cash out instead of refill")
	assert(W.cashout.label:GetText() == L.CASHOUT, "cash out label")
	assert(W.cashout.enabled, "cash out enabled with tokens")
	W.cashout:Click()
	assert(W.cashoutPanel:IsShown() and W.coForm:IsShown() and not W.coState:IsShown(), "cash-out form")
	assert(W.coAmount:GetText() == tostring(game.balance), "amount prefilled with the balance")
	assert(W.coOfficerRows[1]:IsShown() and W.coOfficerRows[1].label:GetText() == "Alice Smith",
		"own name listed with the self test")
	assert(W.coOfficerRows[1].selected, "first officer selected")
	assert(W.coNote:GetText() == L.PO_NOTE, "pays-by-hand note")
	assert(W.coRate:IsShown() and W.coRate:GetText() == string.format(L.PO_RATE, ns.Coins.tokensText(game.balance, 1000),
		fmt(ns, 1000)), "gold equivalent at the guild rate")
	-- Digits only; 0 and more than the balance are refused.
	stub.type(W.coAmount, "12a3")
	assert(W.coAmount:GetText() == "123", "digits only")
	stub.type(W.coAmount, "0")
	W.coRequest:Click()
	assert(W.coError:GetText() == string.format(L.PO_ERR_bad_amount, fmt(ns, game.balance)), "zero refused")
	stub.type(W.coAmount, tostring(game.balance + 1))
	W.coRequest:Click()
	assert(W.coError:GetText() == string.format(L.PO_ERR_bad_amount, fmt(ns, game.balance)), "too much refused")
	assert(session:payout() == nil, "nothing requested yet")
	W.coMax:Click()
	assert(W.coAmount:GetText() == tostring(game.balance), "max fills the balance")
	-- Cancel and re-open.
	W.coCancel:Click()
	assert(not W.cashoutPanel:IsShown(), "cancel hides the form")
	W.cashout:Click()
	assert(W.cashoutPanel:IsShown(), "re-opened")

	-- Officer window open on the Payouts tab, recording what its list shows on every event.
	stub.slash("/gs", "officer")
	O.tabPayouts:Click()
	assert(O.payoutsPart:IsVisible() and not O.grantPart:IsVisible(), "payouts tab content")
	assert(O.payNone:IsShown(), "no requests yet")
	local shown = {}
	ns.Main.subscribe(function(name, data)
		if name == "request" and O.payRows[1]:IsShown() then
			shown[#shown + 1] = { status = data.status, badge = O.payRows[1].badge.text:GetText() }
		end
	end)

	local before = game.balance
	stub.type(W.coAmount, "200")
	local spins = env.count("SPIN")
	W.coRequest:Click()
	local p = session:payout()
	assert(p and p.status == "wait_officer" and p.amount == 200, "request open")
	assert(W.coState:IsShown() and not W.coForm:IsShown(), "state view")
	assert(W.coStateTitle:GetText() == L.PO_S_wait_officer, "waiting for the officer")
	assert(W.coStateSub:GetText() == string.format(L.PO_REQ_SUB, fmt(ns, 200), "Alice Smith"), "amount and officer")
	assert(W.coTimer:GetText() == string.format(L.PO_LEFT, 300), "300 s left")
	assert(W.coHide.label:GetText() == L.PO_HIDE, "hide while open")

	-- Locked: SPIN off, no SPIN message, the status panel once the overlay is hidden.
	assert(not W.spin.enabled, "spin off while the request is open")
	W.spin:Click()
	ns.SlotFrame.spin()
	assert(env.count("SPIN") == spins and S.phase == "idle", "no spin while locked")
	W.coHide:Click()
	assert(not W.cashoutPanel:IsShown(), "overlay hidden")
	assert(W.statusOverlay:IsShown() and W.statusTitle:GetText() == L.PO_LOCK_TITLE, "lock panel")
	assert(W.win:GetText() == L.ST_PAYOUT, "lock line")
	assert(W.cashout.enabled, "cash out re-opens the request")
	W.cashout:Click()
	assert(W.cashoutPanel:IsShown() and W.coState:IsShown(), "request shown again")

	-- PAYREQ, LOGREQ, LOG chunks, verification, ready.
	env.pumpUntil(function()
		local r = session:requests()[1]
		return r and r.status == "ready"
	end, "request ready")
	assert(env.count("PAYREQ") == 1 and env.count("LOGREQ") == 1 and env.count("LOG") >= 1, "messages sent")
	assert(session:payout().status == "wait_decision", "player waits for the decision")
	env.pump(70) -- one refresh of the overlay
	assert(W.coStateTitle:GetText() == L.PO_S_wait_decision, "waiting for the decision")
	local order = {}
	for _, e in ipairs(shown) do
		if order[#order] ~= e.status then order[#order + 1] = e.status end
	end
	assert(table.concat(order, ",") == "fetching,checking,ready", "list went fetching, checking, ready: "
		.. table.concat(order, ","))
	assert(shown[1].badge:find(string.format(L.PAY_B_fetching, 0, 0):sub(1, 3), 1, true), "fetching badge: "
		.. shown[1].badge)
	assert(O.payRows[1].badge.text:GetText() == L.PAY_B_ready, "ready badge")
	assert(O.payRows[1].label:GetText() == "Alice Smith" and O.payRows[1].amount:GetText() == fmt(ns, 200), "row")
	assert(O.payRows[1].selected, "open request selected")
	assert(O.tabBadge:IsShown() and O.tabBadge.text:GetText() == "1", "one open request on the tab")

	-- Review: green light, balance, amount, after.
	assert(O.payReport:IsShown(), "report shown")
	assert(O.payLight.text:GetText() == L.LIGHT_green, "green light: " .. tostring(O.payLight.text:GetText()))
	assert(O.payBalance:GetText() == fmt(ns, before), "calculated balance")
	assert(O.payAmount:GetText() == fmt(ns, 200), "requested amount")
	assert(O.payAfter:GetText() == fmt(ns, before - 200), "balance after")
	-- 200 tokens at the guild rate X = 1000: 2000 copper.
	assert(O.payGold:GetText() == string.format(L.PAY_GOLD, fmt(ns, 200), "20s"), "gold equivalent in the review: "
		.. tostring(O.payGold:GetText()))
	assert(ns.Payouts.goldText(200) == "20s", "the question uses the same text")
	-- The header button counts the open request.
	assert(W.officerBadge:IsShown() and W.officerBadge.text:GetText() == "1", "header badge counts the request")
	assert(O.payNoFindings:IsShown(), "no findings")
	assert(not O.payFollowed:IsShown() and not O.payLuckNone:IsShown(), "the account was transferred")
	assert(O.payLuckRows[1].badge.text:GetText() == L.LUCK_LOW, "too little data for the luck index")
	local luck = session:requests()[1].report.luck
	assert(luck.spins >= 4, "spins counted: " .. tostring(luck.spins))
	assert(O.paySpins:GetText() == string.format(L.LUCK_SPINS, luck.spins, fmt(ns, luck.maxWin)), "spins line")
	assert(O.payLookahead:GetText() ~= L.PAY_LOOKAHEAD_NA, "look-ahead at level 0")
	assert(O.payConfirm:IsShown() and O.payConfirm.enabled and O.payReject.enabled, "confirm and reject")

	-- Confirm: asks once more, then records.
	O.payConfirm:Click()
	assert(session:requests()[1].status == "ready", "first click only asks")
	assert(O.payConfirm.label:GetText() == L.PAY_CONFIRM2 and O.payBack:IsShown(), "confirm step")
	assert(O.payNote:GetText():find(ns.Payouts.goldText(200), 1, true), "gold equivalent in the question")
	O.payConfirm:Click()
	assert(session:requests()[1].status == "paid", "paid on the officer side")
	assert(O.payNote:GetText() == string.format(L.PAY_DONE, fmt(ns, 200), "Alice Smith"), "recorded")
	assert(O.payRows[1].badge.text:GetText() == L.PAY_B_paid, "paid badge")
	assert(not O.tabBadge:IsShown(), "no open requests")

	-- The player: PAY arrives, paid, the balance counts down.
	env.pumpUntil(function() return session:payout().status == "paid" end, "player paid")
	assert(W.coStateTitle:GetText() == L.PO_S_paid, "paid title")
	assert(W.coStateSub:GetText() == string.format(L.PO_PAID, fmt(ns, 200), "Alice Smith"), "paid line")
	assert(W.coHide.label:GetText() == L.PO_CLOSE, "close once finished")
	settle(env)
	assert(game.balance == before - 200, "balance minus 200")
	assert(W.balance:GetText() == fmt(ns, before - 200), "window shows the new balance")
	assert(W.spin.enabled, "spin back on")
	local entries = GuildSlotsDB.guild.accounts["Test Guild"]["Alice Smith"].entries
	local state = ns.Ledger.replay("Test Guild", "Alice Smith", entries)
	assert(state and state.balance == before - 200, "stored account replays to the new balance")
	W.coHide:Click()
	assert(not W.cashoutPanel:IsShown(), "closed")
	W.cashout:Click()
	assert(W.coForm:IsShown(), "form again after closing a finished request")
	W.coCancel:Click()

	-- 2. A rejected request; the officer window is closed when it arrives.
	O.close:Click()
	stub.chat = {}
	local sounds = #stub.sounds
	W.cashout:Click()
	stub.type(W.coAmount, "50")
	W.coRequest:Click()
	env.pumpUntil(function()
		local r = session:requests()[1]
		return r and r.status == "ready"
	end, "second request ready")
	assert(chatHas(stub, string.format(L.PAY_NEW_CHAT, "Alice Smith", fmt(ns, 50))), "chat notice")
	local played = false
	for i = sounds + 1, #stub.sounds do
		if stub.sounds[i] == SOUNDKIT.READY_CHECK then played = true end
	end
	assert(played, "notice sound")
	stub.slash("/gs", "officer")
	assert(O.tab == "payouts", "the window remembers the payouts tab")
	assert(O.payRows[1].selected and O.payRows[1].amount:GetText() == fmt(ns, 50), "new request selected")
	assert(O.payRows[2]:IsShown() and O.payRows[2].badge.text:GetText() == L.PAY_B_paid, "paid one listed below")
	O.payReject:Click()
	assert(O.payDeclined:IsShown() and not O.payMismatch:IsShown() and O.payBack:IsShown(), "reasons (green: no mismatch)")
	O.payBack:Click()
	assert(O.payReject:IsShown() and not O.payDeclined:IsShown(), "back to the review")
	O.payReject:Click()
	O.payDeclined:Click()
	assert(session:requests()[1].status == "rejected", "rejected")
	assert(O.payRows[1].badge.text:GetText() == L.PAY_B_rejected, "rejected badge")
	env.pumpUntil(function() return session:payout().status == "rejected" end, "player rejected")
	assert(W.cashoutPanel:IsShown() and W.coStateTitle:GetText() == L.PO_S_rejected, "rejected shown")
	assert(W.coStateSub:GetText() == string.format(L.PO_REASON, L.REASON_declined), "reason shown")
	assert(game.balance == before - 200, "balance unchanged")
	W.coHide:Click()

	-- 3. An expiring request, on both windows.
	W.cashout:Click()
	stub.type(W.coAmount, "30")
	W.coRequest:Click()
	env.pumpUntil(function()
		local r = session:requests()[1]
		return r and r.status == "ready"
	end, "third request ready")
	env.pump(1, 1)
	assert(W.coTimer:GetText() ~= string.format(L.PO_LEFT, 300), "countdown runs")
	assert(O.payRows[1].secs:GetText() ~= "", "seconds left on the officer side")
	env.pump(305, 1)
	assert(session:payout().status == "expired", "player request expired")
	assert(session:requests()[1].status == "expired", "officer request expired")
	assert(W.coStateTitle:GetText() == L.PO_S_expired and W.coStateSub:GetText() == L.PO_EXPIRED, "expired shown")
	assert(O.payRows[1].badge.text:GetText() == L.PAY_B_expired, "expired badge")
	assert(not O.payConfirm.enabled and not O.payReject.enabled, "nothing to decide")
	assert(W.spin.enabled, "spin free again")
	W.coHide:Click()

	-- 3b. A red check: the officer's anchor does not match the account.
	local anchors = GuildSlotsDB.guild.anchors["Test Guild"]
	anchors["Alice Smith"] = { anchors = 1, head = string.rep("0", 32), time = 1, by = "Alice Smith" }
	W.cashout:Click()
	stub.type(W.coAmount, "10")
	W.coRequest:Click()
	env.pumpUntil(function()
		local r = session:requests()[1]
		return r and r.status == "ready"
	end, "red request ready")
	assert(O.payLight.text:GetText() == L.LIGHT_red, "red light")
	assert(O.payFindingRows[1].text:IsShown(), "a finding listed")
	local found = false
	for _, row in ipairs(O.payFindingRows) do
		if row.text:IsShown() and row.text:GetText():find(L.FIND_anchor_mismatch, 1, true) then found = true end
	end
	assert(found, "anchor finding in words")
	assert(O.payConfirm.enabled, "red does not block the confirm button")
	O.payConfirm:Click()
	assert(O.payNote:GetText():sub(1, #L.PAY_ASK_RED) == L.PAY_ASK_RED, "the question says it is red")
	O.payBack:Click()
	O.payReject:Click()
	assert(O.payMismatch:IsShown(), "mismatch offered when red")
	O.payMismatch:Click()
	env.pumpUntil(function() return session:payout().status == "rejected" end, "player rejected (mismatch)")
	assert(W.coStateSub:GetText() == string.format(L.PO_REASON, L.REASON_mismatch), "mismatch reason shown")
	W.coHide:Click()

	-- An unknown status and code show raw.
	assert(ns.Payouts.badgeText({ status = "weird" }) == "weird", "unknown status raw")
	assert(ns.Payouts.badgeText({ status = "failed", code = "odd_code" }) == string.format(L.PAY_B_failed, "odd_code"),
		"unknown code raw")

	-- 4. /gs payout opens the overlay.
	W.close:Click()
	stub.slash("/gs", "solo")
	stub.slash("/gs", "payout")
	assert(W.frame:IsShown() and S.mode == "guild" and W.cashoutPanel:IsShown() and W.coForm:IsShown(), "/gs payout")

	-- 5. Reload with an open request.
	W.coCancel:Click()
	W.cashout:Click()
	stub.type(W.coAmount, "20")
	W.coRequest:Click()
	env.pumpUntil(function() return session:payout().status == "wait_decision" end, "fourth request sent")
	local db = GuildSlotsDB
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)

	local env2 = boot(locale, { db = db, serverTime = stub.serverTime + 10 })
	local s2 = env2.ns.Main.session()
	local p2 = s2:payout()
	if p2 and ns.Cashout.OPEN[p2.status] then
		env2.stub.slash("/gs", "guild")
		local W2 = env2.ns.SlotFrame.widgets
		assert(not W2.spin.enabled, "locked after the reload")
		assert(W2.cashoutPanel:IsShown() and W2.coState:IsShown(), "request state shown after the reload")
		assert(env2.ns.SlotFrame.state.game:status() == "payout", "game reports the lock")
	else
		io.write("  (reload: open request not restored by this session version, skipped)\n")
	end
	env2.pump(5)
	assert(#env2.stub.blocked == 0, "protected call after the reload: " .. tostring(env2.stub.blocked[1]))
	unknownMethods(env2.stub, unknown)
end

-- A payout of another member whose account the officer's client followed live: nothing is
-- transferred, the review says so, lists the alerts and has no luck index.
local function followedFlow(locale, unknown)
	local env = boot(locale, {})
	local ns, stub, L = env.ns, env.stub, env.L
	local Ledger, Proto = ns.Ledger, ns.Proto
	local session = ns.Main.session()
	env.pump(20)
	local GUILD, BOB = "Test Guild", "Bob Jones"
	local SEED = string.rep("5", 32)
	-- Bob's account: a purchase from Alice and a few spins, followed by this client.
	local state = Ledger.start(GUILD, BOB)
	assert(Ledger.apply(state, { type = "B", buyId = string.rep("b", 16), officer = "Alice Smith", tokens = 500,
		commit = ns.Engine.commit(SEED), seed = SEED, nonce = string.rep("7", 32), time = 1234, line = LINE }))
	for n = 1, 6 do
		assert(Ledger.apply(state, { type = "S", n = n, stake = 10, A = 0, status = "ok", contribs = "" }))
	end
	assert(session:followStart(BOB, state, state.count), "follow record")
	session:addAlert(BOB, "bad_res", 4, 0) -- the officer's own observation
	local function deliver(sender, msgType, fields)
		stub.deliver("GSLOTS", assert(Proto.encode(msgType, fields)), "GUILD", sender)
	end
	local reqId = string.rep("c", 16)
	stub.slash("/gs", "officer")
	local O = ns.OfficerFrame.widgets
	O.tabPayouts:Click()
	deliver(BOB, "PAYREQ", { reqId = reqId, officer = "Alice Smith", amount = 100, head = Ledger.shortHead(state),
		count = state.count })
	deliver("Dora", "ALERT", { reqId = reqId, player = BOB, code = "rewritten", n = 5, g = 0, time = 1234 })
	env.pumpUntil(function()
		local r = session:requests()[1]
		return r and r.status == "ready"
	end, "followed request ready")
	assert(env.count("LOGREQ") == 0, "no LOGREQ")
	local r = session:requests()[1]
	assert(r.followed and r.report.luck == nil, "followed without entries")
	env.pump(70) -- one refresh
	assert(O.payReport:IsShown(), "report shown")
	assert(O.payFollowed:IsShown() and O.payFollowed:GetText() == L.PAY_FOLLOWED, "followed line")
	assert(O.payLight.text:GetText() == L.LIGHT_yellow, "alerts make it yellow")
	assert(O.payBalance:GetText() == fmt(ns, state.balance), "followed balance")
	-- The alerts: sender, what, spin number.
	local lines = {}
	for _, row in ipairs(O.payFindingRows) do
		if row.text:IsShown() then lines[#lines + 1] = row.text:GetText() end
	end
	local function has(text)
		for _, line in ipairs(lines) do
			if line == text then return true end
		end
		return false
	end
	assert(has(string.format(L.PAY_ALERT_ROW, L.FIND_alert_rewritten, "Dora", 5)), "Dora's alert: "
		.. table.concat(lines, " | "))
	assert(has(string.format(L.PAY_ALERT_ROW, L.FIND_alert_bad_res, "Alice Smith", 4)), "the own alert")
	-- No luck index: the luck block says so instead of empty rows.
	assert(O.payLuckNone:IsShown() and O.payLuckNone:GetText() == L.LUCK_FOLLOWED, "no luck index line")
	assert(not O.payLuckRows[1].badge:IsShown() and not O.paySpins:IsShown(), "no empty luck rows")
	assert(O.payConfirm.enabled, "can confirm")
	O.payConfirm:Click()
	O.payConfirm:Click()
	assert(session:requests()[1].status == "paid", "paid")
	env.pump(30)
	assert(env.count("PAY") == 1, "PAY sent")
	assert(session:followed(BOB).balance == state.balance - 100, "record after the payout")
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

-- A member below officer rank: only the Settings tab.
local function memberFlow(locale, unknown)
	local env = boot(locale, { rank = 3 })
	local ns, stub, L = env.ns, env.stub, env.L
	stub.slash("/gs", "officer")
	local O = ns.OfficerFrame.widgets
	assert(O.frame:IsShown(), "window opens for a member")
	assert(not O.tabTokens:IsShown() and not O.tabPayouts:IsShown() and O.tabSettings:IsShown(), "only Settings")
	assert(O.tab == "settings" and O.tabSettings.selected, "settings selected")
	assert(O.statusPart:IsVisible() and O.nonOfficer:IsVisible(), "status and rank line visible")
	assert(O.nonOfficer:GetText() == L.NEED_OFFICER, "rank line")
	assert(not O.grantPart:IsVisible() and not O.payoutsPart:IsVisible(), "no grant, no payouts")
	-- A member with tokens can cash out; without an officer online the form says so.
	env.pump(20)
	stub.slash("/gs", "guild")
	local W = ns.SlotFrame.widgets
	assert(W.cashout:IsShown() and not W.cashout.enabled, "cash out off without tokens")
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

for _, locale in ipairs({ "enUS", "deDE" }) do
	local unknown = {}
	local ok, err = xpcall(function()
		payoutFlow(locale, unknown)
		followedFlow(locale, unknown)
		memberFlow(locale, unknown)
	end, debug.traceback)
	if ok then
		local list = {}
		for k in pairs(unknown) do list[#list + 1] = k end
		table.sort(list)
		io.write("smoke payout ", locale, ": ok")
		if #list > 0 then io.write(" (unmodelled methods, no-ops: ", table.concat(list, ", "), ")") end
		io.write("\n")
	else
		failures = failures + 1
		io.write("smoke payout ", locale, ": FAIL\n", err, "\n")
	end
end
os.exit(failures == 0 and 0 or 1)
