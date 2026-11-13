local t, ns = ...
local Guild, Proto, Ledger, Sha256 = ns.Guild, ns.Proto, ns.Ledger, ns.Sha256

-- A fake guild: every sent message is delivered to every session, the sender included, in the
-- order it was sent. The clock only moves when a test moves it.

local GUILD = "Test Guild"
local LINE = "GSLOTS1;L=0;E=10,50,100;G=3"

local function newWorld()
	return { now = 1000, queue = {}, log = {}, sessions = {}, officers = { Olga = true }, line = LINE, budget = 10 }
end

local function addSession(w, name, opts)
	opts = opts or {}
	local counter = 0
	local s = {}
	s.events = {}
	s.env = {
		guild = GUILD,
		me = name,
		now = function() return w.now end,
		randomHex = function(n)
			counter = counter + 1
			local out = ""
			local i = 0
			while #out < n do
				i = i + 1
				out = out .. Sha256.hex(name .. "|" .. counter .. "|" .. i)
			end
			return out:sub(1, n)
		end,
		send = function(text)
			if w.refuse then
				return nil, "full"
			end
			w.queue[#w.queue + 1] = { name, text }
			w.log[#w.log + 1] = { sender = name, text = text, msg = Proto.decode(text) }
			return true
		end,
		budget = function() return w.budget end,
		isOfficer = function(n) return w.officers[n] == true end,
		line = function()
			if opts.line ~= nil then
				return opts.line or nil
			end
			return w.line
		end,
		store = opts.store or {},
		version = opts.version or "0.3.0",
		onEvent = function(ev, data) s.events[#s.events + 1] = { ev, data } end,
		allowSelf = opts.allowSelf,
		stepBudget = opts.stepBudget,
	}
	s.session = Guild.new(s.env)
	w.sessions[#w.sessions + 1] = s.session
	return s
end

-- w.drop(text) -> true loses a message on the way (it still shows in w.log).
local function flush(w)
	while #w.queue > 0 do
		local m = table.remove(w.queue, 1)
		if not (w.drop and w.drop(m[2])) then
			for _, session in ipairs(w.sessions) do
				session:onMessage(m[1], m[2])
			end
		end
	end
end

-- Deliver a hand-made message to every session.
local function inject(w, sender, msgType, fields)
	local text = assert(Proto.encode(msgType, fields))
	w.queue[#w.queue + 1] = { sender, text }
	flush(w)
end

local function sentTypes(w, from)
	local out = {}
	for _, e in ipairs(w.log) do
		if (not from or e.sender == from) and e.msg then
			out[#out + 1] = e.msg.type
		end
	end
	return table.concat(out, ",")
end

local function find(list, buyId, role)
	for _, p in ipairs(list) do
		if p.buyId == buyId and (not role or p.role == role) then
			return p
		end
	end
end

local function account(s, player)
	return s.env.store.accounts and s.env.store.accounts[GUILD] and s.env.store.accounts[GUILD][player]
end

-- A world with officer Olga and player Pia, Pia already holding `tokens`.
local function funded(tokens, line)
	local w = newWorld()
	w.line = line or w.line
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia")
	local buyId = assert(o.session:grant("Pia", tokens or 1000))
	flush(w)
	return w, o, p, buyId
end

-- Purchase ------------------------------------------------------------------------------------

t.test("a full purchase credits the player and ends done on both sides", function()
	local w = newWorld()
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia")
	local buyId, code = o.session:grant("Pia", 500)
	t.ok(buyId, "grant: " .. tostring(code))
	t.eq(#buyId, 16, "buyId length")
	t.eq(find(o.session:purchases(), buyId).status, "wait_nonce", "officer waits")
	flush(w)
	t.eq(sentTypes(w), "BUY1,BUY2,BUY3", "messages")
	local op = find(o.session:purchases(), buyId)
	t.eq(op.role, "officer", "officer role")
	t.eq(op.status, "done", "officer done")
	t.eq(op.player, "Pia", "player")
	t.eq(op.officer, "Olga", "officer")
	t.eq(op.tokens, 500, "tokens")
	t.eq(op.time, 1000, "time")
	local pp = find(p.session:purchases(), buyId)
	t.eq(pp.role, "player", "player role")
	t.eq(pp.status, "done", "player done")
	t.eq(p.session:game().balance, 500, "balance")
	t.eq(p.session:game():status(), "ok", "status")
	local acc = account(p, "Pia")
	t.eq(#acc.entries, 1, "one stored entry")
	local e = Ledger.decode(acc.entries[1])
	t.eq(e.type, "B", "purchase entry")
	t.eq(e.officer, "Olga", "entry officer")
	t.eq(e.line, LINE, "entry line")
	t.eq(e.time, 1000, "entry time")
	local seenAccount = false
	for _, ev in ipairs(p.events) do
		if ev[1] == "account" then seenAccount = true end
	end
	t.ok(seenAccount, "account event")
	-- Both sides finished: the records survive in the store.
	t.ok(find(o.env.store.purchases, buyId), "officer stored")
	t.ok(find(p.env.store.purchases, buyId), "player stored")
end)

t.test("grant refusals", function()
	local w = newWorld()
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia")
	local _, code = p.session:grant("Olga", 10)
	t.eq(code, "not_officer", "player cannot grant")
	w.line = nil
	_, code = o.session:grant("Pia", 10)
	t.eq(code, "no_settings", "no line")
	w.line = "GSLOTS1;L=7"
	_, code = o.session:grant("Pia", 10)
	t.eq(code, "no_settings", "line does not parse")
	w.line = LINE
	_, code = o.session:grant("Pia", 0)
	t.eq(code, "bad_tokens", "zero")
	_, code = o.session:grant("Pia", 1.5)
	t.eq(code, "bad_tokens", "fraction")
	_, code = o.session:grant("Pia", 1000000001)
	t.eq(code, "bad_tokens", "too many")
	_, code = o.session:grant("Pi|a", 10)
	t.eq(code, "bad_player", "bad name")
	_, code = o.session:grant("Olga", 10)
	t.eq(code, "bad_player", "self without allowSelf")
	w.refuse = true
	_, code = o.session:grant("Pia", 10)
	t.eq(code, "send", "queue refused")
	t.eq(#o.session:purchases(), 0, "nothing recorded")
	w.refuse = false
	t.ok(o.session:grant("Pia", 10), "first grant")
	_, code = o.session:grant("Pia", 10)
	t.eq(code, "busy", "second grant while open")
	t.ok(o.session:grant("Paul", 10), "another player is fine")
end)

t.test("officer timeout: no BUY2 within 30 s, the seed is never sent", function()
	local w = newWorld()
	local o = addSession(w, "Olga")
	local buyId = assert(o.session:grant("Pia", 100))
	flush(w)
	w.now = w.now + 29
	o.session:tick()
	t.eq(find(o.session:purchases(), buyId).status, "wait_nonce", "still waiting at 29 s")
	w.now = w.now + 1
	o.session:tick()
	t.eq(find(o.session:purchases(), buyId).status, "timeout", "timeout at 30 s")
	t.eq(sentTypes(w, "Olga"):find("BUY3"), nil, "no BUY3")
	-- A late BUY2 changes nothing.
	inject(w, "Pia", "BUY2", { buyId = buyId, nonce = string.rep("1", 32), head = string.rep("2", 64), anchors = 0 })
	t.eq(find(o.session:purchases(), buyId).status, "timeout", "late BUY2 ignored")
	t.eq(sentTypes(w, "Olga"):find("BUY3"), nil, "still no BUY3")
end)

-- A BUY1 from an officer without a session, so the test controls BUY3.
local SEED = string.rep("5", 32)
local function buy1(w, buyId, opts)
	opts = opts or {}
	inject(w, opts.from or "Olga", "BUY1", {
		buyId = buyId, player = opts.player or "Pia", tokens = opts.tokens or 300,
		commit = ns.Engine.commit(SEED), time = 1234, lineHash = Proto.lineHash(opts.line or LINE),
	})
end

t.test("player timeout: no BUY3 within 30 s, nothing credited", function()
	local w = newWorld()
	local p = addSession(w, "Pia")
	local buyId = "00000000000000aa"
	buy1(w, buyId)
	t.eq(sentTypes(w, "Pia"), "BUY2", "nonce sent")
	t.eq(find(p.session:purchases(), buyId).status, "wait_seed", "waiting")
	w.now = w.now + 30
	p.session:tick()
	t.eq(find(p.session:purchases(), buyId).status, "timeout", "timeout")
	inject(w, "Olga", "BUY3", { buyId = buyId, seed = SEED })
	t.eq(find(p.session:purchases(), buyId).status, "timeout", "late seed ignored")
	t.eq(p.session:game().balance, 0, "nothing credited")
	t.eq(account(p, "Pia"), nil, "no account stored")
end)

t.test("BUY1 from a non-officer is ignored", function()
	local w = newWorld()
	local p = addSession(w, "Pia")
	buy1(w, "00000000000000bb", { from = "Mallory" })
	t.eq(#w.log, 0, "no reply")
	t.eq(#p.session:purchases(), 0, "no purchase")
	t.eq(#p.session:online(), 0, "not even a sign of life")
end)

t.test("a wrong seed in BUY3 fails the purchase with bad_commit", function()
	local w = newWorld()
	w.officers.Otto = true
	local p = addSession(w, "Pia")
	local buyId = "00000000000000cc"
	buy1(w, buyId)
	-- A BUY3 from another officer is not for this purchase.
	inject(w, "Otto", "BUY3", { buyId = buyId, seed = SEED })
	t.eq(find(p.session:purchases(), buyId).status, "wait_seed", "other officer ignored")
	inject(w, "Olga", "BUY3", { buyId = buyId, seed = string.rep("6", 32) })
	local rec = find(p.session:purchases(), buyId)
	t.eq(rec.status, "failed", "failed")
	t.eq(rec.code, "bad_commit", "code")
	t.eq(p.session:game().balance, 0, "nothing credited")
	t.eq(account(p, "Pia"), nil, "nothing stored")
	-- The same BUY1 again is a buyId already seen.
	buy1(w, buyId)
	t.eq(sentTypes(w, "Pia"), "BUY2", "no second BUY2")
end)

t.test("differing settings lines fail on the player side without a reply", function()
	local w = newWorld()
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia", { line = "GSLOTS1;L=0;E=10,50" })
	local buyId = assert(o.session:grant("Pia", 100))
	flush(w)
	t.eq(sentTypes(w), "BUY1", "no BUY2")
	local rec = find(p.session:purchases(), buyId)
	t.eq(rec.status, "failed", "failed")
	t.eq(rec.code, "settings_differ", "code")
	-- Without any line on the player side.
	local w2 = newWorld()
	local o2 = addSession(w2, "Olga")
	local p2 = addSession(w2, "Pia", { line = false })
	local id2 = assert(o2.session:grant("Pia", 100))
	flush(w2)
	t.eq(find(p2.session:purchases(), id2).code, "no_settings", "no line")
end)

t.test("a player with an open purchase refuses a second one as busy", function()
	local w = newWorld()
	local p = addSession(w, "Pia")
	buy1(w, "00000000000000d1")
	buy1(w, "00000000000000d2")
	local rec = find(p.session:purchases(), "00000000000000d2")
	t.eq(rec.status, "failed", "second failed")
	t.eq(rec.code, "busy", "busy")
	t.eq(find(p.session:purchases(), "00000000000000d1").status, "wait_seed", "first still open")
end)

t.test("self grant works over the echo only with allowSelf", function()
	local w = newWorld()
	local o = addSession(w, "Olga", { allowSelf = true })
	local buyId = assert(o.session:grant("Olga", 250))
	flush(w)
	t.eq(sentTypes(w), "BUY1,BUY2,BUY3", "all three steps from one client")
	t.eq(find(o.session:purchases(), buyId, "officer").status, "done", "officer side")
	t.eq(find(o.session:purchases(), buyId, "player").status, "done", "player side")
	t.eq(o.session:game().balance, 250, "balance")
	t.eq(#o.session:purchases(), 2, "two records")
end)

t.test("purchases are listed newest first", function()
	local w, o, p = funded(100)
	w.now = w.now + 10
	assert(o.session:grant("Pia", 200))
	flush(w)
	local list = p.session:purchases()
	t.eq(list[1].tokens, 200, "newest first")
	t.eq(list[2].tokens, 100, "older second")
	t.eq(p.session:game().balance, 300, "both credited")
end)

-- Spins -----------------------------------------------------------------------------------------

t.test("without a purchase the game has no account", function()
	local w = newWorld()
	local p = addSession(w, "Pia")
	local g = p.session:game()
	t.eq(g.balance, 0, "balance")
	t.eq(g.stakes[1], 10, "default stakes")
	t.eq(g.stake, 10, "stake")
	t.eq(g:status(), "no_account", "status")
	local _, code = g:spin()
	t.eq(code, "no_account", "spin")
	t.eq(g:state(), "idle", "state")
	t.ok(g:info().rtp > 0, "info")
end)

t.test("spins and gamble steps replay from the store to the same balance", function()
	local w, o, p = funded(1000)
	local g = p.session:game()
	local spins, steps, takes = 0, 0, 0
	for _ = 1, 80 do
		w.now = w.now + 2
		if g:state() == "gamble" then
			if steps % 3 == 2 and takes == 0 then
				local r = assert(g:take())
				t.eq(r.kind, "take", "take")
				t.eq(g.pending, 0, "pending 0 after take")
				t.eq(g:state(), "idle", "idle after take")
				takes = takes + 1
			else
				local before = g.pending
				local r, code = g:gamble()
				t.ok(r, "gamble: " .. tostring(code))
				t.eq(r.kind, "gamble", "kind")
				t.eq(r.amount, before, "amount at risk")
				t.ok(r.step >= 1, "step")
				t.eq(r.balance, g.balance, "balance in result")
				steps = steps + 1
			end
		elseif g.balance >= g.stake then
			local r, code = g:spin()
			t.ok(r, "spin: " .. tostring(code))
			spins = spins + 1
			t.eq(r.n, spins, "spin number")
			t.eq(r.kind, "spin", "kind")
			t.eq(#r.window, 3, "window")
			t.eq(r.balance, g.balance, "balance in result")
		end
		flush(w)
	end
	t.ok(spins > 10, "spins made")
	t.ok(steps > 0, "gamble steps made")
	t.ok(takes > 0, "a take made")
	local acc = account(p, "Pia")
	t.eq(#acc.entries, 1 + spins + steps, "one entry per purchase, spin and step")
	local state = Ledger.replay(GUILD, "Pia", acc.entries)
	t.ok(state, "replays")
	t.eq(state.balance, g.balance, "same balance")
	t.eq(state.n, spins, "same spin number")
	-- The officer heard the SPIN/GAM messages.
	local heard = o.session:lastSpin("Pia")
	t.eq(heard.n, spins, "officer heard the last spin")
	t.eq(o.env.store.heard[GUILD].Pia.n, spins, "officer stored it")
	t.eq(p.env.store.heard, nil, "a player stores nothing heard")
	t.ok(p.session:lastSpin("Pia"), "the player still remembers in memory")
end)

local LINE_T2 = "GSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T2"

t.test("a T2 account plays rounds that replay to the same balance", function()
	local w, _, p = funded(1000, LINE_T2)
	local g = p.session:game()
	t.eq(g.tbl.id, "T2", "table from the purchase")
	t.eq(g:info().kind, "lines", "info kind")
	for _ = 1, 60 do
		w.now = w.now + 2
		if g.balance < g.stake then break end
		local r, code = g:spin()
		t.ok(r, "spin: " .. tostring(code))
		t.eq(r.kind, "spin", "kind")
		t.eq(r.round.kind, "lines", "round")
		t.eq(r.round.n, r.n, "round number")
		t.eq(r.win, r.round.win, "win")
		t.eq(r.balance, g.balance, "balance")
		t.eq(r.canGamble, r.pending > 0, "gamble flag")
		t.eq(r.stops, nil, "no T1 stops")
		t.eq(r.symbols, nil, "no T1 symbols")
		flush(w)
		if g:state() == "gamble" then g:take() end
	end
	local state = Ledger.replay(GUILD, "Pia", account(p, "Pia").entries)
	t.eq(state.balance, g.balance, "replayed balance")
end)

t.test("SPIN carries the short head before the entry", function()
	local w, _, p = funded(1000)
	local g = p.session:game()
	local before = Ledger.shortHead(Ledger.replay(GUILD, "Pia", account(p, "Pia").entries))
	assert(g:spin())
	local last = w.log[#w.log].msg
	t.eq(last.type, "SPIN", "type")
	t.eq(last.head, before, "head before")
	t.eq(last.level, 0, "level")
	t.eq(last.A, 0, "A")
	t.eq(last.stake, 10, "stake")
end)

t.test("spin interval, queue budget and a refused send", function()
	local w, _, p = funded(1000)
	local g = p.session:game()
	assert(g:spin())
	local _, code = g:spin()
	t.eq(code, "wait", "at once")
	w.now = w.now + 1.4
	_, code = g:spin()
	t.eq(code, "wait", "after 1.4 s")
	w.now = w.now + 0.1
	w.budget = 2
	_, code = g:spin()
	t.eq(code, "wait", "budget below 3")
	w.budget = 3
	w.refuse = true
	local entries = #account(p, "Pia").entries
	local balance = g.balance
	_, code = g:spin()
	t.eq(code, "send", "refused")
	t.eq(#account(p, "Pia").entries, entries, "no entry")
	t.eq(g.balance, balance, "balance unchanged")
	w.refuse = false
	local r = assert(g:spin())
	t.eq(r.n, 2, "spin number did not advance on refusal")
end)

t.test("no_funds and setStake", function()
	local w, _, p = funded(30)
	local g = p.session:game()
	t.eq(g:setStake(50), true, "set 50")
	t.eq(g:status(), "no_funds", "status")
	local _, code = g:spin()
	t.eq(code, "no_funds", "spin")
	local _, c2 = g:setStake(7)
	t.eq(c2, "bad_stake", "not allowed")
	t.eq(w.log[#w.log].msg.type, "BUY3", "nothing sent")
end)

-- Witnesses (docs/witness-spec.md) ------------------------------------------------------------------

local Engine = ns.Engine
local LINE_W1 = "GSLOTS1;L=1;W=2;R=1;E=10,50,100;G=3"
local ZERO_HEAD = string.rep("0", 32)

-- Officer Olga, player Pia with 1000 tokens bought under `line`, plus one session per name in
-- `names`. Everyone has sent a HELLO, so every session sees every other one online.
local function witnessWorld(line, names, opts)
	opts = opts or {}
	local w = newWorld()
	w.line = line
	for name in pairs(opts.officers or {}) do
		w.officers[name] = true
	end
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia")
	local others = {}
	for _, name in ipairs(names or {}) do
		others[name] = addSession(w, name)
	end
	assert(o.session:grant("Pia", opts.tokens or 1000))
	flush(w)
	for _, session in ipairs(w.sessions) do
		session:tick()
	end
	flush(w)
	return w, o, p, others
end

-- Moves the clock to the end of the window and lets every session tick once.
local function settle(w, seconds)
	w.now = w.now + (seconds or 1.5)
	for _, session in ipairs(w.sessions) do
		session:tick()
	end
	flush(w)
end

local function sentOf(w, msgType, from)
	local out = {}
	for _, e in ipairs(w.log) do
		if e.msg and e.msg.type == msgType and (not from or e.sender == from) then
			out[#out + 1] = e
		end
	end
	return out
end

local function lastEntry(s)
	local entries = account(s, "Pia").entries
	return Ledger.decode(entries[#entries])
end

local function events(s, name)
	local out = {}
	for _, ev in ipairs(s.events) do
		if ev[1] == name then
			out[#out + 1] = ev[2]
		end
	end
	return out
end

local function groups(who)
	local out = {}
	if who ~= "-" then
		for i = 1, #who, 4 do
			out[#out + 1] = who:sub(i, i + 3)
		end
	end
	return out
end

t.test("a level 1 spin collects three witnesses and settles at the end of the window", function()
	local w, o, p, others = witnessWorld(LINE_W1, { "Tom", "Uma" })
	local g = p.session:game()
	t.eq(g.level, 1, "game.level")
	t.eq(g:status(), "ok", "status")
	local head = Ledger.shortHead(Ledger.replay(GUILD, "Pia", account(p, "Pia").entries))
	local r, code = g:spin()
	t.ok(r, "spin: " .. tostring(code))
	t.eq(r.kind, "wait", "wait")
	t.eq(r.what, "spin", "what")
	t.eq(r.n, 1, "n")
	t.eq(r.g, 0, "g")
	t.eq(r.due, w.now + 1.5, "due")
	t.eq(g:state(), "collecting", "collecting")
	local _, c2 = g:spin()
	t.eq(c2, "collecting", "a second spin waits")
	local _, c3 = g:setStake(50)
	t.eq(c3, "busy", "no stake change while collecting")
	local rec = p.env.store.open[GUILD].Pia
	t.eq(rec.kind, "spin", "open kind")
	t.eq(rec.n, 1, "open n")
	t.eq(rec.g, 0, "open g")
	t.eq(rec.stake, 10, "open stake")
	t.eq(rec.amount, 10, "open amount")
	t.eq(rec.A, 3, "A counts Olga, Tom and Uma")
	t.eq(rec.head, head, "head before")
	local spin = sentOf(w, "SPIN")[1].msg
	t.eq(spin.level, 1, "SPIN level")
	t.eq(spin.A, 3, "SPIN A")
	t.eq(#account(p, "Pia").entries, 1, "nothing written yet")
	flush(w)
	local wits = sentOf(w, "WIT")
	t.eq(#wits, 3, "three witnesses answered")
	local values = {}
	for _, e in ipairs(wits) do
		t.eq(e.msg.player, "Pia", "player")
		t.eq(e.msg.kind, "spin", "kind")
		t.eq(e.msg.n, 1, "n")
		t.eq(e.msg.g, 0, "g")
		values[e.sender] = e.msg.value
	end
	local S = others.Tom.env.store.secret.S
	t.eq(#S, 32, "secret")
	t.eq(values.Tom, Engine.witnessValue(S, "Pia", "spin", 1, 0, 10, head), "Tom's value")
	t.eq(#events(p, "result"), 0, "no result inside the window")
	settle(w, 1.4)
	t.eq(#events(p, "result"), 0, "no result at 1.4 s")
	settle(w, 0.1)
	local results = events(p, "result")
	t.eq(#results, 1, "one result")
	local res = results[1]
	t.eq(res.kind, "spin", "result kind")
	t.eq(res.n, 1, "result n")
	t.eq(#res.window, 3, "T1 window")
	t.eq(res.balance, g.balance, "balance")
	t.eq(g:state() ~= "collecting", true, "not collecting")
	t.eq(p.env.store.open[GUILD].Pia, nil, "open record gone")
	local e = lastEntry(p)
	t.eq(e.type, "S", "entry")
	t.eq(e.status, "ok", "status ok")
	t.eq(e.A, 3, "entry A")
	t.eq(e.contribs, "Olga:" .. values.Olga .. ",Tom:" .. values.Tom .. ",Uma:" .. values.Uma, "contribs")
	local state = Ledger.replay(GUILD, "Pia", account(p, "Pia").entries)
	t.ok(state, "replays")
	t.eq(state.balance, g.balance, "replayed balance")
	local resMsg = sentOf(w, "RES", "Pia")[1].msg
	t.eq(resMsg.status, "ok", "RES ok")
	t.eq(resMsg.who, values.Olga:sub(1, 4) .. values.Tom:sub(1, 4) .. values.Uma:sub(1, 4), "who")
	t.eq(resMsg.head, Ledger.shortHead(state), "RES head after")
	local rows = others.Tom.env.store.witness[GUILD]
	t.eq(#rows, 1, "one witness row")
	t.eq(rows[1].player, "Pia", "row player")
	t.eq(rows[1].res, "in", "marked in")
	t.eq(o.env.store.witness[GUILD][1].res, "in", "Olga marked in")
	t.eq(p.env.store.witness, nil, "the player answers nothing itself")
end)

t.test("a void spin: fewer than W answers in time", function()
	local w, _, p, others = witnessWorld("GSLOTS1;L=1;W=3;R=1;E=10,50,100;G=3", { "Tom", "Uma" })
	local g = p.session:game()
	local balance = g.balance
	w.drop = function(text)
		local m = Proto.decode(text)
		return m and m.type == "WIT" and m.value == (others.Uma.env.store.witness
			and others.Uma.env.store.witness[GUILD] and others.Uma.env.store.witness[GUILD][1]
			and others.Uma.env.store.witness[GUILD][1].value)
	end
	assert(g:spin())
	flush(w)
	w.drop = nil
	settle(w)
	local res = events(p, "result")[1]
	t.eq(res.kind, "void", "void")
	t.eq(res.what, "spin", "what")
	t.eq(res.n, 1, "n")
	t.eq(res.need, 3, "need")
	t.eq(res.got, 2, "got")
	t.eq(res.balance, balance, "stake kept")
	t.eq(g.balance, balance, "game balance")
	local e = lastEntry(p)
	t.eq(e.status, "void", "void entry")
	t.eq(#Engine.parseContribs(e.contribs), 2, "the two that arrived")
	local resMsg = sentOf(w, "RES", "Pia")[1].msg
	t.eq(resMsg.status, "void", "RES void")
	t.eq(#groups(resMsg.who), 2, "two tags")
	t.eq(others.Tom.env.store.witness[GUILD][1].res, "void_in", "Tom void_in")
	t.eq(others.Uma.env.store.witness[GUILD][1].res, "void_out", "Uma void_out")
	t.eq(Ledger.replay(GUILD, "Pia", account(p, "Pia").entries).balance, balance, "replays")
	-- The next spin goes on with the next number.
	w.now = w.now + 1
	local r = assert(g:spin())
	t.eq(r.n, 2, "next number")
end)

t.test("few_players: fewer than W other addon users online", function()
	local w, _, p = witnessWorld(LINE_W1, {})
	local g = p.session:game()
	t.eq(g:status(), "few_players", "only Olga")
	local _, code = g:spin()
	t.eq(code, "few_players", "spin refused")
	t.eq(#sentOf(w, "SPIN"), 0, "nothing sent")
	local tom = addSession(w, "Tom")
	tom.session:tick()
	flush(w)
	t.eq(g:status(), "ok", "Tom came online")
end)

t.test("the lottery: with more clients than Z only the drawn ones answer", function()
	local names = {}
	for i = 1, 11 do
		names[i] = "W" .. i
	end
	-- W = 1, Z = 5; A = 12 (Olga and 11 more).
	local w, _, p = witnessWorld("GSLOTS1;L=1;W=1;R=1;E=10,50,100;G=3", names)
	local g = p.session:game()
	local r = assert(g:spin())
	flush(w)
	local rec = p.env.store.open[GUILD].Pia
	t.eq(rec.A, 12, "A")
	local answered = {}
	for _, e in ipairs(sentOf(w, "WIT")) do
		answered[e.sender] = true
	end
	local expected = 0
	for _, name in ipairs({ "Olga", unpack(names) }) do
		local drawn = Engine.drawn(Engine.lot(name, "Pia", "spin", 1, 0), 12, 5)
		t.eq(answered[name] == true, drawn, "answer of " .. name .. " follows the lot")
		if drawn then expected = expected + 1 end
	end
	t.ok(expected < 12, "not everyone was drawn")
	settle(w)
	local e = lastEntry(p)
	t.eq(#Engine.parseContribs(e.contribs), math.min(expected, 8), "contributions")
	t.eq(e.status, expected >= 1 and "ok" or "void", "status")
	t.ok(Ledger.replay(GUILD, "Pia", account(p, "Pia").entries), "replays")
	t.ok(r, "spin")
	-- A witness ignores an A that is off by more than double or half its own count.
	local before = #sentOf(w, "WIT")
	w.now = w.now + 5
	for _, A in ipairs({ 5, 25 }) do
		inject(w, "Pia", "SPIN", { n = 50, stake = 10, level = 1, head = ZERO_HEAD, A = A })
	end
	t.eq(#sentOf(w, "WIT"), before, "no answers to a wrong A")
end)

t.test("at most 8 contributions count; the witness left out is marked out", function()
	local names = {}
	for i = 1, 8 do
		names[i] = "W" .. i
	end
	-- W = 3, Z = 9; A = 9 (Olga and 8 more): everyone is drawn, nine answer.
	local w, o, p, others = witnessWorld("GSLOTS1;L=1;W=3;R=1;E=10,50,100;G=3", names)
	local g = p.session:game()
	assert(g:spin())
	flush(w)
	t.eq(#sentOf(w, "WIT"), 9, "nine answers")
	settle(w)
	local e = lastEntry(p)
	t.eq(e.status, "ok", "ok")
	local list = Engine.parseContribs(e.contribs)
	t.eq(#list, 8, "eight kept")
	local inCount, out = 0, 0
	local all = { o }
	for _, name in ipairs(names) do
		all[#all + 1] = others[name]
	end
	for _, s in ipairs(all) do
		local res = s.env.store.witness[GUILD][1].res
		if res == "in" then inCount = inCount + 1 elseif res == "out" then out = out + 1 end
	end
	t.eq(inCount, 8, "eight in")
	t.eq(out, 1, "one out")
end)

t.test("witness messages never raise, with a request open on every side", function()
	local w, o, p, others = witnessWorld(LINE_W1, { "Tom" })
	local g = p.session:game()
	assert(g:spin())
	flush(w)
	settle(w)
	w.now = w.now + 2
	assert(g:spin())
	local samples = {}
	for _, e in ipairs(w.log) do
		samples[#samples + 1] = e.text
	end
	flush(w)
	local x = 12345
	local alphabet = "1|WITRESspingamokvoid-0123456789abcdef\0"
	local sessions = { o.session, p.session, others.Tom.session }
	for i = 1, 1500 do
		x = (x * 1103515245 + 12345) % 2147483648
		local base = samples[x % #samples + 1]
		local k = x % #base + 1
		local c = (x % 37) + 1
		local text = base:sub(1, k - 1) .. alphabet:sub(c, c) .. base:sub(k + 1)
		for _, s in ipairs(sessions) do
			local ok, err = pcall(s.onMessage, s, ({ "Olga", "Pia", "Tom", "Zed" })[i % 4 + 1], text)
			t.ok(ok, "raised: " .. tostring(err))
		end
		if i % 100 == 0 then
			w.now = w.now + 0.7
			for _, s in ipairs(sessions) do
				t.ok(pcall(s.tick, s), "tick")
			end
			w.queue = {}
		end
	end
	t.ok(Ledger.replay(GUILD, "Pia", account(p, "Pia").entries), "account still replays")
end)

local LINE_W2 = "GSLOTS1;L=2;R=1;E=10,50,100;G=3"

t.test("level 2: only officers answer, one is enough", function()
	local w, o, p, others = witnessWorld(LINE_W2, { "Tom" })
	local g = p.session:game()
	t.eq(g.level, 2, "level")
	t.eq(g:status(), "ok", "Olga is online")
	local r = assert(g:spin())
	t.eq(r.kind, "wait", "wait")
	t.eq(p.env.store.open[GUILD].Pia.A, 0, "A is 0 at level 2")
	t.eq(sentOf(w, "SPIN")[1].msg.level, 2, "SPIN level 2")
	flush(w)
	local wits = sentOf(w, "WIT")
	t.eq(#wits, 1, "one answer")
	t.eq(wits[1].sender, "Olga", "from the officer")
	t.eq(others.Tom.env.store.witness, nil, "Tom is no officer")
	-- A forged WIT from a non-officer does not count.
	inject(w, "Tom", "WIT", { player = "Pia", kind = "spin", n = 1, g = 0, value = string.rep("e", 16) })
	settle(w)
	local e = lastEntry(p)
	t.eq(e.status, "ok", "ok")
	t.eq(e.A, 0, "entry A")
	t.eq(e.contribs, "Olga:" .. wits[1].msg.value, "only Olga")
	t.eq(events(p, "result")[1].kind, "spin", "result")
	t.eq(o.env.store.witness[GUILD][1].res, "in", "marked")
end)

t.test("level 2 without an officer online: no_officer", function()
	local w = newWorld()
	w.line = LINE_W2
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia")
	local tom = addSession(w, "Tom")
	assert(o.session:grant("Pia", 1000))
	flush(w)
	-- Olga logs off before anyone heard a HELLO from her.
	for i, s in ipairs(w.sessions) do
		if s == o.session then table.remove(w.sessions, i) break end
	end
	w.now = w.now + 400
	p.session:tick()
	tom.session:tick()
	flush(w)
	local g = p.session:game()
	t.eq(g:status(), "no_officer", "status")
	local _, code = g:spin()
	t.eq(code, "no_officer", "spin refused")
	-- An officer who is the player does not count either.
	w.officers.Pia = true
	t.eq(g:status(), "no_officer", "the own name is no witness")
end)

t.test("a repeated SPIN: same terms get the same value, other terms get no answer", function()
	local w, _, _, others = witnessWorld(LINE_W1, { "Tom", "Uma" })
	local tom = others.Tom
	local function answers()
		local c = 0
		for _, e in ipairs(sentOf(w, "WIT", "Tom")) do c = c + 1 end
		return c
	end
	-- Pia's client is replaced by hand-made messages.
	inject(w, "Pia", "SPIN", { n = 9, stake = 10, level = 1, head = ZERO_HEAD, A = 3 })
	t.eq(answers(), 1, "first answer")
	local value = sentOf(w, "WIT", "Tom")[1].msg.value
	w.now = w.now + 1
	inject(w, "Pia", "SPIN", { n = 9, stake = 10, level = 1, head = ZERO_HEAD, A = 3 })
	t.eq(answers(), 2, "same terms answered again")
	t.eq(sentOf(w, "WIT", "Tom")[2].msg.value, value, "with the same value")
	w.now = w.now + 1
	inject(w, "Pia", "SPIN", { n = 9, stake = 50, level = 1, head = ZERO_HEAD, A = 3 })
	t.eq(answers(), 2, "another stake: no answer")
	inject(w, "Pia", "SPIN", { n = 9, stake = 10, level = 1, head = string.rep("1", 32), A = 3 })
	t.eq(answers(), 2, "another head: no answer")
	t.eq(#tom.env.store.witness[GUILD], 1, "one row")
	-- At most two answers per player per second, and none below a budget of 3.
	w.now = w.now + 1
	for n = 20, 24 do
		inject(w, "Pia", "SPIN", { n = n, stake = 10, level = 1, head = ZERO_HEAD, A = 3 })
	end
	t.eq(answers(), 4, "two per second")
	w.now = w.now + 1
	w.budget = 2
	inject(w, "Pia", "SPIN", { n = 30, stake = 10, level = 1, head = ZERO_HEAD, A = 3 })
	t.eq(answers(), 4, "budget below 3")
	w.budget = 10
	-- Level 0 and the own echo are never answered.
	inject(w, "Pia", "SPIN", { n = 31, stake = 10, level = 0, head = ZERO_HEAD, A = 0 })
	inject(w, "Tom", "SPIN", { n = 32, stake = 10, level = 1, head = ZERO_HEAD, A = 3 })
	t.eq(answers(), 4, "level 0 and own SPIN")
end)

t.test("witness rows and the secret: cleanup at session creation", function()
	local w, _, _, others = witnessWorld(LINE_W1, { "Tom", "Uma" })
	local store = others.Tom.env.store
	inject(w, "Pia", "SPIN", { n = 1, stake = 10, level = 1, head = ZERO_HEAD, A = 3 })
	local S = store.secret.S
	local rows = store.witness[GUILD]
	for i = 1, 5003 do
		rows[#rows + 1] = { player = "X", kind = "spin", n = i, g = 0, amount = 10, head = ZERO_HEAD, value = string.rep("a", 16), time = w.now }
	end
	table.insert(rows, 1, { player = "Old", kind = "spin", n = 1, g = 0, amount = 10, head = ZERO_HEAD, value = string.rep("a", 16), time = w.now - 15 * 86400 })
	addSession(w, "Tom", { store = store })
	t.eq(#store.witness[GUILD], 5000, "at most 5000")
	t.eq(store.witness[GUILD][5000].n, 5003, "the newest stays")
	t.eq(store.secret.S, S, "secret kept within 14 days")
	w.now = w.now + 14 * 86400
	local again = addSession(w, "Tom", { store = store })
	t.eq(#store.witness[GUILD], 0, "rows older than 14 days dropped")
	t.eq(store.secret, nil, "old secret dropped")
	again.session:onMessage("Pia", assert(Proto.encode("SPIN", { n = 2, stake = 10, level = 1, head = ZERO_HEAD, A = 1 })))
	t.ok(store.secret and store.secret.S ~= S, "a new secret on the next answer")
end)

t.test("a restart with an open request writes a void and sends RES on the first tick", function()
	local w, _, p = witnessWorld(LINE_W1, { "Tom", "Uma" })
	local g = p.session:game()
	local balance = g.balance
	assert(g:spin())
	flush(w)
	-- Reload inside the window.
	for i, s in ipairs(w.sessions) do
		if s == p.session then table.remove(w.sessions, i) break end
	end
	local p2 = addSession(w, "Pia", { store = p.env.store })
	local e = lastEntry(p2)
	t.eq(e.type, "S", "spin entry")
	t.eq(e.status, "void", "void")
	t.eq(e.contribs, "", "no contributions")
	t.eq(p2.env.store.open[GUILD].Pia, nil, "record gone")
	t.eq(p2.session:game().balance, balance, "stake kept")
	t.eq(#sentOf(w, "RES"), 0, "no RES before the tick")
	p2.session:tick()
	flush(w)
	local res = sentOf(w, "RES", "Pia")
	t.eq(#res, 1, "RES on the first tick")
	t.eq(res[1].msg.status, "void", "void")
	t.eq(res[1].msg.who, "-", "nobody")
	t.ok(Ledger.replay(GUILD, "Pia", account(p2, "Pia").entries), "replays")
	-- A record whose head no longer fits is dropped.
	p2.env.store.open[GUILD].Pia = { kind = "spin", n = 9, g = 0, stake = 10, amount = 10, A = 3, head = ZERO_HEAD, time = 1 }
	local count = #account(p2, "Pia").entries
	local p3 = addSession(w, "Pia", { store = p2.env.store })
	t.eq(#account(p3, "Pia").entries, count, "nothing written")
	t.eq(p3.env.store.open[GUILD].Pia, nil, "dropped")
end)

t.test("level 1 gamble steps, a void step, the 2.5 s interval, and the account replays", function()
	local w, _, p, others = witnessWorld(LINE_W1, { "Tom", "Uma" }, { tokens = 5000 })
	local g = p.session:game()
	local spins, steps, voids = 0, 0, 0
	for i = 1, 120 do
		if g:state() == "gamble" then
			local before = g.pending
			local dropAll = voids == 0
			if dropAll then
				w.drop = function(text) local m = Proto.decode(text) return m and m.type == "WIT" end
			end
			local r, code = g:gamble()
			t.ok(r, "gamble: " .. tostring(code))
			t.eq(r.kind, "wait", "wait")
			t.eq(r.what, "gamble", "what")
			t.eq(p.env.store.open[GUILD].Pia.amount, before, "amount at risk")
			t.eq(sentOf(w, "GAM")[#sentOf(w, "GAM")].msg.level, 1, "GAM level")
			flush(w)
			w.drop = nil
			settle(w)
			local res = events(p, "result")
			res = res[#res]
			if dropAll then
				t.eq(res.kind, "void", "void step")
				t.eq(res.what, "gamble", "what")
				t.eq(res.got, 0, "got")
				t.eq(res.need, 2, "need")
				t.eq(res.pending, g.pending, "pending")
				t.eq(res.g, r.g, "g")
				voids = voids + 1
				if r.g < 3 then
					t.eq(res.pending, before, "the offer stays open")
					t.eq(g:state(), "gamble", "can try again")
				end
			else
				t.eq(res.kind, "gamble", "kind")
				t.eq(res.amount, before, "amount")
				t.eq(res.step, r.g, "step")
				steps = steps + 1
			end
		elseif g.balance >= g.stake then
			local r = assert(g:spin())
			t.eq(r.kind, "wait", "wait")
			flush(w)
			settle(w)
			spins = spins + 1
		end
		-- 1.5 s window + 1 s: the 2.5 s interval has passed.
		local _, code = g:spin()
		if g:state() == "idle" then
			t.eq(code, "wait", "interval at 1.5 s")
		end
		w.now = w.now + 1
		if voids > 0 and steps > 2 and spins > 15 then break end
	end
	t.ok(voids > 0 and steps > 0, "steps made")
	local state = Ledger.replay(GUILD, "Pia", account(p, "Pia").entries)
	t.ok(state, "replays")
	t.eq(state.balance, g.balance, "same balance")
	-- Every GAM was answered with the amount bound into the value.
	local rows = others.Tom.env.store.witness[GUILD]
	t.ok(#rows > spins, "rows for spins and steps")
end)

t.test("the ticker at level 1 announces what the player's result gives", function()
	local lv = { big = 2, huge = 5, legendary = 10 }
	local w = newWorld()
	w.line = "GSLOTS1;L=1;W=2;R=1;E=10,50,100;G=3;T=T2"
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia")
	local tom = addSession(w, "Tom")
	addSession(w, "Uma")
	tom.env.tickerLevels = lv
	assert(o.session:grant("Pia", 2000))
	flush(w)
	for _, s in ipairs(w.sessions) do s:tick() end
	flush(w)
	local g = p.session:game()
	local results = {}
	for _ = 1, 60 do
		if g.balance < g.stake then break end
		assert(g:spin())
		flush(w)
		settle(w)
		local r = events(p, "result")
		r = r[#r]
		results[r.n] = r
		if g:state() == "gamble" then g:take() end
		w.now = w.now + 1
	end
	local got, n = {}, 0
	for _, e in ipairs(events(tom, "ticker")) do
		got[e.n] = e
		n = n + 1
	end
	local expected = 0
	for num, r in pairs(results) do
		local level = r.round.win >= lv.legendary * r.stake and "legendary" or r.round.win >= lv.huge * r.stake and "huge"
			or r.round.win >= lv.big * r.stake and "big" or r.round.free and "free" or nil
		if level then
			expected = expected + 1
			t.ok(got[num], "announced " .. num)
			t.eq(got[num] and got[num].win, r.round.win, "win")
			t.eq(got[num] and got[num].level, level, "level")
		else
			t.eq(got[num], nil, "quiet " .. num)
		end
	end
	t.ok(expected > 0, "something notable")
	t.eq(n, expected, "no extra announcements")
end)

t.test("restart from the store keeps account, purchases and spins", function()
	local w, o, p, buyId = funded(1000)
	local g = p.session:game()
	assert(g:spin())
	flush(w)
	w.now = w.now + 2
	assert(g:spin())
	flush(w)
	local balance = g.balance
	-- A new session on the same store, as after a reload.
	local p2 = addSession(w, "Pia", { store = p.env.store })
	local g2 = p2.session:game()
	t.eq(g2.balance, balance, "balance")
	t.eq(g2:status(), "ok", "status")
	t.eq(find(p2.session:purchases(), buyId).status, "done", "purchase remembered")
	local r = assert(g2:spin())
	t.eq(r.n, 3, "spin numbers continue")
	-- The officer's heard list survives too.
	local o2 = addSession(w, "Olga", { store = o.env.store })
	t.eq(o2.session:lastSpin("Pia").n, 2, "officer heard from the store")
end)

t.test("a broken account is left untouched and reported", function()
	local w, _, p = funded(1000)
	local store = p.env.store
	local entries = store.accounts[GUILD].Pia.entries
	entries[#entries + 1] = "S|5|10|0|ok|"
	local copy = table.concat(entries, "\n")
	local p2 = addSession(w, "Pia", { store = store })
	local g = p2.session:game()
	t.eq(g:status(), "broken", "status")
	local _, code = g:spin()
	t.eq(code, "broken", "spin")
	buy1(w, "00000000000000ee")
	t.eq(find(p2.session:purchases(), "00000000000000ee").code, "broken", "purchase refused")
	t.eq(table.concat(store.accounts[GUILD].Pia.entries, "\n"), copy, "store untouched")
end)

-- Presence --------------------------------------------------------------------------------------

t.test("HELLO on the first tick and then every 120..140 s", function()
	local w = newWorld()
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia", { version = "0.3.1" })
	o.session:tick()
	p.session:tick()
	flush(w)
	t.eq(sentTypes(w), "HELLO,HELLO", "two HELLOs")
	t.eq(w.log[1].text, "1|HELLO|0.3.0|0|-", "no account yet")
	local online = o.session:online()
	t.eq(#online, 2, "both online, own echo included")
	t.eq(online[1].name, "Olga", "sorted by name")
	t.eq(online[2].name, "Pia", "second")
	t.eq(online[2].version, "0.3.1", "version stored")
	w.now = w.now + 119
	o.session:tick()
	t.eq(#w.log, 2, "no HELLO before 120 s")
	w.now = w.now + 21
	o.session:tick()
	t.eq(#w.log, 3, "HELLO by 140 s")
	flush(w)
	w.now = w.now + 301
	t.eq(#o.session:online(), 0, "nobody heard within 300 s")
end)

t.test("HELLO carries the own spin number and head; the officer records it", function()
	local w, o, p = funded(1000)
	assert(p.session:game():spin())
	flush(w)
	p.session:tick()
	flush(w)
	local hello = w.log[#w.log].msg
	t.eq(hello.type, "HELLO", "type")
	t.eq(hello.n, 1, "n")
	local state = Ledger.replay(GUILD, "Pia", account(p, "Pia").entries)
	t.eq(hello.head, Ledger.shortHead(state), "head")
	t.eq(o.session:lastSpin("Pia").head, hello.head, "heard")
end)

t.test("a newer version raises one update notice per session", function()
	local w = newWorld()
	local o = addSession(w, "Olga", { version = "0.9.2" })
	local function notices()
		local c = 0
		for _, ev in ipairs(o.events) do
			if ev[1] == "notice" then c = c + 1 end
		end
		return c
	end
	inject(w, "Pia", "HELLO", { version = "0.9.1", n = 0, head = "-" })
	inject(w, "Pia", "HELLO", { version = "0.9", n = 0, head = "-" })
	t.eq(notices(), 0, "older versions")
	inject(w, "Pia", "HELLO", { version = "0.10.0", n = 0, head = "-" })
	t.eq(notices(), 1, "0.10.0 is newer than 0.9.2")
	inject(w, "Paul", "HELLO", { version = "1.0", n = 0, head = "-" })
	t.eq(notices(), 1, "once per session")
end)

-- Payout ----------------------------------------------------------------------------------------

local Pack = ns.Pack
local LINE_PAY = "GSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T2"
local H32 = string.rep("ab", 16)

-- Every session ticks, then the bus is flushed; `rounds` times, one second apart.
local function pump(w, rounds)
	for _ = 1, rounds or 1 do
		for _, session in ipairs(w.sessions) do
			session:tick()
		end
		flush(w)
		w.now = w.now + 1
	end
end

-- Spins `count` times, gambling on every other offer and taking the rest.
local function play(w, p, count)
	local g = p.session:game()
	for i = 1, count do
		w.now = w.now + 2
		if g:state() == "gamble" then
			if i % 2 == 0 then assert(g:gamble()) else g:take() end
		elseif g.balance >= g.stake then
			assert(g:spin())
		end
		flush(w)
	end
end

-- Officer Olga, player Pia, listener Tom; Pia bought 1000 tokens on a T2 table.
local function payWorld(opts)
	opts = opts or {}
	local w = newWorld()
	w.line = LINE_PAY
	local o = addSession(w, "Olga", { stepBudget = opts.stepBudget })
	local p = addSession(w, "Pia")
	local tom = addSession(w, "Tom")
	local buyId = assert(o.session:grant("Pia", opts.tokens or 1000))
	flush(w)
	return w, o, p, tom, buyId
end

local function last(list, field, value)
	for i = #list, 1, -1 do
		if list[i][field] == value then
			return list[i]
		end
	end
end

local function req(o, reqId)
	return last(o.session:requests(), "reqId", reqId)
end

-- Runs a request up to the officer's report.
local function untilReady(w, o, reqId, rounds)
	flush(w)
	for _ = 1, rounds or 50 do
		local r = req(o, reqId)
		if not r or r.status ~= "fetching" and r.status ~= "checking" then
			break
		end
		pump(w)
	end
	return req(o, reqId)
end

local function events(s, name)
	local out = {}
	for _, ev in ipairs(s.events) do
		if ev[1] == name then
			out[#out + 1] = ev[2]
		end
	end
	return out
end

local function replaceSession(w, old, new)
	for i, s in ipairs(w.sessions) do
		if s == old.session then
			table.remove(w.sessions, i)
			break
		end
	end
	return new
end

t.test("a full payout: officer checks, confirms, the player and a third client hold the same anchor", function()
	local w, o, p, tom = payWorld()
	play(w, p, 30)
	local balance = p.session:game().balance
	local reqId, code = p.session:requestPayout("Olga", 100)
	t.ok(reqId, "request: " .. tostring(code))
	t.eq(p.session:payout().status, "wait_officer", "waits for the officer")
	local r = untilReady(w, o, reqId)
	t.eq(r.status, "ready", "report ready")
	t.eq(r.player, "Pia", "player")
	t.eq(r.amount, 100, "amount")
	t.eq(r.progress, 1, "progress")
	t.eq(r.received, r.total, "all chunks")
	t.eq(r.report.light, "green", "green report")
	t.eq(r.report.balance, balance, "replayed balance")
	t.eq(r.report.state, nil, "no replayed state in the public record")
	t.eq(p.session:payout().status, "wait_decision", "player waits for the decision")
	t.eq(p.session:payout().sent, p.session:payout().total, "all chunks sent")
	local payId, c2 = o.session:confirm(reqId)
	t.ok(payId, "confirm: " .. tostring(c2))
	flush(w)
	t.eq(p.session:payout().status, "paid", "paid")
	t.eq(p.session:game().balance, balance - 100, "balance after")
	t.eq(p.session:game():status(), "ok", "lock ended")
	t.eq(req(o, reqId).status, "paid", "officer side paid")
	-- The stored account replays to balanceAfter and ends with the payout entry.
	local entries = account(p, "Pia").entries
	local state = Ledger.replay(GUILD, "Pia", entries)
	t.eq(state.balance, balance - 100, "replays to balanceAfter")
	local e = Ledger.decode(entries[#entries])
	t.eq(e.type, "P", "payout entry")
	t.eq(e.payId, payId, "payId")
	t.eq(e.officer, "Olga", "officer")
	t.eq(e.balanceAfter, balance - 100, "balanceAfter")
	-- The same anchor everywhere.
	local want = Ledger.shortHead(state)
	for _, s in ipairs({ o, p, tom }) do
		local a = s.session:anchor("Pia")
		t.eq(a.anchors, 2, s.env.me .. " anchors")
		t.eq(a.head, want, s.env.me .. " head")
		t.eq(a.by, "Olga", s.env.me .. " by")
		t.eq(s.env.store.seen[GUILD].Pia[payId], true, s.env.me .. " saw the payout")
	end
	-- Events for the UI.
	local statuses = {}
	for _, d in ipairs(events(p, "payout")) do statuses[#statuses + 1] = d.status end
	t.eq(table.concat(statuses, ","), "wait_officer,sending,wait_decision,paid", "player events")
	statuses = {}
	for _, d in ipairs(events(o, "request")) do statuses[#statuses + 1] = d.status end
	t.eq(table.concat(statuses, ","), "fetching,checking,ready,paid", "officer events")
	t.eq(events(o, "request")[1].chunks, nil, "no account text in the event")
	-- The finished request is stored without the account text.
	local stored = o.env.store.requests[#o.env.store.requests]
	t.eq(stored.reqId, reqId, "stored")
	t.eq(stored.report.state, nil, "no state stored")
end)

t.test("a partial payout, more spins, then a second payout with a green anchor check", function()
	local w, o, p = payWorld()
	play(w, p, 10)
	local id1 = assert(p.session:requestPayout("Olga", 50))
	untilReady(w, o, id1)
	assert(o.session:confirm(id1))
	flush(w)
	t.eq(p.session:payout().status, "paid", "first paid")
	play(w, p, 10)
	local id2 = assert(p.session:requestPayout("Olga", p.session:game().balance))
	local r = untilReady(w, o, id2)
	t.eq(r.status, "ready", "ready")
	t.eq(r.report.light, "green", "green")
	for _, f in ipairs(r.report.findings) do
		t.ok(f.check ~= 1, "no anchor finding: " .. tostring(f.code))
	end
	assert(o.session:confirm(id2))
	flush(w)
	t.eq(p.session:game().balance, 0, "paid out to zero")
	t.eq(o.session:anchor("Pia").anchors, 3, "three anchors")
end)

t.test("a player who hides a payout gets a red anchor_mismatch", function()
	local w, o, p = payWorld()
	play(w, p, 10)
	local old = {}
	for i, e in ipairs(account(p, "Pia").entries) do old[i] = e end
	local id1 = assert(p.session:requestPayout("Olga", 200))
	untilReady(w, o, id1)
	assert(o.session:confirm(id1))
	flush(w)
	-- Pia puts the account from before the payout back and restarts.
	local store = p.env.store
	store.accounts[GUILD].Pia.entries = old
	local p2 = replaceSession(w, p, addSession(w, "Pia", { store = store }))
	t.eq(p2.session:game().balance, p.session:game().balance + 200, "the payout is gone")
	local id2 = assert(p2.session:requestPayout("Olga", 100))
	local r = untilReady(w, o, id2)
	t.eq(r.status, "ready", "ready")
	t.eq(r.report.light, "red", "red")
	local found = false
	for _, f in ipairs(r.report.findings) do
		if f.code == "anchor_mismatch" then found = true end
	end
	t.ok(found, "anchor_mismatch")
end)

t.test("the game is locked while a request is open", function()
	local w, o, p = payWorld()
	local g = p.session:game()
	-- Spin until there is a gamble offer, so the request has to take it.
	for _ = 1, 200 do
		if g:state() == "gamble" then break end
		w.now = w.now + 2
		assert(g:spin())
		flush(w)
	end
	t.eq(g:state(), "gamble", "an offer is open")
	local balance = g.balance
	local reqId = assert(p.session:requestPayout("Olga", 10))
	t.eq(g:state(), "idle", "offer taken")
	t.eq(g.balance, balance, "balance unchanged by the take")
	t.eq(g:status(), "payout", "status")
	w.now = w.now + 2
	local _, code = g:spin()
	t.eq(code, "payout", "spin locked")
	_, code = g:gamble()
	t.eq(code, "payout", "gamble locked")
	_, code = p.session:requestPayout("Olga", 10)
	t.eq(code, "busy", "second request")
	-- A purchase for the player is refused while the request is open.
	local buyId = assert(o.session:grant("Pia", 100))
	flush(w)
	local pp = find(p.session:purchases(), buyId, "player")
	t.eq(pp.status, "failed", "purchase refused")
	t.eq(pp.code, "busy", "busy")
	untilReady(w, o, reqId)
	t.eq(g:status(), "payout", "still locked while waiting for the decision")
	assert(o.session:reject(reqId))
	flush(w)
	t.eq(g:status(), "ok", "unlocked after the decision")
	w.now = w.now + 2
	t.ok(g:spin(), "spins again")
end)

t.test("requestPayout refusals", function()
	local w = newWorld()
	w.line = LINE_PAY
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia")
	local _, code = p.session:requestPayout("Olga", 1)
	t.eq(code, "no_account", "no account")
	assert(o.session:grant("Pia", 100))
	flush(w)
	_, code = p.session:requestPayout("Olga", 0)
	t.eq(code, "bad_amount", "zero")
	_, code = p.session:requestPayout("Olga", 101)
	t.eq(code, "bad_amount", "more than the balance")
	_, code = p.session:requestPayout("Olga", 1.5)
	t.eq(code, "bad_amount", "fraction")
	_, code = p.session:requestPayout("Paul", 10)
	t.eq(code, "bad_officer", "not an officer")
	_, code = p.session:requestPayout("Ol|ga", 10)
	t.eq(code, "bad_officer", "bad name")
	_, code = o.session:requestPayout("Olga", 10)
	t.eq(code, "no_account", "officer has no account")
	w.refuse = true
	_, code = p.session:requestPayout("Olga", 10)
	t.eq(code, "send", "queue refused")
	t.eq(p.session:payout(), nil, "nothing recorded")
	w.refuse = false
	-- An open purchase blocks a request.
	local w2 = newWorld()
	w2.line = LINE_PAY
	local p2 = addSession(w2, "Pia")
	buy1(w2, "00000000000000f1", { line = LINE_PAY })
	inject(w2, "Olga", "BUY3", { buyId = "00000000000000f1", seed = SEED })
	t.eq(p2.session:game().balance, 300, "funded")
	buy1(w2, "00000000000000f2", { line = LINE_PAY })
	_, code = p2.session:requestPayout("Olga", 10)
	t.eq(code, "busy", "purchase open")
	-- A broken account.
	local store = p.env.store
	local entries = store.accounts[GUILD].Pia.entries
	entries[#entries + 1] = "S|9|10|0|ok|"
	local p3 = addSession(w, "Pia", { store = store })
	_, code = p3.session:requestPayout("Olga", 10)
	t.eq(code, "broken", "broken")
end)

t.test("officer refusals: confirm, reject and a second request of the same player", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local reqId = assert(p.session:requestPayout("Olga", 10))
	-- Only the PAYREQ and the LOGREQ: the officer is still fetching.
	w.drop = function(text) return text:find("|LOG|", 1, true) ~= nil end
	flush(w)
	local _, code = o.session:confirm(reqId)
	t.eq(code, "not_ready", "not ready")
	_, code = o.session:confirm("0000000000000000")
	t.eq(code, "unknown", "unknown")
	_, code = o.session:reject(reqId, "nope")
	t.eq(code, "bad_reason", "bad reason")
	-- Another request of Pia while one is open: busy.
	inject(w, "Pia", "PAYREQ", { reqId = "00000000000000e1", officer = "Olga", amount = 1, head = H32, count = 1 })
	local rej = w.log[#w.log].msg
	t.eq(rej.type, "REJECT", "rejected")
	t.eq(rej.reason, "busy", "busy")
	t.eq(rej.reqId, "00000000000000e1", "for the second request")
	t.eq(p.session:payout().status, "wait_decision", "the first request goes on")
	-- A PAYREQ to someone who is not an officer here is ignored.
	local before = #w.log
	inject(w, "Tom", "PAYREQ", { reqId = "00000000000000e2", officer = "Pia", amount = 1, head = H32, count = 1 })
	t.eq(#w.log, before, "no reply")
end)

t.test("reject: the player sees the reason and plays on", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local balance = p.session:game().balance
	local reqId = assert(p.session:requestPayout("Olga", 10))
	untilReady(w, o, reqId)
	t.eq(o.session:reject(reqId), true, "rejected")
	flush(w)
	local pay = p.session:payout()
	t.eq(pay.status, "rejected", "player rejected")
	t.eq(pay.code, "declined", "reason")
	t.eq(req(o, reqId).status, "rejected", "officer rejected")
	t.eq(req(o, reqId).code, "declined", "officer code")
	t.eq(p.session:game().balance, balance, "nothing paid")
	local _, code = o.session:confirm(reqId)
	t.eq(code, "unknown", "no confirm after a reject")
end)

t.test("expiry on both sides after 300 s, and confirm after 270 s", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local reqId = assert(p.session:requestPayout("Olga", 10))
	untilReady(w, o, reqId)
	w.now = w.now + 299 - 5
	o.session:tick()
	p.session:tick()
	t.eq(p.session:payout().status, "wait_decision", "still waiting just before 300 s")
	w.now = w.now + 6
	o.session:tick()
	p.session:tick()
	t.eq(p.session:payout().status, "expired", "player expired")
	t.eq(req(o, reqId).status, "expired", "officer expired")
	t.eq(p.session:game():status(), "ok", "lock ended")
	-- Confirm at 270 s: REJECT expired.
	local id2 = assert(p.session:requestPayout("Olga", 10))
	untilReady(w, o, id2)
	w.now = req(o, id2).time + 270
	local _, code = o.session:confirm(id2)
	t.eq(code, "expired", "too late to confirm")
	flush(w)
	t.eq(req(o, id2).status, "expired", "officer expired")
	t.eq(p.session:payout().status, "rejected", "player got the REJECT")
	t.eq(p.session:payout().code, "expired", "reason expired")
end)

t.test("mismatch: the account changed between PAYREQ and LOG", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local reqId = assert(p.session:requestPayout("Olga", 10))
	-- The stored account loses its last entry before the LOG goes out.
	table.remove(account(p, "Pia").entries)
	local r = untilReady(w, o, reqId)
	t.eq(r.status, "failed", "failed")
	t.eq(r.code, "mismatch", "mismatch")
	t.eq(p.session:payout().status, "rejected", "player rejected")
	t.eq(p.session:payout().code, "mismatch", "reason")
	-- Same number of entries, another head: found after the replay. Pam (no session) sends Pia's
	-- entries, which replay under her name to other heads than the one in her PAYREQ.
	local entries = account(p, "Pia").entries
	local id2 = "00000000000000e3"
	inject(w, "Pam", "PAYREQ", { reqId = id2, officer = "Olga", amount = 1, head = H32, count = #entries })
	t.eq(w.log[#w.log].msg.type, "LOGREQ", "officer asks Pam for the log")
	local chunks = Pack.split(Pack.encode(entries))
	for i, c in ipairs(chunks) do
		inject(w, "Pam", "LOG", { reqId = id2, seq = i, total = #chunks, payload = c })
	end
	t.eq(req(o, id2).status, "checking", "checking")
	r = untilReady(w, o, id2)
	t.eq(r.status, "failed", "failed after the replay")
	t.eq(r.code, "mismatch", "head mismatch")
	local rej = last(w.log, "sender", "Olga").msg
	t.eq(rej.type, "REJECT", "REJECT sent")
	t.eq(rej.player, "Pam", "to Pam")
	t.eq(rej.reason, "mismatch", "reason")
end)

t.test("a PAY that does not fit the account fails and leaves it as it was", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local balance = p.session:game().balance
	local count = #account(p, "Pia").entries
	local function pay(reqId, fields)
		local f = { reqId = reqId, payId = "00000000000000d9", player = "Pia", amount = 10,
			balanceAfter = balance - 10, time = 5000, head = H32, anchors = 2 }
		for k, v in pairs(fields or {}) do f[k] = v end
		inject(w, "Olga", "PAY", f)
	end
	local id1 = assert(p.session:requestPayout("Olga", 10))
	untilReady(w, o, id1)
	pay(id1)
	t.eq(p.session:payout().status, "failed", "failed")
	t.eq(p.session:payout().code, "head_mismatch", "head_mismatch")
	assert(o.session:reject(id1)) -- clears the officer side; the player's request is already over
	local id2 = assert(p.session:requestPayout("Olga", 10))
	pay(id2, { balanceAfter = balance })
	t.eq(p.session:payout().code, "bad_balance", "ledger code")
	-- A PAY from another officer than the one asked changes nothing.
	w.officers.Otto = true
	assert(o.session:reject(id2))
	local id3 = assert(p.session:requestPayout("Olga", 10))
	inject(w, "Otto", "PAY", { reqId = id3, payId = "00000000000000d8", player = "Pia", amount = 10,
		balanceAfter = balance - 10, time = 5000, head = H32, anchors = 2 })
	t.eq(p.session:payout().status, "wait_decision", "other officer ignored")
	t.eq(p.session:game().balance, balance, "balance unchanged")
	t.eq(#account(p, "Pia").entries, count, "no entry")
end)

-- The PAY an officer would send for Pia's account as it is now.
local function payFor(p, reqId, amount, payId)
	local state = Ledger.replay(GUILD, "Pia", account(p, "Pia").entries)
	local entry = { type = "P", payId = payId or "00000000000000d7", officer = "Olga", amount = amount,
		balanceAfter = state.balance - amount, time = 9000 }
	assert(Ledger.apply(state, entry))
	return { reqId = reqId, payId = entry.payId, player = "Pia", amount = amount, balanceAfter = entry.balanceAfter,
		time = entry.time, head = Ledger.shortHead(state), anchors = state.anchors }
end

t.test("an open request survives a reload: lock, LOGREQ and PAY", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local balance = p.session:game().balance
	local reqId = assert(p.session:requestPayout("Olga", 30))
	-- Reload before the PAYREQ is even delivered.
	local p2 = replaceSession(w, p, addSession(w, "Pia", { store = p.env.store }))
	t.eq(p2.session:payout().reqId, reqId, "request restored")
	t.eq(p2.session:payout().status, "wait_officer", "status restored")
	t.eq(p2.session:game():status(), "payout", "lock restored")
	local r = untilReady(w, o, reqId)
	t.eq(r.status, "ready", "the restored session answered the LOGREQ")
	assert(o.session:confirm(reqId))
	flush(w)
	t.eq(p2.session:payout().status, "paid", "paid")
	t.eq(p2.session:game().balance, balance - 30, "balance")
	t.eq(p2.env.store.payout[GUILD].Pia.status, "paid", "kept in the store")
	t.eq(p2.env.store.payout[GUILD].Pia.chunks, nil, "no account text in the store")
end)

t.test("a reload while sending sends the LOG again", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local reqId = assert(p.session:requestPayout("Olga", 10))
	local send = p.env.send
	p.env.send = function(text)
		if text:find("|LOG|", 1, true) then return nil, "full" end
		return send(text)
	end
	flush(w)
	t.eq(p.session:payout().status, "sending", "stuck sending")
	local p2 = replaceSession(w, p, addSession(w, "Pia", { store = p.env.store }))
	t.eq(p2.session:payout().status, "sending", "restored sending")
	local r = untilReady(w, o, reqId)
	t.eq(r.status, "ready", "ready")
	t.eq(p2.session:payout().status, "wait_decision", "all sent")
end)

t.test("a PAY after expiry is accepted while the account is unchanged", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local balance = p.session:game().balance
	local reqId = assert(p.session:requestPayout("Olga", 20))
	untilReady(w, o, reqId)
	local pay = payFor(p, reqId, 20)
	w.now = w.now + 300
	p.session:tick()
	t.eq(p.session:payout().status, "expired", "expired")
	t.eq(p.session:game():status(), "ok", "lock ended")
	-- Even after a reload.
	local p2 = replaceSession(w, p, addSession(w, "Pia", { store = p.env.store }))
	t.eq(p2.session:payout().status, "expired", "restored as expired")
	inject(w, "Olga", "PAY", pay)
	t.eq(p2.session:payout().status, "paid", "late PAY accepted")
	t.eq(p2.session:game().balance, balance - 20, "paid")
end)

t.test("a late PAY fails once the player has spun, and is ignored after a newer request", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local id1 = assert(p.session:requestPayout("Olga", 20))
	untilReady(w, o, id1)
	local pay1 = payFor(p, id1, 20)
	w.now = w.now + 300
	pump(w)
	play(w, p, 3)
	local count = #account(p, "Pia").entries
	inject(w, "Olga", "PAY", pay1)
	t.eq(p.session:payout().status, "failed", "failed")
	-- The spins moved the balance, so the ledger refuses the entry before the head is compared.
	t.eq(p.session:payout().code, "bad_balance", "ledger code")
	t.eq(#account(p, "Pia").entries, count, "account unchanged")
	-- A newer request: the PAY of the old one is no longer for this request.
	local id2 = assert(p.session:requestPayout("Olga", 10))
	local pay2 = payFor(p, id1, 20, "00000000000000d6")
	inject(w, "Olga", "PAY", pay2)
	t.eq(p.session:payout().reqId, id2, "newer request")
	t.eq(p.session:payout().status, "wait_decision", "untouched")
	t.eq(#account(p, "Pia").entries, count, "still unchanged")
end)

t.test("a PAY with another amount fails with amount_mismatch", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local balance = p.session:game().balance
	local reqId = assert(p.session:requestPayout("Olga", 20))
	untilReady(w, o, reqId)
	inject(w, "Olga", "PAY", payFor(p, reqId, 25))
	t.eq(p.session:payout().status, "failed", "failed")
	t.eq(p.session:payout().code, "amount_mismatch", "amount_mismatch")
	t.eq(p.session:game().balance, balance, "nothing paid")
end)

t.test("too_large: more than 200 announced chunks, or more entries than Pack allows", function()
	local w, o = payWorld()
	local id = "00000000000000e5"
	inject(w, "Pam", "PAYREQ", { reqId = id, officer = "Olga", amount = 1, head = H32, count = 1 })
	inject(w, "Pam", "LOG", { reqId = id, seq = 1, total = 201, payload = "s10" })
	t.eq(req(o, id).status, "failed", "failed")
	t.eq(req(o, id).code, "too_large", "too_large")
	t.eq(w.log[#w.log].msg.reason, "too_large", "REJECT too_large")
	t.eq(Pack.MAX_ENTRIES, 100000, "limit")
	local id2 = "00000000000000e6"
	inject(w, "Pam", "PAYREQ", { reqId = id2, officer = "Olga", amount = 1, head = H32, count = 100001 })
	t.eq(req(o, id2).status, "failed", "count over the limit")
	t.eq(w.log[#w.log].msg.reason, "too_large", "REJECT too_large")
	local id3 = "00000000000000e7"
	inject(w, "Pam", "PAYREQ", { reqId = id3, officer = "Olga", amount = 1, head = H32, count = 100000 })
	t.eq(req(o, id3).status, "fetching", "at the limit")
end)

t.test("a LOG that does not unpack is rejected as bad_log", function()
	local w, o = payWorld()
	local id = "00000000000000e4"
	inject(w, "Pam", "PAYREQ", { reqId = id, officer = "Olga", amount = 1, head = H32, count = 1 })
	inject(w, "Pam", "LOG", { reqId = id, seq = 2, total = 2, payload = "\n" })
	inject(w, "Mallory", "LOG", { reqId = id, seq = 1, total = 2, payload = "s10" }) -- not the player
	t.eq(req(o, id).received, 1, "one chunk from Pam")
	inject(w, "Pam", "LOG", { reqId = id, seq = 1, total = 2, payload = "s10" })
	t.eq(req(o, id).status, "failed", "failed")
	t.eq(req(o, id).code, "bad_log", "bad_log")
	t.eq(w.log[#w.log].msg.reason, "bad_log", "REJECT bad_log")
end)

t.test("too_large: more than 200 chunks fails before anything is sent", function()
	local w = newWorld()
	w.line = LINE_PAY
	local o = addSession(w, "Olga")
	local entries = {}
	for i = 1, 230 do
		entries[i] = Ledger.encode({
			type = "B", buyId = string.format("%016x", i), officer = "Olga", tokens = 1, commit = ns.Engine.commit(SEED),
			seed = SEED, nonce = string.rep("7", 32), time = 1234, line = LINE_PAY,
		})
	end
	t.ok(#Pack.split(Pack.encode(entries)) > 200, "over 200 chunks")
	local p = addSession(w, "Pia", { store = { accounts = { [GUILD] = { Pia = { entries = entries } } } } })
	t.eq(p.session:game().balance, 230, "replayed")
	local reqId = assert(p.session:requestPayout("Olga", 10))
	flush(w)
	t.eq(p.session:payout().status, "failed", "failed")
	t.eq(p.session:payout().code, "too_large", "too_large")
	t.eq(sentTypes(w, "Pia"), "PAYREQ", "no LOG sent")
	t.eq(p.session:game():status(), "ok", "lock ended")
	t.eq(req(o, reqId).status, "fetching", "the officer waits until expiry")
end)

t.test("chunk loss: the request never completes and expires", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	w.drop = function(text) return text:find("^1|LOG|%x+|1|") ~= nil end
	local reqId = assert(p.session:requestPayout("Olga", 10))
	untilReady(w, o, reqId, 5)
	t.eq(req(o, reqId).status, "fetching", "still fetching")
	w.now = w.now + 300
	pump(w)
	t.eq(req(o, reqId).status, "expired", "officer expired")
	t.eq(p.session:payout().status, "expired", "player expired")
end)

t.test("a refused LOG send is retried on the next tick", function()
	local w, o, p = payWorld()
	play(w, p, 5)
	local reqId = assert(p.session:requestPayout("Olga", 10))
	-- PAYREQ out, LOGREQ back; then the queue refuses.
	local n = 0
	local send = p.env.send
	p.env.send = function(text)
		if text:find("|LOG|", 1, true) then
			n = n + 1
			if n == 1 then return nil, "full" end
		end
		return send(text)
	end
	flush(w)
	t.eq(p.session:payout().status, "sending", "sending")
	t.eq(p.session:payout().sent, 0, "nothing sent yet")
	local r = untilReady(w, o, reqId)
	t.eq(r.status, "ready", "ready after the retry")
end)

t.test("verification is spread over ticks", function()
	local w, o, p = payWorld({ stepBudget = 10 })
	play(w, p, 40)
	local count = #account(p, "Pia").entries
	t.ok(count > 30, "entries " .. count)
	local reqId = assert(p.session:requestPayout("Olga", 10))
	flush(w)
	t.eq(req(o, reqId).status, "checking", "checking before the first tick")
	t.eq(req(o, reqId).progress, 0, "nothing done")
	o.session:tick()
	local r = req(o, reqId)
	t.eq(r.status, "checking", "still checking")
	t.near(r.progress, 10 / count, 1e-9, "one budget done")
	local ticks = 1
	while req(o, reqId).status == "checking" do
		o.session:tick()
		ticks = ticks + 1
	end
	t.eq(req(o, reqId).status, "ready", "ready")
	t.eq(ticks, math.ceil(count / 10) + (count % 10 == 0 and 1 or 0), "ticks")
end)

t.test("self payout with allowSelf", function()
	local w = newWorld()
	w.line = LINE_PAY
	local o = addSession(w, "Olga", { allowSelf = true })
	assert(o.session:grant("Olga", 500))
	flush(w)
	play(w, o, 6)
	local balance = o.session:game().balance
	local reqId = assert(o.session:requestPayout("Olga", 20))
	local r = untilReady(w, o, reqId)
	t.eq(r.status, "ready", "ready")
	assert(o.session:confirm(reqId))
	flush(w)
	t.eq(o.session:payout().status, "paid", "paid")
	t.eq(o.session:game().balance, balance - 20, "balance")
	-- Without allowSelf the own name is not an officer to ask.
	o.env.allowSelf = false
	local _, code = o.session:requestPayout("Olga", 1)
	t.eq(code, "bad_officer", "own name")
end)

t.test("anchors from purchases heard by a third client", function()
	local w, o, p, tom, buyId = payWorld()
	local state = Ledger.replay(GUILD, "Pia", account(p, "Pia").entries)
	for _, s in ipairs({ o, p, tom }) do
		local a = s.session:anchor("Pia")
		t.ok(a, s.env.me .. " has an anchor")
		t.eq(a.anchors, 1, "anchors")
		t.eq(a.head, Ledger.shortHead(state), "head after the purchase")
		t.eq(a.time, 1000, "time of the purchase")
		t.eq(a.by, "Olga", "by")
		t.eq(s.env.store.seen[GUILD].Pia[buyId], true, "seen")
	end
	-- A second purchase moves the anchor on.
	play(w, p, 3)
	w.now = w.now + 5
	assert(o.session:grant("Pia", 100))
	flush(w)
	state = Ledger.replay(GUILD, "Pia", account(p, "Pia").entries)
	t.eq(tom.session:anchor("Pia").anchors, 2, "second purchase")
	t.eq(tom.session:anchor("Pia").head, Ledger.shortHead(state), "head after the second purchase")
	-- A listener with another settings line hashes another entry: seen, but no anchor.
	local w2 = newWorld()
	w2.line = LINE_PAY
	local o2 = addSession(w2, "Olga")
	addSession(w2, "Pia")
	local other = addSession(w2, "Tom", { line = "GSLOTS1;L=0" })
	local id2 = assert(o2.session:grant("Pia", 100))
	flush(w2)
	t.eq(other.session:anchor("Pia"), nil, "no anchor with another line")
	t.eq(other.env.store.seen[GUILD].Pia[id2], true, "seen anyway")
	-- A BUY3 with a wrong seed, or without a BUY2, stores nothing.
	local w3 = newWorld()
	local t3 = addSession(w3, "Tom")
	buy1(w3, "00000000000000c1")
	inject(w3, "Pia", "BUY2", { buyId = "00000000000000c1", nonce = H32, head = H32 .. H32, anchors = 0 })
	inject(w3, "Olga", "BUY3", { buyId = "00000000000000c1", seed = string.rep("6", 32) })
	buy1(w3, "00000000000000c2")
	inject(w3, "Olga", "BUY3", { buyId = "00000000000000c2", seed = SEED })
	t.eq(t3.session:anchor("Pia"), nil, "no anchor")
	t.eq(t3.env.store.seen, nil, "nothing seen")
end)

t.test("OSYNC brings the newest anchors to a client that was offline", function()
	local w, o, p = payWorld()
	local want = o.session:anchor("Pia")
	-- Later: Olga logs in again, Tim was never online before.
	local w2 = newWorld()
	w2.now = w.now + 1000
	w2.line = LINE_PAY
	local o2 = addSession(w2, "Olga", { store = o.env.store })
	local tim = addSession(w2, "Tim")
	o2.session:tick()
	flush(w2)
	w2.now = w2.now + 19
	o2.session:tick()
	flush(w2)
	t.eq(sentTypes(w2, "Olga"):find("OSYNC"), nil, "not before 20 s")
	w2.now = w2.now + 1
	o2.session:tick()
	flush(w2)
	t.eq(sentTypes(w2, "Olga"), "HELLO,OSYNC", "one OSYNC")
	local a = tim.session:anchor("Pia")
	t.eq(a.anchors, want.anchors, "anchors")
	t.eq(a.head, want.head, "head")
	t.eq(a.by, "Olga", "by the sender")
	w2.now = w2.now + 100
	o2.session:tick()
	flush(w2)
	t.eq(sentTypes(w2, "Olga"), "HELLO,OSYNC", "only once")
	-- From a non-officer, or not higher: ignored.
	inject(w2, "Tim", "OSYNC", { player = "Pia", anchors = 9, head = H32, time = 1 })
	t.eq(tim.session:anchor("Pia").anchors, want.anchors, "non-officer ignored")
	inject(w2, "Olga", "OSYNC", { player = "Pia", anchors = want.anchors, head = H32, time = 1 })
	t.eq(tim.session:anchor("Pia").head, want.head, "not higher ignored")
	t.eq(p.session:anchor("Pia").anchors, 1, "the player's own copy")
end)

-- What is ignored -------------------------------------------------------------------------------

t.test("ignored messages change nothing and produce no reply", function()
	local w = newWorld()
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia")
	local buyId = assert(o.session:grant("Pia", 100))
	-- Hold the BUY1 back: Pia is not asked yet.
	w.queue = {}
	local H32 = string.rep("a", 32)
	inject(w, "Mallory", "BUY3", { buyId = buyId, seed = H32 }) -- not an officer
	inject(w, "Pia", "BUY2", { buyId = "ffffffffffffffff", nonce = H32, head = H32 .. H32, anchors = 0 }) -- unknown buyId
	inject(w, "Olga", "BUY3", { buyId = "ffffffffffffffff", seed = H32 }) -- unknown buyId
	inject(w, "Paul", "BUY2", { buyId = buyId, nonce = H32, head = H32 .. H32, anchors = 0 }) -- not the player
	inject(w, "Pia", "BUY1", { buyId = buyId, player = "Pia", tokens = 1, commit = string.rep("b", 64),
		time = 1, lineHash = Proto.lineHash(LINE) }) -- BUY1 from a non-officer
	t.eq(find(o.session:purchases(), buyId).status, "wait_nonce", "officer still waits")
	t.eq(#p.session:purchases(), 0, "player has nothing")
	t.eq(#w.log, 1, "only the BUY1 was ever sent")
	t.eq(#p.session:online(), 0, "no sign of life from ignored messages")
end)

t.test("onMessage survives any text", function()
	local w, o, p = funded(1000)
	-- A finished payout and a second one left open, so mutated payout messages meet open state.
	play(w, p, 6)
	local id1 = assert(p.session:requestPayout("Olga", 10))
	untilReady(w, o, id1)
	assert(o.session:confirm(id1))
	flush(w)
	play(w, p, 4)
	assert(p.session:requestPayout("Olga", 10))
	flush(w)
	local x = 987654321
	local function r(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return x % n
	end
	local samples = { assert(Proto.encode("OSYNC", { player = "Pia", anchors = 3, head = H32, time = 5 })) }
	for _, e in ipairs(w.log) do
		samples[#samples + 1] = e.text
	end
	local alphabet = "1|BUY23SPINGAMHELLOPAYREQLOGJCTOSYNC0123456789abcdef-.=*\n\0\255"
	local senders = { "Olga", "Pia", "Mallory", "", "A|B", false }
	for i = 1, 2000 do
		local text
		if i % 2 == 0 then
			local parts = {}
			for j = 1, r(60) do
				local c = r(#alphabet) + 1
				parts[j] = alphabet:sub(c, c)
			end
			text = table.concat(parts)
		else
			local base = samples[r(#samples) + 1]
			local k, c = r(#base) + 1, r(#alphabet) + 1
			text = base:sub(1, k - 1) .. alphabet:sub(c, c) .. base:sub(k + 1)
		end
		local sender = senders[r(#senders) + 1] or nil
		for _, s in ipairs({ o.session, p.session }) do
			local ok, err = pcall(s.onMessage, s, sender, text)
			t.ok(ok, "raised: " .. tostring(err))
		end
		if i % 50 == 0 then
			w.now = w.now + 7
			for _, s in ipairs({ o.session, p.session }) do
				local ok, err = pcall(s.tick, s)
				t.ok(ok, "tick raised: " .. tostring(err))
			end
		end
	end
	for _, bad in ipairs({ 42, {}, true }) do
		t.ok(pcall(p.session.onMessage, p.session, "Olga", bad), "non-text")
	end
	t.ok(pcall(p.session.onMessage, p.session, "Olga", nil), "nil text")
	t.ok(Ledger.replay(GUILD, "Pia", account(p, "Pia").entries), "account still replays")
end)

-- Guild ticker ---------------------------------------------------------------------------------

local ZERO = string.rep("0", 32)

local function spinText(n, stake, level)
	return assert(Proto.encode("SPIN", { n = n, stake = stake or 10, level = level or 0, head = ZERO, A = 0 }))
end

local function tickerWorld(levels)
	local w, o, p, tom, buyId = payWorld()
	tom.env.tickerLevels = levels or { big = 2, huge = 5, legendary = 10 }
	return w, o, p, tom, buyId
end

-- Pia spins `count` times, two seconds apart; returns the results by n.
local function spinMany(w, p, count)
	local g, results = p.session:game(), {}
	for _ = 1, count do
		w.now = w.now + 2
		if g.balance < g.stake then break end
		local r = assert(g:spin())
		results[r.n] = r
		flush(w)
		if g:state() == "gamble" then g:take() end
	end
	return results
end

local function levelOf(win, stake, lv, free)
	if win >= lv.legendary * stake then return "legendary" end
	if win >= lv.huge * stake then return "huge" end
	if win >= lv.big * stake then return "big" end
	if free then return "free" end
end

t.test("the listener announces notable rounds as the player's own result gives them", function()
	local lv = { big = 2, huge = 5, legendary = 10 }
	local w, _, p, tom = tickerWorld(lv)
	local results = spinMany(w, p, 80)
	local got, n = {}, 0
	for _, e in ipairs(events(tom, "ticker")) do
		got[e.n] = e
		n = n + 1
	end
	t.ok(n > 0, "at least one notable round")
	local expected = 0
	for num, r in pairs(results) do
		local level = levelOf(r.round.win, r.stake, lv, r.round.free)
		if level then
			expected = expected + 1
			local e = got[num]
			t.ok(e, "announced " .. num)
			t.eq(e.player, "Pia", "player")
			t.eq(e.stake, r.stake, "stake")
			t.eq(e.win, r.round.win, "win")
			t.eq(e.mult, r.round.win / r.stake, "mult")
			t.eq(e.level, level, "level")
			t.eq(e.free, r.round.free and r.round.free.awarded or nil, "free")
			t.eq(e.symbol, r.round.free and r.round.free.symbol or nil, "symbol")
		else
			t.eq(got[num], nil, "quiet " .. num)
		end
	end
	t.eq(n, expected, "no extra announcements")
	local list = tom.session:ticker()
	t.ok(#list >= 1 and #list <= 20, "at most 20")
	for i = 2, #list do
		t.ok(list[i - 1].n > list[i].n, "newest first")
	end
end)

t.test("the player's own client and a client without a heard purchase announce nothing", function()
	local w, _, p, tom = tickerWorld()
	local late = addSession(w, "Lena")
	late.env.tickerLevels = { big = 1, huge = 2, legendary = 3 }
	p.env.tickerLevels = { big = 1, huge = 2, legendary = 3 }
	spinMany(w, p, 40)
	t.eq(#events(p, "ticker"), 0, "own spins")
	t.eq(#events(late, "ticker"), 0, "no purchase heard")
	t.eq(#p.session:ticker(), 0, "own list empty")
	t.ok(#events(tom, "ticker") > 0, "the listener hears")
end)

t.test("a SPIN is announced once and only with a higher number", function()
	local w, _, p, tom = tickerWorld({ big = 0.01, huge = 1e9, legendary = 1e9 })
	spinMany(w, p, 1)
	local count = #events(tom, "ticker")
	t.ok(count <= 1, "at most the one spin")
	for _ = 1, 3 do
		w.now = w.now + 5
		tom.session:onMessage("Pia", spinText(1))
	end
	t.eq(#events(tom, "ticker"), count, "no repeats")
end)

t.test("one recalculation per sender per second and five per second in total", function()
	local w, _, _, tom = tickerWorld({ big = 0.01, huge = 1e9, legendary = 1e9 })
	local s = tom.session
	for n = 1, 10 do
		s:onMessage("Pia", spinText(n))
	end
	t.eq(s.tickLast.Pia, 1, "only the first spin of the second was looked at")
	w.now = w.now + 1
	s:onMessage("Pia", spinText(11))
	t.eq(s.tickLast.Pia, 11, "the next second recalculates")
	local list = tom.env.store.keys[GUILD]
	for i = 1, 10 do
		list["Bob" .. i] = { K = list.Pia.K, line = list.Pia.line, time = 1 }
	end
	w.now = w.now + 5
	local calc = 0
	for i = 1, 10 do
		s:onMessage("Bob" .. i, spinText(1))
		if s.tickLast["Bob" .. i] then calc = calc + 1 end
	end
	t.eq(calc, 5, "five in total per second")
	w.now = w.now + 1
	s:onMessage("Bob10", spinText(2))
	t.eq(s.tickLast.Bob10, 2, "budget is back")
end)

t.test("a listener restarted from its store still announces", function()
	local lv = { big = 2, huge = 5, legendary = 10 }
	local w, _, p, tom = tickerWorld(lv)
	t.ok(tom.env.store.keys[GUILD].Pia, "key stored")
	local again = addSession(w, "Tom", { store = tom.env.store })
	again.env.tickerLevels = lv
	spinMany(w, p, 60)
	t.ok(#events(again, "ticker") > 0, "announces after restart")
	t.eq(#events(again, "ticker"), #events(tom, "ticker"), "same as the live listener")
end)

t.test("a second purchase replaces the key", function()
	local w, o, _, tom = tickerWorld()
	local first = tom.env.store.keys[GUILD].Pia
	w.now = w.now + 10
	assert(o.session:grant("Pia", 500))
	flush(w)
	local second = tom.env.store.keys[GUILD].Pia
	t.ok(second.K ~= first.K, "new key")
	t.eq(second.time, 1010, "new time")
end)

t.test("a purchase without a complete exchange drops the key of that player", function()
	local w, o, _, tom = tickerWorld()
	t.ok(tom.env.store.keys[GUILD].Pia, "key")
	w.now = w.now + 10
	w.drop = function(text)
		local m = Proto.decode(text)
		return m and m.type == "BUY3"
	end
	assert(o.session:grant("Pia", 500))
	flush(w)
	w.drop = nil
	w.now = w.now + 100
	tom.session:onMessage("Olga", assert(Proto.encode("HELLO", { version = "0.3.0", n = 0, head = ZERO })))
	t.eq(tom.env.store.keys[GUILD].Pia, nil, "key dropped")
end)

t.test("no ticker for a T1 line or a level 1 SPIN", function()
	local w = newWorld()
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia")
	local tom = addSession(w, "Tom")
	tom.env.tickerLevels = { big = 0.01, huge = 1e9, legendary = 1e9 }
	assert(o.session:grant("Pia", 1000))
	flush(w)
	spinMany(w, p, 20)
	t.eq(#events(tom, "ticker"), 0, "T1")
	local w2, _, _, tom2 = tickerWorld({ big = 0.01, huge = 1e9, legendary = 1e9 })
	w2.now = w2.now + 5
	tom2.session:onMessage("Pia", spinText(1, 10, 1))
	t.eq(#events(tom2, "ticker"), 0, "level 1")
end)

t.test("keeps at most 200 keys", function()
	local w, _, _, tom = tickerWorld()
	local list = tom.env.store.keys[GUILD]
	for i = 1, 250 do
		list["Q" .. i] = { K = "k", line = "x", time = 100 + i }
	end
	w.now = w.now + 10
	assert(addSession(w, "Zed"))
	local o = w.sessions[1]
	assert(o:grant("Zed", 100))
	flush(w)
	local count = 0
	for _ in pairs(list) do count = count + 1 end
	t.eq(count, 200, "capped")
	t.ok(list.Zed, "the newest stays")
	t.eq(list.Q1, nil, "the oldest goes")
end)

t.test("ticker input never raises", function()
	local w, _, _, tom = tickerWorld({ big = 0.01, huge = 1e9, legendary = 1e9 })
	local s = tom.session
	for _, text in ipairs({ "SPIN|x", "SPIN|-1|10|0|h|0", "SPIN", "|||", string.rep("9", 400) }) do
		t.ok(pcall(s.onMessage, s, "Pia", text), "junk")
	end
	for _, bad in ipairs({ { 1 }, "x", 5, { K = 5 }, { K = "k", line = 7 }, { K = "k", line = "GSLOTS1;T=T1" } }) do
		tom.env.store.keys[GUILD].Pia = bad
		w.now = w.now + 2
		t.ok(pcall(s.onMessage, s, "Pia", spinText(50)), "bad key")
	end
	for i = 1, 500 do
		local sender = "P" .. (i % 7)
		tom.env.store.keys[GUILD][sender] = { K = "k", line = LINE_PAY, time = 1 }
		t.ok(pcall(s.onMessage, s, sender, spinText(i)), "flood")
	end
end)
