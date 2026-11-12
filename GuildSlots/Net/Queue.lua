local _, ns = ...

-- Send queue for addon messages. Pure: no WoW API, no clock of its own.
-- `send` and `now` are injected. The server allows `capacity` messages per prefix and
-- gives back `refill` per second, so the queue keeps its own count of that budget.
--
-- Result codes from `send`:
--   0   sent: the message leaves the queue, the count drops by one
--   3   throttled: the message stays, the count is set to 0
--   11  addon messages locked: the message stays, retried one second later
--   other, or an error raised by `send`: the message is dropped and `onDrop` is called

local Queue = {}
ns.Queue = Queue

local MAX_BYTES = 255
local MAX_WAITING = 200
local RETRY_DELAY = 1

local Q = {}
Q.__index = Q

-- opts: send (required), now (required), capacity (10), refill (1), onDrop (optional)
function Queue.new(opts)
	assert(type(opts) == "table", "Queue.new needs opts")
	assert(type(opts.send) == "function", "Queue.new needs opts.send")
	assert(type(opts.now) == "function", "Queue.new needs opts.now")
	local capacity = opts.capacity or 10
	return setmetatable({
		send = opts.send,
		now = opts.now,
		capacity = capacity,
		refill = opts.refill or 1,
		onDrop = opts.onDrop,
		count = capacity,
		last = opts.now(),
		items = {},
		head = 1,
		tail = 0,
	}, Q)
end

-- Adds the time since the last refill to the count, up to capacity.
-- The time is only moved forward by what was added, so fractions accumulate.
function Q:_refill()
	local t = self.now()
	if t > self.last then
		self.count = math.min(self.capacity, self.count + (t - self.last) * self.refill)
		self.last = t
	end
end

function Q:pending()
	return self.tail - self.head + 1
end

function Q:budget()
	self:_refill()
	return math.floor(self.count)
end

-- Queues a message. Never calls `send`.
function Q:push(text, channel, target)
	if #text > MAX_BYTES then
		return nil, "too_long"
	end
	if self:pending() >= MAX_WAITING then
		return nil, "full"
	end
	self.tail = self.tail + 1
	self.items[self.tail] = { text = text, channel = channel, target = target }
	return true
end

-- Sends what the budget allows, oldest first. Stops at the first message that has to wait.
function Q:update()
	self:_refill()
	while self.head <= self.tail do
		local m = self.items[self.head]
		if m.retryAt and self.now() < m.retryAt then
			return
		end
		if self.count < 1 then
			return
		end

		local ok, code = pcall(self.send, m.text, m.channel, m.target)
		if not ok then
			code = nil
		end

		if code == 0 then
			self.count = self.count - 1
			self:_pop()
		elseif code == 3 then
			self.count = 0
			return
		elseif code == 11 then
			m.retryAt = self.now() + RETRY_DELAY
			return
		else
			self:_pop()
			if self.onDrop then
				self.onDrop(m.text, code)
			end
		end
	end
end

function Q:_pop()
	self.items[self.head] = nil
	self.head = self.head + 1
end
