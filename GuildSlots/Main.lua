local addonName, ns = ...

-- Wiring (docs/guild-spec.md section 1): creates the guild session once guild and own name are
-- known, feeds it with Comm messages and a ticker, and passes its events on to the UI.
-- Every handler here is wrapped so an error never escapes into an event handler.

local Roster, Comm, Guild, L = ns.Roster, ns.Comm, ns.Guild, ns.L

local Main = {}
ns.Main = Main

local TICK = 0.25 -- seconds between session:tick() calls
local FALLBACK_VERSION = "0.3.0"

local session, env -- current session and its env (nil when not in a guild)
local listeners = {}
local started = false

local function db()
	if type(GuildSlotsDB) ~= "table" then
		GuildSlotsDB = {}
	end
	return GuildSlotsDB
end

local function chat(text)
	local frame = DEFAULT_CHAT_FRAME
	if frame and frame.AddMessage then
		frame:AddMessage("|cff00e701" .. L.TITLE .. "|r: " .. tostring(text))
	end
end

-- Calls every subscriber; one failing subscriber does not stop the others.
local function dispatch(name, data)
	for _, fn in ipairs(listeners) do
		pcall(fn, name, data)
	end
end

-- fn(name, data) for the session events ("account", "purchase", "presence", "notice", "payout",
-- "request", "ticker", "result") plus "session" (created or dropped) and "roster" (guild roster or guild info changed).
function Main.subscribe(fn)
	listeners[#listeners + 1] = fn
end

function Main.session()
	return session
end

function Main.isOfficer()
	local me = Roster.me()
	return me ~= nil and Roster.isOfficer(me)
end

-- The addon version from the TOC, in the form HELLO accepts.
function Main.version()
	local v
	if C_AddOns and type(C_AddOns.GetAddOnMetadata) == "function" then
		v = C_AddOns.GetAddOnMetadata(addonName, "Version")
	elseif type(GetAddOnMetadata) == "function" then
		v = GetAddOnMetadata(addonName, "Version")
	end
	if type(v) ~= "string" or #v < 1 or #v > 16 or v:find("[^0-9A-Za-z.-]") then
		return FALLBACK_VERSION
	end
	return v
end

-- The session reads env.allowSelf on every grant and BUY1, so this takes effect at once.
function Main.setSelfTest(on)
	db().selfTest = on and true or false
	if env then
		env.allowSelf = db().selfTest
	end
end

local function onEvent(name, data)
	if name == "notice" and type(data) == "table" and data.kind == "update" then
		chat(string.format(L.UPDATE_NOTICE, tostring(data.version)))
	elseif name == "notice" and type(data) == "table" and data.kind == "witness_cheat" then
		chat(string.format(L.WITNESS_CHEAT, tostring(data.name or data.witness or data.from)))
	end
	dispatch(name, data)
end

-- Server time with a fraction: GetServerTime() has whole seconds, which is too coarse for
-- the spin interval. Anchor it once and let the frame clock run from there.
local clockBase, clockStart
local function now()
	if type(GetTime) ~= "function" then
		return Roster.serverTime()
	end
	if not clockBase then
		clockBase, clockStart = Roster.serverTime(), GetTime()
	end
	return clockBase + (GetTime() - clockStart)
end

local function create(guild, me)
	local saved = db()
	if type(saved.guild) ~= "table" then
		saved.guild = {}
	end
	env = {
		guild = guild,
		me = me,
		now = now,
		randomHex = Roster.randomHex,
		send = function(text) return Comm.send(text, "GUILD") end,
		budget = Comm.budget,
		isOfficer = Roster.isOfficer,
		line = Roster.line,
		store = saved.guild,
		version = Main.version(),
		onEvent = onEvent,
		allowSelf = saved.selfTest == true,
	}
	session = Guild.new(env)
end

local function inGuild()
	if type(IsInGuild) == "function" then
		return IsInGuild() and true or false
	end
	return Roster.guild() ~= nil
end

-- Creates, replaces or drops the session to match the current guild.
local function evaluate()
	local guild, me = Roster.guild(), Roster.me()
	if guild and me then
		if not session or session.guild ~= guild or session.me ~= me then
			create(guild, me)
			dispatch("session", session)
		end
	elseif session and not inGuild() then
		-- Left the guild. A guild name that is only missing for a moment keeps the session.
		session, env = nil, nil
		dispatch("session", nil)
	end
end

local function safeEvaluate()
	local ok = pcall(evaluate)
	if not ok then
		session, env = nil, nil
	end
end

local function onMessage(sender, text)
	if session then
		pcall(session.onMessage, session, sender, text)
	end
end

local function start()
	if started then
		return
	end
	started = true
	Comm.start(onMessage)
	Roster.onChange(function()
		safeEvaluate()
		dispatch("roster")
	end)
	local ticker = CreateFrame("Frame")
	local acc = 0
	ticker:SetScript("OnUpdate", function(_, elapsed)
		acc = acc + (tonumber(elapsed) or 0)
		if acc < TICK then
			return
		end
		acc = 0
		if session then
			pcall(session.tick, session)
		end
	end)
	safeEvaluate()
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("PLAYER_GUILD_UPDATE")
events:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		pcall(start)
	elseif event == "PLAYER_GUILD_UPDATE" and started then
		safeEvaluate()
	end
end)
