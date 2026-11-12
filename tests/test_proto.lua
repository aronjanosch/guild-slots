local t, ns = ...
local Proto = ns.Proto

local H16 = "0123456789abcdef"
local H32 = H16 .. H16
local H64 = H32 .. H32

local SAMPLES = {
	{ "HELLO", { version = "0.3.0", n = 0, head = "-" } },
	{ "HELLO", { version = "1.0-beta", n = 57, head = H32 } },
	{ "BUY1", { buyId = H16, player = "Some Player", tokens = 1000000000, commit = H64, time = 1700000000, lineHash = "deadbeef" } },
	{ "BUY2", { buyId = H16, nonce = H32, head = H32 } },
	{ "BUY3", { buyId = H16, seed = H32 } },
	{ "SPIN", { n = 2147483648, stake = 1000000, level = 2, head = H32, A = 10000 } },
	{ "GAM", { n = 1, g = 5, amount = 9007199254740991, level = 0, head = H32, A = 0 } },
}

t.test("constants", function()
	t.eq(Proto.VERSION, "1", "version")
	t.eq(Proto.PREFIX, "GSLOTS", "prefix")
	t.eq(Proto.MAX, 255, "max")
end)

t.test("encode writes version, type and fields in spec order", function()
	t.eq(Proto.encode("BUY3", { buyId = H16, seed = H32 }), "1|BUY3|" .. H16 .. "|" .. H32, "BUY3")
	t.eq(Proto.encode("HELLO", { version = "0.3.0", n = 0, head = "-" }), "1|HELLO|0.3.0|0|-", "HELLO")
	t.eq(Proto.encode("SPIN", { n = 12, stake = 50, level = 0, head = H32, A = 0 }),
		"1|SPIN|12|50|0|" .. H32 .. "|0", "SPIN")
	t.eq(Proto.encode("GAM", { n = 3, g = 1, amount = 10000000000, level = 0, head = H32, A = 0 }),
		"1|GAM|3|1|10000000000|0|" .. H32 .. "|0", "large amount without exponent")
end)

t.test("decode(encode(x)) gives x back for every type", function()
	for _, s in ipairs(SAMPLES) do
		local text = assert(Proto.encode(s[1], s[2]))
		local msg = Proto.decode(text)
		t.ok(msg, "decodes " .. text)
		t.eq(msg.type, s[1], "type")
		local count = 0
		for k, v in pairs(s[2]) do
			t.eq(msg[k], v, s[1] .. "." .. k)
			count = count + 1
		end
		for k in pairs(msg) do
			t.ok(k == "type" or s[2][k] ~= nil, "no extra field " .. k)
		end
		t.ok(count > 0)
	end
end)

t.test("encode codes", function()
	local _, code = Proto.encode("NOPE", {})
	t.eq(code, "bad_type", "unknown type")
	_, code = Proto.encode("BUY3", { buyId = H16 })
	t.eq(code, "bad_field", "missing field")
	_, code = Proto.encode("BUY3", { buyId = "ABCDEF0123456789", seed = H32 })
	t.eq(code, "bad_field", "uppercase hex")
	_, code = Proto.encode("BUY1", { buyId = H16, player = "A", tokens = 0, commit = H64, time = 1, lineHash = "deadbeef" })
	t.eq(code, "bad_field", "tokens 0")
	_, code = Proto.encode("BUY1", { buyId = H16, player = "A|B", tokens = 1, commit = H64, time = 1, lineHash = "deadbeef" })
	t.eq(code, "bad_field", "name with bar")
	_, code = Proto.encode("SPIN", { n = 1.5, stake = 10, level = 0, head = H32, A = 0 })
	t.eq(code, "bad_field", "fraction")
	_, code = Proto.encode("SPIN", { n = "1", stake = 10, level = 0, head = H32, A = 0 })
	t.eq(code, "bad_field", "number as text")
	_, code = Proto.encode("GAM", { n = 1, g = 6, amount = 10, level = 0, head = H32, A = 0 })
	t.eq(code, "bad_field", "g 6")
	_, code = Proto.encode("HELLO", { version = "1_0", n = 0, head = "-" })
	t.eq(code, "bad_field", "version char")
	_, code = Proto.encode("HELLO", { version = "12345678901234567", n = 0, head = "-" })
	t.eq(code, "bad_field", "version too long")
end)

t.test("the longest valid BUY1 fits into 255 bytes", function()
	-- With the field limits of this milestone no valid message reaches "too_long"; the check in
	-- encode guards future fields.
	local text = assert(Proto.encode("BUY1", { buyId = H16, player = string.rep("x", 48), tokens = 1000000000,
		commit = H64, time = 9007199254740991, lineHash = "deadbeef" }))
	t.ok(#text <= Proto.MAX, "longest BUY1 fits")
end)

t.test("decode rejects everything that is not exactly a known message", function()
	local bad = {
		"", "1", "1|", "2|BUY3|" .. H16 .. "|" .. H32, "1|NOPE|x", "1|BUY3|" .. H16,
		"1|BUY3|" .. H16 .. "|" .. H32 .. "|", "1|BUY3|" .. H16 .. "|" .. H32 .. "|x",
		"1|SPIN|01|10|0|" .. H32 .. "|0", "1|SPIN|0|10|0|" .. H32 .. "|0", "1|SPIN|1|+10|0|" .. H32 .. "|0",
		"1|SPIN|1|10|3|" .. H32 .. "|0", "1|SPIN|1|10|0|" .. H32 .. "|10001", "1|SPIN|1|1e3|0|" .. H32 .. "|0",
		"1|SPIN|2147483649|10|0|" .. H32 .. "|0", "1|GAM|1|1|9007199254740992|0|" .. H32 .. "|0",
		"1|GAM|1|1|12345678901234567|0|" .. H32 .. "|0",
		"1|HELLO|0.3|0|abc", "1|HELLO||0|-", "1|HELLO|0.3|-1|-",
		"1|BUY2|" .. H16 .. "|" .. H32 .. "|" .. H32:upper(),
		"1|BUY3|" .. H16 .. "|" .. H32 .. "\0",
		"1|BUY1|" .. H16 .. "||1|" .. H64 .. "|1|deadbeef",
		"1|BUY1|" .. H16 .. "|A\1B|1|" .. H64 .. "|1|deadbeef",
		"1|HELLO|" .. string.rep("1", 300) .. "|0|-",
	}
	for _, text in ipairs(bad) do
		t.eq(Proto.decode(text), nil, "rejects " .. text)
	end
	t.eq(Proto.decode(nil), nil, "nil")
	t.eq(Proto.decode(42), nil, "number")
	t.eq(Proto.decode({}), nil, "table")
end)

t.test("decode survives random text", function()
	-- A small linear congruential generator keeps the test deterministic without math.random.
	local x = 12345
	local function r(n)
		x = (x * 1103515245 + 12345) % 2147483648
		return x % n
	end
	local alphabet = "1|BUYSPINGAMHELLO0123456789abcdef-.:;,\0\255 "
	for _ = 1, 3000 do
		local parts = {}
		for i = 1, r(80) do
			local c = r(#alphabet) + 1
			parts[i] = alphabet:sub(c, c)
		end
		local text = table.concat(parts)
		local ok = pcall(Proto.decode, text)
		t.ok(ok, "decode raised on " .. text)
	end
	-- Mutations of valid messages: drop or change one byte.
	for _, s in ipairs(SAMPLES) do
		local text = Proto.encode(s[1], s[2])
		for i = 1, #text do
			t.ok(pcall(Proto.decode, text:sub(1, i - 1) .. text:sub(i + 1)), "drop")
			t.ok(pcall(Proto.decode, text:sub(1, i - 1) .. "|" .. text:sub(i + 1)), "bar")
		end
	end
end)

t.test("lineHash is the first 8 hex of Sha256.hex(line)", function()
	-- sha256("abc") = ba7816bf...
	t.eq(Proto.lineHash("abc"), "ba7816bf", "abc")
	t.eq(#Proto.lineHash("GSLOTS1;L=0"), 8, "length")
end)
