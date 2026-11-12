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
	}
	s.session = Guild.new(s.env)
	w.sessions[#w.sessions + 1] = s.session
	return s
end

local function flush(w)
	while #w.queue > 0 do
		local m = table.remove(w.queue, 1)
		for _, session in ipairs(w.sessions) do
			session:onMessage(m[1], m[2])
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
	inject(w, "Pia", "BUY2", { buyId = buyId, nonce = string.rep("1", 32), head = string.rep("2", 32) })
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

t.test("a level 1 account cannot spin yet", function()
	local w = newWorld()
	w.line = "GSLOTS1;L=1"
	local o = addSession(w, "Olga")
	local p = addSession(w, "Pia")
	assert(o.session:grant("Pia", 100))
	flush(w)
	local g = p.session:game()
	t.eq(g.balance, 100, "credited")
	t.eq(g:status(), "level", "status")
	local _, code = g:spin()
	t.eq(code, "level", "spin")
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
	inject(w, "Pia", "BUY2", { buyId = "ffffffffffffffff", nonce = H32, head = H32 }) -- unknown buyId
	inject(w, "Olga", "BUY3", { buyId = "ffffffffffffffff", seed = H32 }) -- unknown buyId
	inject(w, "Paul", "BUY2", { buyId = buyId, nonce = H32, head = H32 }) -- not the player
	inject(w, "Pia", "BUY1", { buyId = buyId, player = "Pia", tokens = 1, commit = string.rep("b", 64),
		time = 1, lineHash = Proto.lineHash(LINE) }) -- BUY1 from a non-officer
	t.eq(find(o.session:purchases(), buyId).status, "wait_nonce", "officer still waits")
	t.eq(#p.session:purchases(), 0, "player has nothing")
	t.eq(#w.log, 1, "only the BUY1 was ever sent")
	t.eq(#p.session:online(), 0, "no sign of life from ignored messages")
end)

t.test("onMessage survives any text", function()
	local w, o, p = funded(1000)
	local x = 987654321
	local function r(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return x % n
	end
	local samples = {}
	for _, e in ipairs(w.log) do
		samples[#samples + 1] = e.text
	end
	local alphabet = "1|BUY23SPINGAMHELLO0123456789abcdef-.\0\255"
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
	end
	for _, bad in ipairs({ 42, {}, true }) do
		t.ok(pcall(p.session.onMessage, p.session, "Olga", bad), "non-text")
	end
	t.ok(pcall(p.session.onMessage, p.session, "Olga", nil), "nil text")
	t.ok(Ledger.replay(GUILD, "Pia", account(p, "Pia").entries), "account still replays")
end)
