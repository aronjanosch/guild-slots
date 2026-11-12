-- Smoke test for guild mode (Main.lua, the slot window in guild mode, UI/OfficerFrame.lua)
-- against tests/wowstub.lua, outside the client:
--   luajit tests/smoke_guild.lua
-- One character plays both sides of a purchase over the GUILD echo, like the in-game self
-- test. Runs once per locale (enUS, deDE).

local failures = 0

local LINE = "GSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T2"
local LINE_T1 = "GSLOTS1;L=0;R=1;E=10,50,100;G=3"

-- Fresh globals and a loaded addon. opts: guild (name or false), rank, line (false: none).
local function boot(locale, opts)
	GuildSlotsDB = nil
	local stub = dofile("tests/wowstub.lua")
	stub.locale = locale
	stub.guildName = opts.guild ~= false and (opts.guild or "Test Guild") or nil
	local line = opts.line == nil and LINE or opts.line
	stub.infoText = "Welcome to the guild\n" .. (line or "") .. "\nRaids on Friday"
	stub.roster = stub.guildName and {
		{ name = "Alice Smith", rankIndex = opts.rank or 0, online = true },
		{ name = "Bob Jones", rankIndex = 4, online = true },
	} or {}

	-- The server echoes every GUILD message back to the sender (delivered by pump()).
	local echo = {}
	local send = C_ChatInfo.SendAddonMessage
	C_ChatInfo.SendAddonMessage = function(prefix, text, channel, target)
		local code = send(prefix, text, channel, target)
		if channel == "GUILD" and stub.guildName then
			echo[#echo + 1] = { prefix, text, channel, stub.playerName }
		end
		return code
	end

	local ns = { random = function(n) return math.random(n) - 1 end }
	stub.loadAddon("GuildSlots", "GuildSlots", ns)
	stub.fire("ADDON_LOADED", "GuildSlots")
	stub.fire("PLAYER_LOGIN")
	stub.fire("GUILD_ROSTER_UPDATE")
	-- The guild info is only read during a hardware event; the first slash command does it.
	stub.slash("/gs", "help")

	local env = { stub = stub, ns = ns, L = ns.L }
	-- Frames advance by dt; echoes are delivered after each frame, in order.
	function env.pump(n, dt)
		for _ = 1, n or 1 do
			stub.tick(dt or 1 / 60)
			while #echo > 0 do
				local m = table.remove(echo, 1)
				stub.deliver(m[1], m[2], m[3], m[4])
			end
		end
	end
	function env.sentTypes()
		local list = {}
		for _, s in ipairs(stub.sent) do
			list[#list + 1] = s.text:match("^1|(%u+%d?)|")
		end
		return list
	end
	function env.count(kind)
		local n = 0
		for _, t in ipairs(env.sentTypes()) do
			if t == kind then n = n + 1 end
		end
		return n
	end
	return env
end

local function fmt(ns, n)
	return ns.Anim.formatNumber(n, ns.L.THOUSANDS)
end

-- The balance the window shows at rest: an open offer holds the amount at risk back.
local function resting(game)
	return game.balance - (game:state() == "gamble" and game.pending or 0)
end

local function settle(env)
	local S = env.ns.SlotFrame.state
	local guard = 0
	repeat
		env.pump(1)
		guard = guard + 1
		assert(guard < 2000, "animation never settles (phase " .. S.phase .. ")")
	until (S.phase == "idle" or S.phase == "pick") and next(S.counts) == nil
end

local function unknownMethods(stub, into)
	for k in pairs(stub.unknown) do into[k] = true end
end

-- 1. Officer with self test: grant, buy, spin, wait, mode switch.
local function officerFlow(locale, unknown)
	local env = boot(locale, {})
	local ns, stub, L = env.ns, env.stub, env.L
	local W, S = ns.SlotFrame.widgets, ns.SlotFrame.state

	local session = ns.Main.session()
	assert(session, "session created after login in a guild")
	assert(session.guild == "Test Guild" and session.me == "Alice Smith", "session names")

	-- HELLO goes out on the first tick and comes back as an echo: the own name is online.
	env.pump(20)
	assert(env.count("HELLO") >= 1, "HELLO sent")
	local online = session:online()
	assert(#online == 1 and online[1].name == "Alice Smith", "own echo heard")

	-- Slot window: officer button visible, guild mode without tokens.
	stub.slash("/gs")
	assert(W.frame:IsShown(), "window open")
	assert(W.officer:IsShown(), "officer button visible to an officer")
	-- Guild mode is the default when a session exists; solo stays one click away.
	assert(S.mode == "guild" and W.guildBtn.selected and not W.soloBtn.selected, "guild mode by default")
	W.soloBtn:Click()
	assert(S.mode == "solo" and GuildSlotsDB.mode == "solo", "solo chosen and saved")
	W.guildBtn:Click()
	assert(S.mode == "guild", "guild mode after the switch")
	assert(W.guildBtn.selected and not W.soloBtn.selected, "guild selected")
	assert(GuildSlotsDB.mode == "guild", "mode saved")
	assert(S.game == session:game(), "window drives the session game")
	assert(not W.refill:IsShown(), "no refill in guild mode")
	assert(W.balanceLabel:GetText() == string.upper(L.TOKENS), "balance label reads tokens")
	assert(W.balance:GetText() == fmt(ns, 0), "zero tokens before a purchase")
	assert(W.win:GetText() == L.ST_NO_ACCOUNT, "idle line without an account")
	-- State 10: the status panel over the reels, spin and stakes off.
	assert(W.statusOverlay:IsShown() and W.statusTitle:GetText() == L.NO_TOKENS_TITLE, "no-tokens panel")
	assert(W.statusSub:GetText() == L.ASK_OFFICER, "ask an officer")
	assert(not W.spin.enabled and not W.pills[1].enabled, "spin and stakes off without tokens")
	local sentBefore = #stub.sent
	W.spin:Click()
	env.pump(1)
	assert(S.phase == "idle", "no spin without an account")
	assert(W.win:GetText() == L.ST_NO_ACCOUNT, "no_account line on spin")
	assert(env.count("SPIN") == 0 and #stub.sent == sentBefore, "nothing sent")

	-- Officer window: settings status, form, self test, grant to self.
	W.officer:Click()
	local O = ns.OfficerFrame.widgets
	assert(O.frame:IsShown(), "officer window open")
	assert(O.status:GetText():find("E=10,50,100", 1, true), "parsed settings shown")
	assert(O.grantPart:IsShown() and O.formPart:IsShown(), "officer sees form and grant")
	assert(O.frame:GetWidth() == 448 and O.frame:GetHeight() <= 728, "officer window fits 448 x 728: "
		.. O.frame:GetHeight())
	assert(O.line:GetText() == "GSLOTS1;L=0;W=2;R=1;E=10,50,100;G=3;C=0;T=T2;X=1000", "line prefilled from the guild info")

	-- Form: a bad field names the field, a good one gives the line back.
	stub.type(O.fields.E, "10,abc")
	assert(O.line:GetText() == "", "no line for invalid input")
	assert(O.formNote:GetText():find(L.F_E, 1, true), "invalid field named")
	stub.type(O.fields.E, "15,100")
	assert(O.line:GetText() == "", "T2 needs stakes in multiples of 10")
	assert(O.formNote:GetText():find(L.F_E, 1, true), "the stakes field is named")
	stub.type(O.fields.E, "10,200")
	assert(O.line:GetText():find("E=10,200", 1, true), "line rebuilt")
	assert(O.formNote:GetText() == L.WARN_SPREAD, "spread warning at level 0")
	stub.type(O.fields.L, "2")
	assert(O.formNote:GetText():find(L.NOTE_LEVEL, 1, true), "level note")
	stub.type(O.fields.L, "0")
	stub.type(O.fields.E, "10,50,100")
	assert(O.formNote:GetText() == "", "no note for a plain level 0 line")
	-- Read-only line: typing restores it, focus selects all.
	local line = O.line:GetText()
	stub.type(O.line, "garbage")
	assert(O.line:GetText() == line, "line box is read-only")
	O.line:SetFocus()
	assert(O.line._highlighted, "focus selects the line")

	-- Grant to self is refused without self test.
	assert(#O.onlineRows >= 1 and O.onlineRows[1]:IsShown(), "online list has a row")
	O.onlineRows[1]:Click()
	assert(O.player:GetText() == "Alice Smith", "click selects the player")
	stub.type(O.tokens, "500")
	O.grant:Click()
	assert(O.grantNote:GetText() == L.ERR_bad_player, "self grant refused without self test")
	stub.type(O.tokens, "abc")
	O.grant:Click()
	assert(O.grantNote:GetText() == L.ERR_bad_tokens, "bad token amount refused")

	O.selfTest:Click()
	assert(GuildSlotsDB.selfTest == true, "self test saved")
	stub.type(O.tokens, "500")
	O.grant:Click()
	assert(env.count("BUY1") == 0, "push does not send at once")
	env.pump(30)
	assert(env.count("BUY1") == 1 and env.count("BUY2") == 1 and env.count("BUY3") == 1, "three BUY messages")
	local p = session:purchases()
	assert(#p == 2, "officer and player record")
	for _, rec in ipairs(p) do assert(rec.status == "done", "purchase done: " .. tostring(rec.status)) end
	local row = O.purchaseRows[1]
	assert(row:IsShown() and row.status:GetText() == L.P_done, "purchase list shows done")
	assert(row.amount:GetText() == fmt(ns, 500), "purchase amount")
	local r, g, b = row.badge.tex[1]:GetVertexColor()
	local ok = ns.Theme.colors.statusOk
	assert(r == ok[1] and g == ok[2] and b == ok[3], "done badge is green")

	-- Slot window: 500 tokens and the credit line.
	assert(session:game().balance == 500, "500 tokens credited")
	assert(W.balance:GetText() == fmt(ns, 500), "window shows 500")
	assert(W.win:GetText() == string.format(L.CREDIT, fmt(ns, 500), "Alice Smith"), "credit line")

	-- A spin through the window.
	local spins = env.count("SPIN")
	W.spin:Click()
	assert(S.phase == "round", "round running in guild mode")
	settle(env)
	assert(env.count("SPIN") == spins + 1, "SPIN sent")
	assert(W.balance:GetText() == fmt(ns, resting(session:game())), "shown balance matches the account")
	if W.offerRow:IsShown() then
		W.take:Click()
	end

	-- A quick-stopped spin ends inside the spin interval; the next click must wait. A win
	-- with a long count-up can outlast the interval, so try until a short one comes up.
	local waited = false
	for _ = 1, 20 do
		env.pump(120) -- 2 s: interval over, budget refills
		local before = env.count("SPIN")
		W.spin:Click()
		W.spin:Click() -- quick stop
		W.spin:Click() -- skip the presentation
		local t0 = GetTime()
		settle(env)
		if W.offerRow:IsShown() then
			W.take:Click()
		end
		if GetTime() - t0 < 1.2 then
			W.spin:Click()
			assert(S.phase == "idle", "no spin within the interval")
			assert(W.win:GetText() == L.WAIT, "wait line")
			assert(env.count("SPIN") == before + 1, "no second SPIN")
			waited = true
			break
		end
	end
	assert(waited, "never got a spin short enough to test the interval")

	-- Later: spins and gamble steps go through (until at least one gamble step was played).
	local i = 0
	while i < 6 or (env.count("GAM") == 0 and i < 40) do
		i = i + 1
		stub.serverTime = stub.serverTime + 2
		env.pump(60) -- budget refills
		W.spin:Click()
		settle(env)
		if W.offerRow:IsShown() then
			stub.serverTime = stub.serverTime + 2
			W.gamble:Click()
			assert(S.phase == "pick", "the card waits for a colour")
			W.black:Click()
			settle(env)
			if S.phase == "pick" then -- won: the card stays open; take the doubled amount
				W.take:Click()
				settle(env)
			end
		end
		assert(W.balance:GetText() == fmt(ns, resting(session:game())), "balance matches after spin " .. i)
	end
	assert(env.count("SPIN") >= spins + 2, "more spins sent")
	assert(env.count("GAM") >= 1, "a gamble step was sent")
	if W.offerRow:IsShown() then W.take:Click() end

	-- No bonus buy in guild mode.
	assert(not W.buy:IsShown() and session:game().buy == nil, "no bonus buy in guild mode")
	assert(session:game():info().buy == nil, "no buy price in the guild info")

	-- Autoplay in guild mode: turbo rounds are shorter than the spin interval, so autoplay has
	-- to wait; it never sends more than one SPIN per 1.5 s and never gambles.
	local spinTimes = {}
	local sendAll = C_ChatInfo.SendAddonMessage
	C_ChatInfo.SendAddonMessage = function(prefix, text, ...)
		if text:find("^1|SPIN|") then spinTimes[#spinTimes + 1] = GetTime() end
		if text:find("^1|GAM|") then error("autoplay gambled") end
		return sendAll(prefix, text, ...)
	end
	W.turbo:Click()
	env.pump(120)
	local autoSpins = env.count("SPIN")
	local gameObj, waits = session:game(), 0
	gameObj.spin = function(self)
		local r, code = getmetatable(self).__index.spin(self)
		if code == "wait" then waits = waits + 1 end
		return r, code
	end
	-- No pause between rounds, so autoplay runs into the game's interval.
	local pause = rawget(ns.Theme.timingTurbo, "autoPause")
	ns.Theme.timingTurbo.autoPause = 0
	W.auto:Click()
	assert(S.auto and W.auto.selected, "autoplay on in guild mode")
	-- Ten SPINs; an offer pauses it until the test takes the win.
	local guard, paused = 0, 0
	while env.count("SPIN") < autoSpins + 10 do
		env.pump(1)
		if S.phase == "idle" and S.offer and next(S.counts) == nil then
			paused = paused + 1
			assert(S.auto, "paused, still on")
			W.take:Click()
		end
		guard = guard + 1
		assert(guard < 60 * 120, "guild autoplay stalls")
	end
	W.auto:Click()
	assert(not S.auto, "off")
	ns.Theme.timingTurbo.autoPause = pause
	settle(env)
	env.pump(240)
	assert(env.count("SPIN") == autoSpins + 10, "ten SPINs, none after switching off: " .. (env.count("SPIN") - autoSpins))
	for i = 2, #spinTimes do
		assert(spinTimes[i] - spinTimes[i - 1] >= 1.5 - 1e-9, "at most one SPIN per 1.5 s: " .. (spinTimes[i] - spinTimes[i - 1]))
	end
	assert(waits > 0, "autoplay met the interval and waited")
	gameObj.spin = nil
	assert(W.balance:GetText() == fmt(ns, resting(session:game())), "balance matches after autoplay")
	if W.offerRow:IsShown() then W.take:Click() end
	-- An open payout request switches it off.
	env.pump(120)
	W.auto:Click()
	env.pump(10)
	session.request = { reqId = "r1", officer = "Alice Smith", amount = 1, status = "wait_officer", time = 0 }
	session.env.onEvent("payout", session:payout())
	assert(not S.auto, "a payout request switches autoplay off")
	settle(env)
	session.request = nil
	session:game():refresh()
	session.env.onEvent("payout", nil)
	if W.offerRow:IsShown() then W.take:Click() end
	-- A mode switch switches it off.
	env.pump(120)
	W.auto:Click()
	env.pump(5)
	stub.slash("/gs", "solo")
	assert(not S.auto and S.mode == "solo", "a mode switch switches autoplay off")
	stub.slash("/gs", "guild")
	C_ChatInfo.SendAddonMessage = sendAll
	W.turbo:Click()
	if W.offerRow:IsShown() then W.take:Click() end

	-- Guild ticker on the footer line, fed by the session's "ticker" event.
	local fire = session.env.onEvent
	fire("ticker", { player = "Bob Jones", n = 7, stake = 50, win = 5000, mult = 100, level = "legendary" })
	fire("ticker", { player = "Bob Jones", n = 8, stake = 50, win = 0, mult = 0, free = 10, symbol = "M", level = "free" })
	env.pump(1)
	assert(W.ticker:IsShown() and not W.footer:IsShown(), "ticker replaces the footer")
	assert(W.ticker:GetText() == string.format(L.TICKER_WIN, "Bob Jones", fmt(ns, 5000), "100"), "win entry: "
		.. tostring(W.ticker:GetText()))
	local tc = ns.Theme.tickerColors
	assert(W.ticker:GetAlpha() < 1, "fades in")
	env.pump(math.ceil(ns.Theme.timing.tickerShow * 60) + 1)
	assert(W.ticker:GetText() == string.format(L.TICKER_FREE, "Bob Jones", 10), "then the free-games entry")
	assert(tc.free and tc.legendary, "level colours")
	env.pump(math.ceil(ns.Theme.timing.tickerShow * 60) + 1)
	assert(not W.ticker:IsShown() and W.footer:IsShown(), "footer back when the queue is empty")
	-- Fewer effects: no motion.
	stub.slash("/gs", "fx")
	fire("ticker", { player = "Bob Jones", n = 9, stake = 10, win = 300, mult = 30, level = "big" })
	env.pump(1)
	assert(W.ticker:IsShown() and W.ticker:GetAlpha() == 1, "shown at once with fewer effects")
	stub.slash("/gs", "fx")
	-- Off switch.
	stub.slash("/gs", "ticker")
	assert(GuildSlotsDB.ticker == false and not W.ticker:IsShown(), "/gs ticker turns it off")
	fire("ticker", { player = "Bob Jones", n = 10, stake = 10, win = 300, mult = 30, level = "big" })
	env.pump(2)
	assert(not W.ticker:IsShown() and W.footer:IsShown(), "no entries while off")
	stub.slash("/gs", "ticker")
	assert(GuildSlotsDB.ticker == true, "back on")
	-- Not in solo mode.
	stub.slash("/gs", "solo")
	fire("ticker", { player = "Bob Jones", n = 11, stake = 10, win = 300, mult = 30, level = "big" })
	env.pump(2)
	assert(not W.ticker:IsShown(), "no ticker in solo mode")
	-- Entering guild mode shows the newest entries of session:ticker(), when there is one.
	local had = rawget(session, "ticker")
	session.ticker = function()
		return { { player = "Carol", win = 2000, mult = 40, level = "big" }, { player = "Dave", win = 1, mult = 0.1, level = "big" } }
	end
	stub.slash("/gs", "guild")
	env.pump(1)
	assert(W.ticker:GetText():find("Dave", 1, true), "oldest of the newest first")
	session.ticker = had
	env.pump(math.ceil(ns.Theme.timing.tickerShow * 60) * 2 + 2)
	assert(not W.ticker:IsShown(), "seeded entries shown and gone")

	local guildBalance = session:game().balance

	-- Switch to solo and back: both balances kept.
	W.soloBtn:Click()
	assert(S.mode == "solo" and S.game ~= session:game(), "solo mode")
	assert(W.refill:IsShown(), "refill back in solo")
	assert(W.balanceLabel:GetText() == string.upper(L.BALANCE), "balance label back")
	assert(W.balance:GetText() == fmt(ns, 1000), "solo balance untouched")
	W.spin:Click()
	settle(env)
	local soloBalance = S.game.balance
	assert(GuildSlotsDB.soloBalance == soloBalance, "solo balance saved")
	stub.slash("/gs", "guild")
	assert(S.mode == "guild", "/gs guild")
	assert(W.balance:GetText() == fmt(ns, guildBalance), "guild balance kept")
	stub.slash("/gs", "solo")
	assert(S.mode == "solo" and W.balance:GetText() == fmt(ns, soloBalance), "/gs solo keeps solo balance")

	-- Switching mid-spin settles the spin first.
	stub.slash("/gs", "guild")
	stub.serverTime = stub.serverTime + 2
	env.pump(60)
	local n = env.count("SPIN")
	W.spin:Click()
	env.pump(5)
	assert(S.phase == "round", "round running before the switch")
	assert(not W.soloBtn.enabled, "mode buttons off while the reels turn")
	stub.slash("/gs", "solo")
	assert(S.phase == "idle" and S.mode == "solo", "settled and switched")
	W.guildBtn:Click()
	assert(env.count("SPIN") == n + 1, "spin was sent")
	assert(W.balance:GetText() == fmt(ns, resting(session:game())), "result kept after the switch")

	-- Closing the officer window and reopening via slash.
	stub.slash("/gs", "officer")
	assert(not O.frame:IsShown(), "/gs officer closes")
	stub.slash("/gs", "officer")
	assert(O.frame:IsShown(), "/gs officer opens")

	-- A message that does not decode and an unknown sender never raise.
	stub.deliver("GSLOTS", "1|BUY3|zz", "GUILD", "Bob Jones")
	stub.deliver("GSLOTS", "", "GUILD", nil)
	env.pump(2)

	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

-- 2. A member below officer rank: no officer button, officer window shows only the status.
local function memberFlow(locale, unknown)
	local env = boot(locale, { rank = 3 })
	local ns, stub, L = env.ns, env.stub, env.L
	local W = ns.SlotFrame.widgets
	assert(ns.Main.session(), "member has a session")
	stub.slash("/gs")
	assert(not W.officer:IsShown(), "no officer button for a member")
	stub.slash("/gs", "officer")
	local O = ns.OfficerFrame.widgets
	assert(O.frame:IsShown(), "window opens for a member")
	assert(not O.grantPart:IsShown() and not O.formPart:IsShown(), "member sees no form and no grant")
	assert(O.nonOfficer:IsShown() and O.nonOfficer:GetText() == L.NEED_OFFICER, "officer rank line")
	assert(O.status:GetText():find("E=10,50,100", 1, true), "member sees the settings status")

	-- Promotion shows the button after the next roster update.
	stub.roster[1].rankIndex = 1
	stub.fire("GUILD_ROSTER_UPDATE")
	assert(W.officer:IsShown(), "officer button after promotion")
	assert(O.grantPart:IsShown(), "grant part after promotion")
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

-- 3. No guild: no session, the mode switch explains why. A guild joined later works.
local function noGuildFlow(locale, unknown)
	local env = boot(locale, { guild = false })
	local ns, stub, L = env.ns, env.stub, env.L
	local W, S = ns.SlotFrame.widgets, ns.SlotFrame.state
	assert(ns.Main.session() == nil, "no session without a guild")
	stub.slash("/gs")
	assert(not W.officer:IsShown(), "no officer button without a guild")
	W.guildBtn:Click()
	assert(S.mode == "solo", "stays solo")
	assert(W.win:GetText() == L.NO_GUILD, "switch explains it")
	stub.slash("/gs", "guild")
	assert(S.mode == "solo" and W.win:GetText() == L.NO_GUILD, "/gs guild explains it")
	stub.slash("/gs", "officer")
	assert(ns.OfficerFrame.widgets.status:GetText() == L.NOT_IN_GUILD, "officer window says not in a guild")
	env.pump(10)

	-- Joining later: the session appears on the roster update; leaving drops it again.
	stub.guildName = "Test Guild"
	stub.roster = { { name = "Alice Smith", rankIndex = 0, online = true } }
	stub.fire("PLAYER_GUILD_UPDATE")
	stub.fire("GUILD_ROSTER_UPDATE")
	assert(ns.Main.session(), "session after joining")
	W.guildBtn:Click()
	assert(S.mode == "guild", "guild mode after joining")
	stub.guildName = nil
	stub.roster = {}
	stub.fire("PLAYER_GUILD_UPDATE")
	stub.fire("GUILD_ROSTER_UPDATE")
	assert(ns.Main.session() == nil, "session dropped after leaving")
	assert(S.mode == "solo", "window back to solo")
	env.pump(10)
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

-- 4. A guild on table T1: the account works, the window explains it cannot play it.
local function t1Flow(locale, unknown)
	local env = boot(locale, { line = LINE_T1 })
	local ns, stub, L = env.ns, env.stub, env.L
	local W, S = ns.SlotFrame.widgets, ns.SlotFrame.state
	local session = ns.Main.session()
	env.pump(20)
	ns.Main.setSelfTest(true)
	assert(session:grant("Alice Smith", 300), "grant to self")
	env.pump(30)
	assert(session:game().balance == 300 and session:game().tbl.id == "T1", "T1 account with 300 tokens")
	stub.slash("/gs", "guild")
	assert(S.mode == "guild", "guild mode")
	assert(W.win:GetText() == L.UNSUPPORTED_TABLE, "unsupported table line")
	assert(W.statusOverlay:IsShown() and W.statusSub:GetText() == L.UNSUPPORTED_TABLE, "status panel explains it")
	local spins = env.count("SPIN")
	W.spin:Click()
	env.pump(2)
	assert(S.phase == "idle" and env.count("SPIN") == spins, "no spin on a T1 account")
	assert(W.win:GetText() == L.UNSUPPORTED_TABLE, "line repeated on spin")
	W.payToggle:Click()
	assert(W.ptUnsupported:IsShown() and not W.ptContent:IsShown(), "paytable explains it too")
	W.payToggle:Click()
	-- Solo still plays (T3).
	stub.slash("/gs", "solo")
	W.spin:Click()
	assert(S.phase == "round", "solo plays")
	settle(env)
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

-- 5. No settings line: the officer form proposes T3 and names both lines tables.
local function noLineFlow(locale, unknown)
	local env = boot(locale, { line = false })
	local ns, stub, L = env.ns, env.stub, env.L
	stub.slash("/gs", "officer")
	local O = ns.OfficerFrame.widgets
	assert(O.status:GetText() == L.SET_MISSING, "no line")
	assert(O.fields.T:GetText() == "T3", "table field prefilled with T3")
	assert(O.line:GetText():find(";T=T3;", 1, true), "line for T3")
	local tables = string.format(L.NOTE_TABLES, string.format(L.TABLE_RTP, "T2", 95) .. ", "
		.. string.format(L.TABLE_RTP, "T3", 92), "T3")
	assert(O.formNote:GetText() == tables, "note names T2 and T3: " .. tostring(O.formNote:GetText()))
	stub.type(O.fields.T, "T2")
	assert(O.line:GetText():find(";T=T2;", 1, true), "T2 can still be chosen")
	stub.type(O.fields.E, "10,25")
	assert(O.line:GetText() == "" and O.formNote:GetText():find(L.F_E, 1, true), "25 is not a T2 stake")
	stub.type(O.fields.T, "T3")
	assert(O.line:GetText() == "" and O.formNote:GetText():find(L.F_E, 1, true), "25 is not a T3 stake")
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

-- 6. Lines tables: a T2 guild account next to the T3 solo game in one window, then a new
-- purchase under a T3 line. The reels, the paytable's return rate and the rounds follow the
-- shown game's table.
local function tablesFlow(locale, unknown)
	local env = boot(locale, {})
	local ns, stub, L = env.ns, env.stub, env.L
	local W, S = ns.SlotFrame.widgets, ns.SlotFrame.state
	local T2, T3 = ns.Tables.get("T2"), ns.Tables.get("T3")
	local session = ns.Main.session()
	env.pump(20)
	ns.Main.setSelfTest(true)
	assert(session:grant("Alice Smith", 1000), "grant under the T2 line")
	env.pump(30)
	assert(session:game().tbl.id == "T2", "the account plays T2")

	local function onStrips(tbl)
		for r = 1, 5 do
			if W.reels[r].strip ~= tbl.reels[r] then return false end
		end
		return true
	end
	local function rtpShown(tbl)
		W.payToggle:Click()
		local text = W.ptRtp:GetText()
		W.payToggle:Click()
		return text == string.format(L.RTP, ns.Tables.stats(tbl, 10, 0).rtp * 100)
	end
	local function spinOnce()
		stub.serverTime = stub.serverTime + 2
		env.pump(120)
		W.spin:Click()
		settle(env)
		if W.offerRow:IsShown() then W.take:Click() end
	end

	stub.slash("/gs", "guild")
	assert(S.mode == "guild" and S.game.tbl == T2, "guild mode shows the T2 account")
	assert(onStrips(T2), "T2 strips on the reels")
	assert(rtpShown(T2), "paytable: 95 % return")
	spinOnce()
	assert(onStrips(T2), "still T2 after a guild round")

	W.soloBtn:Click()
	assert(S.mode == "solo" and S.game.tbl == T3, "solo plays T3")
	assert(onStrips(T3), "T3 strips after the switch to solo")
	assert(rtpShown(T3), "paytable: 92 % return")
	W.spin:Click()
	settle(env)
	if W.offerRow:IsShown() then W.take:Click() end
	assert(onStrips(T3), "still T3 after a solo round")

	W.guildBtn:Click()
	assert(S.game.tbl == T2 and onStrips(T2), "back to the T2 strips")

	-- A new purchase under a T3 line: the same account now plays T3.
	stub.infoText = "Welcome\nGSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T3\n"
	stub.slash("/gs", "help") -- the guild info is read on a hardware event
	assert(session:grant("Alice Smith", 500), "grant under the T3 line")
	env.pump(30)
	assert(session:game().tbl.id == "T3", "the account plays T3 after the purchase")
	spinOnce()
	assert(onStrips(T3), "T3 strips in guild mode after the T3 purchase")
	assert(rtpShown(T3), "paytable follows the account: 92 %")
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

for _, locale in ipairs({ "enUS", "deDE" }) do
	local unknown = {}
	local ok, err = xpcall(function()
		officerFlow(locale, unknown)
		memberFlow(locale, unknown)
		noGuildFlow(locale, unknown)
		t1Flow(locale, unknown)
		noLineFlow(locale, unknown)
		tablesFlow(locale, unknown)
	end, debug.traceback)
	if ok then
		local list = {}
		for k in pairs(unknown) do list[#list + 1] = k end
		table.sort(list)
		io.write("smoke guild ", locale, ": ok")
		if #list > 0 then io.write(" (unmodelled methods, no-ops: ", table.concat(list, ", "), ")") end
		io.write("\n")
	else
		failures = failures + 1
		io.write("smoke guild ", locale, ": FAIL\n", err, "\n")
	end
end
os.exit(failures == 0 and 0 or 1)
