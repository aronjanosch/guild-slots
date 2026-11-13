-- Smoke test for a witnessed account (docs/witness-spec.md section 8, docs/follow-spec.md
-- section 7) against tests/wowstub.lua, outside the client:
--   luajit tests/smoke_witness.lua
-- The player (Alice, the stub's character) plays through the slot window; officer Olga and the
-- members Bob and Carol are real guild sessions on the same fake GUILD channel, so they grant the
-- tokens and answer as witnesses. Runs once per locale (enUS, deDE).

local failures = 0

local LINE_W1 = "GSLOTS1;L=1;W=2;R=1;E=10,50,100;G=3;T=T2"
local LINE_W2 = "GSLOTS1;L=2;W=2;R=1;E=10,50,100;G=3;T=T2"
local OTHERS = { "Olga", "Bob Jones", "Carol" }
local OFFICERS = { Olga = true }

-- Fresh globals, a loaded addon and three other clients. Alice is a member (rank 3).
local function boot(locale, line)
	GuildSlotsDB = nil
	local stub = dofile("tests/wowstub.lua")
	stub.locale = locale
	stub.guildName = "Test Guild"
	stub.infoText = "Welcome to the guild\n" .. line .. "\nRaids on Friday"
	stub.roster = {
		{ name = "Alice Smith", rankIndex = 3, online = true },
		{ name = "Olga", rankIndex = 0, online = true },
		{ name = "Bob Jones", rankIndex = 4, online = true },
		{ name = "Carol", rankIndex = 4, online = true },
	}

	-- bus.queue: { sender, text } in send order; every message reaches every client, the sender
	-- included (the server echoes GUILD messages).
	local bus = { queue = {}, dropWit = false, paused = {} }
	local send = C_ChatInfo.SendAddonMessage
	C_ChatInfo.SendAddonMessage = function(prefix, text, channel, target)
		local code = send(prefix, text, channel, target)
		if channel == "GUILD" then
			bus.queue[#bus.queue + 1] = { stub.playerName, text, prefix }
		end
		return code
	end

	local ns = { random = function(n) return math.random(n) - 1 end }
	stub.loadAddon("GuildSlots", "GuildSlots", ns)

	local t0 = GetTime()
	local others = {}
	for _, name in ipairs(OTHERS) do
		local counter = 0
		local env = {
			guild = "Test Guild",
			me = name,
			now = function() return stub.serverTime + (GetTime() - t0) end,
			randomHex = function(n)
				counter = counter + 1
				local out = ""
				local i = 0
				while #out < n do
					i = i + 1
					out = out .. ns.Sha256.hex(name .. "|" .. counter .. "|" .. i)
				end
				return out:sub(1, n)
			end,
			send = function(text)
				bus.queue[#bus.queue + 1] = { name, text, "GSLOTS" }
				return true
			end,
			budget = function() return 10 end,
			isOfficer = function(n) return OFFICERS[n] == true end,
			line = function() return line end,
			store = {},
			version = "0.9.0",
			onEvent = function() end,
		}
		others[name] = ns.Guild.new(env)
	end

	stub.fire("ADDON_LOADED", "GuildSlots")
	stub.fire("PLAYER_LOGIN")
	stub.fire("GUILD_ROSTER_UPDATE")
	stub.slash("/gs", "help") -- the guild info is read on a hardware event

	local env = { stub = stub, ns = ns, L = ns.L, bus = bus, others = others }
	local function flush()
		while #bus.queue > 0 do
			local m = table.remove(bus.queue, 1)
			local sender, text = m[1], m[2]
			local wit = text:find("^1|WIT|") ~= nil
			if not (wit and bus.dropWit) and not bus.paused[sender] then
				stub.deliver(m[3], text, "GUILD", sender)
				for _, name in ipairs(OTHERS) do
					others[name]:onMessage(sender, text)
				end
			end
		end
	end
	function env.pump(n, dt)
		for _ = 1, n or 1 do
			stub.tick(dt or 1 / 60)
			for _, name in ipairs(OTHERS) do
				if not bus.paused[name] then
					others[name]:tick()
				end
			end
			flush()
		end
	end
	function env.count(kind)
		local n = 0
		for _, s in ipairs(stub.sent) do
			if s.text:match("^1|(%u+%d?)|") == kind then n = n + 1 end
		end
		return n
	end

	-- Everyone says hello; then Olga grants Alice 1000 tokens.
	env.pump(30)
	assert(others.Olga:grant("Alice Smith", 1000), "Olga grants")
	env.pump(30)
	local game = ns.Main.session():game()
	assert(game.balance == 1000, "1000 tokens credited: " .. tostring(game.balance))
	return env
end

local function fmt(ns, n)
	return ns.Anim.formatNumber(n, ns.L.THOUSANDS)
end

local function resting(game)
	return game.balance - (game:state() == "gamble" and game.pending or 0)
end

-- Until the window rests (idle or the card waiting for a colour) and nothing counts up.
local function settle(env)
	local S = env.ns.SlotFrame.state
	local guard = 0
	repeat
		env.pump(1)
		guard = guard + 1
		assert(guard < 4000, "animation never settles (phase " .. S.phase .. ")")
	until (S.phase == "idle" or S.phase == "pick") and next(S.counts) == nil
end

local function stops(W)
	local out = {}
	for r = 1, 5 do
		local reel = W.reels[r]
		out[r] = math.floor(reel.x + 0.5) % reel.n
	end
	return out
end

-- 1. Level 1: waiting spins, a void spin, gamble steps, turbo, status, closing while waiting.
local function level1Flow(locale)
	local env = boot(locale, LINE_W1)
	local ns, stub, L = env.ns, env.stub, env.L
	local W, S = ns.SlotFrame.widgets, ns.SlotFrame.state
	local session = ns.Main.session()
	local game = session:game()
	assert(game.level == 1, "a witnessed account")
	assert(game:status() == "ok", "three witnesses online: " .. game:status())

	-- Turbo: hidden and without effect on a witnessed account.
	GuildSlotsDB.turbo = true
	stub.slash("/gs")
	assert(S.mode == "guild" and S.game == game, "guild mode")
	assert(not W.turbo:IsShown(), "turbo button hidden on a witnessed account")

	-- A spin waits with the reels running, then lands.
	local spins = env.count("SPIN")
	W.spin:Click()
	assert(S.phase == "wait", "the window waits for the result: " .. S.phase .. ", " .. tostring(W.win:GetText()))
	env.pump(1)
	assert(env.count("SPIN") == spins + 1, "SPIN sent")
	assert(game:state() == "collecting", "the session collects")
	assert(W.balance:GetText() == fmt(ns, 990), "the stake is shown as taken")
	assert(not W.spin.enabled, "no spin while waiting")
	env.pump(10)
	for r = 1, 5 do
		assert(W.reels[r]:isSpinning(), "reel " .. r .. " runs while waiting")
	end
	local guard = 0
	while S.phase == "wait" do
		env.pump(1)
		guard = guard + 1
		assert(guard < 200, "the result never arrived")
	end
	assert(S.phase == "round", "the round plays once the result is there")
	assert(S.tm == ns.Theme.timing, "turbo has no effect on a witnessed account")
	settle(env)
	assert(game:state() ~= "collecting", "settled")
	assert(W.balance:GetText() == fmt(ns, resting(game)), "shown balance matches the account")
	assert(S.stats:get("guild").rounds == 1, "the round is booked")
	if W.offerRow:IsShown() then W.take:Click() end

	-- A void spin: the reels stop where they were, a notice, nothing booked, no stake taken.
	env.pump(180) -- the 2.5 s interval
	env.bus.dropWit = true
	local before, balance = stops(W), game.balance
	W.spin:Click()
	assert(S.phase == "wait", "void: waiting first")
	env.pump(10)
	settle(env)
	assert(game.balance == balance, "a void spin keeps the stake")
	assert(W.balance:GetText() == fmt(ns, balance), "the balance is shown back")
	local after = stops(W)
	for r = 1, 5 do
		assert(after[r] == before[r], "reel " .. r .. " back on its symbol")
	end
	assert(W.win:GetText() == L.VOID_SPIN, "void notice: " .. tostring(W.win:GetText()))
	assert(S.stats:get("guild").rounds == 1, "a void spin books nothing")
	env.bus.dropWit = false

	-- Autoplay goes on after a void spin.
	env.pump(180)
	env.bus.dropWit = true
	W.auto:Click()
	assert(S.auto and S.phase == "wait", "autoplay started a waiting spin")
	settle(env)
	assert(S.auto, "autoplay still on after a void spin")
	env.bus.dropWit = false
	local sent = env.count("SPIN")
	guard = 0
	while env.count("SPIN") == sent do
		env.pump(1)
		guard = guard + 1
		assert(guard < 600, "autoplay did not go on after a void spin")
	end
	W.auto:Click()
	settle(env)
	if W.offerRow:IsShown() then W.take:Click() end

	-- Gamble: spin until an offer comes up, then a step; the card stays face down until the
	-- result, a won or lost step then turns it over.
	local stepped = false
	for _ = 1, 60 do
		env.pump(180)
		W.spin:Click()
		settle(env)
		if W.offerRow:IsShown() then
			env.pump(180)
			W.gamble:Click()
			assert(S.phase == "pick", "the card waits for a colour")
			local steps = env.count("GAM")
			W.black:Click()
			assert(S.phase == "flip" and S.flip.wait, "the card waits for the result: " .. tostring(W.win:GetText()))
			env.pump(1)
			assert(env.count("GAM") == steps + 1, "GAM sent")
			env.pump(29)
			if game:state() == "collecting" then
				assert(W.card:GetTexture() == ns.Theme.tex.cardBack, "the card stays face down while collecting")
				assert(S.phase == "flip" and S.flip.wait, "still waiting for the step")
			end
			settle(env)
			assert(W.balance:GetText() == fmt(ns, resting(game)), "balance after a step")
			if S.phase == "pick" then W.take:Click() end
			if W.offerRow:IsShown() then W.take:Click() end
			stepped = true
			break
		end
	end
	assert(stepped, "never got a gamble offer")

	-- A void step leaves the card open while the win is still at stake.
	local voided = false
	for _ = 1, 60 do
		env.pump(180)
		W.spin:Click()
		settle(env)
		if W.offerRow:IsShown() then
			local pending = game.pending
			env.pump(180)
			W.gamble:Click()
			env.bus.dropWit = true
			W.black:Click()
			settle(env)
			env.bus.dropWit = false
			assert(W.win:GetText() == L.VOID_STEP, "void step notice: " .. tostring(W.win:GetText()))
			assert(S.phase == "pick" and W.cardOverlay:IsShown(), "the card stays open")
			assert(game.pending == pending, "the win is still at stake")
			W.take:Click()
			voided = true
			break
		end
	end
	assert(voided, "never got a gamble offer for the void step")

	-- Closing the window while waiting does not cancel the request; the next open shows the
	-- settled account.
	env.pump(180)
	W.spin:Click()
	assert(S.phase == "wait", "waiting before the close")
	stub.slash("/gs")
	assert(not W.frame:IsShown(), "closed")
	assert(game:state() == "collecting", "the request stays open")
	env.pump(120)
	assert(game:state() ~= "collecting", "the session finished it")
	stub.slash("/gs")
	assert(S.phase == "idle", "at rest after the open")
	assert(W.balance:GetText() == fmt(ns, resting(game)), "the settled balance is shown")
	if W.offerRow:IsShown() then W.take:Click() end

	-- Too few players: Bob and Carol go quiet and age out of the online list.
	env.bus.paused["Bob Jones"], env.bus.paused.Carol = true, true
	env.pump(1300, 0.25)
	assert(game:status() == "few_players", "few players: " .. game:status())
	local line = string.format(L.ST_FEW_PLAYERS, 2)
	assert(W.win:GetText() == line, "few players line: " .. tostring(W.win:GetText()))
	assert(W.statusOverlay:IsShown() and W.statusSub:GetText() == line, "few players panel")
	assert(not W.spin.enabled, "spin off with too few players")

	-- The witness_cheat notice goes to the chat with the witness's name.
	session.env.onEvent("notice", { kind = "witness_cheat", name = "Bob Jones" })
	local last = stub.chat[#stub.chat]
	assert(last and last:find(string.format(L.WITNESS_CHEAT, "Bob Jones"), 1, true), "witness_cheat notice: "
		.. tostring(last))
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
end

-- 2. Level 2: waiting for an officer.
local function level2Flow(locale)
	local env = boot(locale, LINE_W2)
	local ns, stub, L = env.ns, env.stub, env.L
	local W = ns.SlotFrame.widgets
	local game = ns.Main.session():game()
	assert(game.level == 2, "level 2 account")
	stub.slash("/gs")
	assert(not W.turbo:IsShown(), "no turbo at level 2")
	env.bus.paused.Olga = true
	env.pump(1300, 0.25)
	assert(game:status() == "no_officer", "no officer: " .. game:status())
	assert(W.win:GetText() == L.ST_NO_OFFICER, "no officer line: " .. tostring(W.win:GetText()))
	assert(not W.spin.enabled, "spin off without an officer")
	assert(#stub.blocked == 0, "protected call outside a hardware event: " .. tostring(stub.blocked[1]))
end

for _, locale in ipairs({ "enUS", "deDE" }) do
	local ok, err = xpcall(function()
		level1Flow(locale)
		level2Flow(locale)
	end, debug.traceback)
	if ok then
		io.write("smoke witness ", locale, ": ok\n")
	else
		failures = failures + 1
		io.write("smoke witness ", locale, ": FAIL\n", err, "\n")
	end
end
os.exit(failures == 0 and 0 or 1)
