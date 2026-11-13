local t, ns = ...
local Pack, Ledger, Engine = ns.Pack, ns.Ledger, ns.Engine

local SEED = string.rep("5", 32)
local LINE_T2 = "GSLOTS1;L=0;R=1;E=10,50,100;G=3;T=T2"

local function purchase(id, tokens)
	return Ledger.encode({
		type = "B", buyId = id, officer = "Olga", tokens = tokens or 1000, commit = Engine.commit(SEED),
		seed = SEED, nonce = string.rep("7", 32), time = 1234, line = LINE_T2,
	})
end

local function same(got, want, msg)
	t.ok(got, msg .. ": decoded")
	t.eq(#got, #want, msg .. ": count")
	for i = 1, #want do
		t.eq(got[i], want[i], msg .. ": entry " .. i)
	end
end

local function roundTrip(entries, msg)
	local text = Pack.encode(entries)
	same(Pack.decode(text), entries, msg)
	return text
end

t.test("short forms for in-sequence level-0 spins and gamble steps", function()
	local entries = {
		purchase("00000000000000a1"),
		"S|1|10|0|ok|", "S|2|10|0|ok|", "S|3|10|0|ok|",
		"G|3|1|0|ok|", "G|3|2|0|ok|",
		"S|4|50|0|ok|",
		"G|4|1|0|ok|",
		"S|5|10|0|ok|",
	}
	local text = roundTrip(entries, "mixed")
	t.eq(text, "=" .. entries[1] .. "\ns10*3\ng*2\ns50\ng\ns10", "packed text")
end)

t.test("everything out of the short forms is written verbatim", function()
	local entries = {
		purchase("00000000000000a1"),
		"S|1|10|0|ok|",
		"S|3|10|0|ok|", -- out of sequence
		"S|4|10|0|ok|", -- in sequence after the raw S
		"S|5|10|0|void|", -- void
		"G|5|1|0|ok|",
		"G|5|3|0|ok|", -- step out of sequence
		"G|5|4|0|ok|", -- continues from the raw step
		"S|6|10|3|ok|Anna:0123456789abcdef,Bert:0123456789abcdef", -- contributions
		"S|7|10|0|ok|",
		"P|00000000000000b1|Olga|100|500|1300",
		"S|8|10|0|ok|", -- n carries across a payout
		purchase("00000000000000a2", 50),
		"G|8|1|0|ok|", -- g carries across a purchase
		"S|08|10|0|ok|", -- not canonical: verbatim
		"S|9|010|0|ok|",
	}
	local text = roundTrip(entries, "raw items")
	t.ok(text:find("\n=S|3|10|0|ok|\ns10\n", 1, true), "raw spin sets n")
	t.ok(text:find("\n=G|5|3|0|ok|\ng\n", 1, true), "raw step sets g")
	t.ok(text:find("\n=S|5|10|0|void|\n", 1, true), "void verbatim")
	t.ok(text:find("\n=P|", 1, true), "payout verbatim")
end)

t.test("gamble steps before any spin and empty lists", function()
	roundTrip({ "G|0|1|0|ok|" }, "gamble before spin") -- the short form for n = 0
	roundTrip({}, "empty")
	roundTrip({ "S|1|10|0|ok|" }, "one spin")
	roundTrip({ "x", "=", "\255" }, "odd texts")
end)

t.test("a pseudo-random account round trips", function()
	local x = 4242
	local function r(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return x % n
	end
	for _ = 1, 20 do
		local entries, n, g = { purchase("00000000000000a1") }, 0, 0
		for _ = 1, r(300) + 1 do
			local k = r(10)
			if k < 5 then
				n, g = n + 1, 0
				entries[#entries + 1] = "S|" .. n .. "|" .. ({ 10, 50, 100 })[r(3) + 1] .. "|0|ok|"
			elseif k < 8 then
				g = g + 1
				entries[#entries + 1] = "G|" .. n .. "|" .. g .. "|0|ok|"
			elseif k == 8 then
				entries[#entries + 1] = "P|" .. string.format("%016x", r(100000)) .. "|Olga|1|1|1"
			else
				n = n + r(3)
				entries[#entries + 1] = "S|" .. n .. "|10|0|" .. (r(2) == 0 and "void" or "ok") .. "|"
				g = 0
			end
		end
		roundTrip(entries, "random")
	end
end)

t.test("decode rejects malformed text without raising", function()
	local bad = {
		"\n", "s10\n", "\ns10", "s", "s0", "s010", "s10*", "s10*1", "s10*0", "s10*02", "s10*x",
		"g*", "g*1", "g1", "x", "=", "=S|1|10|0|ok|\n\n", "s10*99999999999999999",
		"s" .. string.rep("9", 20), "q", "S|1|10|0|ok|", "g**2",
	}
	for _, text in ipairs(bad) do
		local ok, entries = pcall(Pack.decode, text)
		t.ok(ok, "raised on " .. text)
		t.eq(entries, nil, "rejects " .. text:gsub("\n", "\\n"))
	end
	t.eq(Pack.decode(nil), nil, "nil")
	t.eq(Pack.decode(42), nil, "number")
	-- A run past the spin limit after a raw spin with a huge number.
	t.eq(Pack.decode("=S|99999999999999999999|10|0|ok|\ns10"), nil, "no short form after a huge number")
	local x = 99
	local function r(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return x % n
	end
	local alphabet = "=sg*|\n0123456789SGBPok"
	for _ = 1, 3000 do
		local parts = {}
		for i = 1, r(40) do
			local c = r(#alphabet) + 1
			parts[i] = alphabet:sub(c, c)
		end
		t.ok(pcall(Pack.decode, table.concat(parts)), "random text")
	end
end)

t.test("decode stops at a limit of entries", function()
	local entries, code = Pack.decode("s10*1000000", 1000)
	t.eq(entries, nil, "over the limit")
	t.eq(code, "too_many", "code")
	t.eq(#Pack.decode("s10*1000", 1000), 1000, "at the limit")
end)

t.test("split and join", function()
	local text = string.rep("abcdefghij", 45) -- 450 bytes
	local chunks = Pack.split(text)
	t.eq(#chunks, 3, "three chunks of 200")
	t.eq(#chunks[1], 200, "first")
	t.eq(#chunks[3], 50, "last")
	t.eq(Pack.join(chunks), text, "join")
	t.eq(#Pack.split(text, 100), 5, "size 100")
	t.eq(#Pack.split(string.rep("x", 200)), 1, "exactly one chunk")
	t.eq(#Pack.split(""), 0, "empty text, no chunks")
end)

t.test("1000 level-0 spins with some gamble steps pack well under 3 KB", function()
	-- A real T2 account: the gamble steps follow from the ledger.
	local state = Ledger.start("Test Guild", "Pia")
	local entries = { purchase("00000000000000a1", 100000) }
	assert(Ledger.apply(state, Ledger.decode(entries[1])))
	local steps = 0
	for n = 1, 1000 do
		local e = { type = "S", n = n, stake = 10, A = 0, status = "ok", contribs = "" }
		assert(Ledger.apply(state, e))
		entries[#entries + 1] = Ledger.encode(e)
		if state.pending > 0 and n % 2 == 0 then
			local gstep = { type = "G", n = n, g = 1, A = 0, status = "ok", contribs = "" }
			assert(Ledger.apply(state, gstep))
			entries[#entries + 1] = Ledger.encode(gstep)
			steps = steps + 1
		end
	end
	t.ok(steps > 20, "some gamble steps")
	local text = roundTrip(entries, "1000 spins")
	t.ok(#text < 2000, "packed size " .. #text)
	t.ok(Ledger.replay("Test Guild", "Pia", Pack.decode(text)), "replays")
end)
