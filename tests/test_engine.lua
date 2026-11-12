local t, ns = ...
local Engine, Sha256, Tables = ns.Engine, ns.Sha256, ns.Tables

-- Literal values below were computed independently with Python's hashlib/hmac from the
-- formulas in docs/core-spec.md section 5.
local SEED = "0123456789abcdef0123456789abcdef"
local NONCE = "fedcba9876543210fedcba9876543210"
local BUY = "00112233aabbccdd"
local K = "527ebd46fa51ecd5e06dfae1b8d355459ebe986607484e404a94dff357807c16"
local T1 = Tables.get("T1")

t.test("commit is the SHA-256 of the seed text", function()
	t.eq(Engine.commit(SEED), "3eb1bd439947eb762998e566ccc2e099c791118b2f40579cc4f7da2b5061b7f9")
end)

t.test("purchaseKey hashes GS1|K|buyId|seed|nonce", function()
	t.eq(Engine.purchaseKey(BUY, SEED, NONCE), K)
end)

t.test("witnessValue is the first 16 hex chars of the HMAC over the request", function()
	local v = Engine.witnessValue("aaaaaaaaaaaaaaaabbbbbbbbbbbbbbbb", "Alice", "spin", 7, 0, 50,
		"0123456789abcdef0123456789abcdef")
	t.eq(v, "be881c0c2b8bba7d")
end)

t.test("lot reads the first 8 hex chars as a number", function()
	t.eq(Engine.lot("Bob", "Alice", "gam", 7, 2), 132085698)
end)

t.test("lot stays a plain non-negative number above 2^31", function()
	-- Search deterministically for a witness name whose lot is >= 2^31.
	local found
	for i = 1, 200 do
		local l = Engine.lot("W" .. i, "Alice", "spin", 1, 0)
		t.ok(l >= 0 and l <= 4294967295 and l % 1 == 0, "range")
		if l >= 2147483648 then found = l end
	end
	t.ok(found, "some lot above 2^31")
end)

t.test("drawn: everyone when A <= Z, else lot below floor(Z * 2^32 / A)", function()
	t.eq(Engine.drawn(4294967295, 7, 7), true, "A == Z")
	t.eq(Engine.drawn(4294967295, 1, 7), true, "A < Z")
	-- Z = 7, A = 14: limit = 2^31
	t.eq(Engine.drawn(2147483647, 14, 7), true, "just below")
	t.eq(Engine.drawn(2147483648, 14, 7), false, "at limit")
	-- Z = 7, A = 10000: limit = floor(7 * 2^32 / 10000) = 3006477
	t.eq(Engine.drawn(3006476, 10000, 7), true)
	t.eq(Engine.drawn(3006477, 10000, 7), false)
	t.eq(Engine.drawn(0, 10000, 13), true)
end)

t.test("contribs sorts by name and joins name:value", function()
	t.eq(Engine.contribs({}), "", "empty")
	t.eq(Engine.contribs({
		{ name = "Carol", value = "8899aabbccddeeff", lot = 5 },
		{ name = "Bob", value = "0011223344556677", lot = 9 },
	}), "Bob:0011223344556677,Carol:8899aabbccddeeff")
end)

t.test("contribs compares names by byte value", function()
	t.eq(Engine.contribs({
		{ name = "b", value = "0000000000000001", lot = 1 },
		{ name = "B", value = "0000000000000002", lot = 2 },
		{ name = "a", value = "0000000000000003", lot = 3 },
	}), "B:0000000000000002,a:0000000000000003,b:0000000000000001")
end)

t.test("contribs keeps the 8 lowest lots, ties by smaller name", function()
	local list = {}
	for i = 1, 10 do
		list[#list + 1] = { name = "N" .. string.char(64 + i), value = string.format("%016x", i), lot = 100 - i }
	end
	-- Lots: NA 99, NB 98, ..., NJ 90. Lowest 8 are NC..NJ.
	-- Add a tie at lot 91 with a name smaller than NI ("NH" has 92) -> "M0" lot 91 ties with NI.
	list[#list + 1] = { name = "M0", value = "00000000000000ff", lot = 91 }
	-- Lowest: NJ 90, NI 91, M0 91, NH 92, NG 93, NF 94, NE 95, ND 96 -> NC (97) drops.
	local text = Engine.contribs(list)
	t.eq(text, "M0:00000000000000ff,ND:0000000000000004,NE:0000000000000005,NF:0000000000000006,"
		.. "NG:0000000000000007,NH:0000000000000008,NI:0000000000000009,NJ:000000000000000a")
	-- Tie at the cut: two names with the same lot, only one fits.
	local tie = {}
	for i = 1, 7 do tie[i] = { name = "X" .. i, value = "0000000000000000", lot = i } end
	tie[8] = { name = "Zed", value = "1111111111111111", lot = 50 }
	tie[9] = { name = "Amy", value = "2222222222222222", lot = 50 }
	local s = Engine.contribs(tie)
	t.ok(s:find("Amy:", 1, true), "smaller name kept")
	t.ok(not s:find("Zed:", 1, true), "larger name dropped")
end)

t.test("contribs does not modify the input list", function()
	local list = { { name = "b", value = "0000000000000001", lot = 1 }, { name = "a", value = "0000000000000002", lot = 2 } }
	Engine.contribs(list)
	t.eq(list[1].name, "b")
end)

t.test("parseContribs accepts empty and well-formed texts", function()
	local l = Engine.parseContribs("")
	t.eq(#l, 0, "empty")
	l = Engine.parseContribs("Bob:0011223344556677,Carol:8899aabbccddeeff")
	t.eq(#l, 2)
	t.eq(l[1].name, "Bob")
	t.eq(l[1].value, "0011223344556677")
	t.eq(l[2].name, "Carol")
end)

t.test("parseContribs rejects unsorted, duplicate and malformed texts", function()
	local bad = {
		"Carol:8899aabbccddeeff,Bob:0011223344556677", -- unsorted
		"Bob:0011223344556677,Bob:8899aabbccddeeff", -- duplicate
		"Bob:0011223344556677,", -- trailing comma
		",Bob:0011223344556677", -- leading comma
		"Bob", -- no value
		"Bob:", -- empty value
		":0011223344556677", -- empty name
		"Bob:0011223344556677:00", -- extra colon
		"Bob:0011223344556677A", -- too long
		"Bob:001122334455667", -- too short
		"Bob:00112233445566AA", -- uppercase hex
		"Bob:00112233445566zz", -- not hex
		"B;b:0011223344556677", -- bad name character
		string.rep("x", 49) .. ":0011223344556677", -- name too long
		"B\tb:0011223344556677", -- control byte
	}
	for _, text in ipairs(bad) do
		local l, code = Engine.parseContribs(text)
		t.eq(l, nil, text)
		t.eq(code, "bad_contribs", text)
	end
	t.ok(Engine.parseContribs(string.rep("x", 48) .. ":0011223344556677"), "48-byte name")
end)

t.test("spin stops match the reference", function()
	local s1, s2, s3 = Engine.spin(K, 1, "", T1)
	t.eq(s1, 22) t.eq(s2, 23) t.eq(s3, 13)
	s1, s2, s3 = Engine.spin(K, 2, "", T1)
	t.eq(s1, 31) t.eq(s2, 12) t.eq(s3, 5)
	s1, s2, s3 = Engine.spin(K, 3, "Bob:0011223344556677,Carol:8899aabbccddeeff", T1)
	t.eq(s1, 12) t.eq(s2, 1) t.eq(s3, 18)
end)

t.test("spin accepts a keyed function in place of K", function()
	local keyed = Sha256.keyed(K)
	local s1, s2, s3 = Engine.spin(keyed, 5, "", T1)
	t.eq(s1, 16) t.eq(s2, 18) t.eq(s3, 20)
end)

t.test("gamble outcome matches the reference", function()
	local c = "Bob:0011223344556677,Carol:8899aabbccddeeff"
	local want = { { false, true }, { false, false }, { true, true }, { false, true } }
	local keyed = Sha256.keyed(K)
	for g = 1, 4 do
		t.eq(Engine.gamble(K, 2, g, ""), want[g][1], "plain g=" .. g)
		t.eq(Engine.gamble(keyed, 2, g, c), want[g][2], "contribs g=" .. g)
	end
end)
