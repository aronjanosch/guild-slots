local t, ns = ...
local Proto = ns.Proto

local H16 = "0123456789abcdef"
local H32 = H16 .. H16
local H64 = H32 .. H32

local SAMPLES = {
	{ "HELLO", { version = "0.3.0", n = 0, head = "-" } },
	{ "HELLO", { version = "1.0-beta", n = 57, head = H32 } },
	{ "BUY1", { buyId = H16, player = "Some Player", tokens = 1000000000, commit = H64, time = 1700000000, lineHash = "deadbeef" } },
	{ "BUY2", { buyId = H16, nonce = H32, head = H64, anchors = 0 } },
	{ "BUY2", { buyId = H16, nonce = H32, head = H64, anchors = 2147483648 } },
	{ "PAYREQ", { reqId = H16, officer = "Some Officer", amount = 9007199254740991, head = H32, count = 2147483648 } },
	{ "LOGREQ", { reqId = H16, player = "Some Player", from = 0 } },
	{ "LOGREQ", { reqId = H16, player = "Some Player", from = 2147483648 } },
	{ "LOG", { reqId = H16, seq = 1, total = 1, payload = "x" } },
	{ "LOG", { reqId = H16, seq = 600, total = 600, payload = "=B|a|b\ns10*3\ng|" .. string.rep("y", 205) } },
	{ "PAY", { reqId = H16, payId = H16, player = "Some Player", amount = 1, balanceAfter = 0, time = 1700000000, head = H32, anchors = 2, n = 0, ck = H16 } },
	{ "PAY", { reqId = H16, payId = H16, player = "P", amount = 1, balanceAfter = 0, time = 1, head = H32, anchors = 2, n = 2147483648, ck = H16 } },
	{ "AUD", { reqId = H16, witness = "Some Witness", player = "Some Player", from = 0, items = "-" } },
	{ "AUD", { reqId = H16, witness = "W", player = "P", from = 12, items = "s12,g12.1,g12.2,s2147483648" } },
	{ "AUDR", { reqId = H16, player = "Some Player", items = "-" } },
	{ "AUDR", { reqId = H16, player = "P", items = "s12=" .. H16 .. "+,g12.1=-,s13=" .. H16 .. "?,g9.5=" .. H16 .. "-" } },
	{ "CSYNC", { player = "Some Player", anchors = 1, head = H32, balance = 0, n = 0, ck = H16, time = 0 } },
	{ "CSYNC", { player = "P", anchors = 2147483648, head = H32, balance = 9007199254740991, n = 2147483648, ck = H16, time = 1700000000 } },
	{ "REJECT", { reqId = H16, player = "Some Player", reason = "declined" } },
	{ "REJECT", { reqId = H16, player = "P", reason = "bad_log" } },
	{ "OSYNC", { player = "Some Player", anchors = 1, head = H32, time = 0 } },
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

t.test("LOG takes everything after the fifth bar as payload", function()
	local msg = Proto.decode("1|LOG|" .. H16 .. "|2|3|a|b||c\nd|")
	t.ok(msg, "decodes")
	t.eq(msg.seq, 2, "seq")
	t.eq(msg.total, 3, "total")
	t.eq(msg.payload, "a|b||c\nd|", "payload with bars and newline")
	t.eq(Proto.encode("LOG", { reqId = H16, seq = 1, total = 1, payload = "a|b" }), "1|LOG|" .. H16 .. "|1|1|a|b", "encode")
	local longest = assert(Proto.encode("LOG", { reqId = H16, seq = 600, total = 600, payload = string.rep("\255", 220) }))
	t.ok(#longest <= Proto.MAX, "longest LOG at 600 chunks fits")
	-- More than 200 chunks still decodes, so that the officer can refuse it as too_large.
	local big = Proto.decode("1|LOG|" .. H16 .. "|1|2147483648|x")
	t.ok(big, "total 2^31 decodes")
	t.eq(big.total, 2147483648, "total")
end)

t.test("encode codes for the payout messages", function()
	local cases = {
		{ "BUY2", { buyId = H16, nonce = H32, head = H32, anchors = 0 }, "short head in BUY2" },
		{ "BUY2", { buyId = H16, nonce = H32, head = H64 }, "BUY2 without anchors" },
		{ "BUY2", { buyId = H16, nonce = H32, head = H64, anchors = 2147483649 }, "anchors too high" },
		{ "PAYREQ", { reqId = H16, officer = "O", amount = 0, head = H32, count = 1 }, "amount 0" },
		{ "PAYREQ", { reqId = H16, officer = "O", amount = 1, head = H32, count = 0 }, "count 0" },
		{ "PAYREQ", { reqId = H16, officer = "O|x", amount = 1, head = H32, count = 1 }, "bad officer" },
		{ "LOGREQ", { reqId = H32, player = "P", from = 0 }, "long reqId" },
		{ "LOGREQ", { reqId = H16, player = "P" }, "LOGREQ without from" },
		{ "LOGREQ", { reqId = H16, player = "P", from = 2147483649 }, "from above 2^31" },
		{ "LOG", { reqId = H16, seq = 0, total = 1, payload = "x" }, "seq 0" },
		{ "LOG", { reqId = H16, seq = 2, total = 1, payload = "x" }, "seq above total" },
		{ "LOG", { reqId = H16, seq = 1, total = 2147483649, payload = "x" }, "total above 2^31" },
		{ "LOG", { reqId = H16, seq = 1, total = 1, payload = "" }, "empty payload" },
		{ "LOG", { reqId = H16, seq = 1, total = 1, payload = string.rep("x", 221) }, "payload 221" },
		{ "LOG", { reqId = H16, seq = 1, total = 1, payload = "a\0b" }, "NUL in payload" },
		{ "PAY", { reqId = H16, payId = H16, player = "P", amount = 0, balanceAfter = 0, time = 1, head = H32, anchors = 1, n = 0, ck = H16 }, "pay 0" },
		{ "PAY", { reqId = H16, payId = H16, player = "P", amount = 1, balanceAfter = 0, time = 1, head = H32, anchors = 0, n = 0, ck = H16 }, "anchors 0" },
		{ "PAY", { reqId = H16, payId = H16, player = "P", amount = 1, balanceAfter = 0, time = 1, head = H32, anchors = 1 }, "PAY without n and ck" },
		{ "PAY", { reqId = H16, payId = H16, player = "P", amount = 1, balanceAfter = 0, time = 1, head = H32, anchors = 1, n = 0, ck = H32 }, "long ck" },
		{ "REJECT", { reqId = H16, player = "P", reason = "nope" }, "unknown reason" },
		{ "OSYNC", { player = "P", anchors = 0, head = H32, time = 1 }, "osync anchors 0" },
	}
	for _, c in ipairs(cases) do
		local text, code = Proto.encode(c[1], c[2])
		t.eq(text, nil, c[3])
		t.eq(code, "bad_field", c[3])
	end
	for _, reason in ipairs({ "declined", "mismatch", "expired", "busy", "too_large", "bad_log" }) do
		t.ok(Proto.encode("REJECT", { reqId = H16, player = "P", reason = reason }), reason)
	end
end)

t.test("decode rejects malformed payout messages", function()
	local bad = {
		"1|BUY2|" .. H16 .. "|" .. H32 .. "|" .. H32,
		"1|BUY2|" .. H16 .. "|" .. H32 .. "|" .. H64,
		"1|BUY2|" .. H16 .. "|" .. H32 .. "|" .. H64 .. "|01",
		"1|LOG|" .. H16 .. "|1|1|",
		"1|LOG|" .. H16 .. "|1|1",
		"1|LOG|" .. H16 .. "|2|1|x",
		"1|LOG|" .. H16 .. "|0|1|x",
		"1|LOG|" .. H16 .. "|1|2147483649|x",
		"1|LOG|" .. H16 .. "|1|1|" .. string.rep("x", 221),
		"1|LOG|" .. H16 .. "|1|1|a\0",
		"1|LOG|" .. H16:upper() .. "|1|1|x",
		"1|PAYREQ|" .. H16 .. "|O|1|" .. H32 .. "|1|",
		"1|PAYREQ|" .. H16 .. "|O|1|" .. H32,
		"1|LOGREQ|" .. H16 .. "|",
		"1|LOGREQ|" .. H16 .. "|P",
		"1|LOGREQ|" .. H16 .. "|P|01",
		"1|PAY|" .. H16 .. "|" .. H16 .. "|P|1|0|1|" .. H32 .. "|0|0|" .. H16,
		"1|PAY|" .. H16 .. "|" .. H16 .. "|P|1|0|1|" .. H32 .. "|1",
		"1|REJECT|" .. H16 .. "|P|other",
		"1|OSYNC|P|1|" .. H32,
	}
	for _, text in ipairs(bad) do
		t.eq(Proto.decode(text), nil, "rejects " .. text)
	end
end)

t.test("the longest valid BUY1 fits into 255 bytes", function()
	-- With the field limits of this milestone no valid message reaches "too_long"; the check in
	-- encode guards future fields.
	local text = assert(Proto.encode("BUY1", { buyId = H16, player = string.rep("x", 48), tokens = 1000000000,
		commit = H64, time = 9007199254740991, lineHash = "deadbeef" }))
	t.ok(#text <= Proto.MAX, "longest BUY1 fits")
end)

t.test("WIT and RES: fields, round trips and limits", function()
	t.eq(Proto.encode("WIT", { player = "Pia", kind = "spin", n = 7, g = 0, value = H16 }),
		"1|WIT|Pia|spin|7|0|" .. H16, "WIT text")
	t.eq(Proto.encode("RES", { kind = "gam", n = 7, g = 2, status = "void", who = "-", head = H32 }),
		"1|RES|gam|7|2|void|-|" .. H32, "RES text")
	local good = {
		{ "WIT", { player = string.rep("x", 48), kind = "gam", n = 2147483648, g = 5, value = H16 } },
		{ "RES", { kind = "spin", n = 1, g = 0, status = "ok", who = "abcd", head = H32 } },
		{ "RES", { kind = "gam", n = 1, g = 1, status = "ok", who = string.rep("0123", 8), head = H32 } },
	}
	for _, s in ipairs(good) do
		local text = assert(Proto.encode(s[1], s[2]))
		t.ok(#text <= Proto.MAX, "fits")
		local msg = Proto.decode(text)
		t.ok(msg, "decodes " .. text)
		for k, v in pairs(s[2]) do
			t.eq(msg[k], v, s[1] .. "." .. k)
		end
	end
	local bad = {
		{ "WIT", { player = "Pia", kind = "spun", n = 1, g = 0, value = H16 } },
		{ "WIT", { player = "Pia", kind = "spin", n = 1, g = 1, value = H16 } }, -- a spin has g 0
		{ "WIT", { player = "Pia", kind = "gam", n = 1, g = 0, value = H16 } }, -- a step has g >= 1
		{ "WIT", { player = "Pia", kind = "gam", n = 1, g = 6, value = H16 } },
		{ "WIT", { player = "Pia", kind = "spin", n = 0, g = 0, value = H16 } },
		{ "WIT", { player = "Pia", kind = "spin", n = 1, g = 0, value = H32 } },
		{ "WIT", { player = "P|a", kind = "spin", n = 1, g = 0, value = H16 } },
		{ "RES", { kind = "spin", n = 1, g = 0, status = "fine", who = "-", head = H32 } },
		{ "RES", { kind = "spin", n = 1, g = 0, status = "ok", who = "", head = H32 } },
		{ "RES", { kind = "spin", n = 1, g = 0, status = "ok", who = "abc", head = H32 } },
		{ "RES", { kind = "spin", n = 1, g = 0, status = "ok", who = "ABCD", head = H32 } },
		{ "RES", { kind = "spin", n = 1, g = 0, status = "ok", who = string.rep("0123", 9), head = H32 } },
		{ "RES", { kind = "spin", n = 1, g = 0, status = "ok", who = "-", head = H16 } },
	}
	for i, s in ipairs(bad) do
		local _, code = Proto.encode(s[1], s[2])
		t.eq(code, "bad_field", "bad " .. i)
	end
	t.eq(Proto.decode("1|WIT|Pia|spin|1|1|" .. H16), nil, "decode checks kind and g")
	t.eq(Proto.decode("1|RES|spin|1|0|ok|abcde|" .. H32), nil, "decode checks who")
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
	local alphabet = "1|BUYSPINGAMHELLOPAYREQLOGJCTOSYNCAUDRCS=+?.0123456789abcdef-.:;,\n\0\255 "
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

-- Milestone 5: audit messages and checkpoints (docs/witness-spec.md section 1) ------------------

t.test("auditItems parses AUD and AUDR item lists", function()
	local list = Proto.auditItems("s12,g12.1,g7.5")
	t.eq(#list, 3, "three items")
	t.eq(list[1].kind, "spin", "spin kind")
	t.eq(list[1].n, 12, "spin n")
	t.eq(list[1].g, 0, "spin g is 0")
	t.eq(list[1].value, nil, "no value in an AUD list")
	t.eq(list[1].flag, nil, "no flag in an AUD list")
	t.eq(list[2].kind, "gam", "gamble kind")
	t.eq(list[2].n, 12, "gamble n")
	t.eq(list[2].g, 1, "gamble g")
	t.eq(list[3].g, 5, "step 5")

	list = Proto.auditItems("s3=" .. H16 .. "+,g3.1=-,s4=" .. H16 .. "?,s5=fedcba9876543210-")
	t.eq(#list, 4, "four answers")
	t.eq(list[1].value, H16, "value")
	t.eq(list[1].flag, "+", "included")
	t.eq(list[2].kind, "gam", "no-record item kind")
	t.eq(list[2].value, nil, "no record: no value")
	t.eq(list[2].flag, nil, "no record: no flag")
	t.eq(list[3].flag, "?", "no RES seen")
	t.eq(list[4].value, "fedcba9876543210", "value 4")
	t.eq(list[4].flag, "-", "left out")

	t.eq(#Proto.auditItems("-"), 0, "dash is the empty list")
	local eight = {}
	for i = 1, 8 do eight[i] = "s" .. i end
	t.eq(#Proto.auditItems(table.concat(eight, ",")), 8, "eight items")
end)

t.test("auditItems rejects malformed lists", function()
	local nine = {}
	for i = 1, 9 do nine[i] = "s" .. i end
	local bad = {
		"", ",", "s1,", ",s1", "s0", "s01", "s", "g1", "g1.", "g1.0", "g1.6", "g1.01", "g0.1", "x1",
		"s2147483649", "s1=" .. H16, "s1=" .. H16 .. "*", "s1=" .. H16:upper() .. "+", "s1=" .. H32 .. "+",
		"s1=", "s1=--", "s1,s2=-", "s1=-,s2", "--", "- ", "s1 ", table.concat(nine, ","), "s1|s2",
	}
	for _, text in ipairs(bad) do
		t.eq(Proto.auditItems(text), nil, "rejects '" .. text .. "'")
	end
	t.eq(Proto.auditItems(nil), nil, "nil")
	t.eq(Proto.auditItems(12), nil, "number")
end)

t.test("AUD carries only AUD items and AUDR only answers", function()
	local answers = "s1=" .. H16 .. "+"
	t.eq(Proto.encode("AUD", { reqId = H16, witness = "W", player = "P", from = 0, items = answers }), nil, "answers in AUD")
	t.eq(Proto.encode("AUDR", { reqId = H16, player = "P", items = "s1" }), nil, "AUD items in AUDR")
	t.eq(Proto.decode("1|AUD|" .. H16 .. "|W|P|0|" .. answers), nil, "decode answers in AUD")
	t.eq(Proto.decode("1|AUDR|" .. H16 .. "|P|s1,g1.1"), nil, "decode AUD items in AUDR")
	t.eq(Proto.decode("1|AUD|" .. H16 .. "|W|P|0|"), nil, "empty items field")
	t.eq(Proto.decode("1|AUD|" .. H16 .. "|W|P|2147483649|s1"), nil, "from above 2^31")
	t.eq(Proto.decode("1|AUDR|" .. H16 .. "|P"), nil, "AUDR without items")
	local msg = Proto.decode("1|AUDR|" .. H16 .. "|P|" .. answers .. ",g1.1=-")
	t.ok(msg, "AUDR decodes")
	t.eq(msg.items, answers .. ",g1.1=-", "items stay text")
	t.eq(#Proto.auditItems(msg.items), 2, "and parse")
end)

t.test("CSYNC field limits", function()
	local base = { player = "P", anchors = 1, head = H32, balance = 0, n = 0, ck = H16, time = 0 }
	local function with(k, v)
		local c = {}
		for key, val in pairs(base) do c[key] = val end
		c[k] = v
		return c
	end
	t.ok(Proto.encode("CSYNC", base), "base")
	t.eq(Proto.encode("CSYNC", with("anchors", 0)), nil, "anchors 0")
	t.eq(Proto.encode("CSYNC", with("balance", 9007199254740992)), nil, "balance above 2^53-1")
	t.eq(Proto.encode("CSYNC", with("n", 2147483649)), nil, "n above 2^31")
	t.eq(Proto.encode("CSYNC", with("ck", H32)), nil, "ck 32 hex")
	t.eq(Proto.encode("CSYNC", with("head", H64)), nil, "full head")
	t.eq(Proto.decode("1|CSYNC|P|1|" .. H32 .. "|0|0|" .. H16), nil, "time missing")
end)

t.test("an AUDR with eight long items exceeds 255 bytes and encode says so", function()
	local items = {}
	for i = 1, 8 do items[i] = "g" .. (2147483640 + i) .. ".5=" .. H16 .. "+" end
	local text, code = Proto.encode("AUDR", { reqId = H16, player = string.rep("p", 48), items = table.concat(items, ",") })
	t.eq(text, nil, "too long")
	t.eq(code, "too_long", "code")
end)
