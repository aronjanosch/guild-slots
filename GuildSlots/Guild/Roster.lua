local _, ns = ...

-- Guild facts from the client: guild name, own name, settings line, officer test, entropy.
-- See docs/guild-spec.md section 5. Nothing here touches the WoW API at load time.

local Roster = {}
ns.Roster = Roster

local Sha256, Settings = ns.Sha256, ns.Settings

local counter = 0
local listeners, frame = {}, nil

local function cutRealm(name)
	if type(name) ~= "string" then
		return nil
	end
	return (name:gsub("%-.*$", ""))
end

-- The guild info text is protected in this client: reading it works from a hardware event
-- (a click, a key, a slash command) but raises ADDON_ACTION_BLOCKED from a timer or an event
-- handler. So it is read only in Roster.refreshInfo(), which UI code calls from clicks and
-- slash commands, and everything else uses the copy. The copy is saved per guild so the
-- settings are known right after login.
local infoCache

local function guildName()
	if type(GetGuildInfo) ~= "function" then
		return nil
	end
	local name = GetGuildInfo("player")
	if type(name) == "string" and name ~= "" then
		return name
	end
end

local function savedInfo()
	local db = type(GuildSlotsDB) == "table" and GuildSlotsDB or nil
	local saved = db and db.info
	if type(saved) == "table" and type(saved.text) == "string" and saved.guild == guildName() then
		return saved.text
	end
end

local function infoText()
	if infoCache and infoCache.guild == guildName() then
		return infoCache.text
	end
	return savedInfo()
end

local fire

-- Reads the guild info text. Call only from a hardware event. Returns true when it was read.
function Roster.refreshInfo()
	if type(InCombatLockdown) == "function" and InCombatLockdown() then
		return false
	end
	local guild = guildName()
	if not guild then
		return false
	end
	local text
	if type(GetGuildInfoText) == "function" then
		text = GetGuildInfoText()
	elseif C_GuildInfo and type(C_GuildInfo.GetInfoText) == "function" then
		text = C_GuildInfo.GetInfoText()
	end
	if type(text) ~= "string" then
		return false
	end
	local before = infoText()
	infoCache = { guild = guild, text = text }
	if type(GuildSlotsDB) ~= "table" then
		GuildSlotsDB = {}
	end
	GuildSlotsDB.info = { guild = guild, text = text }
	if text ~= before then
		fire()
	end
	return true
end

function Roster.guild()
	return guildName()
end

function Roster.me()
	local name
	if type(GetUnitName) == "function" then
		name = GetUnitName("player", true)
	end
	if not name and type(UnitName) == "function" then
		name = UnitName("player")
	end
	return cutRealm(name)
end

function Roster.line()
	return Settings.find(infoText())
end

function Roster.settings()
	local line = Roster.line()
	if not line then
		return nil, "no_settings"
	end
	return Settings.parse(line)
end

local function requestRoster()
	if C_GuildInfo and type(C_GuildInfo.GuildRoster) == "function" then
		C_GuildInfo.GuildRoster()
	elseif type(GuildRoster) == "function" then
		GuildRoster()
	end
end

function Roster.members()
	local list = {}
	if type(GetNumGuildMembers) ~= "function" or type(GetGuildRosterInfo) ~= "function" then
		return list
	end
	for i = 1, GetNumGuildMembers() do
		local name, _, rankIndex, _, _, _, _, _, online = GetGuildRosterInfo(i)
		name = cutRealm(name)
		if name then
			list[#list + 1] = { name = name, rankIndex = rankIndex, online = online and true or false }
		end
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end

function Roster.isOfficer(name)
	name = cutRealm(name)
	if not name then
		return false
	end
	local s = Roster.settings()
	if not s then
		return false
	end
	for _, m in ipairs(Roster.members()) do
		if m.name == name then
			return type(m.rankIndex) == "number" and m.rankIndex <= s.R
		end
	end
	return false
end

function Roster.serverTime()
	return GetServerTime()
end

local function entropy()
	local parts = {
		GetTime(),
		type(debugprofilestop) == "function" and debugprofilestop() or 0,
		type(GetServerTime) == "function" and GetServerTime() or 0,
		type(UnitGUID) == "function" and UnitGUID("player") or "",
	}
	for _ = 1, 4 do
		parts[#parts + 1] = math.random(2147483647)
	end
	return table.concat(parts, "|")
end

function Roster.randomHex(n)
	if type(GuildSlotsDB) ~= "table" then
		GuildSlotsDB = {}
	end
	local db = GuildSlotsDB
	counter = counter + 1
	local pool = tostring(db.pool or "")
	pool = Sha256.hex(pool .. "|" .. counter .. "|" .. entropy())
	db.pool = pool
	local out = Sha256.hex("out|" .. pool .. "|" .. counter)
	local block = 1
	while #out < n do
		block = block + 1
		out = out .. Sha256.hex("out|" .. pool .. "|" .. counter .. "|" .. block)
	end
	return out:sub(1, n)
end

fire = function()
	for _, fn in ipairs(listeners) do
		fn()
	end
end

function Roster.onChange(fn)
	listeners[#listeners + 1] = fn
	if not frame then
		frame = CreateFrame("Frame")
		frame:RegisterEvent("GUILD_ROSTER_UPDATE")
		frame:RegisterEvent("PLAYER_GUILD_UPDATE")
		frame:SetScript("OnEvent", function(_, event)
			if event ~= "GUILD_ROSTER_UPDATE" then
				requestRoster() -- membership changed
			end
			fire()
		end)
		requestRoster()
	end
end
