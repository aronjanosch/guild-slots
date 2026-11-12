local _, ns = ...

-- Guild ticker queue: entries from the guild session's "ticker" event, shown one after another
-- for a few seconds each on the slot window's footer line. Pure Lua, no WoW API; the window
-- passes its clock. Tested by tests/test_ticker.lua.
--
-- Ticker.new(show, max) -> queue (show: seconds per entry, max: entries waiting at most; older
--                          waiting entries are dropped)
-- queue:push(entry)         entry: { player, win, mult, free, level } (Game/Guild.lua)
-- queue:update(now) -> entry, t   the entry shown at `now` and the seconds since it started, or
--                                 nil when nothing is shown
-- queue:clear()
-- Ticker.text(entry, L, fmt) -> text, level   "<player> wins 5,000 (x100)" or
--                                             "<player> hits 10 free games"

local Ticker = {}
ns.Ticker = Ticker

local Queue = {}
Queue.__index = Queue

function Ticker.new(show, max)
	return setmetatable({ show = show, max = max or 5, list = {}, cur = nil, t0 = 0 }, Queue)
end

function Queue:push(entry)
	if type(entry) ~= "table" then
		return
	end
	local list = self.list
	list[#list + 1] = entry
	while #list > self.max do
		table.remove(list, 1)
	end
end

function Queue:update(now)
	if self.cur and now - self.t0 >= self.show then
		self.cur = nil
	end
	if not self.cur and #self.list > 0 then
		self.cur = table.remove(self.list, 1)
		self.t0 = now
	end
	if self.cur then
		return self.cur, now - self.t0
	end
	return nil
end

function Queue:clear()
	self.list, self.cur = {}, nil
end

function Ticker.text(entry, L, fmt)
	local player = tostring(entry.player or "?")
	local level = entry.level
	if level == "free" and tonumber(entry.free) then
		return string.format(L.TICKER_FREE, player, tonumber(entry.free)), level
	end
	local win = tonumber(entry.win) or 0
	local mult = tonumber(entry.mult)
	if mult then
		local m = mult % 1 == 0 and string.format("%d", mult) or string.format("%.1f", mult)
		return string.format(L.TICKER_WIN, player, fmt(win), m), level
	end
	return string.format(L.TICKER_WIN_PLAIN, player, fmt(win)), level
end
