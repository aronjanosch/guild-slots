local _, ns = ...

-- The guild session at security level 0 (docs/guild-spec.md section 6): the own account, token
-- purchases between an officer and a player, level-0 spins and gamble steps, and presence.
-- Pure Lua 5.1: clock, random text, sending and the guild data all come in through `env`.
-- onMessage never raises on any text a sender may put on the wire.

local Proto, Ledger, Engine, Settings, Tables = ns.Proto, ns.Ledger, ns.Engine, ns.Settings, ns.Tables

local Guild = {}
ns.Guild = Guild

local floor, sort, sub = math.floor, table.sort, string.sub

local STEP_TIMEOUT = 30 -- seconds per purchase step
local SPIN_INTERVAL = 1.5 -- seconds between spins or gamble steps
local SPIN_BUDGET = 3 -- queue budget a spin needs
local HELLO_EVERY = 120 -- seconds, plus a random 0..20
local HELLO_JITTER = 20
local ONLINE_WINDOW = 300 -- seconds a sign of life counts
local KEEP_PURCHASES = 100
local MAX_TOKENS = 1000000000

local Session = {}
Session.__index = Session

local Game = {}
Game.__index = Game

-- Helpers ------------------------------------------------------------------------------------

local function event(self, name, data)
	if self.env.onEvent then
		self.env.onEvent(name, data)
	end
end

local function subtable(t, key)
	local v = t[key]
	if type(v) ~= "table" then
		v = {}
		t[key] = v
	end
	return v
end

-- The public fields of a purchase record, as purchases() and the store hold them.
local PUBLIC = { "buyId", "role", "player", "officer", "tokens", "time", "status", "code" }

local function publicCopy(p)
	local c = {}
	for _, k in ipairs(PUBLIC) do
		c[k] = p[k]
	end
	return c
end

-- Settings of the line, or nil when there is no line or it does not parse.
local function parsedLine(line)
	if type(line) ~= "string" then
		return nil
	end
	return Settings.parse(line)
end

-- "1.10.2" > "1.9": compare numerically per dot-separated part; the leading digits of a part
-- count, a part without digits or a missing part is 0.
local function versionParts(v)
	local parts = {}
	for part in (v .. "."):gmatch("([^.]*)%.") do
		parts[#parts + 1] = tonumber(part:match("^%d*")) or 0
	end
	return parts
end

local function newerVersion(a, b)
	local pa, pb = versionParts(a), versionParts(b)
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then
			return x > y
		end
	end
	return false
end

-- Session ------------------------------------------------------------------------------------

function Guild.new(env)
	assert(type(env) == "table", "Guild.new needs env")
	local self = setmetatable({
		env = env,
		guild = env.guild,
		me = env.me,
		store = env.store,
		open = {}, -- purchases still waiting, oldest first
		seen = {}, -- name -> { name, version, seen }
		heard = {}, -- name -> { n, head, time }
		nextHello = nil,
		lastAction = nil,
		noticed = false,
		declined = false,
	}, Session)

	local accounts = subtable(subtable(self.store, "accounts"), self.guild)
	self.account = accounts[self.me]
	subtable(self.store, "purchases")

	local entries = self.account and self.account.entries
	if type(entries) == "table" and #entries > 0 then
		local state = Ledger.replay(self.guild, self.me, entries)
		if state then
			self.state = state
		else
			self.broken = true
		end
	else
		self.state = Ledger.start(self.guild, self.me)
	end

	self.gameObj = setmetatable({ session = self, stake = nil }, Game)
	self.gameObj:refresh()
	return self
end

function Session:hasAccount()
	return self.state ~= nil and self.state.settings ~= nil
end

-- Applies an entry to the account and stores its text form. Returns info or nil, code.
function Session:append(entry, state)
	state = state or self.state
	local info, code = Ledger.apply(state, entry)
	if not info then
		return nil, code
	end
	if not self.account then
		self.account = { entries = {} }
		self.store.accounts[self.guild][self.me] = self.account
	end
	local entries = subtable(self.account, "entries")
	entries[#entries + 1] = Ledger.encode(entry)
	return info
end

function Session:send(msgType, fields)
	local text, code = Proto.encode(msgType, fields)
	if not text then
		return nil, code
	end
	local ok, sendCode = self.env.send(text)
	if not ok then
		return nil, sendCode or "send"
	end
	return true
end

-- Purchases ----------------------------------------------------------------------------------

function Session:findOpen(buyId, role)
	for _, p in ipairs(self.open) do
		if p.buyId == buyId and (not role or p.role == role) then
			return p
		end
	end
end

function Session:knownBuyId(buyId, role)
	if self:findOpen(buyId, role) then
		return true
	end
	for _, p in ipairs(self.store.purchases) do
		if p.buyId == buyId and (not role or p.role == role) then
			return true
		end
	end
	return false
end

-- Moves an open purchase to its final status and into the store.
function Session:finish(p, status, code)
	p.status, p.code = status, code
	for i, q in ipairs(self.open) do
		if q == p then
			table.remove(self.open, i)
			break
		end
	end
	local list = self.store.purchases
	list[#list + 1] = publicCopy(p)
	while #list > KEEP_PURCHASES do
		table.remove(list, 1)
	end
	event(self, "purchase", publicCopy(p))
end

function Session:expire()
	local now = self.env.now()
	for i = #self.open, 1, -1 do
		local p = self.open[i]
		if now - p.started >= STEP_TIMEOUT then
			self:finish(p, "timeout")
		end
	end
end

function Session:grant(player, tokens)
	local env = self.env
	if not env.isOfficer(self.me) then
		return nil, "not_officer"
	end
	local line = env.line()
	if not parsedLine(line) then
		return nil, "no_settings"
	end
	if type(tokens) ~= "number" or tokens % 1 ~= 0 or tokens < 1 or tokens > MAX_TOKENS then
		return nil, "bad_tokens"
	end
	if not Engine.validName(player) or (player == self.me and not env.allowSelf) then
		return nil, "bad_player"
	end
	self:expire()
	for _, p in ipairs(self.open) do
		if p.role == "officer" and p.player == player then
			return nil, "busy"
		end
	end
	local buyId, seed = env.randomHex(16), env.randomHex(32)
	local p = {
		buyId = buyId, role = "officer", player = player, officer = self.me, tokens = tokens,
		time = floor(env.now()), status = "wait_nonce", seed = seed, started = env.now(),
	}
	local ok = self:send("BUY1", {
		buyId = buyId, player = player, tokens = tokens, commit = Engine.commit(seed),
		time = p.time, lineHash = Proto.lineHash(line),
	})
	if not ok then
		return nil, "send"
	end
	self.open[#self.open + 1] = p
	event(self, "purchase", publicCopy(p))
	return buyId
end

-- Player side: a BUY1 naming the own player.
function Session:onBuy1(sender, msg)
	local env = self.env
	if sender == self.me and not env.allowSelf then
		return
	end
	local line = env.line()
	local p = {
		buyId = msg.buyId, role = "player", player = self.me, officer = sender, tokens = msg.tokens,
		time = msg.time, commit = msg.commit, line = line, started = env.now(),
	}
	local code
	if not parsedLine(line) then
		code = "no_settings"
	elseif Proto.lineHash(line) ~= msg.lineHash then
		code = "settings_differ"
	else
		for _, q in ipairs(self.open) do
			if q.role == "player" then
				code = "busy"
			end
		end
		if not code and self.broken then
			code = "broken"
		end
	end
	self.open[#self.open + 1] = p
	if code then
		return self:finish(p, "failed", code)
	end
	p.nonce = env.randomHex(32)
	p.status = "wait_seed"
	if not self:send("BUY2", { buyId = p.buyId, nonce = p.nonce, head = Ledger.shortHead(self.state) }) then
		return self:finish(p, "failed", "send")
	end
	event(self, "purchase", publicCopy(p))
end

-- Officer side: the player's nonce.
function Session:onBuy2(sender, msg, p)
	if p.status ~= "wait_nonce" or sender ~= p.player then
		return
	end
	p.nonce, p.head = msg.nonce, msg.head
	if not self:send("BUY3", { buyId = p.buyId, seed = p.seed }) then
		return self:finish(p, "failed", "send")
	end
	self:finish(p, "done")
end

-- Player side: the officer's seed.
function Session:onBuy3(sender, msg, p)
	if p.status ~= "wait_seed" then
		return
	end
	local entry = {
		type = "B", buyId = p.buyId, officer = p.officer, tokens = p.tokens, commit = p.commit,
		seed = msg.seed, nonce = p.nonce, time = p.time, line = p.line,
	}
	local info, code = self:append(entry)
	if not info then
		return self:finish(p, "failed", code)
	end
	self.declined = false
	self.gameObj:refresh()
	self:finish(p, "done")
	event(self, "account", { balance = self.state.balance })
end

-- Presence -----------------------------------------------------------------------------------

function Session:alive(sender, version)
	local now = self.env.now()
	local s = self.seen[sender]
	local changed = not s or now - s.seen > ONLINE_WINDOW
	if not s then
		s = { name = sender }
		self.seen[sender] = s
	end
	if version and s.version ~= version then
		s.version = version
		changed = true
	end
	s.seen = now
	if changed then
		event(self, "presence", { name = sender, version = s.version })
	end
end

function Session:hear(sender, n, head)
	local rec = { n = n, head = head, time = self.env.now() }
	self.heard[sender] = rec
	if self.env.isOfficer(self.me) then
		local list = subtable(subtable(self.store, "heard"), self.guild)
		list[sender] = { n = n, head = head, time = rec.time }
	end
end

function Session:sendHello()
	local state = self.state
	local hasAccount = self:hasAccount()
	return self:send("HELLO", {
		version = self.env.version,
		n = hasAccount and state.n or 0,
		head = hasAccount and Ledger.shortHead(state) or "-",
	})
end

function Session:tick()
	local env = self.env
	self:expire()
	local now = env.now()
	if not self.nextHello or now >= self.nextHello then
		self:sendHello()
		local jitter = (tonumber(env.randomHex(4), 16) or 0) % (HELLO_JITTER + 1)
		self.nextHello = now + HELLO_EVERY + jitter
	end
end

-- Messages -----------------------------------------------------------------------------------

function Session:onMessage(sender, text)
	if not Engine.validName(sender) then
		return
	end
	local msg = Proto.decode(text)
	if not msg then
		return
	end
	self:expire()
	local env = self.env
	local kind = msg.type

	if kind == "BUY1" then
		if not env.isOfficer(sender) then
			return
		end
		self:alive(sender)
		if msg.player == self.me and not self:knownBuyId(msg.buyId, "player") then
			self:onBuy1(sender, msg)
		end
	elseif kind == "BUY2" then
		local p = self:findOpen(msg.buyId, "officer")
		if not p and not self:knownBuyId(msg.buyId) then
			return
		end
		self:alive(sender)
		if p then
			self:onBuy2(sender, msg, p)
		end
	elseif kind == "BUY3" then
		if not env.isOfficer(sender) or not self:knownBuyId(msg.buyId) then
			return
		end
		local p = self:findOpen(msg.buyId, "player")
		if p and sender ~= p.officer then
			return
		end
		self:alive(sender)
		if p then
			self:onBuy3(sender, msg, p)
		end
	elseif kind == "HELLO" then
		self:alive(sender, msg.version)
		self:hear(sender, msg.n, msg.head)
		if not self.noticed and type(env.version) == "string" and newerVersion(msg.version, env.version) then
			self.noticed = true
			event(self, "notice", { kind = "update", version = msg.version, from = sender })
		end
	else -- SPIN, GAM
		self:alive(sender)
		self:hear(sender, msg.n, msg.head)
	end
end

-- Queries ------------------------------------------------------------------------------------

function Session:purchases()
	local list = {}
	for _, p in ipairs(self.store.purchases) do
		list[#list + 1] = publicCopy(p)
	end
	for _, p in ipairs(self.open) do
		list[#list + 1] = publicCopy(p)
	end
	-- Newest first: by purchase time, and among equal times the later record first.
	for i, p in ipairs(list) do
		p.order = i
	end
	sort(list, function(a, b)
		if a.time ~= b.time then
			return (a.time or 0) > (b.time or 0)
		end
		return a.order > b.order
	end)
	for _, p in ipairs(list) do
		p.order = nil
	end
	return list
end

function Session:online()
	local now, list = self.env.now(), {}
	for _, s in pairs(self.seen) do
		if now - s.seen <= ONLINE_WINDOW then
			list[#list + 1] = { name = s.name, version = s.version, seen = s.seen }
		end
	end
	sort(list, function(a, b) return a.name < b.name end)
	return list
end

function Session:lastSpin(player)
	local rec = self.heard[player]
	if not rec then
		local stored = self.store.heard and self.store.heard[self.guild]
		rec = stored and stored[player]
	end
	if type(rec) ~= "table" then
		return nil
	end
	return { n = rec.n, head = rec.head, time = rec.time }
end

function Session:game()
	return self.gameObj
end

-- Game ---------------------------------------------------------------------------------------
-- Same shape as Solo (Game/Solo.lua), backed by the ledger.

-- Copies the account state into the public fields the slot window reads.
function Game:refresh()
	local s = self.session
	local state = s:hasAccount() and s.state or nil
	local settings = state and state.settings or Settings.defaults()
	self.settings = settings
	self.tbl = state and state.tbl or Tables.get(settings.T)
	self.stakes = settings.E
	self.maxGamble = settings.G
	self.cap = settings.C
	self.balance = state and state.balance or 0
	self.pending = (state and not s.declined) and state.pending or 0
	local keep = false
	for _, v in ipairs(self.stakes) do
		if v == self.stake then keep = true end
	end
	if not keep then
		self.stake = self.stakes[1]
	end
end

function Game:state()
	return self.pending > 0 and "gamble" or "idle"
end

function Game:setStake(v)
	if self:state() ~= "idle" then
		return nil, "busy"
	end
	for _, s in ipairs(self.stakes) do
		if s == v then
			self.stake = v
			return true
		end
	end
	return nil, "bad_stake"
end

function Game:status()
	local s = self.session
	if s.broken then
		return "broken"
	end
	if not s:hasAccount() then
		return "no_account"
	end
	if s.state.settings.L ~= 0 then
		return "level"
	end
	if self.balance < self.stake and self:state() ~= "gamble" then
		return "no_funds"
	end
	return "ok"
end

-- Shared checks before a spin or gamble step: account, level, interval and queue budget.
function Game:ready()
	local s = self.session
	if s.broken then
		return nil, "broken"
	end
	if not s:hasAccount() then
		return nil, "no_account"
	end
	if s.state.settings.L ~= 0 then
		return nil, "level"
	end
	return true
end

function Game:waiting()
	local s = self.session
	local now = s.env.now()
	return (s.lastAction and now - s.lastAction < SPIN_INTERVAL) or s.env.budget() < SPIN_BUDGET
end

function Game:spin()
	local ok, code = self:ready()
	if not ok then
		return nil, code
	end
	local s = self.session
	local stake = self.stake
	if s.state.balance < stake then
		return nil, "no_funds"
	end
	if self:waiting() then
		return nil, "wait"
	end
	local entry = { type = "S", n = s.state.n + 1, stake = stake, A = 0, status = "ok", contribs = "" }
	local head = Ledger.shortHead(s.state)
	local trial = Ledger.copy(s.state)
	local info
	info, code = Ledger.apply(trial, entry)
	if not info then
		return nil, code
	end
	if not s:send("SPIN", { n = entry.n, stake = stake, level = 0, head = head, A = 0 }) then
		return nil, "send"
	end
	s:append(entry)
	s.declined = false
	s.lastAction = s.env.now()
	self:refresh()

	local tbl = s.state.tbl
	local stops = info.stops
	local window = {}
	for r = 1, 3 do
		window[r] = { Tables.window(tbl, r, stops[r]) }
	end
	local a, b, c = Tables.symbols(tbl, stops[1], stops[2], stops[3])
	local win = info.win
	return {
		kind = "spin",
		n = entry.n,
		stake = stake,
		stops = { stops[1], stops[2], stops[3] },
		symbols = { a, b, c },
		window = window,
		multiplier = info.multiplier,
		win = win,
		balance = info.balance,
		pending = info.pending,
		canGamble = info.pending > 0,
		winReels = { win > 0, win > 0, win > 0 and a == c },
		anticipation = a == b,
	}
end

function Game:take()
	if self:state() ~= "gamble" then
		return nil, "no_gamble"
	end
	local amount = self.pending
	self.session.declined = true
	self:refresh()
	return { kind = "take", amount = amount, balance = self.balance }
end

function Game:gamble()
	if self:state() ~= "gamble" then
		return nil, "no_gamble"
	end
	local ok, code = self:ready()
	if not ok then
		return nil, code
	end
	if self:waiting() then
		return nil, "wait"
	end
	local s = self.session
	local state = s.state
	local amount = state.pending
	local entry = { type = "G", n = state.n, g = state.g + 1, A = 0, status = "ok", contribs = "" }
	local head = Ledger.shortHead(state)
	local info
	info, code = Ledger.apply(Ledger.copy(state), entry)
	if not info then
		return nil, code
	end
	if not s:send("GAM", { n = entry.n, g = entry.g, amount = amount, level = 0, head = head, A = 0 }) then
		return nil, "send"
	end
	s:append(entry)
	s.lastAction = s.env.now()
	self:refresh()
	return {
		kind = "gamble",
		won = info.won,
		step = entry.g,
		amount = amount,
		pending = info.pending,
		balance = info.balance,
		canGamble = info.pending > 0,
	}
end

function Game:info()
	local stats = Tables.stats(self.tbl, self.stake, self.cap)
	return {
		pair = self.tbl.pair,
		triple = self.tbl.triple,
		order = { "D", "M", "W", "T", "G", "S", "K" },
		rtp = stats and stats.rtp or 0,
		hit = stats and stats.hit or 0,
		maxGamble = self.maxGamble,
	}
end
