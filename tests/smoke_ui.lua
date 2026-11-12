-- Load smoke test for the in-game UI, outside the client:
--   luajit tests/smoke_ui.lua
-- Loads every file in TOC order against tests/wowstub.lua, opens the window via the slash
-- command and drives OnUpdate through several spins, a gamble, a quick stop, refill,
-- keyboard and combat handling. Runs once per locale (enUS, deDE).

local failures = 0

local function scenario(locale)
	-- Fresh globals for every run.
	GuildSlotsDB = nil
	local stub = dofile("tests/wowstub.lua")
	stub.locale = locale

	local values = {}
	local function queue(...)
		for _, v in ipairs({ ... }) do values[#values + 1] = v end
	end
	local seed = 12345
	local preset = {}
	preset.random = function(n)
		local v = table.remove(values, 1)
		if v == nil then
			seed = (seed * 1103515245 + 12345) % 2147483648
			v = seed % n
		end
		assert(v >= 0 and v < n, "queued rng value out of range")
		return v
	end

	-- ns.random must be set before SlotFrame loads; inject through a preloaded ns.
	local ns = {}
	ns.random = preset.random
	local _, loaded = stub.loadAddon("GuildSlots", "GuildSlots", ns)
	-- TOC and files must not drift apart: every .lua under GuildSlots/ is listed.
	local listed = {}
	for _, path in ipairs(loaded) do listed[path] = true end
	local find = io.popen("find GuildSlots -name '*.lua' | sort")
	for path in find:lines() do
		assert(listed[path], path .. " is not listed in GuildSlots.toc")
	end
	find:close()
	assert(ns.Engine and ns.Ledger, "Core Engine and Ledger loaded from the TOC")

	stub.fire("ADDON_LOADED", "OtherAddon")
	stub.fire("ADDON_LOADED", "GuildSlots")
	assert(type(GuildSlotsDB) == "table", "GuildSlotsDB created")

	local L, Anim = ns.L, ns.Anim
	local W, S = ns.SlotFrame.widgets, ns.SlotFrame.state

	local function ticks(n, dt)
		for i = 1, n do
			stub.tick(type(dt) == "function" and dt(i) or dt or 1 / 60)
		end
	end
	local function settle()
		local guard = 0
		repeat
			stub.tick(1 / 60)
			guard = guard + 1
			assert(guard < 2000, "animation never settles (phase " .. S.phase .. ")")
		until S.phase == "idle" and next(S.counts) == nil
	end
	local function shownMatches(where)
		local want = Anim.formatNumber(S.game.balance, L.THOUSANDS)
		assert(W.balance:GetText() == want,
			where .. ": balance shows " .. tostring(W.balance:GetText()) .. ", game has " .. want)
	end

	-- Open via slash command.
	stub.slash("/gs")
	assert(W.frame and W.frame:IsShown(), "window open after /gs")
	local found = false
	for _, n in ipairs(UISpecialFrames) do found = found or n == "GuildSlotsFrame" end
	assert(found, "registered for Escape")
	assert(W.frame:IsKeyboardEnabled(), "keyboard enabled out of combat")
	shownMatches("open")

	-- 1. Losing spin: K S G.
	queue(0, 1, 2)
	W.spin:Click()
	assert(S.phase == "spinning", "spinning")
	assert(W.spin.label:GetText() == L.STOP, "button reads STOP while spinning")
	ticks(30)
	assert(S.phase == "spinning", "still spinning after 0.5 s")
	settle()
	assert(S.game.balance == 990, "990 after a loss")
	shownMatches("after loss")
	for i = 1, 3 do
		assert(math.floor(W.reels[i].x + 0.5) == S.result.stops[i], "reel " .. i .. " on its stop")
	end

	-- 2. Pair S with anticipation, then a won gamble.
	queue(1, 1, 0)
	W.spin:Click()
	ticks(100) -- 1.67 s: reel 3 waits for its anticipation (1.7 + 0.8 s)
	assert(W.reels[3]:isSpinning(), "reel 3 runs longer on anticipation")
	assert(W.tease:IsShown(), "anticipation glow on reel 3")
	settle()
	assert(S.game.balance == 1000, "990 - 10 + 20")
	assert(W.offerRow:IsShown(), "take/gamble offered")
	assert(W.reels[1].mode == "win" and W.reels[3].mode == "dim", "winning reels highlighted")
	shownMatches("after pair")
	queue(0)
	W.gamble:Click()
	assert(S.phase == "flip", "coin flip")
	assert(W.coinOverlay:IsShown(), "coin shown")
	settle()
	assert(S.game.balance == 1020, "won gamble adds 20")
	assert(W.offerRow:IsShown(), "gamble offered again")
	assert(W.take.label:GetText():find(Anim.formatNumber(40, L.THOUSANDS), 1, true), "take shows 40")
	shownMatches("after gamble win")
	W.take:Click()
	assert(not W.offerRow:IsShown(), "offer closed after take")
	assert(S.game:state() == "idle", "idle after take")

	-- 3. Stake 100, triple D (big win) with quick stop, uneven frame times, lost gamble.
	W.pills[3]:Click()
	assert(S.game.stake == 100, "stake 100")
	assert(W.pills[3].selected and not W.pills[1].selected, "pill selected")
	queue(19, 19, 19)
	W.spin:Click()
	ticks(12)
	W.spin:Click() -- quick stop
	ticks(30, function(i) return (i % 3 == 0) and 0.1 or 0.004 end)
	assert(S.phase ~= "spinning", "quick stop landed within 0.5 s")
	assert(W.flash:IsShown(), "big win celebration")
	settle()
	assert(S.game.balance == 1020 - 100 + 50000, "triple D pays 500x")
	shownMatches("after big win")
	queue(1)
	W.gamble:Click()
	settle()
	assert(S.game.balance == 50920 - 50000, "lost gamble")
	assert(not W.offerRow:IsShown(), "no offer after a loss")
	shownMatches("after gamble loss")

	-- 4. Spin during a presentation skips it; spin during a gamble offer takes the win.
	queue(1, 1, 0, 0, 1, 2)
	W.pills[1]:Click()
	W.spin:Click()
	settle()
	assert(W.offerRow:IsShown(), "offer after pair")
	W.spin:Click()
	settle()
	assert(S.game.balance == 920 - 10 + 20 - 10, "offer taken by the next spin")
	shownMatches("after take by spin")

	-- 5. Space key: only with the mouse over the window; other keys propagate.
	local onKey = W.frame:GetScript("OnKeyDown")
	stub.mouseOver = false
	queue(0, 1, 2)
	onKey(W.frame, "SPACE")
	assert(S.phase == "idle", "space ignored without the mouse over the window")
	stub.mouseOver = true
	onKey(W.frame, "W")
	assert(W.frame._propagate == true, "other keys propagate")
	onKey(W.frame, "SPACE")
	assert(S.phase == "spinning", "space spins")
	assert(W.frame._propagate == false, "space consumed")
	onKey(W.frame, "SPACE") -- quick stop
	settle()
	shownMatches("after space spin")

	-- 6. Combat: keyboard released, space does nothing.
	stub.fire("PLAYER_REGEN_DISABLED")
	stub.combat = true
	assert(not W.frame:IsKeyboardEnabled(), "keyboard released in combat")
	onKey(W.frame, "SPACE")
	assert(S.phase == "idle", "no spin from keys in combat")
	W.spin:Click() -- mouse still works
	settle()
	stub.combat = false
	stub.fire("PLAYER_REGEN_ENABLED")
	assert(W.frame:IsKeyboardEnabled(), "keyboard back after combat")

	-- 7. Closing mid-spin settles the result; reopening shows it.
	W.spin:Click()
	ticks(5)
	stub.slash("/gslots")
	assert(not W.frame:IsShown(), "closed")
	assert(S.phase == "idle", "settled on close")
	shownMatches("after close")
	stub.slash("/gs")

	-- 8. No funds, refill.
	S.game.balance = 5
	W.spin:Click()
	assert(S.phase == "idle", "no spin without funds")
	assert(W.win:GetText() == L.NO_FUNDS, "no funds message")
	W.refill:Click()
	assert(S.game.balance == 1000, "refilled")
	shownMatches("after refill")

	-- 9. Paytable, sound toggle, slash options, saved state.
	local h = W.frame:GetHeight()
	W.payToggle:Click()
	assert(W.paytable:IsShown() and W.frame:GetHeight() > h, "paytable opens")
	W.payToggle:Click()
	assert(not W.paytable:IsShown() and W.frame:GetHeight() == h, "paytable closes")
	local played = #stub.sounds
	assert(played > 0, "sounds played")
	W.sound:Click()
	assert(GuildSlotsDB.sound == false, "sound off saved")
	queue(0, 1, 2)
	W.spin:Click()
	settle()
	assert(#stub.sounds == played, "no sounds when off")
	stub.slash("/gs", "sound")
	assert(GuildSlotsDB.sound == true, "sound on via slash")
	stub.slash("/gs", "space")
	assert(GuildSlotsDB.space == false and not W.frame:IsKeyboardEnabled(), "space option off")
	stub.slash("/gs", "help")
	W.frame:GetScript("OnDragStop")(W.frame)
	assert(type(GuildSlotsDB.pos) == "table", "position saved")
	stub.slash("/gs", "reset")
	assert(GuildSlotsDB.pos == nil, "position reset")
	assert(GuildSlotsDB.soloBalance == S.game.balance, "balance saved")
	assert(W.footer:GetText() == L.FOOTER, "footer text")

	-- 10. A few hundred random spins with gambles, frame times 5..60 ms.
	for i = 1, 60 do
		W.spin:Click()
		ticks(20, function(k) return 0.005 + ((k * 7 + i) % 12) * 0.005 end)
		settle()
		if W.offerRow:IsShown() and i % 2 == 0 then
			W.gamble:Click()
			settle()
		end
		if S.game.balance < 100 then W.refill:Click() end
		shownMatches("random spin " .. i)
	end

	local unknown = {}
	for k in pairs(stub.unknown) do unknown[#unknown + 1] = k end
	table.sort(unknown)
	return unknown
end

for _, locale in ipairs({ "enUS", "deDE" }) do
	local ok, res = xpcall(function() return scenario(locale) end, debug.traceback)
	if ok then
		io.write("smoke ", locale, ": ok")
		if #res > 0 then io.write(" (unmodelled methods, no-ops: ", table.concat(res, ", "), ")") end
		io.write("\n")
	else
		failures = failures + 1
		io.write("smoke ", locale, ": FAIL\n", res, "\n")
	end
end
os.exit(failures == 0 and 0 or 1)
