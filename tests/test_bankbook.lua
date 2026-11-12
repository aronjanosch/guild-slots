local t, ns = ...
local Book = ns.BankBook

local HOUR = 3600
-- A server time a little after the start of an hour.
local T0 = 470000 * HOUR + 600

local function dep(name, copper, hoursAgo, kind)
	return { kind = kind or "deposit", name = name, copper = copper, hoursAgo = hoursAgo }
end

-- The open deposits for a log read at `now`.
local function open(book, log, now)
	return Book.open(book, Book.deposits(log, now), now)
end

t.test("bank book: only deposits with a name and an amount count", function()
	local list = Book.deposits({
		dep("Bob Jones", 50000, 0),
		dep("Bob Jones", 20000, 1, "withdraw"),
		dep("Carol", 0, 0),
		dep(nil, 100, 0),
		dep("Dave", 100, -1),
		dep("Erin", 300, 2, "repair"),
	}, T0)
	t.eq(#list, 1, "one deposit")
	t.eq(list[1].name, "Bob Jones", "name")
	t.eq(list[1].copper, 50000, "copper")
	t.eq(list[1].hour, 470000, "absolute hour")
end)

t.test("bank book: open deposits are listed newest first with their age", function()
	local book = {}
	local list = open(book, { dep("Old", 100, 5), dep("New", 200, 0), dep("Mid", 300, 2) }, T0)
	t.eq(#list, 3, "three open")
	t.eq(list[1].name, "New", "newest first")
	t.eq(list[2].name, "Mid", "then the middle one")
	t.eq(list[3].name, "Old", "oldest last")
	t.eq(list[3].hoursAgo, 5, "age in hours")
	t.ok(list[1].key ~= list[2].key, "distinct keys")
end)

t.test("bank book: a handled deposit seen again an hour later is not new", function()
	local book = {}
	local list = open(book, { dep("Bob Jones", 50000, 0) }, T0)
	Book.handle(book, list[1], T0, "buy1")
	t.eq(#open(book, { dep("Bob Jones", 50000, 0) }, T0), 0, "handled at once")
	t.eq(#open(book, { dep("Bob Jones", 50000, 1) }, T0 + HOUR), 0, "an hour later")
	-- The log rounds the age: the same deposit may read one hour off either way.
	t.eq(#open(book, { dep("Bob Jones", 50000, 0) }, T0 + HOUR), 0, "age rounded down")
	t.eq(#open(book, { dep("Bob Jones", 50000, 2) }, T0 + HOUR), 0, "age rounded up")
end)

t.test("bank book: two equal deposits in one hour count twice", function()
	local book = {}
	local log = { dep("Bob Jones", 10000, 0), dep("Bob Jones", 10000, 0) }
	local list = open(book, log, T0)
	t.eq(#list, 2, "two open")
	Book.handle(book, list[1], T0)
	list = open(book, log, T0)
	t.eq(#list, 1, "one left after handling one")
	Book.handle(book, list[1], T0)
	t.eq(#open(book, log, T0), 0, "none left")
	-- A third identical deposit later is new.
	log[3] = dep("Bob Jones", 10000, 0)
	log[1].hoursAgo, log[2].hoursAgo = 3, 3
	t.eq(#open(book, log, T0 + 3 * HOUR), 1, "a new identical deposit is open")
end)

t.test("bank book: a different amount or name is a different deposit", function()
	local book = {}
	local list = open(book, { dep("Bob Jones", 10000, 0) }, T0)
	Book.handle(book, list[1], T0)
	t.eq(#open(book, { dep("Bob Jones", 10001, 0) }, T0), 1, "other amount")
	t.eq(#open(book, { dep("Bob Smith", 10000, 0) }, T0), 1, "other name")
end)

t.test("bank book: a handled deposit stays handled as the log ages by several hours", function()
	local book = {}
	local list = open(book, { dep("Bob Jones", 70000, 0) }, T0)
	Book.handle(book, list[1], T0)
	for h = 1, 12 do
		t.eq(#open(book, { dep("Bob Jones", 70000, h) }, T0 + h * HOUR), 0, "after " .. h .. " hours")
	end
	-- An identical deposit three hours after the first one is new.
	t.eq(#open(book, { dep("Bob Jones", 70000, 12), dep("Bob Jones", 70000, 9) }, T0 + 12 * HOUR), 1,
		"a later identical deposit is open")
end)

t.test("bank book: a released grant opens the deposit again, a settled one stays handled", function()
	local book = {}
	local log = { dep("Bob Jones", 10000, 0), dep("Carol", 20000, 0) }
	local list = open(book, log, T0)
	t.eq(list[1].name, "Carol", "the later log entry first within an hour")
	Book.handle(book, list[2], T0, "b1")
	Book.handle(book, list[1], T0, "b2")
	t.eq(#open(book, log, T0), 0, "both handled")
	t.eq(Book.release(book, "b1"), true, "released")
	t.eq(Book.release(book, "b1"), false, "only once")
	t.eq(Book.settle(book, "b2"), true, "settled")
	t.eq(Book.release(book, "b2"), false, "a settled grant cannot be released")
	list = open(book, log, T0)
	t.eq(#list, 1, "one open again")
	t.eq(list[1].copper, 10000, "the released one")
	t.eq(#Book.pending(book), 0, "nothing pending")
end)

t.test("bank book: pending grants are listed", function()
	local book = {}
	local list = open(book, { dep("Bob Jones", 10000, 0) }, T0)
	Book.handle(book, list[1], T0, "b9")
	local p = Book.pending(book)
	t.eq(#p, 1, "one pending")
	t.eq(p[1], "b9", "its buyId")
end)

t.test("bank book: records older than 30 days are pruned, the log beyond them is ignored", function()
	local book = {}
	local list = open(book, { dep("Bob Jones", 10000, 0) }, T0)
	Book.handle(book, list[1], T0)
	local later = T0 + 29 * 24 * HOUR
	Book.prune(book, later)
	t.eq(#book.records, 1, "kept within 30 days")
	t.eq(#open(book, { dep("Bob Jones", 10000, 29 * 24) }, later), 0, "still handled")
	later = T0 + 31 * 24 * HOUR
	Book.prune(book, later)
	t.eq(#book.records, 0, "pruned after 30 days")
	-- A deposit that old no longer shows up, so it cannot come back as open.
	t.eq(#open(book, { dep("Bob Jones", 10000, 31 * 24) }, later), 0, "too old to list")
	t.eq(#Book.deposits({ dep("Old", 1, 30 * 24) }, later), 0, "30 days is too old")
end)

t.test("bank book: a broken store does not raise", function()
	local book = { records = { "junk", { name = 5 } } }
	local list = open(book, { dep("Bob Jones", 10000, 0) }, T0)
	t.eq(#list, 1, "listed")
	Book.prune(book, T0)
	t.eq(#Book.pending(book), 0, "no pending")
end)
