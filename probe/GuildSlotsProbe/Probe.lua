-- Guild Slots probe (milestone 0): confirms on the live client every API the design relies on.
-- Results are printed and stored in GuildSlotsProbeDB (written on logout or /reload).
--
--   /gsprobe            local checks (build, API presence, bit, entropy, roster, permissions, lockdown flags)
--   /gsprobe sv         SavedVariables history (run once, fully restart the client, run again)
--   /gsprobe ping       GUILD ping; every online member with the probe answers (round-trip time)
--   /gsprobe burst [n]  sends n (default 15) GUILD messages at once; receivers report how many arrived
--   /gsprobe note [name] [timer]  officer-note write test (default: yourself), original note is restored
--   /gsprobe info [timer]         guild-info write test (appends a line, measures max length, restores)
--   /gsprobe bank       guild bank money log (only at the vault; also read automatically on open)
--   /gsprobe more       hash speed, C_EncodingUtil, clocks, roster/rank checks (local, no messages)
--   /gsprobe bytes      message length limit + byte safety via the own GUILD echo
--   /gsprobe svbig [n]  writes n (default 5000) ledger-like rows; next boot checks they came back
--   /gsprobe report     prints everything collected so far
--   /gsprobe reset      clears stored results (keeps the SavedVariables history)
--
-- "timer" runs the write from C_Timer.After instead of the slash command, i.e. WITHOUT a hardware event.
local ADDON, ns = ...
local PREFIX = "GSLOTSPRB"

GuildSlotsProbeDB = GuildSlotsProbeDB or {}
local DB = GuildSlotsProbeDB

local function say(msg) print("|cffffcc00GSProbe|r " .. tostring(msg)) end
local function now() return GetServerTime and GetServerTime() or time() end

local function log(section, entry)
	DB.results = DB.results or {}
	DB.results[section] = DB.results[section] or {}
	local list = DB.results[section]
	entry.t = now()
	list[#list + 1] = entry
end

-- ---------------------------------------------------------------- SavedVariables history

local function recordBoot(isInitialLogin, isReloadingUi)
	DB.sv = DB.sv or { boots = 0, history = {} }
	DB.sv.boots = DB.sv.boots + 1
	local h = DB.sv.history
	h[#h + 1] = {
		boot = DB.sv.boots,
		initialLogin = isInitialLogin and true or false,
		reload = isReloadingUi and true or false,
		t = now(),
	}
	while #h > 20 do table.remove(h, 1) end
	say(("SavedVariables: boot #%d (%s). If this says #1 after a full client restart, cold-start loading is broken.")
		:format(DB.sv.boots, isReloadingUi and "reload" or (isInitialLogin and "login" or "zone")))
end

local function showSv()
	if not DB.sv then return say("no SavedVariables history yet") end
	say(("boots stored: %d"):format(DB.sv.boots))
	for _, e in ipairs(DB.sv.history) do
		say(("  #%d %s%s at %s"):format(e.boot, e.initialLogin and "login" or "", e.reload and "reload" or "",
			date("%Y-%m-%d %H:%M:%S", e.t)))
	end
end

-- ---------------------------------------------------------------- roster helpers

local function myName()
	local n, r = UnitFullName("player")
	if not r or r == "" then r = GetNormalizedRealmName and GetNormalizedRealmName() or "" end
	return n .. "-" .. r
end

local function normalize(name)
	if not name then return nil end
	if not name:find("-", 1, true) then
		local realm = GetNormalizedRealmName and GetNormalizedRealmName() or ""
		name = name .. "-" .. realm
	end
	return name
end

-- Character names may contain spaces ("First Last"); compare without the realm suffix, case-insensitive.
local function baseName(name)
	if not name then return "" end
	return (name:gsub("%-[^%-]+$", "")):lower()
end

-- WoW Forever: CHAT_MSG_ADDON delivers the full "First Last" name, UnitName("player") only "First".
local function isMe(name)
	if not name then return false end
	local full = GetUnitName and GetUnitName("player", true) or UnitName("player")
	return name:lower() == full:lower() or baseName(name) == baseName(full)
end

local function findMember(name)
	local want = baseName(name)
	for i = 1, GetNumGuildMembers() do
		local n, rankName, rankIndex, _, _, _, publicNote, officerNote, online, _, _, _, _, _, _, _, guid =
			GetGuildRosterInfo(i)
		if n and baseName(n) == want then
			return {
				index = i, name = n, rankName = rankName, rankIndex = rankIndex,
				publicNote = publicNote, officerNote = officerNote, online = online, guid = guid,
			}
		end
	end
end

local function requestRoster()
	if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster()
	elseif GuildRoster then GuildRoster() end
end

-- ---------------------------------------------------------------- local checks

local function lockdownFlags()
	local r = {}
	if C_ChatInfo then
		if C_ChatInfo.InChatMessagingLockdown then
			r.inChatMessagingLockdown = C_ChatInfo.InChatMessagingLockdown()
		end
		if C_ChatInfo.AreOutgoingAddonChatMessagesRestricted then
			r.outgoingAddonRestricted = C_ChatInfo.AreOutgoingAddonChatMessagesRestricted()
		end
	end
	-- 12.x restriction system (present in Forever): Combat, Encounter, ChallengeMode, PvPMatch, Map, Chat
	local RA, T = C_RestrictedActions, Enum and Enum.AddOnRestrictionType
	if RA and RA.GetAddOnRestrictionState and T then
		r.restrictions = {}
		for name, id in pairs(T) do
			local ok, state = pcall(RA.GetAddOnRestrictionState, id)
			r.restrictions[name] = ok and state or ("error: " .. tostring(state))
		end
	end
	local inInstance, instanceType = IsInInstance()
	r.inInstance, r.instanceType = inInstance and true or false, instanceType
	r.inCombat = InCombatLockdown() and true or false
	return r
end

local function logLockdown(trigger)
	local r = lockdownFlags()
	r.trigger = trigger
	log("lockdown", r)
	return r
end

local function runChecks()
	local R = {}
	local version, build, bdate, interface = GetBuildInfo()
	R.build = { version = version, build = build, date = bdate, interface = interface, project = WOW_PROJECT_ID }
	R.lua = _VERSION

	local function kind(path)
		local v = _G
		for part in path:gmatch("[^%.]+") do
			if type(v) ~= "table" then return "nil" end
			v = v[part]
		end
		return type(v)
	end
	R.api = {}
	for _, p in ipairs({
		"C_ChatInfo.RegisterAddonMessagePrefix", "C_ChatInfo.SendAddonMessage",
		"C_ChatInfo.InChatMessagingLockdown", "C_ChatInfo.AreOutgoingAddonChatMessagesRestricted",
		"C_GuildInfo.GuildRoster", "C_GuildInfo.SetNote", "C_GuildInfo.SetInfoText", "C_GuildInfo.GetInfoText",
		"C_GuildInfo.CanEditOfficerNote", "C_GuildInfo.CanViewOfficerNote", "C_GuildInfo.IsGuildOfficer",
		"GuildRosterSetOfficerNote", "GuildRoster", "GetGuildRosterInfo", "GetNumGuildMembers",
		"GetGuildInfoText", "SetGuildInfoText", "CanEditGuildInfo",
		"GetServerTime", "GetTime", "debugprofilestop", "GetCursorPosition", "UnitGUID",
		"bit.band", "bit.bor", "bit.bxor", "bit.rshift", "bit.lshift", "bit.bnot", "bit.tobit",
		"C_EncodingUtil.CompressString", "C_EncodingUtil.SerializeCBOR", "C_EncodingUtil.EncodeHex",
		"LibStub", "ChatThrottleLib", "Ambiguate", "GetNormalizedRealmName",
	}) do
		R.api[p] = kind(p)
	end

	-- bit semantics a SHA-256 port depends on (signed 32-bit results in LuaBitOp)
	if bit then
		R.bit = {
			band = bit.band(0xFFFFFFFF, 0x0F0F0F0F),
			rshift = bit.rshift(0x80000000, 1),
			lshift = bit.lshift(1, 31),
			bxor = bit.bxor(0xAAAAAAAA, 0x55555555),
			ror = bit.ror and bit.ror(1, 1) or "no ror",
			tobitBig = bit.tobit and bit.tobit(2 ^ 32 + 5) or "no tobit",
		}
	end

	R.entropy = { serverTime = now(), time = GetTime(), profile = debugprofilestop and debugprofilestop() or "nil" }

	R.guild = { inGuild = IsInGuild() and true or false }
	if IsInGuild() then
		requestRoster()
		R.guild.members = GetNumGuildMembers()
		R.guild.canEditInfo = CanEditGuildInfo and CanEditGuildInfo() or "nil"
		R.guild.canEditOfficerNote = C_GuildInfo and C_GuildInfo.CanEditOfficerNote and C_GuildInfo.CanEditOfficerNote()
		R.guild.canViewOfficerNote = C_GuildInfo and C_GuildInfo.CanViewOfficerNote and C_GuildInfo.CanViewOfficerNote()
		R.guild.isOfficer = C_GuildInfo and C_GuildInfo.IsGuildOfficer and C_GuildInfo.IsGuildOfficer()
		local me = findMember(GetUnitName("player", true))
		if me then
			R.guild.myRankIndex, R.guild.myRankName = me.rankIndex, me.rankName
			R.guild.guidFromRoster = me.guid ~= nil
		end
		local info = GetGuildInfoText and GetGuildInfoText() or ""
		R.guild.infoTextLength = #info
	end

	R.lockdown = lockdownFlags()
	DB.checks = R

	say(("build %s (%s), interface %s, %s"):format(tostring(version), tostring(build), tostring(interface), R.lua))
	local missing = {}
	for p, k in pairs(R.api) do if k == "nil" then missing[#missing + 1] = p end end
	table.sort(missing)
	say("missing APIs: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
	if R.bit then
		say(("bit: band=%s rshift=%s lshift=%s bxor=%s ror=%s"):format(
			tostring(R.bit.band), tostring(R.bit.rshift), tostring(R.bit.lshift), tostring(R.bit.bxor), tostring(R.bit.ror)))
	end
	say(("guild: in=%s members=%s rank=%s editInfo=%s editOfficerNote=%s officer=%s infoLen=%s"):format(
		tostring(R.guild.inGuild), tostring(R.guild.members), tostring(R.guild.myRankIndex),
		tostring(R.guild.canEditInfo), tostring(R.guild.canEditOfficerNote), tostring(R.guild.isOfficer),
		tostring(R.guild.infoTextLength)))
	say(("lockdown: chat=%s addonOut=%s instance=%s combat=%s"):format(
		tostring(R.lockdown.inChatMessagingLockdown), tostring(R.lockdown.outgoingAddonRestricted),
		tostring(R.lockdown.instanceType), tostring(R.lockdown.inCombat)))
end

-- ---------------------------------------------------------------- addon messages

local pending = {}      -- ping id -> sent time (GetTime)
local burstSeen = {}    -- "sender:burstId" -> count

local function send(msg, channel, target)
	local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel, target)
	return ok, res
end

local function ping()
	if not IsInGuild() then return say("not in a guild") end
	local id = tostring(math.floor(GetTime() * 1000))
	pending[id] = GetTime()
	local ok, res = send("PING|" .. id, "GUILD")
	log("ping", { id = id, sendOk = ok, result = tostring(res), lockdown = lockdownFlags() })
	say(("PING %s sent: ok=%s result=%s (answers follow)"):format(id, tostring(ok), tostring(res)))
end

local function burst(n)
	if not IsInGuild() then return say("not in a guild") end
	n = tonumber(n) or 15
	local id = tostring(math.floor(GetTime() * 1000))
	local results = {}
	for i = 1, n do
		local ok, res = send(("BURST|%s|%d|%d"):format(id, i, n), "GUILD")
		results[i] = ok and tostring(res) or ("error: " .. tostring(res))
	end
	log("burst", { id = id, n = n, results = results })
	say(("BURST %s: sent %d, send results: %s"):format(id, n, table.concat(results, ",")))
	say("receivers print how many arrived after 5 s")
end

local onBytesEcho -- defined further down

local function onAddonMessage(prefix, msg, channel, sender)
	if prefix ~= PREFIX then return end
	if isMe(sender) and onBytesEcho(msg) then return end
	local kind, a, b, c = strsplit("|", msg)
	local isSelf = isMe(sender)
	-- raw trace of everything that arrives, with the sender exactly as the server delivers it
	log("received", { kind = kind, channel = channel, sender = sender, isSelf = isSelf })
	say(("received %s on %s from %q (self=%s)"):format(tostring(kind), tostring(channel), tostring(sender), tostring(isSelf)))
	if kind == "SELF" then
		local t0 = pending[a]
		log("selfWhisper", { id = a, rttMs = t0 and math.floor((GetTime() - t0) * 1000) or -1 })
		return
	end
	if kind == "PING" and isSelf then
		-- the server echoes our own GUILD messages: proves sending works even with one character
		local t0 = pending[a]
		local rtt = t0 and math.floor((GetTime() - t0) * 1000) or -1
		log("ping", { echo = true, id = a, rttMs = rtt, channel = channel })
		say(("own PING came back from the server after %d ms: sending works"):format(rtt))
	elseif kind == "PING" and not isSelf then
		send("PONG|" .. a .. "|" .. sender, "GUILD")
	elseif kind == "PONG" then
		local t0 = pending[a]
		if t0 and isMe(b) then
			local rtt = math.floor((GetTime() - t0) * 1000)
			log("ping", { pongFrom = sender, id = a, rttMs = rtt, channel = channel })
			say(("PONG from %s: %d ms"):format(sender, rtt))
		end
	elseif kind == "BURST" and not isSelf then
		local key = sender .. ":" .. a
		if not burstSeen[key] then
			burstSeen[key] = 0
			C_Timer.After(5, function()
				local got = burstSeen[key]
				log("burstReceived", { from = sender, id = a, expected = tonumber(c), received = got })
				say(("BURST from %s: received %d of %s"):format(sender, got, tostring(c)))
				send(("BURSTACK|%s|%d|%s"):format(a, got, tostring(c)), "GUILD")
			end)
		end
		burstSeen[key] = burstSeen[key] + 1
	elseif kind == "BURSTACK" and not isSelf then
		say(("%s received %s of %s from burst %s"):format(sender, tostring(b), tostring(c), tostring(a)))
		log("burst", { ackFrom = sender, id = a, received = tonumber(b), expected = tonumber(c) })
	end
end

-- ---------------------------------------------------------------- officer note write

local NOTE_TEST = "GS:probe:" .. string.rep("0123456789", 4) -- 49 chars, longer than the expected 31 limit

local function setOfficerNote(member, text)
	if C_GuildInfo and C_GuildInfo.SetNote and member.guid then
		return pcall(C_GuildInfo.SetNote, member.guid, text, false), "C_GuildInfo.SetNote"
	elseif GuildRosterSetOfficerNote then
		return pcall(GuildRosterSetOfficerNote, member.index, text), "GuildRosterSetOfficerNote"
	end
	return false, "no setter"
end

local function noteTest(name, viaTimer)
	if not IsInGuild() then return say("not in a guild") end
	requestRoster()
	local member = findMember(name or GetUnitName("player", true))
	if not member then return say(("member not found: %q"):format(tostring(name))) end
	local original = member.officerNote or ""
	if original ~= "" and original:sub(1, 3) ~= "GS:" then
		return say(("officer note of %s is in use (%q); refusing to overwrite. Test on a member with an empty note.")
			:format(member.name, original))
	end
	DB.noteBackup = { name = member.name, note = original }

	local function run()
		local ok, api = setOfficerNote(member, NOTE_TEST)
		local entry = { target = isMe(member.name) and "<me>" or "<other member>", api = api, hardwareEvent = not viaTimer, callOk = ok }
		say(("officer note write via %s (%s): call ok=%s; reading back in 3 s")
			:format(api, viaTimer and "timer, no hardware event" or "slash command", tostring(ok)))
		requestRoster()
		C_Timer.After(3, function()
			local after = findMember(member.name)
			local got = after and after.officerNote or ""
			entry.readBack, entry.readBackLength = got, #got
			entry.written = got:sub(1, 9) == "GS:probe:"
			log("officerNote", entry)
			say(("read back %q (length %d, written=%s)"):format(got, #got, tostring(entry.written)))
			-- restore
			setOfficerNote(after or member, original)
			requestRoster()
			C_Timer.After(3, function()
				local back = findMember(member.name)
				local restored = back and back.officerNote == original
				say(("restore to %q: %s"):format(original, restored and "ok" or "NOT CONFIRMED, check the roster"))
				entry.restored = restored
			end)
		end)
	end

	if viaTimer then C_Timer.After(0.5, run) else run() end
end

-- ---------------------------------------------------------------- guild info write

local function setInfo(text)
	if C_GuildInfo and C_GuildInfo.SetInfoText then
		return pcall(C_GuildInfo.SetInfoText, text), "C_GuildInfo.SetInfoText"
	elseif SetGuildInfoText then
		return pcall(SetGuildInfoText, text), "SetGuildInfoText"
	end
	return false, "no setter"
end

local function getInfo()
	if GetGuildInfoText then return GetGuildInfoText() or "" end
	if C_GuildInfo and C_GuildInfo.GetInfoText then return C_GuildInfo.GetInfoText() or "" end
	return ""
end

local function infoTest(viaTimer, force)
	if not IsInGuild() then return say("not in a guild") end
	local original = getInfo()
	if original == "" and not force then
		-- the text may simply not be loaded yet; restoring "" would wipe the real guild info
		requestRoster()
		return say("guild info reads empty (probably not loaded yet). Open the guild info tab once, then run "
			.. "/gsprobe info again. Use '/gsprobe info force' only if the guild info is really empty.")
	end
	DB.infoBackup = original
	say(("guild info backed up (%d chars) to GuildSlotsProbeDB.infoBackup"):format(#original))

	local function run()
		local line = "GS1;L=0;E=10,50,100"
		local text = (original ~= "" and (original .. "\n") or "") .. line
		local ok, api = setInfo(text)
		local entry = { api = api, hardwareEvent = not viaTimer, callOk = ok, originalLength = #original }
		say(("guild info write via %s (%s): call ok=%s; reading back in 3 s")
			:format(api, viaTimer and "timer, no hardware event" or "slash command", tostring(ok)))
		requestRoster()
		C_Timer.After(3, function()
			local got = getInfo()
			entry.lineWritten = got:find(line, 1, true) ~= nil
			-- max length: write an oversized text and see what survives
			local long = (original ~= "" and (original .. "\n") or "") .. string.rep("x", 1200)
			setInfo(long)
			requestRoster()
			C_Timer.After(3, function()
				entry.maxLength = #getInfo()
				-- restore
				setInfo(original)
				requestRoster()
				C_Timer.After(3, function()
					entry.restored = getInfo() == original
					log("guildInfo", entry)
					say(("line written=%s, max length=%d, restored=%s"):format(
						tostring(entry.lineWritten), entry.maxLength, tostring(entry.restored)))
					if not entry.restored then
						say("RESTORE NOT CONFIRMED: the original text is in GuildSlotsProbeDB.infoBackup")
					end
				end)
			end)
		end)
	end

	if viaTimer then C_Timer.After(0.5, run) else run() end
end

-- ---------------------------------------------------------------- guild bank money log

-- Other players' names are stored redacted: we only need the format (surname? realm?), not who.
local function redact(name)
	if not name then return "nil" end
	if isMe(name) then return "<me>" end
	local hasSpace = name:find(" ", 1, true) ~= nil
	local hasDash = name:find("-", 1, true) ~= nil
	return ("%s*** (len %d, space=%s, dash=%s)"):format(name:sub(1, 1), #name, tostring(hasSpace), tostring(hasDash))
end

local bankOpen = false

local function readMoneyLog(trigger)
	local n = GetNumGuildBankMoneyTransactions and GetNumGuildBankMoneyTransactions() or -1
	local entries = {}
	for i = 1, math.max(n, 0) do
		local kind, name, amount, years, months, days, hours = GetGuildBankMoneyTransaction(i)
		entries[i] = {
			kind = tostring(kind), name = redact(name), amount = amount,
			ago = ("%sy %sm %sd %sh"):format(tostring(years), tostring(months), tostring(days), tostring(hours)),
		}
	end
	log("bankLog", { trigger = trigger, count = n, entries = entries, bankMoney = GetGuildBankMoney and GetGuildBankMoney() })
	say(("guild bank money log (%s): %d entries"):format(trigger, n))
	for i = math.max(1, #entries - 4), #entries do
		local e = entries[i]
		say(("  #%d %s %s %s copper, %s ago"):format(i, e.kind, e.name, tostring(e.amount), e.ago))
	end
end

local function queryBank(trigger)
	if not bankOpen then
		return say("open the guild bank first (the log can only be read at the vault); it is read automatically on open")
	end
	-- the money log is the tab after the last item tab
	local tab = (MAX_GUILDBANK_TABS or 8) + 1
	local ok, err = pcall(QueryGuildBankLog, tab)
	say(("QueryGuildBankLog(%d): ok=%s %s"):format(tab, tostring(ok), ok and "" or tostring(err)))
	C_Timer.After(2, function() readMoneyLog(trigger) end)
end

-- ---------------------------------------------------------------- hash speed + correctness

local function hashTest()
	local sha = ns.sha256
	local vectors = {
		{ "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
		{ "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
		{ "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
			"248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1" },
	}
	local correct = 0
	for _, v in ipairs(vectors) do if sha(v[1]) == v[2] then correct = correct + 1 end end
	-- one spin = one hash over ~100 bytes (key, spin number, witness parts); a luck-index recompute = many
	local input = string.rep("k", 64) .. "|000123|" .. string.rep("w", 30)
	local t0 = debugprofilestop()
	local h = input
	for _ = 1, 1000 do h = sha(h .. input) end
	local ms = debugprofilestop() - t0
	local r = { vectorsOk = correct, vectorsTotal = #vectors, ms1000 = math.floor(ms), usPerHash = math.floor(ms) }
	log("hash", r)
	say(("SHA-256: %d/%d test vectors ok, 1000 chained hashes (~170 B each) in %d ms (%d µs per hash)")
		:format(correct, #vectors, r.ms1000, r.usPerHash))
end

-- ---------------------------------------------------------------- C_EncodingUtil + time + hash-like APIs

local function encTest()
	local r = { funcs = {}, roundTrip = {} }
	local E = C_EncodingUtil
	if E then
		for k, v in pairs(E) do if type(v) == "function" then r.funcs[#r.funcs + 1] = k end end
		table.sort(r.funcs)
		local sample = "GS1|buy|" .. string.rep("ab", 40) .. "\1\2\255"
		local function try(name, enc, dec, input)
			if not (E[enc] and E[dec]) then r.roundTrip[name] = "missing"; return end
			local ok, out = pcall(E[enc], input)
			if not ok then r.roundTrip[name] = "encode error: " .. tostring(out); return end
			local ok2, back = pcall(E[dec], out)
			if not ok2 then r.roundTrip[name] = "decode error: " .. tostring(back); return end
			r.roundTrip[name] = (back == input) and ("ok, " .. #input .. " -> " .. #tostring(out) .. " bytes") or "MISMATCH"
		end
		try("base64", "EncodeBase64", "DecodeBase64", sample)
		try("hex", "EncodeHex", "DecodeHex", sample)
		try("compress", "CompressString", "DecompressString", string.rep(sample, 4))
		if E.SerializeCBOR and E.DeserializeCBOR then
			local ok, out = pcall(E.SerializeCBOR, { n = 7, s = "x", list = { 1, 2, 3 } })
			-- never print the raw CBOR: binary bytes ("|") can swallow the chat line
			local ok2, back = false, nil
			if ok then ok2, back = pcall(E.DeserializeCBOR, out) end
			if not ok then r.roundTrip.cbor = "encode error: " .. tostring(out)
			elseif not ok2 then r.roundTrip.cbor = "decode error: " .. tostring(back)
			elseif type(back) == "table" and back.n == 7 and back.list and back.list[3] == 3 then
				r.roundTrip.cbor = "ok, " .. #out .. " bytes"
			else r.roundTrip.cbor = "decoded to " .. type(back) .. ", values differ" end
		end
	end
	-- any built-in hash would replace the Lua SHA-256: functions only, globals and C_ namespaces
	r.hashLike = {}
	local function hashy(k) local l = k:lower(); return l:find("hash") or l:find("sha%d") or l:find("crypt") or l:find("digest") end
	for k, v in pairs(_G) do
		if type(k) == "string" then
			if type(v) == "function" and hashy(k) then r.hashLike[#r.hashLike + 1] = k end
			if type(v) == "table" and k:find("^C_") then
				for f, fv in pairs(v) do
					if type(f) == "string" and type(fv) == "function" and hashy(f) then r.hashLike[#r.hashLike + 1] = k .. "." .. f end
				end
			end
		end
	end
	table.sort(r.hashLike)
	-- clocks: commits and luck index need a time every client agrees on
	r.time = { serverTime = GetServerTime(), localTime = time(), utcOffsetH = (time() - time(date("!*t"))) / 3600 }
	r.time.serverMinusLocal = r.time.serverTime - r.time.localTime
	log("enc", r)
	say("C_EncodingUtil functions: " .. (#r.funcs > 0 and table.concat(r.funcs, ", ") or "none"))
	for name, res in pairs(r.roundTrip) do say(("  %s: %s"):format(name, res)) end
	say("hash-like globals: " .. (#r.hashLike > 0 and table.concat(r.hashLike, ", ") or "none"))
	say(("time: server-local=%ds, UTC offset %sh"):format(r.time.serverMinusLocal, tostring(r.time.utcOffsetH)))
end

-- ---------------------------------------------------------------- roster: can a receiver verify officers?

-- Stores only counts and rank permissions, never member names.
local function rosterTest()
	if not IsInGuild() then return say("not in a guild") end
	requestRoster()
	local r = { members = GetNumGuildMembers(), withSpace = 0, withDash = 0, duplicates = 0, missingRank = 0 }
	local seen = {}
	for i = 1, r.members do
		local n, _, rankIndex = GetGuildRosterInfo(i)
		if n then
			if n:find(" ", 1, true) then r.withSpace = r.withSpace + 1 end
			if n:find("-", 1, true) then r.withDash = r.withDash + 1 end
			local key = baseName(n)
			if seen[key] then r.duplicates = r.duplicates + 1 end
			seen[key] = true
			if rankIndex == nil then r.missingRank = r.missingRank + 1 end
		end
	end
	-- the sender name from CHAT_MSG_ADDON must be found in the roster to check the rank
	r.ownSenderFound = findMember(GetUnitName("player", true)) ~= nil
	r.numRanks = GuildControlGetNumRanks and GuildControlGetNumRanks() or "nil"
	r.rankFlags = {}
	local getFlags = GuildControlGetRankFlags or (C_GuildInfo and C_GuildInfo.GuildControlGetRankFlags)
	if getFlags and type(r.numRanks) == "number" then
		for i = 1, r.numRanks do
			-- retail returns one table of booleans, older clients several booleans: keep both shapes
			local ok, flags = pcall(function(idx)
				local first, second = getFlags(idx)
				if type(first) == "table" then return first end
				return { getFlags(idx) }
			end, i)
			r.rankFlags[i] = ok and flags or tostring(flags)
		end
	end
	r.api = {
		GuildControlGetRankFlags = type(GuildControlGetRankFlags),
		GuildControlGetRankName = type(GuildControlGetRankName),
		["C_GuildInfo.GuildControlGetRankFlags"] = C_GuildInfo and type(C_GuildInfo.GuildControlGetRankFlags) or "nil",
		["C_GuildInfo.MemberExistsByName"] = C_GuildInfo and type(C_GuildInfo.MemberExistsByName) or "nil",
	}
	log("roster", r)
	say(("roster: %d members, %d with space, %d with dash, %d duplicate base names, rank missing %d, own sender found=%s")
		:format(r.members, r.withSpace, r.withDash, r.duplicates, r.missingRank, tostring(r.ownSenderFound)))
	say(("ranks: %s, rank flags read for %d ranks; GuildControlGetRankFlags=%s, C_GuildInfo.GuildControlGetRankFlags=%s")
		:format(tostring(r.numRanks), #r.rankFlags, r.api.GuildControlGetRankFlags, r.api["C_GuildInfo.GuildControlGetRankFlags"]))
end

-- ---------------------------------------------------------------- message size + byte safety (own GUILD echo)

local byteSent = {} -- part -> payload

local function bytesTest()
	if not IsInGuild() then return say("not in a guild") end
	local r = { lengths = {} }
	-- length limit: the server echo tells whether long messages arrive intact
	for _, len in ipairs({ 250, 255, 256 }) do
		local head = ("LEN|%d|"):format(len)
		local ok, res = send(head .. string.rep("x", len - #head), "GUILD")
		r.lengths[len] = { ok = ok, result = tostring(res) }
	end
	-- byte safety: all byte values 1..255 in two messages, plus one with a NUL byte
	local lo, hi = {}, {}
	for b = 1, 127 do lo[#lo + 1] = string.char(b) end
	for b = 128, 255 do hi[#hi + 1] = string.char(b) end
	byteSent["1"], byteSent["2"], byteSent["0"] = table.concat(lo), table.concat(hi), "a\0b"
	for part, payload in pairs(byteSent) do
		local ok, res = send("BYTES|" .. part .. "|" .. payload, "GUILD")
		r["send" .. part] = { ok = ok, result = tostring(res) }
	end
	log("bytes", r)
	for len, e in pairs(r.lengths) do say(("LEN %d: send ok=%s result=%s"):format(len, tostring(e.ok), e.result)) end
	say(("BYTES sent: 1..127 %s, 128..255 %s, NUL %s; echo results follow"):format(
		r.send1.result, r.send2.result, r.send0.result))
end

-- handles the raw message before the "|" split, since the payload contains "|" itself
function onBytesEcho(msg)
	local len = msg:match("^LEN|(%d+)|")
	if len then
		log("bytesEcho", { kind = "LEN", sent = tonumber(len), received = #msg })
		say(("LEN %s echo: %d bytes arrived"):format(len, #msg))
		return true
	end
	local part, payload = msg:match("^BYTES|(%d)|(.*)$")
	if not part then return false end
	local want = byteSent[part]
	local bad = {}
	if want then
		for i = 1, math.max(#want, #payload) do
			if want:byte(i) ~= payload:byte(i) then
				bad[#bad + 1] = ("%s->%s"):format(tostring(want:byte(i) or "none"), tostring(payload:byte(i) or "none"))
				if #bad >= 10 then break end
			end
		end
	end
	local e = { part = part, sentLen = want and #want or -1, receivedLen = #payload, intact = want == payload, firstDiffs = bad }
	log("bytesEcho", e)
	say(("BYTES %s echo: intact=%s (sent %d, got %d)%s"):format(part, tostring(e.intact), e.sentLen, e.receivedLen,
		#bad > 0 and (" diffs " .. table.concat(bad, " ")) or ""))
	return true
end

-- ---------------------------------------------------------------- SavedVariables size

-- Writes a ledger-sized table; the next boot (reload AND full restart) checks it came back complete.
local function svBig(rows)
	rows = tonumber(rows) or 5000
	local data = {}
	for i = 1, rows do
		data[i] = { i, ns.sha256(tostring(i)), (i * 37) % 1000, "BUY" }
	end
	DB.svLoad = { rows = rows, last = data[rows][2], written = now(), data = data }
	say(("wrote %d ledger-like rows (~%d KB) into SavedVariables; /reload and later a full restart check them")
		:format(rows, math.floor(rows * 90 / 1024)))
end

local function checkSvLoad()
	local s = DB.svLoad
	if not s then return end
	local ok = type(s.data) == "table" and #s.data == s.rows and s.data[s.rows][2] == s.last
	log("svLoad", { rows = s.rows, complete = ok, writtenAt = s.written })
	say(("SavedVariables size test: %d rows %s"):format(s.rows, ok and "came back complete" or "INCOMPLETE"))
end

-- ---------------------------------------------------------------- report

local function report()
	if DB.checks then say("local checks: stored (see SavedVariables)") end
	showSv()
	local r = DB.results or {}
	for _, section in ipairs({ "ping", "burst", "burstReceived", "officerNote", "guildInfo", "lockdown", "blocked", "bankLog", "received", "selfWhisper",
		"hash", "enc", "roster", "bytes", "bytesEcho", "svLoad", "restrictionChanged" }) do
		local list = r[section]
		say(("%s: %d entries"):format(section, list and #list or 0))
	end
	local lock = r.lockdown or {}
	for i = math.max(1, #lock - 5), #lock do
		local e = lock[i]
		say(("  lockdown[%s] chat=%s addonOut=%s instance=%s combat=%s"):format(tostring(e.trigger),
			tostring(e.inChatMessagingLockdown), tostring(e.outgoingAddonRestricted),
			tostring(e.instanceType), tostring(e.inCombat)))
	end
end

-- ---------------------------------------------------------------- events + slash

local evf = CreateFrame("Frame")
evf:RegisterEvent("ADDON_LOADED")
evf:RegisterEvent("PLAYER_ENTERING_WORLD")
evf:RegisterEvent("CHAT_MSG_ADDON")
evf:RegisterEvent("PLAYER_REGEN_DISABLED")
evf:RegisterEvent("ADDON_ACTION_BLOCKED")
evf:RegisterEvent("ADDON_ACTION_FORBIDDEN")
evf:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
evf:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
pcall(evf.RegisterEvent, evf, "ENCOUNTER_START")
pcall(evf.RegisterEvent, evf, "ADDON_RESTRICTION_STATE_CHANGED")
pcall(evf.RegisterEvent, evf, "GUILDBANKFRAME_OPENED")
pcall(evf.RegisterEvent, evf, "GUILDBANKFRAME_CLOSED")
evf:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		if ... == ADDON then
			-- SavedVariables replace the global after the files ran: rebind.
			GuildSlotsProbeDB = GuildSlotsProbeDB or {}
			DB = GuildSlotsProbeDB
			C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
			checkSvLoad()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		local isInitialLogin, isReloadingUi = ...
		if isInitialLogin or isReloadingUi then recordBoot(isInitialLogin, isReloadingUi) end
		logLockdown("enterWorld")
	elseif event == "CHAT_MSG_ADDON" then
		onAddonMessage(...)
	elseif event == "ENCOUNTER_START" then
		-- boss pull: record the restriction state and try one GUILD ping (result 11 = AddOnMessageLockdown)
		C_Timer.After(2, function()
			logLockdown("encounter")
			ping()
		end)
	elseif event == "ADDON_RESTRICTION_STATE_CHANGED" then
		local rtype, state = ...
		log("restrictionChanged", { type = tostring(rtype), state = tostring(state), lockdown = lockdownFlags() })
	elseif event == "PLAYER_REGEN_DISABLED" then
		-- the flag is read one frame later, inside combat
		C_Timer.After(0.2, function() logLockdown("combat") end)
	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "GUILDBANKFRAME_OPENED" then
		local itype = ...
		local banker = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker
		if event == "GUILDBANKFRAME_OPENED" or (banker and itype == banker) then
			if not bankOpen then
				bankOpen = true
				say("guild bank opened (" .. event .. ")")
				queryBank("bankOpened")
			end
		end
	elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" or event == "GUILDBANKFRAME_CLOSED" then
		local itype = ...
		local banker = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker
		if event == "GUILDBANKFRAME_CLOSED" or (banker and itype == banker) then bankOpen = false end
	elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
		local addon, fn = ...
		if addon == ADDON then
			log("blocked", { event = event, func = tostring(fn) })
			say(("%s: %s"):format(event, tostring(fn)))
		end
	end
end)

SLASH_GSPROBE1 = "/gsprobe"
SlashCmdList.GSPROBE = function(input)
	input = strtrim(input or "")
	local cmd, rest = input:match("^(%S*)%s*(.-)$")
	cmd = (cmd or ""):lower()
	local viaTimer = false
	if rest:lower():match("%s?timer$") then
		viaTimer = true
		rest = strtrim(rest:gsub("%s?[Tt][Ii][Mm][Ee][Rr]$", ""))
	end
	if cmd == "" then runChecks()
	elseif cmd == "sv" then showSv()
	elseif cmd == "ping" then ping()
	elseif cmd == "self" then
		-- addon WHISPER to yourself: does the client receive anything at all?
		local id = tostring(math.floor(GetTime() * 1000))
		pending[id] = GetTime()
		local ok, res = send("SELF|" .. id, "WHISPER", GetUnitName("player", true))
		log("selfWhisper", { id = id, sendOk = ok, result = tostring(res) })
		say(("SELF whisper sent: ok=%s result=%s"):format(tostring(ok), tostring(res)))
	elseif cmd == "burst" then burst(rest)
	elseif cmd == "note" then noteTest(rest ~= "" and rest or nil, viaTimer)
	elseif cmd == "info" then infoTest(viaTimer, rest:lower() == "force")
	elseif cmd == "lock" then
		local r = logLockdown("manual")
		say(("lockdown: chat=%s addonOut=%s instance=%s combat=%s"):format(tostring(r.inChatMessagingLockdown),
			tostring(r.outgoingAddonRestricted), tostring(r.instanceType), tostring(r.inCombat)))
	elseif cmd == "bank" then queryBank("manual")
	elseif cmd == "more" then hashTest(); encTest(); rosterTest()
	elseif cmd == "bytes" then bytesTest()
	elseif cmd == "svbig" then svBig(rest)
	elseif cmd == "svclear" then DB.svLoad = nil; say("size test data removed")
	elseif cmd == "report" then report()
	elseif cmd == "reset" then DB.results, DB.checks = nil, nil; say("results cleared")
	else
		say("commands: (none) | sv | ping | burst [n] | self | bank | more | bytes | svbig [n] | svclear | note [name] [timer] | info [timer] | lock | report | reset")
	end
end
