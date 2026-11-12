-- Smoke test for Net/Comm.lua and Guild/Roster.lua against tests/wowstub.lua:
--   luajit tests/smoke_net.lua

local stub = dofile("tests/wowstub.lua")
local ns = {}
stub.loadAddon("GuildSlots", "GuildSlots", ns)
assert(ns.Comm and ns.Roster, "Comm and Roster loaded from the TOC")

-- Throwaway queue with the interface of docs/guild-spec.md section 3, used only when the real
-- Net/Queue.lua is not loaded.
if not ns.Queue then
	local Queue = {}
	ns.Queue = Queue
	function Queue.new(o)
		local q = { msgs = {}, count = o.capacity or 10, last = o.now(), cap = o.capacity or 10, refill = o.refill or 1 }
		function q:push(text, channel, target)
			if #text > 255 then return nil, "too_long" end
			self.msgs[#self.msgs + 1] = { text, channel, target }
			return true
		end
		function q:budget()
			local t = o.now()
			self.count = math.min(self.cap, self.count + (t - self.last) * self.refill)
			self.last = t
			return math.floor(self.count)
		end
		function q:pending() return #self.msgs end
		function q:update()
			while #self.msgs > 0 and self:budget() >= 1 do
				local m = self.msgs[1]
				local ok, code = pcall(o.send, m[1], m[2], m[3])
				if not ok then
					table.remove(self.msgs, 1)
					if o.onDrop then o.onDrop(m[1], code) end
				elseif code == 0 then
					table.remove(self.msgs, 1)
					self.count = self.count - 1
				elseif code == 3 then
					self.count = 0
					return
				elseif code == 11 then
					return
				else
					table.remove(self.msgs, 1)
					if o.onDrop then o.onDrop(m[1], code) end
				end
			end
		end
		return q
	end
end

local Comm, Roster = ns.Comm, ns.Roster
local function eq(got, want, msg)
	if got ~= want then
		error((msg or "eq") .. ": got " .. tostring(got) .. ", want " .. tostring(want), 2)
	end
end

-- Comm -----------------------------------------------------------------------------------
eq(Comm.send("x"), nil, "send before start refuses")
eq(Comm.budget(), 0, "budget before start")

local got = {}
Comm.start(function(sender, text, channel) got[#got + 1] = { sender, text, channel } end)
eq(stub.prefixes[1], "GSLOTS", "prefix registered on start")

stub.deliver("GSLOTS", "1|HELLO|0.2|0|-", "GUILD", "Bob Jones-Realm")
stub.deliver("OTHER", "ignored", "GUILD", "Carol Day")
stub.deliver("GSLOTS", "1|HELLO|0.2|0|-", "GUILD", "Dave Moon")
eq(#got, 2, "only our prefix reaches onMessage")
eq(got[1][1], "Bob Jones", "realm suffix cut")
eq(got[1][2], "1|HELLO|0.2|0|-", "text passed on")
eq(got[1][3], "GUILD", "channel passed on")
eq(got[2][1], "Dave Moon", "name without realm unchanged")

eq(Comm.budget(), 10, "full budget")
assert(Comm.send("hello"), "send pushes")
eq(#stub.sent, 0, "push does not send")
stub.tick(1 / 60)
eq(#stub.sent, 1, "frame update sends")
eq(stub.sent[1].prefix, "GSLOTS", "sent prefix")
eq(stub.sent[1].channel, "GUILD", "default channel")
eq(stub.sent[1].text, "hello", "sent text")
eq(Comm.budget(), 9, "budget after a send")

local ok, code = Comm.send(("x"):rep(256))
eq(ok, nil, "too long refused")
eq(code, "too_long", "too long code")

assert(Comm.send("whisper", "WHISPER", "Bob Jones"))
stub.tick(1 / 60)
eq(stub.sent[2].channel, "WHISPER", "explicit channel")
eq(stub.sent[2].target, "Bob Jones", "explicit target")

-- Result 3: kept, budget drops to 0, retried after a second.
stub.sendCode = 3
Comm.send("throttled")
stub.tick(1 / 60)
local n = #stub.sent
eq(stub.sent[n].text, "throttled", "throttled message was tried")
eq(Comm.budget(), 0, "code 3 empties the budget")
stub.sendCode = 0
stub.tick(1 / 60)
eq(#stub.sent, n, "no retry without budget")
stub.tick(1.1)
eq(#stub.sent, n + 1, "retry after the budget refills")
eq(stub.sent[n + 1].text, "throttled", "same message retried")
stub.tick(1 / 60)
eq(#stub.sent, n + 1, "message was sent only once more")

-- Result 0 with a nil return (older signature) counts as sent.
local real = C_ChatInfo.SendAddonMessage
C_ChatInfo.SendAddonMessage = function(...) real(...) end
Comm.send("legacy")
stub.tick(1.1)
eq(stub.sent[#stub.sent].text, "legacy", "nil return counts as 0")
C_ChatInfo.SendAddonMessage = real

-- Roster ---------------------------------------------------------------------------------
stub.guildName = "Test Guild"
eq(Roster.guild(), "Test Guild", "guild")
stub.guildName = nil
eq(Roster.guild(), nil, "no guild")
stub.guildName = "Test Guild"
eq(Roster.me(), "Alice Smith", "own name")
stub.playerName = "Alice Smith-Realm"
eq(Roster.me(), "Alice Smith", "own name without realm")
stub.playerName = "Alice Smith"
eq(Roster.serverTime(), 1700000000, "server time")

stub.roster = {
	{ name = "Zed Last", rankIndex = 3, online = false },
	{ name = "Alice Smith-Realm", rankIndex = 0, online = true },
	{ name = "Bob Jones", rankIndex = 1, online = true },
	{ name = "Carol Day", rankIndex = 2, online = false },
}

-- No settings line: nobody is an officer.
stub.infoText = "Welcome to the guild\nRaids on Friday"
eq(Roster.line(), nil, "no line")
local s, c = Roster.settings()
eq(s, nil, "no settings")
assert(c, "settings code")
eq(Roster.isOfficer("Alice Smith"), false, "guild leader is no officer without settings")
eq(Roster.isOfficer("Bob Jones"), false, "nobody is an officer without settings")

stub.infoText = "Welcome\n  GSLOTS1;L=0;R=1  \nRaids on Friday"
eq(Roster.line(), "GSLOTS1;L=0;R=1", "line found and trimmed")
s = Roster.settings()
eq(s.R, 1, "parsed rank limit")
eq(Roster.isOfficer("Alice Smith"), true, "rank 0 is an officer")
eq(Roster.isOfficer("Bob Jones-Realm"), true, "rank 1 is an officer, realm cut")
eq(Roster.isOfficer("Carol Day"), false, "rank 2 is not")
eq(Roster.isOfficer("Zed Last"), false, "rank 3 is not")
eq(Roster.isOfficer("Nobody Here"), false, "unlisted name is not")
eq(Roster.isOfficer("bob jones"), false, "names compare byte for byte")
eq(Roster.isOfficer(nil), false, "nil name")

stub.infoText = "GSLOTS1;R=banana"
eq(Roster.isOfficer("Alice Smith"), false, "invalid settings: nobody")

local m = Roster.members()
eq(#m, 4, "member count")
eq(m[1].name, "Alice Smith", "sorted, realm cut")
eq(m[2].name, "Bob Jones", "second")
eq(m[4].name, "Zed Last", "last")
eq(m[1].rankIndex, 0, "rank index")
eq(m[1].online, true, "online")
eq(m[3].online, false, "offline")

-- onChange
local changes = 0
Roster.onChange(function() changes = changes + 1 end)
assert(stub.rosterRequests >= 1, "roster requested")
stub.fire("GUILD_ROSTER_UPDATE")
eq(changes, 1, "fires on GUILD_ROSTER_UPDATE")
stub.fire("GUILD_ROSTER_UPDATE")
eq(changes, 2, "fires again")
stub.fire("PLAYER_GUILD_UPDATE")
eq(changes, 2, "no fire when the info text is unchanged")
stub.infoText = "GSLOTS1;L=0"
stub.fire("PLAYER_GUILD_UPDATE")
eq(changes, 3, "fires when the info text changed")

-- randomHex
GuildSlotsDB = { pool = "start" }
local a = Roster.randomHex(32)
local pool1 = GuildSlotsDB.pool
local b = Roster.randomHex(32)
eq(#a, 32, "length 32")
assert(a:match("^[0-9a-f]+$"), "lowercase hex")
assert(a ~= b, "calls differ")
assert(pool1 ~= "start" and GuildSlotsDB.pool ~= pool1, "pool updated each call")
eq(#Roster.randomHex(16), 16, "length 16")
eq(#Roster.randomHex(1), 1, "length 1")
local long = Roster.randomHex(200)
eq(#long, 200, "more than one block")
assert(long:match("^[0-9a-f]+$"), "long hex")
assert(long:sub(1, 64) ~= long:sub(65, 128), "blocks differ")
GuildSlotsDB = nil
eq(#Roster.randomHex(8), 8, "works without a saved table")
assert(type(GuildSlotsDB) == "table" and GuildSlotsDB.pool, "pool created")

io.write("smoke net: ok\n")
