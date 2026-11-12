local _, ns = ...

-- Bookkeeping of guild bank deposits the officer has dealt with (pure: plain data in, plain
-- data out, no WoW API). Guild/Bank.lua reads the money log and keeps one book per guild.
--
-- The log has no id and gives the age in whole hours only, so a deposit is known by its name,
-- its amount and the absolute hour it happened in: floor((serverTime - hoursAgo * 3600) / 3600).
-- The age rounds, so a record matches a deposit up to one hour off either way. A record counts
-- how many identical deposits of that hour were handled (granted or dismissed); a deposit is
-- open while the log shows more of it than the records cover.
--
-- book = { records = { { name, copper, hour, n, buys = { [buyId] = true }, at }, ... } }
--   n     deposits handled
--   buys  grants still running; a failed one is released (n - 1), a done one settled
--   at    server time of the last change

local BankBook = {}
ns.BankBook = BankBook

local floor = math.floor

local HOUR = 3600
BankBook.LIMIT = 30 * 24 -- hours a record is kept
BankBook.TOLERANCE = 1 -- hours a record may be off from the log's age
-- Deposits older than this are not listed: a record must outlive the deposit it covers.
local LISTED = BankBook.LIMIT - 2 * BankBook.TOLERANCE

local function records(book)
	if type(book.records) ~= "table" then
		book.records = {}
	end
	return book.records
end

local function valid(r)
	return type(r) == "table" and type(r.name) == "string" and type(r.copper) == "number"
		and type(r.hour) == "number" and type(r.n) == "number"
end

-- entries: { { kind, name, copper, hoursAgo }, ... } as read from the log. Returns the deposits
-- { name, copper, hour } in log order; withdrawals, other kinds and broken entries are left out.
function BankBook.deposits(entries, now)
	local list = {}
	local nowHour = floor(now / HOUR)
	for _, e in ipairs(entries or {}) do
		local ago = e.hoursAgo
		if e.kind == "deposit" and type(e.name) == "string" and e.name ~= "" and type(e.copper) == "number"
			and e.copper >= 1 and e.copper % 1 == 0 and type(ago) == "number" and ago >= 0 then
			local hour = floor((now - ago * HOUR) / HOUR)
			if nowHour - hour <= LISTED then
				list[#list + 1] = { name = e.name, copper = e.copper, hour = hour }
			end
		end
	end
	return list
end

local function sameDeposit(a, b)
	return a.name == b.name and a.copper == b.copper
end

-- The deposits the records do not cover, newest first: { name, copper, hour, hoursAgo, key }.
-- Matching is greedy by hour (oldest first), each deposit taking the earliest record in reach.
function BankBook.open(book, deps, now)
	local nowHour = floor(now / HOUR)
	local recs = records(book)
	local left = {}
	for i, r in ipairs(recs) do
		if valid(r) then
			left[i] = r.n
		end
	end
	local order = {}
	for i, d in ipairs(deps) do
		order[i] = { d = d, i = i }
	end
	table.sort(order, function(a, b)
		if a.d.hour ~= b.d.hour then
			return a.d.hour < b.d.hour
		end
		return a.i < b.i
	end)
	local open, seen = {}, {}
	for _, o in ipairs(order) do
		local d = o.d
		local best
		for i, r in ipairs(recs) do
			if (left[i] or 0) > 0 and sameDeposit(r, d) and math.abs(r.hour - d.hour) <= BankBook.TOLERANCE
				and (not best or r.hour < recs[best].hour) then
				best = i
			end
		end
		if best then
			left[best] = left[best] - 1
		else
			local base = d.name .. "|" .. d.copper .. "|" .. d.hour
			seen[base] = (seen[base] or 0) + 1
			open[#open + 1] = {
				name = d.name, copper = d.copper, hour = d.hour, key = base .. "|" .. seen[base],
				hoursAgo = math.max(0, nowHour - d.hour), order = o.i,
			}
		end
	end
	table.sort(open, function(a, b)
		if a.hour ~= b.hour then
			return a.hour > b.hour
		end
		return a.order > b.order
	end)
	for _, d in ipairs(open) do
		d.order = nil
	end
	return open
end

-- Marks one deposit as handled; buyId: the grant it started (nil: dismissed).
function BankBook.handle(book, dep, now, buyId)
	local recs = records(book)
	local rec
	for _, r in ipairs(recs) do
		if valid(r) and sameDeposit(r, dep) and r.hour == dep.hour then
			rec = r
		end
	end
	if not rec then
		rec = { name = dep.name, copper = dep.copper, hour = dep.hour, n = 0 }
		recs[#recs + 1] = rec
	end
	rec.n = rec.n + 1
	rec.at = now
	if buyId then
		if type(rec.buys) ~= "table" then
			rec.buys = {}
		end
		rec.buys[buyId] = true
	end
	return rec
end

local function withBuy(book, buyId)
	for i, r in ipairs(records(book)) do
		if valid(r) and type(r.buys) == "table" and r.buys[buyId] then
			return r, i
		end
	end
end

-- A grant failed or timed out: its deposit is open again. Returns true when one was released.
function BankBook.release(book, buyId)
	local r, i = withBuy(book, buyId)
	if not r then
		return false
	end
	r.buys[buyId] = nil
	r.n = r.n - 1
	if r.n <= 0 then
		table.remove(book.records, i)
	end
	return true
end

-- A grant went through: the deposit stays handled for good. Returns true when one was found.
function BankBook.settle(book, buyId)
	local r = withBuy(book, buyId)
	if not r then
		return false
	end
	r.buys[buyId] = nil
	return true
end

-- buyIds of the grants still running.
function BankBook.pending(book)
	local list = {}
	for _, r in ipairs(records(book)) do
		if valid(r) and type(r.buys) == "table" then
			for id in pairs(r.buys) do
				list[#list + 1] = id
			end
		end
	end
	table.sort(list)
	return list
end

-- First read of a guild's log on this client: deposits FIRST_READ_HOURS old or older are
-- recorded as handled (auto = true) so old donations do not flood the list; younger ones stay
-- open. Later reads do not call this.
BankBook.FIRST_READ_HOURS = 24
function BankBook.seed(book, deps, now)
	local nowHour = floor(now / HOUR)
	for _, d in ipairs(deps) do
		if nowHour - d.hour >= BankBook.FIRST_READ_HOURS then
			BankBook.handle(book, d, now).auto = true
		end
	end
end

-- Drops records older than LIMIT hours and broken ones.
function BankBook.prune(book, now)
	local nowHour = floor(now / HOUR)
	local recs = records(book)
	for i = #recs, 1, -1 do
		local r = recs[i]
		if not valid(r) or nowHour - r.hour > BankBook.LIMIT then
			table.remove(recs, i)
		end
	end
end
