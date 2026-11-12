-- Benchmark: cost of Verify.run per entry, to estimate the in-game cost (about 270 us per
-- SHA-256 block in the client today). Not run by tests/run.lua.
--   luajit tests/bench_verify.lua

local function load(count)
	local ns = {}
	for _, name in ipairs({ "Sha256", "Tables", "Settings", "Engine", "Ledger", "Verify" }) do
		assert(loadfile("GuildSlots/Core/" .. name .. ".lua"))("GuildSlots", ns)
		if name == "Sha256" and count then
			-- Count compression blocks: a message of len bytes takes floor((len + 9 + 63) / 64).
			local S, blocks = ns.Sha256, count
			local function n(len) return math.floor((len + 72) / 64) end
			local hex, raw, hmac, hmacRaw, keyed = S.hex, S.raw, S.hmac, S.hmacRaw, S.keyed
			S.hex = function(m) blocks.n = blocks.n + n(#m) return hex(m) end
			S.raw = function(m) blocks.n = blocks.n + n(#m) return raw(m) end
			-- HMAC with a short key: 2 key blocks + inner (64 + len) + outer (64 + 32).
			S.hmac = function(k, m) blocks.n = blocks.n + n(64 + #m) + 2 + 1 return hmac(k, m) end
			S.hmacRaw = function(k, m) blocks.n = blocks.n + n(64 + #m) + 2 + 1 return hmacRaw(k, m) end
			-- Keyed: the two key blocks are hashed once at setup.
			S.keyed = function(k)
				local f = keyed(k)
				blocks.n = blocks.n + 2
				return function(m, r)
					blocks.n = blocks.n + n(64 + #m) - 1 + 1
					return f(m, r)
				end
			end
		end
	end
	return ns
end

local PLAYER, NONCE = "Alice", "fedcba9876543210fedcba9876543210"

local function build(ns, line, spins, witnesses)
	local Ledger, Engine = ns.Ledger, ns.Engine
	local st = Ledger.start("Guild", PLAYER)
	local entries = {}
	local function add(e)
		assert(Ledger.apply(st, e))
		entries[#entries + 1] = e
	end
	local seed = string.format("%032x", 1)
	add({ type = "B", buyId = string.format("%016x", 1), officer = "Officer", tokens = 1000000000,
		commit = Engine.commit(seed), seed = seed, nonce = NONCE, time = 1700000000, line = line })
	local function contribs(kind, n, g, amount)
		local list = {}
		for _, name in ipairs(witnesses) do
			list[#list + 1] = { name = name, lot = 0,
				value = Engine.witnessValue(string.rep("ab", 16), PLAYER, kind, n, g, amount, Ledger.shortHead(st)) }
		end
		return Engine.contribs(list)
	end
	local A = #witnesses > 0 and 3 or 0
	for n = 1, spins do
		add({ type = "S", n = n, stake = 10, A = A, status = "ok", contribs = contribs("spin", n, 0, 10) })
		while st.pending > 0 do
			local g = st.g + 1
			add({ type = "G", n = n, g = g, A = A, status = "ok", contribs = contribs("gam", n, g, st.pending) })
		end
	end
	return entries
end

local function bench(label, line, spins, witnesses)
	local ns = load()
	local entries = build(ns, line, spins, witnesses)
	local input = { guild = "Guild", player = PLAYER, entries = entries, amount = 1,
		isOfficer = function() return true end }
	ns.Verify.run(input) -- warm up (statistics cache)
	local best = math.huge
	for _ = 1, 3 do
		local t0 = os.clock()
		ns.Verify.run(input)
		best = math.min(best, os.clock() - t0)
	end
	local blocks = { n = 0 }
	local counted = load(blocks)
	counted.Verify.run({ guild = "Guild", player = PLAYER, entries = entries, amount = 1,
		isOfficer = function() return true end })
	local perEntry = blocks.n / #entries
	print(string.format("%-28s %6d entries  %8.1f us/entry  %5.2f blocks/entry  ~%6.2f s in game",
		label, #entries, best / #entries * 1e6, perEntry, blocks.n * 270e-6))
end

bench("level 0, 10000 spins", "GSLOTS1;L=0;G=3", 10000, {})
bench("level 1 (W=2), 2000 spins", "GSLOTS1;L=1;W=2;G=3", 2000, { "Wit1", "Wit2" })
