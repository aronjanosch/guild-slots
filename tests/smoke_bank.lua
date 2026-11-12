-- Smoke test for guild bank deposits (Guild/Bank.lua, the Deposits section of the officer
-- window), the guild rate shown next to amounts, and the officer button in the header, against
-- tests/wowstub.lua outside the client:
--   luajit tests/smoke_bank.lua
-- One officer character with the self test deposits gold and gets the tokens over the GUILD
-- echo, like the in-game test. Runs once per locale (enUS, deDE).

local failures = 0

local LINE = "GSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T2;X=1000"
local HOUR = 3600

local function boot(locale, opts)
	GuildSlotsDB = opts.db
	local stub = dofile("tests/wowstub.lua")
	stub.locale = locale
	stub.infoText = "Welcome to the guild\n" .. LINE .. "\nRaids on Friday"
	stub.roster = {
		{ name = "Alice Smith", rankIndex = opts.rank or 0, online = true },
		{ name = "Bob Jones", rankIndex = 4, online = true },
	}
	local env = { stub = stub, echoOn = true }
	local echo = {}
	local send = C_ChatInfo.SendAddonMessage
	C_ChatInfo.SendAddonMessage = function(prefix, text, channel, target)
		local code = send(prefix, text, channel, target)
		if channel == "GUILD" and env.echoOn then
			echo[#echo + 1] = { prefix, text, channel, stub.playerName }
		end
		return code
	end
	local ns = { random = function(n) return math.random(n) - 1 end }
	stub.loadAddon("GuildSlots", "GuildSlots", ns)
	stub.fire("ADDON_LOADED", "GuildSlots")
	stub.fire("PLAYER_LOGIN")
	stub.fire("GUILD_ROSTER_UPDATE")
	stub.slash("/gs", "help")
	env.ns, env.L = ns, ns.L
	function env.pump(n, dt)
		for _ = 1, n or 1 do
			stub.tick(dt or 1 / 60)
			while #echo > 0 do
				local m = table.remove(echo, 1)
				stub.deliver(m[1], m[2], m[3], m[4])
			end
		end
	end
	-- Opens the vault and waits for the delayed read.
	function env.openBank()
		stub.openBank()
		env.pump(150)
	end
	return env
end

local function fmt(ns, n)
	return ns.Anim.formatNumber(n, ns.L.THOUSANDS)
end

local function chatCount(stub, text)
	local n = 0
	for _, line in ipairs(stub.chat) do
		if line:find(text, 1, true) then n = n + 1 end
	end
	return n
end

-- x, y, w, h of a button placed by Skin.rect in window coordinates.
local function rect(b)
	local _, _, _, x, y = b:GetPoint(1)
	return x, -y, b:GetWidth(), b:GetHeight()
end

local function overlaps(a, b)
	local ax, ay, aw, ah = rect(a)
	local bx, by, bw, bh = rect(b)
	return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end

-- The shown buttons of the bottom row: inside the window, no overlap, same width.
local function checkRow(list, what)
	for i, b in ipairs(list) do
		assert(b:IsShown(), what .. ": button " .. i .. " shown")
		local x, y, w = rect(b)
		assert(x >= 22 and x + w <= 578 + 1e-9, what .. ": button " .. i .. " inside the window")
		assert(y == 562, what .. ": button " .. i .. " on the row")
		for j = i + 1, #list do
			assert(not overlaps(b, list[j]), what .. ": buttons " .. i .. " and " .. j .. " overlap")
		end
		local _, _, w1 = rect(list[1])
		assert(math.abs(w - w1) <= 1, what .. ": even widths")
	end
	local x1 = rect(list[1])
	local xn, _, wn = rect(list[#list])
	assert(x1 == 22 and math.abs(xn + wn - 578) <= 1, what .. ": the row spans the window")
end

local function unknownMethods(stub, into)
	for k in pairs(stub.unknown) do into[k] = true end
end

local function officerFlow(locale, unknown)
	local env = boot(locale, {})
	local ns, stub, L = env.ns, env.stub, env.L
	local W, S = ns.SlotFrame.widgets, ns.SlotFrame.state
	local session = ns.Main.session()
	env.pump(20)
	ns.Main.setSelfTest(true)

	-- Header: the officer button sits left of the sound button, never in the bottom row.
	stub.slash("/gs")
	assert(S.mode == "guild", "guild mode")
	assert(W.officer:IsShown(), "officer button for an officer")
	local ox, oy, ow = rect(W.officer)
	local sx = rect(W.sound)
	assert(oy == 29 and ox + ow <= sx, "officer button in the header, left of sound")
	for _, b in ipairs({ W.sessionBtn, W.soloBtn, W.guildBtn, W.sound, W.close }) do
		assert(not overlaps(W.officer, b), "header buttons do not overlap")
	end
	assert(not overlaps(W.sessionBtn, W.soloBtn) and not overlaps(W.soloBtn, W.guildBtn), "header row")
	assert(not W.officerBadge:IsShown(), "no badge without anything open")
	-- Tooltip.
	W.officer:GetScript("OnEnter")(W.officer)
	assert(stub.tooltip and stub.tooltip.owner == W.officer and stub.tooltip.text == L.OFFICER_TITLE, "tooltip")
	W.officer:GetScript("OnLeave")(W.officer)
	assert(not GameTooltip:IsShown(), "tooltip hidden again")
	-- Bottom row in guild mode: paytable and cash out, spread evenly.
	checkRow({ W.payToggle, W.cashout }, "guild row")

	-- The vault with two deposits and a withdrawal, oldest first.
	local balance0 = session:game().balance
	stub.bankLog = {
		{ kind = "deposit", name = "Bob Jones", amount = 1234, hours = 2 },
		{ kind = "withdraw", name = "Bob Jones", amount = 20000, hours = 1 },
		{ kind = "deposit", name = "Alice Smith", amount = 50000, hours = 0 },
	}
	env.openBank()
	assert(stub.bankQueries[1] == 9, "money log queried as tab MAX_GUILDBANK_TABS + 1")
	assert(ns.Bank.openCount() == 2, "two open deposits: " .. ns.Bank.openCount())
	assert(chatCount(stub, string.format(L.BANK_CHAT, 2)) == 1, "one chat line about new deposits")
	assert(type(GuildSlotsDB.bank) == "table" and type(GuildSlotsDB.bank["Test Guild"]) == "table", "stored per guild")
	-- A log update while open reads again without a second chat line.
	stub.fire("GUILDBANKLOG_UPDATE")
	env.pump(2)
	assert(ns.Bank.openCount() == 2, "still two")
	assert(chatCount(stub, string.format(L.BANK_CHAT, 2)) == 1, "no repeated chat line")

	assert(W.officerBadge:IsShown() and W.officerBadge.text:GetText() == "2", "header badge counts deposits")
	W.officer:Click()
	local O = ns.OfficerFrame.widgets
	assert(O.frame:IsShown() and O.tab == "tokens", "officer window on the tokens tab")
	assert(O.frame:GetHeight() <= 728, "officer window fits: " .. O.frame:GetHeight())
	assert(O.depositPart:IsVisible(), "deposits section shown")
	assert(O.tokensBadge:IsShown() and O.tokensBadge.text:GetText() == "2", "tokens tab badge")
	local r1, r2 = O.depositRows[1], O.depositRows[2]
	assert(r1:IsShown() and r2:IsShown() and not O.depositRows[3]:IsShown(), "two rows")
	assert(r1.name:GetText() == "Alice Smith", "newest first")
	assert(r1.amount:GetText() == "5g", "amount in gold: " .. tostring(r1.amount:GetText()))
	assert(r1.info:GetText():find(fmt(ns, 5000), 1, true), "tokens at the guild rate: " .. r1.info:GetText())
	assert(r2.name:GetText() == "Bob Jones" and r2.amount:GetText() == ns.Coins.text(1234), "older deposit")
	assert(r2.info:GetText():find(fmt(ns, 123), 1, true), "123 tokens for 12s 34c")
	assert(r2.info:GetText():find(string.format(L.BANK_AGO, 2), 1, true), "two hours ago")
	assert(r1.grant:IsShown() and r1.grant.enabled, "grant for an online add-on user")
	assert(r2.grant:IsShown() and not r2.grant.enabled, "no grant for a player not online with the add-on")
	assert(r2.info:GetText():find(L.BANK_OFFLINE, 1, true), "the reason")
	assert(O.depositRead:GetText():find(L.BANK_REFRESH, 1, true), "where to refresh")
	-- Grant form: tokens show their gold, gold converts to tokens.
	assert(O.grantRate:IsShown(), "rate line shown")
	stub.type(O.tokens, "1250")
	assert(O.grantRate:GetText():find("1g 25s", 1, true), "gold equivalent of 1250 tokens: " .. O.grantRate:GetText())
	stub.type(O.gold, "12.5")
	assert(O.tokens:GetText() == "12500", "12.5 gold is 12500 tokens")
	assert(O.grantRate:GetText():find("12g 50s", 1, true), "and its gold")
	stub.type(O.gold, "")
	-- A click on a disabled Grant does nothing.
	r2.grant:Click()
	assert(ns.Bank.openCount() == 2, "still two open")

	-- Grant on the own deposit runs the purchase through the echo.
	r1.grant:Click()
	assert(O.player:GetText() == "Alice Smith" and O.tokens:GetText() == "5000", "grant form filled")
	assert(ns.Bank.openCount() == 1, "the deposit is handled at once")
	env.pump(30)
	assert(session:game().balance == balance0 + 5000, "5000 tokens credited")
	assert(W.balance:GetText() == fmt(ns, balance0 + 5000), "slot window shows the new balance")
	assert(ns.Bank.openCount() == 1, "stays handled after the purchase")
	assert(O.depositRows[1].name:GetText() == "Bob Jones" and not O.depositRows[2]:IsShown(), "one row left")
	assert(W.officerBadge.text:GetText() == "1", "header badge follows")

	-- Dismiss the other one.
	O.depositRows[1].dismiss:Click()
	assert(ns.Bank.openCount() == 0, "dismissed")
	assert(not O.tokensBadge:IsShown() and not W.officerBadge:IsShown(), "badges gone")
	assert(O.depositNone:IsShown(), "no open deposits line")

	-- An hour later the log reads one hour older: nothing new.
	stub.closeBank()
	stub.serverTime = stub.serverTime + HOUR
	for _, e in ipairs(stub.bankLog) do e.hours = e.hours + 1 end
	local chats = #stub.chat
	env.openBank()
	assert(ns.Bank.openCount() == 0, "nothing new an hour later")
	assert(#stub.chat == chats, "no chat line")

	-- A new identical deposit is new.
	stub.closeBank()
	stub.bankLog[#stub.bankLog + 1] = { kind = "deposit", name = "Alice Smith", amount = 50000, hours = 0 }
	env.openBank()
	assert(ns.Bank.openCount() == 1, "the new identical deposit is open")
	assert(chatCount(stub, string.format(L.BANK_CHAT, 1)) == 1, "chat line for it")

	-- A purchase that times out (no answer) leaves it open.
	env.echoOn = false
	O.depositRows[1].grant:Click()
	assert(ns.Bank.openCount() == 0, "handled while the purchase runs")
	env.pump(40, 1)
	env.echoOn = true
	local timedOut = false
	for _, p in ipairs(session:purchases()) do
		if p.role == "officer" and p.status == "timeout" then timedOut = true end
	end
	assert(timedOut, "purchase timed out")
	assert(ns.Bank.openCount() == 1, "open again after the timeout")
	assert(O.depositRows[1]:IsShown(), "listed again")
	-- A grant refused at once (self test off: bad player) records nothing.
	ns.Main.setSelfTest(false)
	O.depositRows[1].grant:Click()
	assert(O.grantNote:GetText() == L.ERR_bad_player, "refused")
	assert(ns.Bank.openCount() == 1, "still open")
	ns.Main.setSelfTest(true)

	-- Cash out: the gold equivalent at the guild rate and the by-hand reminder.
	O.close:Click()
	env.pump(10)
	W.cashout:Click()
	assert(W.cashoutPanel:IsShown(), "cash-out panel")
	assert(W.coNote:GetText() == L.PO_NOTE, "settled by hand")
	assert(W.coRate:IsShown() and W.coRate:GetText():find("5g", 1, true), "gold of 5000 tokens: " .. W.coRate:GetText())
	stub.type(W.coAmount, "1250")
	assert(W.coRate:GetText():find("1g 25s", 1, true), "follows the amount")
	-- The rate is always the current settings line's, not the one the tokens were bought at.
	stub.infoText = "GSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T2;X=2000"
	stub.slash("/gs", "help")
	stub.type(W.coAmount, "5000")
	assert(W.coRate:GetText():find("2g 50s", 1, true), "current guild rate: " .. W.coRate:GetText())
	-- Without valid settings no conversion is shown.
	stub.infoText = "no settings line"
	stub.slash("/gs", "help")
	stub.type(W.coAmount, "5000")
	assert(not W.coRate:IsShown(), "no gold without settings")
	stub.infoText = LINE
	stub.slash("/gs", "help")
	W.coCancel:Click()

	-- Bottom row in solo mode: paytable, refill and the bonus buy.
	W.soloBtn:Click()
	assert(W.buy:IsShown(), "buy button in solo")
	checkRow({ W.payToggle, W.refill, W.buy }, "solo row")
	W.guildBtn:Click()
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)

	-- A grant still running at a /reload is lost with the session: the next read opens the
	-- deposit again.
	stub.slash("/gs", "officer")
	env.echoOn = false
	O.depositRows[1].grant:Click()
	assert(ns.Bank.openCount() == 0, "handled while the purchase runs")
	local db, serverTime, log = GuildSlotsDB, stub.serverTime, stub.bankLog
	env = boot(locale, { db = db })
	ns, stub = env.ns, env.stub
	stub.serverTime, stub.bankLog = serverTime, log
	env.pump(20)
	env.openBank()
	assert(ns.Bank.openCount() == 1, "open again after the reload")
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

-- A member: no officer button, the vault is never read and nothing is stored.
local function memberFlow(locale, unknown)
	local env = boot(locale, { rank = 3 })
	local ns, stub = env.ns, env.stub
	local W = ns.SlotFrame.widgets
	stub.slash("/gs")
	assert(not W.officer:IsShown(), "no officer button for a member")
	stub.bankLog = { { kind = "deposit", name = "Bob Jones", amount = 10000, hours = 0 } }
	env.openBank()
	assert(#stub.bankQueries == 0, "a member never queries the log")
	assert(GuildSlotsDB.bank == nil, "a member stores nothing")
	assert(ns.Bank.openCount() == 0, "no deposits for a member")
	stub.slash("/gs", "officer")
	local O = ns.OfficerFrame.widgets
	assert(O.frame:IsShown() and O.tab == "settings", "members still reach the settings tab")
	assert(not O.depositPart:IsVisible(), "no deposits section")
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
	unknownMethods(stub, unknown)
end

-- Without the bank API the feature is empty and nothing raises.
local function noApiFlow(locale, unknown)
	local env = boot(locale, {})
	local ns, stub = env.ns, env.stub
	env.pump(20)
	GetGuildBankMoneyTransaction, GetNumGuildBankMoneyTransactions, QueryGuildBankLog = nil, nil, nil
	env.openBank()
	assert(ns.Bank.openCount() == 0, "empty without the API")
	stub.slash("/gs", "officer")
	assert(ns.OfficerFrame.widgets.depositNone:IsShown() or ns.OfficerFrame.widgets.depositRead:GetText() ~= "",
		"section still renders")
	unknownMethods(stub, unknown)
end

for _, locale in ipairs({ "enUS", "deDE" }) do
	local unknown = {}
	local ok, err = xpcall(function()
		officerFlow(locale, unknown)
		memberFlow(locale, unknown)
		noApiFlow(locale, unknown)
	end, debug.traceback)
	if ok then
		local list = {}
		for k in pairs(unknown) do list[#list + 1] = k end
		table.sort(list)
		io.write("smoke bank ", locale, ": ok")
		if #list > 0 then io.write(" (unmodelled methods, no-ops: ", table.concat(list, ", "), ")") end
		io.write("\n")
	else
		failures = failures + 1
		io.write("smoke bank ", locale, ": FAIL\n", err, "\n")
	end
end
os.exit(failures == 0 and 0 or 1)
