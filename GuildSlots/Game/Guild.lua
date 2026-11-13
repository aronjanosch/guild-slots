local _, ns = ...

-- The guild session at security level 0 (docs/guild-spec.md section 6): the own account, token
-- purchases between an officer and a player, level-0 spins and gamble steps, and presence.
-- Payouts, anchors and OSYNC follow docs/payout-spec.md section 4.
-- Pure Lua 5.1: clock, random text, sending and the guild data all come in through `env`.
-- onMessage never raises on any text a sender may put on the wire.

local Proto, Ledger, Engine, Settings, Tables = ns.Proto, ns.Ledger, ns.Engine, ns.Settings, ns.Tables
local Pack, Verify, Sha256 = ns.Pack, ns.Verify, ns.Sha256

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

local REQUEST_TIMEOUT = 300 -- seconds a payout request stays open
local CONFIRM_LIMIT = 270 -- seconds after which the officer can no longer confirm
local MAX_CHUNKS = 200 -- LOG messages per request
local KEEP_REQUESTS = 50
local STEP_BUDGET = 150 -- entries verified per tick() unless env.stepBudget says otherwise
local OSYNC_DELAY = 20 -- seconds after the first tick as an officer
local OSYNC_MAX = 30
local WATCH_MAX = 100 -- purchases between others followed at once
local KEEP_KEYS = 200 -- players whose last purchase key is kept for the ticker
local TICKER_BIG, TICKER_HUGE, TICKER_LEGENDARY = 20, 50, 100 -- win / stake for the ticker levels
local TICKER_KEEP = 20 -- entries session:ticker() returns
local TICKER_PER_SENDER = 1 -- seconds between two recalculations for one sender
local TICKER_PER_SECOND = 5 -- recalculations per second in total
local REASONS = { declined = true, mismatch = true, expired = true, busy = true, too_large = true, bad_log = true }

-- Player request states that lock the game, and officer request states still open.
local PLAYER_OPEN = { wait_officer = true, sending = true, wait_decision = true }
local OFFICER_OPEN = { fetching = true, checking = true, ready = true }

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
		heard = {}, -- name -> { n, head, time, live = { n, g, head } }
		watch = {}, -- buyId -> purchase heard on the wire, followed for an anchor
		tickLast = {}, -- player -> last spin number the ticker looked at
		tickAt = {}, -- player -> time of the last recalculation
		tickSecond = 0, -- the second tickCount counts in
		tickCount = 0,
		tickList = {}, -- ticker entries, newest first
		request = nil, -- the own payout request (player side)
		reqs = {}, -- payout requests addressed to this officer, still open, oldest first
		nextHello = nil,
		lastAction = nil,
		noticed = false,
		declined = false,
	}, Session)

	local accounts = subtable(subtable(self.store, "accounts"), self.guild)
	self.account = accounts[self.me]
	subtable(self.store, "purchases")
	subtable(self.store, "requests")
	self:restorePayout()

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
	for id, w in pairs(self.watch) do
		if now - w.started >= 2 * STEP_TIMEOUT then
			self.watch[id] = nil
			self:dropKey(w.player, w.time)
		end
	end
	local r = self.request
	if r and PLAYER_OPEN[r.status] and now - r.time >= REQUEST_TIMEOUT then
		self:setPayout("expired")
	end
	for i = #self.reqs, 1, -1 do
		local q = self.reqs[i]
		if q and now - q.time >= REQUEST_TIMEOUT then
			self:setReq(q, "expired")
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
		time = floor(env.now()), status = "wait_nonce", seed = seed, started = env.now(), line = line,
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
		if not code and self:payoutOpen() then
			code = "busy"
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
	if not self:send("BUY2", { buyId = p.buyId, nonce = p.nonce, head = self.state.head, anchors = self.state.anchors }) then
		return self:finish(p, "failed", "send")
	end
	event(self, "purchase", publicCopy(p))
end

-- Officer side: the player's nonce.
function Session:onBuy2(sender, msg, p)
	if p.status ~= "wait_nonce" or sender ~= p.player then
		return
	end
	p.nonce, p.head, p.anchors = msg.nonce, msg.head, msg.anchors
	if not self:send("BUY3", { buyId = p.buyId, seed = p.seed }) then
		return self:finish(p, "failed", "send")
	end
	-- The issuing officer knows the purchase first-hand, echo or not.
	self:purchaseAnchor({
		player = p.player, buyId = p.buyId, officer = self.me, tokens = p.tokens, commit = Engine.commit(p.seed),
		nonce = p.nonce, time = p.time, line = p.line, lineHash = Proto.lineHash(p.line), head = p.head,
		anchors = p.anchors,
	}, p.seed)
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

-- Anchors and first-hand knowledge ------------------------------------------------------------

-- Stores the anchor { anchors, head, time, by } for a player when it is higher than the stored one.
function Session:storeAnchor(player, a)
	local list = subtable(subtable(self.store, "anchors"), self.guild)
	local cur = list[player]
	if type(cur) == "table" and type(cur.anchors) == "number" and cur.anchors >= a.anchors then
		return false
	end
	list[player] = { anchors = a.anchors, head = a.head, time = a.time, by = a.by }
	return true
end

-- Guild ticker: the key and rules of the latest complete purchase heard for another player.
-- store.keys[guild][player] = { K, line, time }; at most KEEP_KEYS players, the oldest dropped.
function Session:storeKey(w, K, line)
	if w.player == self.me or type(w.time) ~= "number" then
		return
	end
	local list = subtable(subtable(self.store, "keys"), self.guild)
	local cur = list[w.player]
	if type(cur) == "table" and type(cur.time) == "number" and cur.time > w.time then
		return
	end
	list[w.player] = { K = K, line = line, time = w.time }
	local count = 0
	for _ in pairs(list) do
		count = count + 1
	end
	while count > KEEP_KEYS do
		local oldest, at
		for name, k in pairs(list) do
			local t = type(k) == "table" and type(k.time) == "number" and k.time or -1
			if not at or t < at then
				oldest, at = name, t
			end
		end
		list[oldest] = nil
		count = count - 1
	end
end

-- A newer BUY1 for the player ended without a complete exchange the listener could follow: the
-- stored key may belong to an older purchase than the account now plays on, so it goes.
function Session:dropKey(player, time)
	local list = self.store.keys and self.store.keys[self.guild]
	local k = type(list) == "table" and list[player]
	if type(k) == "table" and (type(k.time) ~= "number" or type(time) ~= "number" or k.time <= time) then
		list[player] = nil
	end
end

function Session:markSeen(player, id)
	subtable(subtable(subtable(self.store, "seen"), self.guild), player)[id] = true
end

function Session:anchor(player)
	local list = self.store.anchors and self.store.anchors[self.guild]
	local a = type(list) == "table" and list[player]
	if type(a) ~= "table" then
		return nil
	end
	return { anchors = a.anchors, head = a.head, time = a.time, by = a.by }
end

-- A complete purchase: w = { player, buyId, officer, tokens, commit, nonce, time, line, head (64 hex,
-- before the purchase), anchors (B/P entries before it) }. The seed must match the commit.
-- The anchor needs the own line to hash like the officer's; the id counts as seen either way.
function Session:purchaseAnchor(w, seed)
	if Engine.commit(seed) ~= w.commit then
		self:dropKey(w.player, w.time)
		return
	end
	self:markSeen(w.player, w.buyId)
	local line = w.line
	if not parsedLine(line) or Proto.lineHash(line) ~= w.lineHash then
		self:dropKey(w.player, w.time)
		return
	end
	self:storeKey(w, Engine.purchaseKey(w.buyId, seed, w.nonce), line)
	local text = Ledger.encode({
		type = "B", buyId = w.buyId, officer = w.officer, tokens = w.tokens, commit = w.commit, seed = seed,
		nonce = w.nonce, time = w.time, line = line,
	})
	if not text then
		return
	end
	self:storeAnchor(w.player, {
		anchors = w.anchors + 1, head = sub(Sha256.hex(w.head .. "|" .. text), 1, 32), time = w.time, by = w.officer,
	})
end

-- Purchases between anyone, as every client hears them.
function Session:watchBuy1(sender, msg)
	if self.watch[msg.buyId] then
		return
	end
	local count = 0
	for _ in pairs(self.watch) do
		count = count + 1
	end
	if count >= WATCH_MAX then
		return
	end
	self.watch[msg.buyId] = {
		player = msg.player, buyId = msg.buyId, officer = sender, tokens = msg.tokens, commit = msg.commit,
		time = msg.time, lineHash = msg.lineHash, line = self.env.line(), started = self.env.now(),
	}
end

function Session:watchBuy2(sender, msg)
	local w = self.watch[msg.buyId]
	if w and not w.nonce and sender == w.player then
		w.nonce, w.head, w.anchors = msg.nonce, msg.head, msg.anchors
	end
end

function Session:watchBuy3(sender, msg)
	local w = self.watch[msg.buyId]
	if w and w.nonce and sender == w.officer then
		self.watch[msg.buyId] = nil
		self:purchaseAnchor(w, msg.seed)
	end
end

-- Guild ticker --------------------------------------------------------------------------------
-- A SPIN of another player is recalculated under the key of the purchase this client heard. This
-- shows what the SPIN implies under that purchase; it is no verification. A player whose account
-- moved on to a purchase the listener missed gives nothing or a wrong line; the payout check
-- decides what is true.

function Session:tickerLevels()
	local lv = self.env.tickerLevels
	lv = type(lv) == "table" and lv or {}
	return lv.big or TICKER_BIG, lv.huge or TICKER_HUGE, lv.legendary or TICKER_LEGENDARY
end

function Session:onTickerSpin(sender, msg)
	local env = self.env
	if sender == self.me or msg.level ~= 0 or type(msg.n) ~= "number" or type(msg.stake) ~= "number" then
		return
	end
	local list = self.store.keys and self.store.keys[self.guild]
	local k = type(list) == "table" and list[sender]
	if type(k) ~= "table" or type(k.K) ~= "string" then
		return
	end
	local last = self.tickLast[sender]
	if last and msg.n <= last then
		return
	end
	local s = parsedLine(k.line) and Settings.parse(k.line)
	local tbl = s and Tables.get(s.T)
	if not tbl or tbl.kind ~= "lines" or msg.stake % tbl.lineCount ~= 0 then
		return
	end
	local allowed = false
	for _, v in ipairs(s.E) do
		if v == msg.stake then
			allowed = true
		end
	end
	if not allowed then
		return
	end
	local now = env.now()
	local at = self.tickAt[sender]
	if at and now - at < TICKER_PER_SENDER then
		return
	end
	local second = floor(now)
	if second ~= self.tickSecond then
		self.tickSecond, self.tickCount = second, 0
	end
	if self.tickCount >= TICKER_PER_SECOND then
		return
	end
	self.tickCount = self.tickCount + 1
	self.tickAt[sender] = now
	self.tickLast[sender] = msg.n
	local ok, round = pcall(Engine.round, k.K, msg.n, "", tbl, msg.stake, s.C)
	if not ok or type(round) ~= "table" or type(round.win) ~= "number" then
		return
	end
	local win, stake = round.win, msg.stake
	local big, huge, legendary = self:tickerLevels()
	local level
	if win >= legendary * stake then
		level = "legendary"
	elseif win >= huge * stake then
		level = "huge"
	elseif win >= big * stake then
		level = "big"
	elseif round.free then
		level = "free"
	else
		return
	end
	local data = {
		player = sender, n = msg.n, stake = stake, win = win, mult = win / stake,
		free = round.free and round.free.awarded or nil, symbol = round.free and round.free.symbol or nil,
		level = level,
	}
	table.insert(self.tickList, 1, data)
	self.tickList[TICKER_KEEP + 1] = nil
	event(self, "ticker", data)
end

-- The last 20 ticker entries, newest first (memory only).
function Session:ticker()
	local out = {}
	for i, d in ipairs(self.tickList) do
		out[i] = d
	end
	return out
end

-- Payout, player side -------------------------------------------------------------------------

function Session:payoutOpen()
	local r = self.request
	return r ~= nil and PLAYER_OPEN[r.status] == true
end

function Session:payout()
	local r = self.request
	if not r then
		return nil
	end
	return {
		reqId = r.reqId, officer = r.officer, amount = r.amount, status = r.status, sent = r.sent,
		total = r.total, code = r.code, time = r.time,
	}
end

-- The last request lives in store.payout[guild][player], so a reload keeps the lock and can
-- still answer LOGREQ and accept PAY/REJECT. The LOG chunks are rebuilt from the account.
local PLAYER_STATES = {
	wait_officer = true, sending = true, wait_decision = true, paid = true, rejected = true, expired = true,
	failed = true,
}

function Session:restorePayout()
	local list = self.store.payout and self.store.payout[self.guild]
	local r = type(list) == "table" and list[self.me]
	if type(r) ~= "table" or type(r.reqId) ~= "string" or type(r.officer) ~= "string" or type(r.amount) ~= "number"
		or type(r.time) ~= "number" or not PLAYER_STATES[r.status] then
		return
	end
	if r.status == "sending" then
		r.sent = 0 -- everything again: the officer ignores chunks it already has
	end
	self.request = r
end

function Session:setPayout(status, code)
	local r = self.request
	r.status, r.code = status, code
	if not PLAYER_OPEN[status] then
		self.logChunks = nil
		self.gameObj:refresh()
	end
	event(self, "payout", self:payout())
end

function Session:requestPayout(officer, amount)
	local env = self.env
	if self.broken then
		return nil, "broken"
	end
	if not self:hasAccount() then
		return nil, "no_account"
	end
	if type(amount) ~= "number" or amount % 1 ~= 0 or amount < 1 or amount > self.state.balance then
		return nil, "bad_amount"
	end
	if not Engine.validName(officer) or not env.isOfficer(officer) or (officer == self.me and not env.allowSelf) then
		return nil, "bad_officer"
	end
	self:expire()
	if self:payoutOpen() then
		return nil, "busy"
	end
	for _, p in ipairs(self.open) do
		if p.role == "player" then
			return nil, "busy"
		end
	end
	local reqId = env.randomHex(16)
	local ok = self:send("PAYREQ", {
		reqId = reqId, officer = officer, amount = amount, head = Ledger.shortHead(self.state),
		count = self.state.count,
	})
	if not ok then
		return nil, "send"
	end
	-- An open gamble offer is taken: the ledger already holds the win.
	self.declined = true
	self.gameObj:refresh()
	-- head and count are the account at the request: a late PAY only fits while they still hold.
	self.request = {
		reqId = reqId, officer = officer, amount = amount, status = "wait_officer", sent = 0, total = 0,
		time = env.now(), head = Ledger.shortHead(self.state), count = self.state.count,
	}
	self.logChunks = nil
	subtable(subtable(self.store, "payout"), self.guild)[self.me] = self.request
	event(self, "payout", self:payout())
	return reqId
end

-- Sends LOG chunks until the queue refuses one; the rest goes out on the next tick().
function Session:pumpLog()
	local r = self.request
	if not r or r.status ~= "sending" then
		return
	end
	local chunks = self.logChunks
	if not chunks then
		chunks = Pack.split(Pack.encode(self.account.entries))
		if #chunks ~= r.total then
			return self:setPayout("failed", "mismatch") -- the account changed under a restored request
		end
		self.logChunks = chunks
	end
	while r.sent < r.total do
		local seq = r.sent + 1
		if not self:send("LOG", { reqId = r.reqId, seq = seq, total = r.total, payload = chunks[seq] }) then
			return
		end
		r.sent = seq
	end
	self:setPayout("wait_decision")
end

function Session:onLogReq(sender, msg)
	local r = self.request
	if not r or r.status ~= "wait_officer" or r.reqId ~= msg.reqId or sender ~= r.officer or msg.player ~= self.me then
		return
	end
	local chunks = Pack.split(Pack.encode(self.account.entries))
	if #chunks > MAX_CHUNKS then
		return self:setPayout("failed", "too_large")
	end
	self.logChunks, r.total, r.sent = chunks, #chunks, 0
	self:setPayout("sending")
	self:pumpLog()
end

-- PAY for the open request, or for the last one after it expired: the head check below only
-- passes while the account is unchanged since the request.
function Session:onPay(sender, msg)
	local r = self.request
	if not r or not (PLAYER_OPEN[r.status] or r.status == "expired") or r.reqId ~= msg.reqId
		or sender ~= r.officer then
		return
	end
	if msg.player ~= self.me or msg.amount ~= r.amount then
		return self:setPayout("failed", "amount_mismatch")
	end
	local entry = {
		type = "P", payId = msg.payId, officer = sender, amount = msg.amount, balanceAfter = msg.balanceAfter,
		time = msg.time,
	}
	local trial = Ledger.copy(self.state)
	local info, code = Ledger.apply(trial, entry)
	if not info then
		return self:setPayout("failed", code)
	end
	if Ledger.shortHead(trial) ~= msg.head then
		return self:setPayout("failed", "head_mismatch")
	end
	self:append(entry)
	self:setPayout("paid")
	event(self, "account", { balance = self.state.balance })
end

function Session:onReject(sender, msg)
	local r = self.request
	if not r or not PLAYER_OPEN[r.status] or r.reqId ~= msg.reqId or sender ~= r.officer then
		return
	end
	self:setPayout("rejected", msg.reason)
end

-- Payout, officer side ------------------------------------------------------------------------

local REQ_PUBLIC = { "reqId", "player", "amount", "time", "status", "received", "total", "progress", "code" }

-- The request record without the account text; the report without the replayed state.
local function requestCopy(r)
	local c = {}
	for _, k in ipairs(REQ_PUBLIC) do
		c[k] = r[k]
	end
	if type(r.report) == "table" then
		local rep = {}
		for k, v in pairs(r.report) do
			if k ~= "state" then
				rep[k] = v
			end
		end
		c.report = rep
	end
	return c
end

function Session:findReq(reqId)
	for _, r in ipairs(self.reqs) do
		if r.reqId == reqId then
			return r
		end
	end
end

function Session:knownReqId(reqId)
	if self:findReq(reqId) then
		return true
	end
	for _, r in ipairs(self.store.requests) do
		if r.reqId == reqId then
			return true
		end
	end
	return false
end

function Session:setReq(r, status, code)
	r.status, r.code = status, code
	if not OFFICER_OPEN[status] then
		r.co, r.entries, r.chunks = nil, nil, nil
		for i, q in ipairs(self.reqs) do
			if q == r then
				table.remove(self.reqs, i)
				break
			end
		end
		local list = self.store.requests
		list[#list + 1] = requestCopy(r)
		while #list > KEEP_REQUESTS do
			table.remove(list, 1)
		end
	end
	event(self, "request", requestCopy(r))
end

function Session:sendReject(reqId, player, reason)
	return self:send("REJECT", { reqId = reqId, player = player, reason = reason })
end

function Session:onPayReq(sender, msg)
	local env = self.env
	if msg.officer ~= self.me or not env.isOfficer(self.me) or (sender == self.me and not env.allowSelf) then
		return
	end
	if self:knownReqId(msg.reqId) then
		return
	end
	for _, r in ipairs(self.reqs) do
		if r.player == sender then
			self:sendReject(msg.reqId, sender, "busy")
			return
		end
	end
	local r = {
		reqId = msg.reqId, player = sender, amount = msg.amount, time = env.now(), head = msg.head,
		count = msg.count, status = "fetching", received = 0, progress = 0, chunks = {},
	}
	self.reqs[#self.reqs + 1] = r
	if msg.count > Pack.MAX_ENTRIES then
		self:sendReject(r.reqId, sender, "too_large")
		return self:setReq(r, "failed", "too_large")
	end
	if not self:send("LOGREQ", { reqId = r.reqId, player = sender, from = 0 }) then
		return self:setReq(r, "failed", "send")
	end
	event(self, "request", requestCopy(r))
end

function Session:onLog(sender, msg)
	local r = self:findReq(msg.reqId)
	if not r or r.status ~= "fetching" or sender ~= r.player then
		return
	end
	if r.total == nil then
		if msg.total > MAX_CHUNKS then
			r.total = msg.total
			self:sendReject(r.reqId, r.player, "too_large")
			return self:setReq(r, "failed", "too_large")
		end
		r.total = msg.total
	elseif r.total ~= msg.total then
		return
	end
	if r.chunks[msg.seq] then
		return
	end
	r.chunks[msg.seq] = msg.payload
	r.received = r.received + 1
	if r.received < r.total then
		return
	end
	local entries, code = Pack.decode(table.concat(r.chunks, "", 1, r.total), r.count)
	r.chunks = nil
	if not entries then
		local reason = code == "too_many" and "mismatch" or "bad_log"
		self:sendReject(r.reqId, r.player, reason)
		return self:setReq(r, "failed", reason)
	end
	if #entries ~= r.count then
		self:sendReject(r.reqId, r.player, "mismatch")
		return self:setReq(r, "failed", "mismatch")
	end
	self:startVerify(r, entries)
end

function Session:startVerify(r, entries)
	local env = self.env
	local known = {}
	local seen = self.store.seen and self.store.seen[self.guild] and self.store.seen[self.guild][r.player]
	if type(seen) == "table" then
		for id, v in pairs(seen) do
			known[id] = v
		end
	end
	local heardList = self.store.heard and self.store.heard[self.guild]
	local heard = type(heardList) == "table" and type(heardList[r.player]) == "table" and heardList[r.player].live or nil
	local budget = env.stepBudget or STEP_BUDGET
	local steps, total = 0, #entries
	local input = {
		guild = self.guild, player = r.player, entries = entries, amount = r.amount,
		anchor = self:anchor(r.player), known = known,
		heard = type(heard) == "table" and { n = heard.n, g = heard.g, head = heard.head } or nil,
		isOfficer = function(name) return env.isOfficer(name) and true or false end,
		onStep = function(i)
			r.progress = i / total
			steps = steps + 1
			if steps >= budget then
				steps = 0
				coroutine.yield()
			end
		end,
	}
	r.entries = entries
	r.co = coroutine.create(function() return Verify.run(input) end)
	self:setReq(r, "checking")
end

-- Resumes the verification of the oldest request being checked by one step budget.
function Session:verifyStep()
	for _, r in ipairs(self.reqs) do
		if r.status == "checking" and r.co then
			local ok, report = coroutine.resume(r.co)
			if not ok then
				self:sendReject(r.reqId, r.player, "bad_log")
				return self:setReq(r, "failed", "verify")
			end
			if coroutine.status(r.co) == "dead" then
				r.co, r.entries = nil, nil
				if report.state and Ledger.shortHead(report.state) ~= r.head then
					self:sendReject(r.reqId, r.player, "mismatch")
					return self:setReq(r, "failed", "mismatch")
				end
				r.report, r.progress = report, 1
				self:setReq(r, "ready")
			end
			return
		end
	end
end

function Session:confirm(reqId)
	local env = self.env
	self:expire()
	local r = self:findReq(reqId)
	if not r then
		return nil, "unknown"
	end
	if r.status ~= "ready" then
		return nil, "not_ready"
	end
	local now = env.now()
	if now - r.time >= CONFIRM_LIMIT then
		self:sendReject(r.reqId, r.player, "expired")
		self:setReq(r, "expired")
		return nil, "expired"
	end
	local report = r.report
	if not report.state then
		return nil, "no_replay"
	end
	if r.amount > report.balance then
		return nil, "amount_too_high"
	end
	local entry = {
		type = "P", payId = env.randomHex(16), officer = self.me, amount = r.amount,
		balanceAfter = report.balance - r.amount, time = floor(now),
	}
	local after = Ledger.copy(report.state)
	local info, code = Ledger.apply(after, entry)
	if not info then
		return nil, code
	end
	local head = Ledger.shortHead(after)
	local ok = self:send("PAY", {
		reqId = r.reqId, payId = entry.payId, player = r.player, amount = entry.amount,
		balanceAfter = entry.balanceAfter, time = entry.time, head = head, anchors = after.anchors,
		n = after.n, ck = Ledger.checkpointKey(after.n, after.K, after.line),
	})
	if not ok then
		return nil, "send"
	end
	r.payId = entry.payId
	self:storeAnchor(r.player, { anchors = after.anchors, head = head, time = entry.time, by = self.me })
	self:markSeen(r.player, entry.payId)
	self:setReq(r, "paid")
	return entry.payId
end

function Session:reject(reqId, reason)
	reason = reason or "declined"
	if not REASONS[reason] then
		return nil, "bad_reason"
	end
	self:expire()
	local r = self:findReq(reqId)
	if not r then
		return nil, "unknown"
	end
	if not self:sendReject(r.reqId, r.player, reason) then
		return nil, "send"
	end
	self:setReq(r, "rejected", reason)
	return true
end

function Session:requests()
	local list = {}
	for _, r in ipairs(self.store.requests) do
		list[#list + 1] = requestCopy(r)
	end
	for _, r in ipairs(self.reqs) do
		list[#list + 1] = requestCopy(r)
	end
	for i, r in ipairs(list) do
		r.order = i
	end
	sort(list, function(a, b)
		if a.time ~= b.time then
			return (a.time or 0) > (b.time or 0)
		end
		return a.order > b.order
	end)
	for _, r in ipairs(list) do
		r.order = nil
	end
	return list
end

-- OSYNC: the newest own anchors, once, 20 s after the first tick as an officer.
function Session:osync()
	local env, now = self.env, self.env.now()
	if not self.osyncQueue then
		if not env.isOfficer(self.me) then
			return
		end
		self.officerSince = self.officerSince or now
		if now - self.officerSince < OSYNC_DELAY then
			return
		end
		local queue = {}
		local list = self.store.anchors and self.store.anchors[self.guild]
		if type(list) == "table" then
			for player, a in pairs(list) do
				if type(a) == "table" and a.by == self.me then
					queue[#queue + 1] = { player = player, anchors = a.anchors, head = a.head, time = a.time }
				end
			end
		end
		sort(queue, function(a, b)
			if a.time ~= b.time then
				return a.time > b.time
			end
			return a.player < b.player
		end)
		while #queue > OSYNC_MAX do
			table.remove(queue)
		end
		self.osyncQueue = queue
	end
	local queue = self.osyncQueue
	while #queue > 0 do
		local text = Proto.encode("OSYNC", queue[1])
		if text then
			local ok = self.env.send(text)
			if not ok then
				return -- refused by the queue: try again on the next tick
			end
		end
		table.remove(queue, 1)
	end
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

-- n and head as the message carries them. `live` is { n, g, head before that entry } for a SPIN or
-- GAM; a HELLO (head after the last entry) keeps the last one, which is what Verify check 4 reads.
function Session:hear(sender, n, head, live)
	local prev = self.heard[sender]
	local rec = { n = n, head = head, time = self.env.now(), live = live or (prev and prev.live) }
	self.heard[sender] = rec
	if self.env.isOfficer(self.me) then
		local list = subtable(subtable(self.store, "heard"), self.guild)
		local stored = list[sender]
		if not live and type(stored) == "table" then
			live = stored.live
		end
		list[sender] = { n = n, head = head, time = rec.time, live = live or rec.live }
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
	self:pumpLog()
	self:verifyStep()
	self:osync()
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
		self:watchBuy1(sender, msg)
		if msg.player == self.me and not self:knownBuyId(msg.buyId, "player") then
			self:onBuy1(sender, msg)
		end
	elseif kind == "BUY2" then
		local p = self:findOpen(msg.buyId, "officer")
		if not p and not self.watch[msg.buyId] and not self:knownBuyId(msg.buyId) then
			return
		end
		self:alive(sender)
		self:watchBuy2(sender, msg)
		if p then
			self:onBuy2(sender, msg, p)
		end
	elseif kind == "BUY3" then
		if not env.isOfficer(sender) or not (self.watch[msg.buyId] or self:knownBuyId(msg.buyId)) then
			return
		end
		local p = self:findOpen(msg.buyId, "player")
		if p and sender ~= p.officer then
			return
		end
		self:alive(sender)
		self:watchBuy3(sender, msg)
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
	elseif kind == "SPIN" then
		self:alive(sender)
		self:hear(sender, msg.n, msg.head, { n = msg.n, g = 0, head = msg.head })
		self:onTickerSpin(sender, msg)
	elseif kind == "GAM" then
		self:alive(sender)
		self:hear(sender, msg.n, msg.head, { n = msg.n, g = msg.g, head = msg.head })
	elseif kind == "PAYREQ" then
		self:alive(sender)
		self:onPayReq(sender, msg)
	elseif kind == "LOGREQ" then
		self:alive(sender)
		if msg.player == self.me then
			self:onLogReq(sender, msg)
		end
	elseif kind == "LOG" then
		self:alive(sender)
		self:onLog(sender, msg)
	elseif kind == "PAY" then
		if not env.isOfficer(sender) then
			return
		end
		self:alive(sender)
		self:storeAnchor(msg.player, { anchors = msg.anchors, head = msg.head, time = msg.time, by = sender })
		self:markSeen(msg.player, msg.payId)
		if msg.player == self.me then
			self:onPay(sender, msg)
		end
	elseif kind == "REJECT" then
		if not env.isOfficer(sender) then
			return
		end
		self:alive(sender)
		if msg.player == self.me then
			self:onReject(sender, msg)
		end
	elseif kind == "OSYNC" then
		if not env.isOfficer(sender) then
			return
		end
		self:alive(sender)
		self:storeAnchor(msg.player, { anchors = msg.anchors, head = msg.head, time = msg.time, by = sender })
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
	if s:payoutOpen() then
		return "payout"
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
	if s:payoutOpen() then
		return nil, "payout"
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
	if tbl.kind == "lines" then
		return {
			kind = "spin",
			n = entry.n,
			stake = stake,
			win = info.win,
			balance = info.balance,
			pending = info.pending,
			canGamble = info.pending > 0,
			round = info.round,
		}
	end
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
	if self.session:payoutOpen() then
		return nil, "payout"
	end
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
	return ns.Solo.info(self.tbl, self.stake, self.cap, self.maxGamble)
end
