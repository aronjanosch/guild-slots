local t, ns = ...
local Settings = ns.Settings

local EXAMPLE = "GSLOTS1;L=1;W=2;R=1;E=10,50,100;G=3;C=0;T=T1;X=1000"

-- Asserts that a line is rejected, optionally with a specific code.
local function rejected(line, code)
	local s, got = Settings.parse(line)
	t.eq(s, nil, "accepted " .. tostring(line))
	if code then
		t.eq(got, code, "code for " .. tostring(line))
	end
end

-- Asserts that a line parses and that one field has the given value.
local function field(line, key, want)
	local s, code = Settings.parse(line)
	t.ok(s ~= nil, "rejected " .. line .. " (" .. tostring(code) .. ")")
	t.eq(s[key], want, key .. " in " .. line)
end

t.test("example line parses to the listed values", function()
	local s = Settings.parse(EXAMPLE)
	t.eq(s.L, 1, "L")
	t.eq(s.W, 2, "W")
	t.eq(s.R, 1, "R")
	t.eq(#s.E, 3, "E count")
	t.eq(s.E[1], 10, "E[1]")
	t.eq(s.E[2], 50, "E[2]")
	t.eq(s.E[3], 100, "E[3]")
	t.eq(s.G, 3, "G")
	t.eq(s.C, 0, "C")
	t.eq(s.T, "T1", "T")
	t.eq(s.X, 1000, "X")
	t.eq(s.Z, 2 * 2 + 3, "Z = 2W+3")
end)

t.test("GSLOTS1 alone gives all defaults", function()
	local s = Settings.parse("GSLOTS1")
	t.eq(s.L, 0, "L")
	t.eq(s.W, 2, "W")
	t.eq(s.R, 1, "R")
	t.eq(table.concat(s.E, ","), "10,50,100", "E")
	t.eq(s.G, 3, "G")
	t.eq(s.C, 0, "C")
	t.eq(s.T, "T1", "T")
	t.eq(s.X, 1000, "X")
	t.eq(s.Z, 7, "Z")
	local d = Settings.defaults()
	t.eq(Settings.format(d), Settings.format(s), "defaults equal GSLOTS1")
end)

t.test("defaults returns a fresh table each call", function()
	local a = Settings.defaults()
	a.E[1] = 999
	t.eq(Settings.defaults().E[1], 10, "not shared")
end)

t.test("missing fields take defaults", function()
	local s = Settings.parse("GSLOTS1;L=2")
	t.eq(s.L, 2, "L")
	t.eq(s.W, 2, "W default")
	t.eq(s.G, 3, "G default")
	t.eq(s.X, 1000, "X default")
end)

t.test("W missing from a line still gives Z from the default W", function()
	t.eq(Settings.parse("GSLOTS1;L=0").Z, 7, "Z")
	t.eq(Settings.parse("GSLOTS1;W=5").Z, 13, "Z with W=5")
end)

t.test("unknown keys are ignored", function()
	local s = Settings.parse("GSLOTS1;Q=whatever;L=1;Zed=9")
	t.eq(s.L, 1, "L")
	t.eq(s.W, 2, "W default")
end)

t.test("valid edge values are accepted", function()
	field("GSLOTS1;L=0", "L", 0)
	field("GSLOTS1;L=2", "L", 2)
	field("GSLOTS1;W=1", "W", 1)
	field("GSLOTS1;W=5", "W", 5)
	field("GSLOTS1;R=0", "R", 0)
	field("GSLOTS1;R=9", "R", 9)
	field("GSLOTS1;G=0", "G", 0)
	field("GSLOTS1;G=5", "G", 5)
	field("GSLOTS1;C=1000000000", "C", 1000000000)
	field("GSLOTS1;X=1", "X", 1)
	field("GSLOTS1;X=1000000000", "X", 1000000000)
end)

t.test("E accepts 1 to 5 distinct stakes and one at the maximum", function()
	local s = Settings.parse("GSLOTS1;E=1000000")
	t.eq(#s.E, 1, "one stake")
	t.eq(s.E[1], 1000000, "max stake")
	local five = Settings.parse("GSLOTS1;E=1,2,3,4,5")
	t.eq(#five.E, 5, "five stakes")
end)

t.test("out-of-range and malformed single values are rejected", function()
	rejected("GSLOTS1;L=3", "bad_level")
	rejected("GSLOTS1;W=0", "bad_witnesses")
	rejected("GSLOTS1;W=6", "bad_witnesses")
	rejected("GSLOTS1;R=10", "bad_rank")
	rejected("GSLOTS1;G=6", "bad_gamble")
	rejected("GSLOTS1;C=-1", "bad_cap")
	rejected("GSLOTS1;C=1000000001", "bad_cap")
	rejected("GSLOTS1;X=0", "bad_rate")
	rejected("GSLOTS1;L=", "bad_level")
	rejected("GSLOTS1;L=1.5", "bad_level")
	rejected("GSLOTS1;L=1e3", "bad_level")
	rejected("GSLOTS1;L=01", "bad_level")
	rejected("GSLOTS1;W=+2", "bad_witnesses")
	rejected("GSLOTS1;G=x", "bad_gamble")
end)

t.test("E rejects empty, too many, duplicate, zero and too large stakes", function()
	rejected("GSLOTS1;E=", "bad_stakes")
	rejected("GSLOTS1;E=1,2,3,4,5,6", "bad_stakes")
	rejected("GSLOTS1;E=10,50,10", "bad_stakes")
	rejected("GSLOTS1;E=0", "bad_stakes")
	rejected("GSLOTS1;E=1000001", "bad_stakes")
	rejected("GSLOTS1;E=10,,50", "bad_stakes")
	rejected("GSLOTS1;E=10,50,", "bad_stakes")
	rejected("GSLOTS1;E=1.5", "bad_stakes")
	rejected("GSLOTS1;E=1e3", "bad_stakes")
	rejected("GSLOTS1;E=010", "bad_stakes")
end)

t.test("T must be a known table", function()
	rejected("GSLOTS1;T=T9", "bad_table")
	rejected("GSLOTS1;T=", "bad_table")
	field("GSLOTS1;T=T1", "T", "T1")
end)

t.test("repeated key is rejected", function()
	rejected("GSLOTS1;L=1;L=1", "repeated_key")
	rejected("GSLOTS1;E=10;E=20", "repeated_key")
end)

t.test("a segment without = or with an empty key is rejected", function()
	rejected("GSLOTS1;L", "bad_field")
	rejected("GSLOTS1;=1", "bad_field")
	rejected("GSLOTS1;", "bad_field")
	rejected("GSLOTS1;;L=1", "bad_field")
end)

t.test("a line longer than 120 bytes is rejected", function()
	local long = "GSLOTS1;E=1,2,3,4,5;Q=" .. string.rep("a", 120)
	t.ok(#long > 120, "fixture is long")
	rejected(long, "too_long")
	local exact = "GSLOTS1;Q=" .. string.rep("a", 120 - #"GSLOTS1;Q=")
	t.eq(#exact, 120, "fixture is exactly 120")
	t.ok(Settings.parse(exact) ~= nil, "exactly 120 bytes accepted")
end)

t.test("a line containing | or a control byte is rejected", function()
	rejected("GSLOTS1;L=1|", "bad_char")
	rejected("GSLOTS1;L=1\t", "bad_char")
	rejected("GSLOTS1;L=1\0", "bad_char")
	rejected("GSLOTS1;L=1\r", "bad_char")
end)

t.test("a line without the GSLOTS1 prefix is rejected", function()
	rejected("GSLOTS10;L=1", "bad_format")
	rejected("gslots1;L=1", "bad_format")
	rejected("L=1;W=2", "bad_format")
	rejected("", "bad_format")
	rejected(nil, "bad_format")
end)

t.test("E is returned ascending even when written unsorted", function()
	local s = Settings.parse("GSLOTS1;E=100,10,50")
	t.eq(s.E[1], 10, "first")
	t.eq(s.E[2], 50, "second")
	t.eq(s.E[3], 100, "third")
end)

t.test("find picks the line out of a multi-line CRLF info text", function()
	local info = "Welcome to the guild\r\n"
		.. "  \tGSLOTS1;L=1;W=2;R=1;E=10,50,100;G=3;C=0;T=T1;X=1000  \r\n"
		.. "Officers meet on Fridays\r\n"
	t.eq(Settings.find(info), EXAMPLE, "trimmed line")
end)

t.test("find returns nil when the line is absent", function()
	t.eq(Settings.find("Hello\nno settings here"), nil, "absent")
	t.eq(Settings.find(""), nil, "empty")
	t.eq(Settings.find(nil), nil, "nil text")
end)

t.test("find does not match GSLOTS10 or text where GSLOTS1 is not at the line start", function()
	t.eq(Settings.find("GSLOTS10;L=1"), nil, "GSLOTS10")
	t.eq(Settings.find("note: GSLOTS1;L=1"), nil, "not at line start")
	t.eq(Settings.find("xGSLOTS1;L=1\nmore"), nil, "prefix char before")
end)

t.test("find accepts a bare GSLOTS1 line", function()
	t.eq(Settings.find("hi\nGSLOTS1\n"), "GSLOTS1", "bare prefix")
end)

t.test("format is canonical and parses back to equal settings", function()
	local s = Settings.parse("GSLOTS1;E=100,10;L=2;X=5")
	local line = Settings.format(s)
	t.eq(line, "GSLOTS1;L=2;W=2;R=1;E=10,100;G=3;C=0;T=T1;X=5", "canonical form")
	local back = Settings.parse(line)
	t.eq(Settings.format(back), line, "round trip")
	for _, key in ipairs({ "L", "W", "R", "G", "C", "T", "X", "Z" }) do
		t.eq(back[key], s[key], key)
	end
	t.eq(#back.E, #s.E, "E length")
	for i = 1, #s.E do
		t.eq(back.E[i], s.E[i], "E " .. i)
	end
end)

t.test("format of the example line is the example line", function()
	t.eq(Settings.format(Settings.parse(EXAMPLE)), EXAMPLE, "example")
end)

t.test("format does not reorder the caller's stake list", function()
	local s = Settings.parse("GSLOTS1;E=100,10")
	s.E = { 100, 10 }
	Settings.format(s)
	t.eq(s.E[1], 100, "untouched")
end)

t.test("format rejects settings that would not parse", function()
	local s = Settings.defaults()
	s.L = 7
	local line, code = Settings.format(s)
	t.eq(line, nil, "invalid level")
	t.eq(code, "bad_level", "code")
	t.eq(Settings.format(nil), nil, "not a table")
end)
