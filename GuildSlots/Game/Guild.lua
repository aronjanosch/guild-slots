local _, ns = ...

-- The guild session at security level 0 (docs/guild-spec.md section 6): the own account, token
-- purchases between an officer and a player, level-0 spins and gamble steps, and presence.
-- Payouts, anchors and OSYNC follow docs/payout-spec.md section 4. Witnesses at level 1 and 2
-- (both sides) and the level-1/2 ticker follow docs/witness-spec.md sections 2 to 4. The witness
-- commit, following, alerts and early settling follow docs/follow-spec.md sections 2, 3, 4 and 6.
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
local WITNESS_INTERVAL = 2.5 -- seconds between spins or gamble steps at level 1 and 2
local WITNESS_WINDOW = 1.5 -- seconds the player collects WIT, unless env.witnessWindow says otherwise
local SETTLE_MIN = 0.3 -- seconds a request is open at least, even when every expected witness answered
local WITNESS_AGE = 14 * 86400 -- seconds a previous secret, a witness row, a sample and an alert are kept
local SECRET_LIFE = 86400 -- seconds a session secret is used before it is replaced at session creation
local WITNESS_KEEP = 5000 -- witness rows per guild
local WITNESS_RATE = 2 -- answers per player per second
local MAX_A = 10000
local TICKER_WIT_MAX = 16 -- WIT values the ticker keeps per SPIN
local TICKER_WIT_AGE = 10 -- seconds they are kept
local LIVE_WIT_MAX = 64 -- WIT values kept per heard request of another player
local SAMPLE_ROWS = 20 -- rows per sample reservoir
local ALERT_KEEP = 200 -- own alerts per guild
local ALERT_SEND = 3 -- ALERT messages per PAYREQ
local ALERT_DELAY = 3 -- seconds, the most an ALERT batch waits after the PAYREQ (random 0..3)
local ALERT_GIVE_UP = 10 -- seconds after its due time a batch that found no budget is dropped
local ALERT_IN_MAX = 50 -- ALERT rows kept per reqId
local OMIT_MARGIN = 0.5 -- seconds a WIT must precede the RES to count as omitted
local FOLLOW_STEPS = 8 -- followed ledger entries applied per tick()
local FOLLOW_QUEUE = 50 -- followed messages waiting per player
local FOLLOW_ENTRIES = 3000 -- entries an officer keeps per followed account
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
		tickWit = {}, -- player -> { n, stake, time, values = { name -> value }, count } of the newest level 1/2 SPIN
		wreq = nil, -- the own open witness request: { rec (as in store.open), level, due, got, seen }
		resOut = {}, -- RES messages still to send, oldest first
		witRate = {}, -- player -> { second, count } of the answers sent to that player
		witIndex = {}, -- "player|kind|n|g" -> witness row
		request = nil, -- the own payout request (player side)
		reqs = {}, -- payout requests addressed to this officer, still open, oldest first
		nextHello = nil,
		lastAction = nil,
		noticed = false,
		declined = false,
		created = env.now(),
		live = {}, -- player -> the newest SPIN/GAM heard from that player, with its WIT values
		fol = {}, -- player -> { state, req, trusted, queued } of the followed account (in memory)
		fq = {}, -- followed steps waiting, in arrival order: { player, k, … }
		fqHead = 1, -- index of the oldest waiting step
		fqTail = 0, -- index of the newest
		payreqs = {}, -- reqId -> { player, count, head, officer, time } of every PAYREQ heard
		alertsIn = {}, -- reqId -> { { by, player, code, n, g, time }, … } ALERT messages heard
		alertOut = {}, -- ALERT batches waiting for their delay: { reqId, player, due, until, rows }
		witSent = {}, -- "player|kind|n|g" -> time the own WIT for that request went out
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
	self:initWitness()
	self:cleanFollow()
	self:restoreOpen()

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
			if w.nonce then
				-- The player answered but the seed was not heard: the purchase may have completed.
				self:followQueue(w.player, { k = "lost" })
			end
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
		if not code and (self:payoutOpen() or self.wreq) then
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
-- `purchase` is the purchase entry text: a PAY restarts following from it (docs/follow-spec.md 3).
function Session:storeKey(w, K, line, purchase)
	if w.player == self.me or type(w.time) ~= "number" then
		return
	end
	local list = subtable(subtable(self.store, "keys"), self.guild)
	local cur = list[w.player]
	if type(cur) == "table" and type(cur.time) == "number" and cur.time > w.time then
		return
	end
	list[w.player] = { K = K, line = line, time = w.time, purchase = purchase }
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
		self:followQueue(w.player, { k = "lost" }) -- the account changed in a way this client cannot follow
		return
	end
	local text = Ledger.encode({
		type = "B", buyId = w.buyId, officer = w.officer, tokens = w.tokens, commit = w.commit, seed = seed,
		nonce = w.nonce, time = w.time, line = line,
	})
	self:storeKey(w, Engine.purchaseKey(w.buyId, seed, w.nonce), line, text)
	if not text then
		return
	end
	self:followQueue(w.player, { k = "buy", text = text, buyId = w.buyId, head = w.head, anchors = w.anchors },
		w.anchors == 0)
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
	if w and sender == w.officer then
		self.watch[msg.buyId] = nil
		if w.nonce then
			self:purchaseAnchor(w, msg.seed)
		else
			-- The BUY2 was missed: the player may now hold a purchase this client cannot rebuild.
			self:dropKey(w.player, w.time)
			self:followQueue(w.player, { k = "lost" })
		end
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

-- The stored key of another player, or nil.
function Session:tickerKey(player)
	local list = self.store.keys and self.store.keys[self.guild]
	local k = type(list) == "table" and list[player]
	if type(k) ~= "table" or type(k.K) ~= "string" then
		return nil
	end
	return k
end

function Session:onTickerSpin(sender, msg)
	if sender == self.me or type(msg.n) ~= "number" or type(msg.stake) ~= "number" then
		return
	end
	if msg.level == 0 then
		return self:tickerRound(sender, msg.n, msg.stake, "")
	end
	-- Level 1 and 2: keep the WIT values of this SPIN until the player's RES names the included ones.
	if self:tickerKey(sender) then
		self.tickWit[sender] = { n = msg.n, stake = msg.stake, time = self.env.now(), values = {}, count = 0 }
	end
end

function Session:onTickerWit(sender, msg)
	local rec = self.tickWit[msg.player]
	if not rec or msg.kind ~= "spin" or msg.n ~= rec.n or sender == msg.player or rec.values[sender]
		or rec.count >= TICKER_WIT_MAX or self.env.now() - rec.time > TICKER_WIT_AGE then
		return
	end
	rec.values[sender] = msg.value
	rec.count = rec.count + 1
end

-- A RES of a level 1/2 spin: every 4-hex group of `who` must match exactly one kept value.
function Session:onTickerRes(sender, msg)
	if msg.kind ~= "spin" then
		return
	end
	local rec = self.tickWit[sender]
	self.tickWit[sender] = nil
	if not rec or msg.status ~= "ok" or msg.n ~= rec.n or self.env.now() - rec.time > TICKER_WIT_AGE
		or msg.who == "-" then
		return
	end
	local list, used = {}, {}
	for i = 1, #msg.who, 4 do
		local tag = sub(msg.who, i, i + 3)
		local match
		for name, value in pairs(rec.values) do
			if sub(value, 1, 4) == tag then
				if match then
					return -- two values carry this tag
				end
				match = name
			end
		end
		if not match or used[match] then
			return
		end
		used[match] = true
		list[#list + 1] = { name = match, value = rec.values[match], lot = 0 }
	end
	self:tickerRound(sender, rec.n, rec.stake, Engine.contribs(list))
end

-- Recalculates round n of another player under the stored key and announces it when notable.
function Session:tickerRound(sender, n, stake, contribs)
	local env = self.env
	local k = self:tickerKey(sender)
	if not k then
		return
	end
	local last = self.tickLast[sender]
	if last and n <= last then
		return
	end
	local s = parsedLine(k.line) and Settings.parse(k.line)
	local tbl = s and Tables.get(s.T)
	if not tbl or tbl.kind ~= "lines" or stake % tbl.lineCount ~= 0 then
		return
	end
	local allowed = false
	for _, v in ipairs(s.E) do
		if v == stake then
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
	self.tickLast[sender] = n
	local ok, round = pcall(Engine.round, k.K, n, contribs, tbl, stake, s.C)
	if not ok or type(round) ~= "table" or type(round.win) ~= "number" then
		return
	end
	local win = round.win
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
		player = sender, n = n, stake = stake, win = win, mult = win / stake,
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

-- Witness side (docs/witness-spec.md section 2) ----------------------------------------------

local function witKey(player, kind, n, g)
	return player .. "|" .. kind .. "|" .. n .. "|" .. g
end

-- Replaces a stale secret, drops old or surplus witness rows, and indexes the rest. Runs at
-- creation; the secret is created here because HELLO carries its commit (docs/follow-spec.md 2).
function Session:initWitness()
	local now = self.env.now()
	self:rotateSecret()
	local all = self.store.witness
	local list = type(all) == "table" and all[self.guild]
	if type(list) ~= "table" then
		return
	end
	local kept = {}
	for _, row in ipairs(list) do
		if type(row) == "table" and type(row.time) == "number" and now - row.time < WITNESS_AGE
			and type(row.player) == "string" and type(row.value) == "string" and type(row.n) == "number"
			and type(row.g) == "number" and (row.kind == "spin" or row.kind == "gam") then
			kept[#kept + 1] = row
		end
	end
	local out = {}
	for i = math.max(1, #kept - WITNESS_KEEP + 1), #kept do
		out[#out + 1] = kept[i]
		self.witIndex[witKey(kept[i].player, kept[i].kind, kept[i].n, kept[i].g)] = kept[i]
	end
	all[self.guild] = out
end

local function validSecret(sec)
	return type(sec) == "table" and type(sec.S) == "string" and #sec.S == 32 and type(sec.time) == "number"
end

-- At session creation: a secret older than 24 hours is replaced and moves to store.secret.prev,
-- which HELLO reveals and which is kept 14 days from its own creation (docs/follow-spec.md 2).
function Session:rotateSecret()
	local now = self.env.now()
	local sec = self.store.secret
	if validSecret(sec) and now - sec.time >= SECRET_LIFE then
		sec = { S = self.env.randomHex(32), time = floor(now), prev = { S = sec.S, time = sec.time } }
		self.store.secret = sec
	end
	if validSecret(sec) and sec.prev ~= nil and (not validSecret(sec.prev) or now - sec.prev.time >= WITNESS_AGE) then
		sec.prev = nil
	end
	self:secret()
end

-- The session secret S; created when missing. It does not rotate within a session.
function Session:secret()
	local sec = self.store.secret
	if not validSecret(sec) then
		sec = { S = self.env.randomHex(32), time = floor(self.env.now()) }
		self.store.secret = sec
	end
	return sec.S
end

-- The previous secret HELLO reveals, or "-".
function Session:revealed()
	local prev = self.store.secret and self.store.secret.prev
	return validSecret(prev) and prev.S or "-"
end

-- Commits ------------------------------------------------------------------------------------
-- store.commits[guild][name] = { commit, time } of the latest HELLO of every other sender.

function Session:commits()
	return subtable(subtable(self.store, "commits"), self.guild)
end

-- The known commit of a name, or nil. A stored commit counts (a WIT counts, the name is a witness).
function Session:commitOf(name)
	local c = self:commits()[name]
	return type(c) == "table" and type(c.commit) == "string" and c.commit or nil
end

-- The commit of a name heard in this session, or nil: only those are safe to sample under, since
-- the witness may have rotated its secret while this client was away.
function Session:liveCommit(name)
	local c = self:commits()[name]
	if type(c) == "table" and type(c.commit) == "string" and type(c.time) == "number" and c.time >= self.created then
		return c.commit
	end
end

function Session:addWitnessRow(row)
	local list = subtable(subtable(self.store, "witness"), self.guild)
	list[#list + 1] = row
	self.witIndex[witKey(row.player, row.kind, row.n, row.g)] = row
	if #list > WITNESS_KEEP then
		local old = table.remove(list, 1)
		local key = witKey(old.player, old.kind, old.n, old.g)
		if self.witIndex[key] == old then
			self.witIndex[key] = nil
		end
	end
end

-- A SPIN or GAM of another member at level 1 or 2.
function Session:answerRequest(sender, msg, kind)
	local env = self.env
	if sender == self.me or (msg.level ~= 1 and msg.level ~= 2) then
		return
	end
	local g = kind == "gam" and msg.g or 0
	if msg.level == 2 then
		if not env.isOfficer(self.me) then
			return
		end
	else
		local A = msg.A
		if A < 1 or A > MAX_A then
			return
		end
		local count, meOnline = 0, false
		for _, s in ipairs(self:online()) do
			if s.name ~= sender then
				count = count + 1
			end
			if s.name == self.me then
				meOnline = true
			end
		end
		if not meOnline then
			count = count + 1
		end
		if 2 * A < count or A > 2 * count then
			return
		end
		local settings = parsedLine(env.line())
		if not settings or not Engine.drawn(Engine.lot(self.me, sender, kind, msg.n, g), A, settings.Z) then
			return
		end
	end
	if env.budget() < SPIN_BUDGET then
		return
	end
	local now = env.now()
	local second = floor(now)
	local rate = self.witRate[sender]
	if not rate or rate.second ~= second then
		rate = { second = second, count = 0 }
		self.witRate[sender] = rate
	end
	if rate.count >= WITNESS_RATE then
		return
	end
	local amount = kind == "gam" and msg.amount or msg.stake
	local row = self.witIndex[witKey(sender, kind, msg.n, g)]
	if row then
		if row.amount ~= amount or row.head ~= msg.head then
			return -- the same number with other terms: a retry after seeing the result
		end
	else
		row = {
			player = sender, kind = kind, n = msg.n, g = g, amount = amount, head = msg.head, time = now,
			value = Engine.witnessValue(self:secret(), sender, kind, msg.n, g, amount, msg.head),
		}
		self:addWitnessRow(row)
	end
	if self:send("WIT", { player = sender, kind = kind, n = msg.n, g = g, value = row.value }) then
		rate.count = rate.count + 1
		self.witSent[witKey(sender, kind, msg.n, g)] = now
	end
end

-- A RES of another member marks the row of that request; the first RES wins.
function Session:markWitness(sender, msg)
	local row = self.witIndex[witKey(sender, msg.kind, msg.n, msg.g)]
	if not row or row.res ~= nil then
		return
	end
	local tag, hit = sub(row.value, 1, 4), false
	if msg.who ~= "-" then
		for i = 1, #msg.who, 4 do
			if sub(msg.who, i, i + 3) == tag then
				hit = true
			end
		end
	end
	if msg.status == "ok" then
		row.res = hit and "in" or "out"
	else
		row.res = hit and "void_in" or "void_out"
	end
	-- Left out although the own WIT went out in time. With 8 included the limit may have left it
	-- out, so only fewer than 8 counts.
	local key = witKey(sender, msg.kind, msg.n, msg.g)
	local sent = self.witSent[key]
	self.witSent[key] = nil
	if not hit and sent and self.env.now() - sent >= OMIT_MARGIN - 1e-9 and (msg.who == "-" or #msg.who < 32) then
		self:addAlert(sender, "omitted", msg.n, msg.g)
	end
end

-- Player side at level 1 and 2 (docs/witness-spec.md section 3) ----------------------------------

-- The entry of a request with the given status and contributions.
local function requestEntry(rec, status, contribs)
	if rec.kind == "spin" then
		return { type = "S", n = rec.n, stake = rec.stake, A = rec.A, status = status, contribs = contribs }
	end
	return { type = "G", n = rec.n, g = rec.g, A = rec.A, status = status, contribs = contribs }
end

-- A for a request at this level, or nil and few_players / no_officer.
function Session:witnessesOnline(level, W)
	local env, A = self.env, 0
	for _, s in ipairs(self:online()) do
		if s.name ~= self.me and self:commitOf(s.name) then
			if level == 2 and env.isOfficer(s.name) then
				return 0
			end
			A = A + 1
		end
	end
	if level == 2 then
		return nil, "no_officer"
	end
	if A < W then
		return nil, "few_players"
	end
	return math.min(A, MAX_A)
end

-- The names that should answer a request (docs/follow-spec.md section 6): online with a known
-- commit, not the own name, and drawn at level 1 or officers at level 2.
function Session:expectedWitnesses(rec, level)
	local out, Z = {}, self.state.settings.Z
	for _, s in ipairs(self:online()) do
		local name = s.name
		if name ~= self.me and self:commitOf(name) then
			local ok
			if level == 2 then
				ok = self.env.isOfficer(name)
			else
				ok = Engine.drawn(Engine.lot(name, self.me, rec.kind, rec.n, rec.g), rec.A, Z)
			end
			if ok then
				out[#out + 1] = name
			end
		end
	end
	return out
end

-- Stores the open request, sends SPIN or GAM and starts the window. r = { kind, n, g, stake, amount, A }.
function Session:startRequest(r)
	local env, state = self.env, self.state
	local level = state.settings.L
	local head = Ledger.shortHead(state)
	local probe, code = Ledger.apply(Ledger.copy(state), requestEntry(r, "void", ""))
	if not probe then
		return nil, code
	end
	local now = env.now()
	local rec = { kind = r.kind, n = r.n, g = r.g, stake = r.stake, amount = r.amount, A = r.A, head = head, time = now }
	local opens = subtable(subtable(self.store, "open"), self.guild)
	opens[self.me] = rec
	local ok
	if r.kind == "spin" then
		ok = self:send("SPIN", { n = r.n, stake = r.stake, level = level, head = head, A = r.A })
	else
		ok = self:send("GAM", { n = r.n, g = r.g, amount = r.amount, level = level, head = head, A = r.A })
	end
	if not ok then
		opens[self.me] = nil
		return nil, "send"
	end
	local due = now + (env.witnessWindow or WITNESS_WINDOW)
	self.wreq = { rec = rec, level = level, due = due, got = {}, seen = {}, expect = self:expectedWitnesses(rec, level) }
	if r.kind == "spin" then
		self.declined = true -- an open gamble offer is taken; the spin's own offer comes with its entry
	end
	self.lastAction = now
	self.gameObj:refresh()
	return { kind = "wait", what = r.kind == "spin" and "spin" or "gamble", n = r.n, g = r.g, due = due }
end

-- A WIT for the own open request.
function Session:collectWit(sender, msg)
	local q = self.wreq
	if not q or msg.player ~= self.me or sender == self.me or q.seen[sender] or not self:commitOf(sender) then
		return
	end
	local rec = q.rec
	if msg.kind ~= rec.kind or msg.n ~= rec.n or msg.g ~= rec.g or self.env.now() > q.due then
		return
	end
	local lot = Engine.lot(sender, self.me, rec.kind, rec.n, rec.g)
	if q.level == 1 then
		if not Engine.drawn(lot, rec.A, self.state.settings.Z) then
			return
		end
	elseif not self.env.isOfficer(sender) then
		return
	end
	q.seen[sender] = true
	q.got[#q.got + 1] = { name = sender, value = msg.value, lot = lot }
end

function Session:queueRes(rec, status, list)
	local tags = {}
	for i, c in ipairs(list) do
		tags[i] = sub(c.value, 1, 4)
	end
	self.resOut[#self.resOut + 1] = {
		kind = rec.kind, n = rec.n, g = rec.kind == "spin" and 0 or rec.g, status = status,
		who = #tags > 0 and table.concat(tags) or "-", head = Ledger.shortHead(self.state),
	}
end

function Session:pumpRes()
	while #self.resOut > 0 do
		local text = Proto.encode("RES", self.resOut[1])
		if text and not self.env.send(text) then
			return -- refused by the queue: again on the next tick
		end
		table.remove(self.resOut, 1)
	end
end

-- The level-0 result tables (guild-spec section 6), shared with the level 1/2 results.
local function spinResult(state, entry, info)
	local tbl = state.tbl
	if tbl.kind == "lines" then
		return {
			kind = "spin", n = entry.n, stake = entry.stake, win = info.win, balance = info.balance,
			pending = info.pending, canGamble = info.pending > 0, round = info.round,
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
		stake = entry.stake,
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

local function gambleResult(entry, amount, info)
	return {
		kind = "gamble", won = info.won, step = entry.g, amount = amount, pending = info.pending,
		balance = info.balance, canGamble = info.pending > 0,
	}
end

-- At the first tick at or after `due`: write the entry, send RES, raise `result`.
function Session:settleRequest()
	local q = self.wreq
	if not q then
		return
	end
	local now = self.env.now()
	if now < q.due then
		-- Settle early once every expected witness answered, but not before the reels started.
		if now - q.rec.time < SETTLE_MIN - 1e-9 then
			return
		end
		for _, name in ipairs(q.expect) do
			if not q.seen[name] then
				return
			end
		end
	end
	self.wreq = nil
	local rec = q.rec
	local settings = self.state.settings
	local need = q.level == 1 and settings.W or 1
	local contribs = Engine.contribs(q.got)
	local list = Engine.parseContribs(contribs) or {}
	local status = #list >= need and "ok" or "void"
	local entry = requestEntry(rec, status, contribs)
	local info = self:append(entry)
	if not info and status == "ok" then
		status, entry = "void", requestEntry(rec, "void", contribs)
		info = self:append(entry)
	end
	if not info then
		list = {}
		entry = requestEntry(rec, "void", "")
		info = self:append(entry)
	end
	local opens = self.store.open and self.store.open[self.guild]
	if type(opens) == "table" then
		opens[self.me] = nil
	end
	if rec.kind == "spin" then
		self.declined = false
	end
	if not info then
		self.gameObj:refresh()
		return -- cannot happen for a request that passed the probe; nothing to report
	end
	self:queueRes(rec, status, list)
	self:pumpRes()
	self.gameObj:refresh()
	local result
	if status == "ok" then
		result = rec.kind == "spin" and spinResult(self.state, entry, info) or gambleResult(entry, rec.amount, info)
	elseif rec.kind == "spin" then
		result = { kind = "void", what = "spin", n = rec.n, need = need, got = #list, balance = self.state.balance }
	else
		result = {
			kind = "void", what = "gamble", n = rec.n, g = rec.g, need = need, got = #list,
			balance = self.state.balance, pending = self.gameObj.pending,
		}
	end
	event(self, "result", result)
end

-- An open request found at creation: void when the account is still where it was, else dropped.
-- Asking again after a reload would let a modified client look at the result first.
function Session:restoreOpen()
	local opens = self.store.open and self.store.open[self.guild]
	if type(opens) ~= "table" or opens[self.me] == nil then
		return
	end
	local rec = opens[self.me]
	opens[self.me] = nil
	if type(rec) ~= "table" or self.broken or not self:hasAccount() or rec.head ~= Ledger.shortHead(self.state)
		or (rec.kind ~= "spin" and rec.kind ~= "gam") then
		return
	end
	if self:append(requestEntry(rec, "void", "")) then
		self:queueRes(rec, "void", {})
	end
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
	if self:payoutOpen() or self.wreq then
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
	if trial.head ~= msg.head then
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
	if not self:send("LOGREQ", { reqId = r.reqId, player = sender, from = 0, head = "-" }) then
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
		balanceAfter = entry.balanceAfter, time = entry.time, head = after.head, anchors = after.anchors,
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

-- Requests heard from others ------------------------------------------------------------------
-- self.live[player] = the newest SPIN/GAM of another player: { kind, n, g, amount, head, A, level,
-- wits = { name -> value }, count, ambiguous }. Samples and following read the WIT values from it.

function Session:hearRequest(sender, msg, kind)
	if sender == self.me then
		return nil
	end
	local g = kind == "gam" and msg.g or 0
	local amount = kind == "gam" and msg.amount or msg.stake
	local prev = self.live[sender]
	if prev and prev.kind == kind and prev.n == msg.n and prev.g == g then
		if prev.amount == amount and prev.head == msg.head then
			return prev -- the same request again: its values stay
		end
		-- The same number with other terms: a late WIT could belong to either, so none is sampled.
		local rec = { kind = kind, n = msg.n, g = g, amount = amount, head = msg.head, A = msg.A, level = msg.level,
			wits = {}, count = 0, ambiguous = true }
		self.live[sender] = rec
		return rec
	end
	local rec = { kind = kind, n = msg.n, g = g, amount = amount, head = msg.head, A = msg.A, level = msg.level,
		wits = {}, count = 0 }
	self.live[sender] = rec
	return rec
end

-- A WIT for another player's request: kept for following, sampled when the sender is another.
function Session:hearWit(sender, msg)
	local player = msg.player
	local rec = self.live[player]
	if not rec or sender == player or rec.kind ~= msg.kind or rec.n ~= msg.n or rec.g ~= msg.g then
		return
	end
	if rec.wits[sender] == nil and rec.count < LIVE_WIT_MAX then
		rec.wits[sender] = msg.value
		rec.count = rec.count + 1
	end
	if sender ~= self.me and not rec.ambiguous then
		self:sample(sender, {
			player = player, kind = rec.kind, n = rec.n, g = rec.g, amount = rec.amount, head = rec.head, value = msg.value,
		})
	end
end

-- Following (docs/follow-spec.md section 3) ----------------------------------------------------
-- store.follow[guild][player] = { snap, count, lost, entries, base } (see the spec). In memory:
-- self.fol[player] = { state (restored lazily), req (open level 1/2 request), trusted, queued }.
-- Messages about a followed player wait in self.fq (arrival order) and tick() applies at most
-- FOLLOW_STEPS ledger entries per call.

function Session:followList()
	return subtable(subtable(self.store, "follow"), self.guild)
end

-- The stored record of a player, or nil.
function Session:followRecord(player)
	local rec = self:followList()[player]
	if type(rec) ~= "table" or type(rec.snap) ~= "table" then
		return nil
	end
	return rec
end

function Session:folOf(player)
	local f = self.fol[player]
	if not f then
		f = { queued = 0 }
		self.fol[player] = f
	end
	return f
end

-- The followed ledger state of a player (restored from the snapshot when needed), or nil when
-- the player is not followed or the stream is lost.
function Session:followedState(player)
	local rec = self:followRecord(player)
	if not rec or rec.lost then
		return nil
	end
	local f = self:folOf(player)
	if not f.state then
		local state = Ledger.restore(self.guild, player, rec.snap)
		if not state or not state.settings then
			rec.lost = true
			return nil
		end
		f.state = state
	end
	return f.state
end

-- Starts (or restarts) following a player at a ledger state this client trusts. `state` is not
-- changed. count = entries of the whole account at that state, or nil. Officers also keep `base`
-- (a ledger state, default `state`) and `entries` (texts from base to state, default none).
-- Starting point 3 (a payout check on an officer's client) calls this with the replayed state.
function Session:followStart(player, state, count, base, entries)
	if player == self.me or type(state) ~= "table" or not state.settings then
		return false
	end
	local rec = { snap = Ledger.snapshot(state), count = count }
	if self.env.isOfficer(self.me) then
		rec.base = Ledger.snapshot(base or state)
		local list = {}
		for i, text in ipairs(entries or {}) do
			list[i] = text
		end
		rec.entries = #list <= FOLLOW_ENTRIES and list or nil
		if not rec.entries then
			rec.base = nil
		end
	end
	self:followList()[player] = rec
	local f = self:folOf(player)
	f.state, f.req, f.trusted = Ledger.copy(state), nil, true
	return true
end

-- The stream broke: the snapshot stays as the last checked state.
function Session:followLost(player, code, n, g)
	local f = self:folOf(player)
	local rec = self:followRecord(player)
	if code and (code ~= "rewritten" or f.trusted) then
		self:addAlert(player, code, n, g)
	end
	if rec then
		rec.lost = true
	end
	f.state, f.req = nil, nil
end

-- An entry applied to the followed state: write the snapshot back and keep the officer's entries.
function Session:followCommit(player, state, text)
	local rec = self:followRecord(player)
	rec.snap = Ledger.snapshot(state)
	if type(rec.count) == "number" then
		rec.count = rec.count + 1
	end
	if type(rec.entries) == "table" then
		if #rec.entries >= FOLLOW_ENTRIES then
			rec.entries, rec.base = nil, nil
		else
			rec.entries[#rec.entries + 1] = text
		end
	end
	self:folOf(player).trusted = true
end

-- Applies an entry to the followed state. Returns true, or nil after marking the stream lost.
function Session:followApply(player, state, entry, n, g)
	local info = Ledger.apply(state, entry)
	if not info then
		self:followLost(player, "bad_entry", n, g)
		return nil
	end
	self:followCommit(player, state, Ledger.encode(entry))
	return true
end

-- Queues a message about another player. Starting points are queued for anyone; steps only for
-- players this client follows (or will, once a queued starting point is applied).
function Session:followQueue(player, item, isStart)
	if player == self.me or not Engine.validName(player) then
		return
	end
	local f = self.fol[player]
	local queued = f and f.queued or 0
	if not isStart and queued == 0 then
		local rec = self:followRecord(player)
		if not rec or rec.lost then
			return
		end
	end
	f = self:folOf(player)
	if f.queued >= FOLLOW_QUEUE then
		-- Too much waiting: the stream is lost; the queued steps of that player go.
		local keep = {}
		for i = self.fqHead, self.fqTail do
			local q = self.fq[i]
			if q.player ~= player then
				keep[#keep + 1] = q
			end
		end
		self.fq, self.fqHead, self.fqTail, f.queued = keep, 1, #keep, 0
		self:followLost(player)
		if not isStart then
			return
		end
	end
	f.queued = f.queued + 1
	item.player = player
	self.fqTail = self.fqTail + 1
	self.fq[self.fqTail] = item
end

-- Applies queued steps until FOLLOW_STEPS entries were applied.
function Session:followTick()
	local applied = 0
	while applied < FOLLOW_STEPS and self.fqHead <= self.fqTail do
		local item = self.fq[self.fqHead]
		self.fq[self.fqHead] = nil
		self.fqHead = self.fqHead + 1
		local f = self:folOf(item.player)
		f.queued = f.queued - 1
		applied = applied + (self:followStep(item.player, item) or 0)
	end
	if self.fqHead > self.fqTail then
		self.fq, self.fqHead, self.fqTail = {}, 1, 0
	end
end

-- One queued message. Returns the number of ledger entries applied (0 or 1).
function Session:followStep(player, item)
	local k = item.k
	if k == "buy" then
		return self:followBuy(player, item)
	elseif k == "pay" then
		return self:followPay(player, item)
	end
	local state = self:followedState(player)
	if not state then
		return 0
	end
	local f = self:folOf(player)
	local msg = item.msg
	if k == "lost" then
		self:followLost(player)
	elseif k == "hello" then
		if f.req then
			return 0 -- the open request's RES decides
		end
		if msg.n == state.n then
			if msg.head ~= Ledger.shortHead(state) then
				self:followLost(player, "rewritten", msg.n, 0)
			else
				f.trusted = true
			end
		else
			self:followLost(player) -- missed spins (or an account this client cannot place)
		end
	elseif k == "spin" or k == "gam" then
		return self:followRequest(player, state, f, item)
	elseif k == "res" then
		return self:followRes(player, state, f, msg)
	end
	return 0
end

-- A SPIN or GAM of a followed player.
function Session:followRequest(player, state, f, item)
	local msg, k = item.msg, item.k
	local g = k == "gam" and msg.g or 0
	if f.req then
		self:followLost(player) -- a new request before the RES
		return 0
	end
	if (k == "spin" and msg.n ~= state.n + 1) or (k == "gam" and (msg.n ~= state.n or msg.g ~= state.g + 1)) then
		self:followLost(player)
		return 0
	end
	if msg.head ~= Ledger.shortHead(state) then
		self:followLost(player, "rewritten", msg.n, g)
		return 0
	end
	f.trusted = true
	if msg.level ~= state.settings.L then
		self:followLost(player, "bad_entry", msg.n, g)
		return 0
	end
	if msg.level == 0 then
		local entry
		if k == "spin" then
			entry = { type = "S", n = msg.n, stake = msg.stake, A = 0, status = "ok", contribs = "" }
		else
			entry = { type = "G", n = msg.n, g = msg.g, A = 0, status = "ok", contribs = "" }
		end
		return self:followApply(player, state, entry, msg.n, g) and 1 or 0
	end
	f.req = item.live
	return 0
end

-- The RES of a followed level 1/2 request: rebuild the contributions from the kept WIT values.
function Session:followRes(player, state, f, msg)
	local req = f.req
	f.req = nil
	if not req or req.kind ~= msg.kind or req.n ~= msg.n or req.g ~= msg.g then
		self:followLost(player)
		return 0
	end
	local list = {}
	if msg.who ~= "-" then
		for i = 1, #msg.who, 4 do
			local tag = sub(msg.who, i, i + 3)
			local match
			for name, value in pairs(req.wits) do
				if sub(value, 1, 4) == tag then
					if match then
						match = false
						break
					end
					match = name
				end
			end
			if not match then
				self:followLost(player)
				return 0
			end
			list[#list + 1] = { name = match, value = req.wits[match], lot = Engine.lot(match, player, req.kind, req.n, req.g) }
		end
	end
	local entry = requestEntry({ kind = req.kind, n = req.n, g = req.g, stake = req.amount, A = req.A }, msg.status,
		Engine.contribs(list))
	local info = Ledger.apply(state, entry)
	if not info then
		self:followLost(player, "bad_entry", msg.n, msg.g)
		return 1
	end
	if Ledger.shortHead(state) ~= msg.head then
		self:followLost(player, "bad_res", msg.n, msg.g)
		return 1
	end
	self:followCommit(player, state, Ledger.encode(entry))
	return 1
end

-- A complete purchase: { text, buyId, head (64 hex before it), anchors }.
function Session:followBuy(player, item)
	local rec = self:followRecord(player)
	local state = self:followedState(player)
	if state and state.buyIds[item.buyId] then
		return 0 -- heard twice (the issuing officer)
	end
	local entry = Ledger.decode(item.text)
	if not entry then
		return 0
	end
	if item.anchors == 0 and item.head == Ledger.start(self.guild, player).head then
		-- Starting point 1: the account starts here.
		local start = Ledger.start(self.guild, player)
		local s = Ledger.copy(start)
		if not Ledger.apply(s, entry) then
			return 0
		end
		self:followStart(player, s, 1, start, { item.text })
		return 1
	end
	if not state then
		return 0
	end
	local f = self:folOf(player)
	if f.req then
		self:followLost(player)
		return 0
	end
	if item.head ~= state.head or item.anchors ~= state.anchors then
		self:followLost(player, "rewritten", state.n, 0)
		return 0
	end
	return self:followApply(player, state, entry, state.n, 0) and 1 or 0
end

-- A PAY from an officer: a step when it fits the followed state, else starting point 2.
function Session:followPay(player, item)
	local msg = item.msg
	local state = self:followedState(player)
	local f = self:folOf(player)
	if state and state.payIds[msg.payId] then
		return 0
	end
	if state and not f.req and msg.anchors == state.anchors + 1 then
		local entry = {
			type = "P", payId = msg.payId, officer = item.officer, amount = msg.amount, balanceAfter = msg.balanceAfter,
			time = msg.time,
		}
		local trial = Ledger.copy(state)
		if Ledger.apply(trial, entry) and trial.head == msg.head then
			f.state = trial
			self:followCommit(player, trial, Ledger.encode(entry))
			local rec = self:followRecord(player)
			if type(rec.entries) == "table" then
				rec.base, rec.entries = Ledger.snapshot(trial), {}
			end
			return 1
		end
	end
	-- Starting point 2: the key of the player's last purchase and the checkpoint key.
	local keys = self.store.keys and self.store.keys[self.guild]
	local k = type(keys) == "table" and keys[player]
	local b = type(k) == "table" and type(k.purchase) == "string" and Ledger.decode(k.purchase)
	local started = false
	if b and b.type == "B" then
		local s = Ledger.restore(self.guild, player, {
			head = msg.head, count = item.count or 0, anchors = msg.anchors, balance = msg.balanceAfter, n = msg.n,
			g = 0, pending = 0, purchase = k.purchase, buyIds = { b.buyId }, payIds = { msg.payId },
		})
		if s and s.settings and Ledger.checkpointKey(msg.n, s.K, s.line) == msg.ck then
			started = self:followStart(player, s, item.count)
		end
	end
	if not started and state then
		self:followLost(player)
	end
	return 0
end

-- PAYREQ heard from anyone: its count gives the count after the PAY. self.payreqs[reqId].
function Session:hearPayReq(sender, msg)
	local now = self.env.now()
	for id, r in pairs(self.payreqs) do
		if now - r.time > REQUEST_TIMEOUT * 3 then
			self.payreqs[id] = nil
			self.alertsIn[id] = nil
		end
	end
	if not self.payreqs[msg.reqId] then
		self.payreqs[msg.reqId] = { player = sender, count = msg.count, head = msg.head, officer = msg.officer, time = now }
	end
end

-- The view the UI and the payout check read: { n, balance, lost, count, hasEntries } or nil.
function Session:followed(player)
	local rec = self:followRecord(player)
	if not rec then
		return nil
	end
	return {
		n = rec.snap.n, balance = rec.snap.balance, lost = rec.lost == true, count = rec.count,
		hasEntries = type(rec.entries) == "table",
	}
end

-- Samples (docs/follow-spec.md section 2) ------------------------------------------------------
-- store.samples[guild][witness] = { commit, seen, rows, time, old = { commit, seen, rows, time } }

function Session:samples()
	return subtable(subtable(self.store, "samples"), self.guild)
end

local function randomBelow(env, n)
	return (tonumber(env.randomHex(8), 16) or 0) % n
end

function Session:sample(witness, row)
	local commit = self:liveCommit(witness)
	if not commit then
		return
	end
	local all = self:samples()
	local res = all[witness]
	if type(res) ~= "table" or type(res.rows) ~= "table" or type(res.seen) ~= "number" then
		res = nil
	end
	if not res or res.commit ~= commit then
		local old = res and res.seen > 0 and res or nil
		if old then
			old.old = nil
		end
		res = { commit = commit, seen = 0, rows = {}, time = floor(self.env.now()), old = old }
		all[witness] = res
	end
	res.seen = res.seen + 1
	if #res.rows < SAMPLE_ROWS then
		res.rows[#res.rows + 1] = row
	else
		local j = randomBelow(self.env, res.seen) + 1
		if j <= SAMPLE_ROWS then
			res.rows[j] = row
		end
	end
end

-- Checks the rows of one reservoir against the revealed secret; true when one differed.
function Session:checkRows(rows, S)
	local bad = false
	for _, row in ipairs(rows) do
		if type(row) == "table" and type(row.player) == "string" and (row.kind == "spin" or row.kind == "gam")
			and type(row.n) == "number" and type(row.g) == "number" and type(row.amount) == "number"
			and type(row.head) == "string" then
			local ok, value = pcall(Engine.witnessValue, S, row.player, row.kind, row.n, row.g, row.amount, row.head)
			if ok and value ~= row.value then
				bad = true
				self:addAlert(row.player, "bad_value", row.n, row.g)
			end
		end
	end
	return bad
end

-- A HELLO's reveal: the reservoir under the commit it hashes to is checked and dropped.
function Session:checkReveal(sender, reveal)
	if reveal == "-" then
		return
	end
	local all = self:samples()
	local res = all[sender]
	if type(res) ~= "table" then
		return
	end
	local commit = Engine.witnessCommit(reveal)
	local bad = false
	if type(res.old) == "table" and res.old.commit == commit then
		bad = type(res.old.rows) == "table" and self:checkRows(res.old.rows, reveal)
		res.old = nil
	end
	if res.commit == commit then
		bad = (type(res.rows) == "table" and self:checkRows(res.rows, reveal)) or bad
		all[sender] = type(res.old) == "table" and res.old or nil
	end
	if bad then
		event(self, "notice", { kind = "witness_cheat", name = sender })
	end
end

-- Alerts (docs/follow-spec.md section 4) -------------------------------------------------------
-- store.alerts[guild] = { { player, code, n, g, time }, … }, oldest first.

function Session:alertList()
	return subtable(subtable(self.store, "alerts"), self.guild)
end

-- Stores an own observation once per (player, code, n, g).
function Session:addAlert(player, code, n, g)
	local list = self:alertList()
	for _, a in ipairs(list) do
		if a.player == player and a.code == code and a.n == n and a.g == g then
			return
		end
	end
	list[#list + 1] = { player = player, code = code, n = n, g = g, time = floor(self.env.now()) }
	while #list > ALERT_KEEP do
		table.remove(list, 1)
	end
end

-- The own alerts about a player, newest first.
function Session:alerts(player)
	local out = {}
	local list = self:alertList()
	for i = #list, 1, -1 do
		local a = list[i]
		if a.player == player then
			out[#out + 1] = { player = a.player, code = a.code, n = a.n, g = a.g, time = a.time }
		end
	end
	return out
end

-- A PAYREQ of another player this client holds alerts for: up to 3 ALERT messages, newest first,
-- after a random delay of 0..3 s. The officer addressed collects its own alerts itself.
function Session:scheduleAlerts(sender, msg)
	if sender == self.me or msg.officer == self.me then
		return
	end
	local list = self:alerts(sender)
	if #list == 0 then
		return
	end
	local rows = {}
	for i = 1, math.min(ALERT_SEND, #list) do
		rows[i] = list[i]
	end
	local due = self.env.now() + randomBelow(self.env, ALERT_DELAY * 1000 + 1) / 1000
	self.alertOut[#self.alertOut + 1] = { reqId = msg.reqId, player = sender, due = due, rows = rows }
end

function Session:pumpAlerts()
	local env, now = self.env, self.env.now()
	for i = #self.alertOut, 1, -1 do
		local b = self.alertOut[i]
		if now >= b.due then
			if env.budget() >= SPIN_BUDGET then
				table.remove(self.alertOut, i)
				for _, a in ipairs(b.rows) do
					self:send("ALERT", { reqId = b.reqId, player = b.player, code = a.code, n = a.n, g = a.g, time = a.time })
				end
			elseif now - b.due > ALERT_GIVE_UP then
				table.remove(self.alertOut, i)
			end
		end
	end
end

-- An ALERT from another client, kept in memory per reqId of a heard PAYREQ for the officer's
-- report: self.alertsIn[reqId] = { { by, player, code, n, g, time }, … }.
function Session:hearAlert(sender, msg)
	local r = self.payreqs[msg.reqId]
	if sender == self.me or not r or r.player ~= msg.player then
		return
	end
	local list = self.alertsIn[msg.reqId]
	if not list then
		list = {}
		self.alertsIn[msg.reqId] = list
	end
	if #list >= ALERT_IN_MAX then
		return
	end
	for _, a in ipairs(list) do
		if a.by == sender and a.code == msg.code and a.n == msg.n and a.g == msg.g then
			return
		end
	end
	list[#list + 1] = { by = sender, player = msg.player, code = msg.code, n = msg.n, g = msg.g, time = msg.time }
end

-- The ALERT messages heard for a payout request, as Verify's `alerts` input takes them.
function Session:heardAlerts(reqId)
	local out = {}
	for i, a in ipairs(self.alertsIn[reqId] or {}) do
		out[i] = { by = a.by, player = a.player, code = a.code, n = a.n, g = a.g, time = a.time }
	end
	return out
end

-- At creation: alerts, samples and commits older than 14 days go.
function Session:cleanFollow()
	local now = self.env.now()
	local alerts, kept = self:alertList(), {}
	for _, a in ipairs(alerts) do
		if type(a) == "table" and type(a.time) == "number" and now - a.time < WITNESS_AGE and type(a.player) == "string"
			and type(a.code) == "string" and type(a.n) == "number" and type(a.g) == "number" then
			kept[#kept + 1] = a
		end
	end
	while #kept > ALERT_KEEP do
		table.remove(kept, 1)
	end
	self.store.alerts[self.guild] = kept
	local function fresh(r)
		return type(r) == "table" and type(r.time) == "number" and now - r.time < WITNESS_AGE
			and type(r.rows) == "table" and type(r.seen) == "number" and type(r.commit) == "string"
	end
	local samples = self:samples()
	for name, res in pairs(samples) do
		if type(res) == "table" and not fresh(res.old) then
			res.old = nil
		end
		if not fresh(res) then
			samples[name] = type(res) == "table" and res.old or nil
		end
	end
	local commits = self:commits()
	for name, c in pairs(commits) do
		if type(c) ~= "table" or type(c.time) ~= "number" or now - c.time >= WITNESS_AGE then
			commits[name] = nil
		end
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
		commit = Engine.witnessCommit(self:secret()),
		reveal = self:revealed(),
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
	self:settleRequest()
	self:pumpRes()
	self:pumpLog()
	self:verifyStep()
	self:osync()
	self:followTick()
	self:pumpAlerts()
	if not self.witPrune or now - self.witPrune >= TICKER_WIT_AGE then
		self.witPrune = now
		for key, at in pairs(self.witSent) do
			if now - at > 60 then
				self.witSent[key] = nil -- no RES came for that request
			end
		end
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
		if sender ~= self.me then
			self:checkReveal(sender, msg.reveal)
			self:commits()[sender] = { commit = msg.commit, time = env.now() }
			self:followQueue(sender, { k = "hello", msg = msg })
		end
		if not self.noticed and type(env.version) == "string" and newerVersion(msg.version, env.version) then
			self.noticed = true
			event(self, "notice", { kind = "update", version = msg.version, from = sender })
		end
	elseif kind == "SPIN" then
		self:alive(sender)
		self:hear(sender, msg.n, msg.head, { n = msg.n, g = 0, head = msg.head })
		self:followQueue(sender, { k = "spin", msg = msg, live = self:hearRequest(sender, msg, "spin") })
		self:onTickerSpin(sender, msg)
		self:answerRequest(sender, msg, "spin")
	elseif kind == "GAM" then
		self:alive(sender)
		self:hear(sender, msg.n, msg.head, { n = msg.n, g = msg.g, head = msg.head })
		self:followQueue(sender, { k = "gam", msg = msg, live = self:hearRequest(sender, msg, "gam") })
		self:answerRequest(sender, msg, "gam")
	elseif kind == "WIT" then
		self:alive(sender)
		self:collectWit(sender, msg)
		self:hearWit(sender, msg)
		self:onTickerWit(sender, msg)
	elseif kind == "RES" then
		self:alive(sender)
		if sender ~= self.me then
			self:markWitness(sender, msg)
			self:onTickerRes(sender, msg)
			self:followQueue(sender, { k = "res", msg = msg })
		end
	elseif kind == "PAYREQ" then
		self:alive(sender)
		self:hearPayReq(sender, msg)
		self:scheduleAlerts(sender, msg)
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
		-- PAY carries the full head; anchors keep the short one.
		self:storeAnchor(msg.player, { anchors = msg.anchors, head = sub(msg.head, 1, 32), time = msg.time, by = sender })
		self:markSeen(msg.player, msg.payId)
		local r = self.payreqs[msg.reqId]
		local count = r and r.player == msg.player and r.count + 1 or nil
		self:followQueue(msg.player, { k = "pay", msg = msg, officer = sender, count = count }, true)
		if msg.player == self.me then
			self:onPay(sender, msg)
		end
	elseif kind == "ALERT" then
		self:alive(sender)
		self:hearAlert(sender, msg)
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
-- Same shape as Solo (Game/Solo.lua), backed by the ledger. At level 1 and 2 spin() and gamble()
-- return a `wait` table and the result arrives as the `result` event (docs/witness-spec.md section 3).

-- Copies the account state into the public fields the slot window reads.
function Game:refresh()
	local s = self.session
	local state = s:hasAccount() and s.state or nil
	local settings = state and state.settings or Settings.defaults()
	self.settings = settings
	self.level = state and settings.L or 0
	self.tbl = state and state.tbl or Tables.get(settings.T)
	self.stakes = settings.E
	self.maxGamble = settings.G
	self.cap = settings.C
	self.balance = state and state.balance or 0
	-- After a void step at the last step the ledger still holds pending, but no step can follow.
	local open = state and not s.declined and state.g < settings.G
	self.pending = open and state.pending or 0
	local keep = false
	for _, v in ipairs(self.stakes) do
		if v == self.stake then keep = true end
	end
	if not keep then
		self.stake = self.stakes[1]
	end
end

function Game:state()
	if self.session.wreq then
		return "collecting"
	end
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
	if self.balance < self.stake and self:state() ~= "gamble" then
		return "no_funds"
	end
	local level = s.state.settings.L
	if level ~= 0 then
		local A, code = s:witnessesOnline(level, s.state.settings.W)
		if not A then
			return code
		end
	end
	return "ok"
end

-- Shared checks before a spin or gamble step: account, payout lock and an open request.
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
	if s.wreq then
		return nil, "collecting"
	end
	return true
end

function Game:waiting()
	local s = self.session
	local now = s.env.now()
	local interval = s.state.settings.L == 0 and SPIN_INTERVAL or WITNESS_INTERVAL
	return (s.lastAction and now - s.lastAction < interval) or s.env.budget() < SPIN_BUDGET
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
	local settings = s.state.settings
	if settings.L ~= 0 then
		local A
		A, code = s:witnessesOnline(settings.L, settings.W)
		if not A then
			return nil, code
		end
		if self:waiting() then
			return nil, "wait"
		end
		return s:startRequest({ kind = "spin", n = s.state.n + 1, g = 0, stake = stake, amount = stake, A = A })
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
	return spinResult(s.state, entry, info)
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
	if self.session.wreq then
		return nil, "collecting"
	end
	if self:state() ~= "gamble" then
		return nil, "no_gamble"
	end
	local ok, code = self:ready()
	if not ok then
		return nil, code
	end
	local s = self.session
	local state = s.state
	local amount = state.pending
	local settings = state.settings
	if settings.L ~= 0 then
		local A
		A, code = s:witnessesOnline(settings.L, settings.W)
		if not A then
			return nil, code
		end
		if self:waiting() then
			return nil, "wait"
		end
		return s:startRequest({ kind = "gam", n = state.n, g = state.g + 1, amount = amount, A = A })
	end
	if self:waiting() then
		return nil, "wait"
	end
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
	return gambleResult(entry, amount, info)
end

function Game:info()
	return ns.Solo.info(self.tbl, self.stake, self.cap, self.maxGamble)
end
