local _, ns = ...

-- Guild facts from the client: guild name, own name, settings line, officer test, entropy.
-- See docs/guild-spec.md section 5. Nothing here touches the WoW API at load time.

local Roster = {}
ns.Roster = Roster

local Sha256, Settings = ns.Sha256, ns.Settings

local counter = 0
local listeners, frame, lastInfo = {}, nil, nil

local function cutRealm(name)
	if type(name) ~= "string" then
		return nil
	end
	return (name:gsub("%-.*$", ""))
end

local function infoText()
	if type(GetGuildInfoText) == "function" then
		return GetGuildInfoText()
	end
	if C_GuildInfo and type(C_GuildInfo.GetInfoText) == "function" then
		return C_GuildInfo.GetInfoText()
	end
end

function Roster.guild()
	if type(GetGuildInfo) ~= "function" then
		return nil
	end
	local name = GetGuildInfo("player")
	if type(name) == "string" and name ~= "" then
		return name
	end
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

local function fire()
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
			if event == "GUILD_ROSTER_UPDATE" then
				lastInfo = infoText()
				fire()
			else
				-- Membership or guild info changed: refresh, fire when the text differs.
				requestRoster()
				local info = infoText()
				if info ~= lastInfo then
					lastInfo = info
					fire()
				end
			end
		end)
		lastInfo = infoText()
		requestRoster()
	end
end
