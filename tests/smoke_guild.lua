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
	assert(W.soloBtn.selected and not W.guildBtn.selected, "solo selected")
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
	-- Solo still plays T2.
	stub.slash("/gs", "solo")
	W.spin:Click()
	assert(S.phase == "round", "solo plays")
	settle(env)
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

-- 5. No settings line: the officer form proposes T2.
local function noLineFlow(locale, unknown)
	local env = boot(locale, { line = false })
	local ns, stub, L = env.ns, env.stub, env.L
	stub.slash("/gs", "officer")
	local O = ns.OfficerFrame.widgets
	assert(O.status:GetText() == L.SET_MISSING, "no line")
	assert(O.fields.T:GetText() == "T2", "table field prefilled with T2")
	assert(O.line:GetText():find(";T=T2;", 1, true), "line for T2")
	stub.type(O.fields.E, "10,25")
	assert(O.line:GetText() == "" and O.formNote:GetText():find(L.F_E, 1, true), "25 is not a T2 stake")
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
