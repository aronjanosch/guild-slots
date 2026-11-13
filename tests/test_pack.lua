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
	t.ok(text:find("\nS10|0|v|\n", 1, true), "void in sequence takes the dictionary form")
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
	t.eq(#chunks, 3, "three chunks of 220")
	t.eq(#chunks[1], 220, "first")
	t.eq(#chunks[3], 10, "last")
	t.eq(Pack.join(chunks), text, "join")
	t.eq(#Pack.split(text, 100), 5, "size 100")
	t.eq(#Pack.split(string.rep("x", 220)), 1, "exactly one chunk")
	t.eq(#Pack.split(string.rep("x", 221)), 2, "one byte more")
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

-- Milestone 5: dictionary forms and the partial-log header (docs/witness-spec.md section 5) ------

local V1, V2, V0 = "0123456789abcdef", "ffffffffffffffff", "0000000000000000"
-- The same values in the 11-character form, worked out by hand: the top nibble, then five groups
-- of 12 bits as two characters each (A-Z = 0..25, a-z = 26..51, 0-9 = 52..61, - = 62, _ = 63).
local W1, W2, W0 = "AEjRWeJq83v", "P__________", "AAAAAAAAAAA"

t.test("contributions pack into a dictionary and 11-character values", function()
	local entries = {
		purchase("00000000000000a1"),
		"S|1|10|3|ok|Anna:" .. V1 .. ",Bert:" .. V2,
		"G|1|1|3|void|Bert:" .. V0,
		"S|2|10|0|void|",
		"S|3|50|7|ok|Cleo-Realm:" .. V2 .. ",Anna:" .. V0, -- the entry's order, not sorted
		"G|3|1|0|ok|", -- level-0 step after an S item
		"S|4|10|0|ok|",
	}
	local text = roundTrip(entries, "contributions")
	t.eq(text, table.concat({
		"=" .. entries[1],
		"@Anna", "@Bert",
		"S10|3|o|" .. W1 .. "1," .. W2 .. "2",
		"G3|v|" .. W0 .. "2",
		"S10|0|v|",
		"@Cleo-Realm",
		"S50|7|o|" .. W2 .. "3," .. W0 .. "1",
		"g",
		"s10",
	}, "\n"), "packed text")
end)

t.test("entries that do not fit the dictionary forms stay verbatim", function()
	local entries = {
		purchase("00000000000000a1"),
		"S|2|10|3|ok|Anna:" .. V1, -- out of sequence
		"S|3|10|3|ok|Anna:" .. V1:upper(), -- value not lowercase hex
		"S|4|10|3|ok|Anna:" .. V1 .. "0", -- value too long
		"S|5|10|3|ok|Anna" .. V1, -- no colon
		"S|6|10|3|maybe|", -- unknown status
		"S|7|010|3|ok|", -- stake not canonical
		"S|8|10|03|ok|",
		"S|9|10|3|ok|Anna:" .. V1 .. ",", -- trailing comma
		"G|9|2|3|ok|", -- step out of sequence
		"S|10|10|3|ok|A,b:" .. V1, -- name with a comma
		"S|11|10|3|ok|Anna:" .. V1 .. "|x", -- an extra field
	}
	local text = roundTrip(entries, "verbatim")
	t.ok(not text:find("\nS", 1, true) and not text:find("\nG", 1, true), "no dictionary items: " .. text)
	t.ok(not text:find("@", 1, true), "no names")
end)

t.test("a mixed-level account replays after a round trip", function()
	local state = Ledger.start("Test Guild", "Pia")
	local entries = {}
	local function add(e)
		assert(Ledger.apply(state, e))
		entries[#entries + 1] = type(e) == "string" and e or Ledger.encode(e)
	end
	add(Ledger.decode(purchase("00000000000000a1", 100000)))
	for n = 1, 30 do
		add({ type = "S", n = n, stake = 10, A = 0, status = "ok", contribs = "" })
	end
	local buy2 = Ledger.encode({
		type = "B", buyId = "00000000000000a2", officer = "Olga", tokens = 10, commit = Engine.commit(SEED),
		seed = SEED, nonce = string.rep("7", 32), time = 1300, line = "GSLOTS1;L=2;E=10,50,100;G=3;T=T2",
	})
	add(Ledger.decode(buy2))
	for n = 31, 60 do
		local c = n % 3 == 0 and "" or ("Olga:" .. string.format("%016x", n * 7919) .. ",Otto:" .. string.format("%016x", n))
		add({ type = "S", n = n, stake = 10, A = 0, status = c == "" and "void" or "ok", contribs = c })
		if state.pending > 0 then
			add({ type = "G", n = n, g = 1, A = 0, status = "ok", contribs = "Otto:" .. V1 })
		end
	end
	local text = roundTrip(entries, "mixed levels")
	t.eq(select(2, text:gsub("\n@", "")), 2, "two dictionary names")
	local decoded = Pack.decode(text)
	local replayed = Ledger.replay("Test Guild", "Pia", decoded)
	t.ok(replayed, "replays")
	t.eq(replayed.head, state.head, "same head")
	t.ok(#text < #table.concat(entries, "\n") * 0.6, "under 60 % of the raw size: " .. #text .. " of " .. #table.concat(entries, "\n"))
end)

t.test("decode rejects malformed dictionary items", function()
	local B = "=" .. purchase("00000000000000a1") .. "\n"
	local bad = {
		"@", "@A,b", "@A|b", "@Anna\n@Anna", "@" .. string.rep("x", 49),
		"@Anna\nS10|3|o|" .. W1 .. "0", -- index 0
		"@Anna\nS10|3|o|" .. W1 .. "2", -- index beyond the dictionary
		"@Anna\nS10|3|o|" .. W1 .. "01",
		"S10|3|o|" .. W1 .. "1", -- no dictionary
		"@Anna\nS10|3|o|" .. W1:sub(1, 10) .. "1", -- 10 characters
		"@Anna\nS10|3|o|Q" .. W1:sub(2) .. "1", -- first character above 15
		"@Anna\nS10|3|o|" .. W1:sub(1, 10) .. "*1",
		"@Anna\nS10|3|o|" .. W1 .. "1,",
		"@Anna\nS10|3|o|," .. W1 .. "1",
		"@Anna\nS10|3|o|" .. W1,
		"S10|3|x|", "S10|3|ok|", "S0|3|o|", "S010|3|o|", "S10|03|o|", "S10||o|", "S10|3|o", "S10|3|o||",
		"S|3|o|", "S10|10001|o|x",
		"G3|x|", "G03|o|", "G3|o", "G|o|",
	}
	for _, text in ipairs(bad) do
		local ok, entries = pcall(Pack.decode, B .. text)
		t.ok(ok, "raised on " .. text)
		t.eq(entries, nil, "rejects " .. text:gsub("\n", "\\n"))
	end
	-- A huge raw spin leaves n unknown: no dictionary form can follow.
	t.eq(Pack.decode("=S|99999999999999999999|10|0|ok|\nS10|0|v|"), nil, "no S after a huge number")
	t.eq(Pack.decode("=G|1|99999999999999999999|0|ok|\nG0|v|"), nil, "no G after a huge step")
end)

t.test("a partial log carries a header and numbers on from it", function()
	local header = {
		head = string.rep("ab", 32), n = 41,
		payout = "P|00000000000000b1|Olga|100|500|1300",
		purchase = purchase("00000000000000a1"),
	}
	local entries = { "S|42|10|0|ok|", "S|43|10|3|ok|Anna:" .. V1, "G|43|1|0|ok|", "P|00000000000000b2|Olga|1|1|1" }
	local text = Pack.encode(entries, header)
	t.eq(text, table.concat({
		"^" .. header.head .. "|41", header.payout, header.purchase,
		"s10", "@Anna", "S10|3|o|" .. W1 .. "1", "g", "=" .. entries[4],
	}, "\n"), "packed text")
	local got, h = Pack.decode(text)
	same(got, entries, "suffix")
	t.eq(h.head, header.head, "head")
	t.eq(h.n, 41, "n")
	t.eq(h.payout, header.payout, "payout")
	t.eq(h.purchase, header.purchase, "purchase")

	-- An empty suffix.
	got, h = Pack.decode(Pack.encode({}, header))
	t.eq(#got, 0, "no entries")
	t.eq(h.n, 41, "header alone")

	-- A whole account has no header.
	got, h = Pack.decode(Pack.encode({ "S|1|10|0|ok|" }))
	t.eq(#got, 1, "whole account")
	t.eq(h, nil, "no header")
end)

t.test("decode rejects a malformed header", function()
	local P, B = "P|00000000000000b1|Olga|100|500|1300", purchase("00000000000000a1")
	local H = string.rep("ab", 32)
	local bad = {
		"^" .. H .. "|41", "^" .. H .. "|41\n" .. P, "^" .. H .. "|41\n" .. P .. "\n",
		"^" .. H .. "|041\n" .. P .. "\n" .. B, "^" .. H .. "|2147483649\n" .. P .. "\n" .. B,
		"^" .. H:upper() .. "|41\n" .. P .. "\n" .. B, "^" .. H:sub(2) .. "|41\n" .. P .. "\n" .. B,
		"^" .. H .. "\n" .. P .. "\n" .. B, "^" .. H .. "|41|x\n" .. P .. "\n" .. B,
		"^" .. H .. "|41\n" .. B .. "\n" .. P, -- payout and purchase swapped
		"^" .. H .. "|41\n" .. P .. "\n" .. B .. "\n", -- empty item after the header
		"=S|1|10|0|ok|\n^" .. H .. "|41\n" .. P .. "\n" .. B, -- header not first
	}
	for _, text in ipairs(bad) do
		local ok, entries = pcall(Pack.decode, text)
		t.ok(ok, "raised")
		t.eq(entries, nil, "rejects " .. text:gsub("\n", "\\n"))
	end
end)

t.test("decode survives random text with the new item forms", function()
	local x = 7
	local function r(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return x % n
	end
	local alphabet = "=sgSG@^|,*\n0123456789ovAPab_-:ok"
	for _ = 1, 3000 do
		local parts = {}
		for i = 1, r(50) do
			local c = r(#alphabet) + 1
			parts[i] = alphabet:sub(c, c)
		end
		t.ok(pcall(Pack.decode, table.concat(parts)), "random text")
	end
end)
