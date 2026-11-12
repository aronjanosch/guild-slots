local t, ns = ...
local Queue = ns.Queue

-- Fake clock: clock.t is the time in seconds, advanced by the tests.
local function newClock()
	local clock = { t = 0 }
	clock.now = function() return clock.t end
	return clock
end

-- send that returns the given codes in order (a code of "error" raises), then 0 forever.
-- Every call is recorded in `sent` as { text, channel, target }.
local function scripted(sent, ...)
	local codes, i = { ... }, 0
	return function(text, channel, target)
		sent[#sent + 1] = { text, channel, target }
		i = i + 1
		local c = codes[i]
		if c == nil then c = 0 end
		if c == "error" then error("boom") end
		return c
	end
end

t.test("budget starts at capacity and is reported as whole messages", function()
	local clock = newClock()
	local q = Queue.new({ send = scripted({}), now = clock.now, capacity = 10 })
	t.eq(q:budget(), 10, "budget")
	t.eq(q:pending(), 0, "pending")
end)

t.test("budget refills by refill per second up to capacity", function()
	local clock = newClock()
	local sent = {}
	local q = Queue.new({ send = scripted(sent), now = clock.now, capacity = 10, refill = 1 })
	for i = 1, 10 do
		assert(q:push("m" .. i))
	end
	q:update()
	t.eq(#sent, 10, "all ten sent at once")
	t.eq(q:budget(), 0, "budget empty")

	clock.t = 1
	t.eq(q:budget(), 1, "one second later")
	clock.t = 3
	t.eq(q:budget(), 3, "three seconds later")
	clock.t = 1000
	t.eq(q:budget(), 10, "never above capacity")
end)

t.test("fractional time accumulates across calls", function()
	local clock = newClock()
	local sent = {}
	local q = Queue.new({ send = scripted(sent), now = clock.now, capacity = 2, refill = 1 })
	q:push("a")
	q:push("b")
	q:update()
	t.eq(q:budget(), 0, "empty")

	clock.t = 0.5
	t.eq(q:budget(), 0, "half a second is not a message")
	clock.t = 0.75
	t.eq(q:budget(), 0, "three quarters is not a message")
	clock.t = 1
	t.eq(q:budget(), 1, "a full second is one message")
end)

t.test("refill rate other than 1 is honoured", function()
	local clock = newClock()
	local sent = {}
	local q = Queue.new({ send = scripted(sent), now = clock.now, capacity = 4, refill = 2 })
	for _ = 1, 4 do q:push("x") end
	q:update()
	clock.t = 0.5
	t.eq(q:budget(), 1, "two per second, half a second gives one")
end)

t.test("messages go out in first in, first out order with their channel and target", function()
	local clock = newClock()
	local sent = {}
	local q = Queue.new({ send = scripted(sent), now = clock.now })
	q:push("first", "GUILD", nil)
	q:push("second", "WHISPER", "Someone")
	q:push("third", "GUILD", nil)
	q:update()
	t.eq(#sent, 3, "count")
	t.eq(sent[1][1], "first", "order 1")
	t.eq(sent[2][1], "second", "order 2")
	t.eq(sent[3][1], "third", "order 3")
	t.eq(sent[2][2], "WHISPER", "channel")
	t.eq(sent[2][3], "Someone", "target")
	t.eq(q:pending(), 0, "pending after sending")
end)

t.test("code 0 takes one from the budget and removes the message", function()
	local clock = newClock()
	local sent = {}
	local q = Queue.new({ send = scripted(sent), now = clock.now, capacity = 2 })
	q:push("a")
	q:push("b")
	q:push("c")
	q:update()
	t.eq(#sent, 2, "only the budget goes out")
	t.eq(q:budget(), 0, "budget used up")
	t.eq(q:pending(), 1, "one waits")
end)

t.test("code 3 keeps the message, sets the budget to 0 and sends it later", function()
	local clock = newClock()
	local sent = {}
	local q = Queue.new({ send = scripted(sent, 3), now = clock.now, capacity = 10 })
	q:push("a")
	q:push("b")
	q:update()
	t.eq(#sent, 1, "one attempt, then the queue waits")
	t.eq(sent[1][1], "a", "the attempted message")
	t.eq(q:budget(), 0, "budget set to 0")
	t.eq(q:pending(), 2, "message kept")

	clock.t = 1
	q:update()
	t.eq(#sent, 2, "sent after a second")
	t.eq(sent[2][1], "a", "same message retried")
	t.eq(q:pending(), 1, "b still waits")
end)

t.test("code 11 keeps the message, retries one second later and leaves the budget unchanged", function()
	local clock = newClock()
	local sent = {}
	local q = Queue.new({ send = scripted(sent, 11), now = clock.now, capacity = 10 })
	q:push("a")
	q:push("b")
	q:update()
	t.eq(#sent, 1, "one attempt")
	t.eq(q:budget(), 10, "budget unchanged")
	t.eq(q:pending(), 2, "message kept")

	clock.t = 0.5
	q:update()
	t.eq(#sent, 1, "no retry before one second")

	clock.t = 1
	q:update()
	t.eq(#sent, 3, "retried, then b sent")
	t.eq(sent[2][1], "a", "retry of a")
	t.eq(sent[3][1], "b", "then b")
	t.eq(q:budget(), 8, "two sends cost two")
end)

t.test("another code drops the message, calls onDrop and continues with the next one", function()
	local clock = newClock()
	local sent, dropped = {}, {}
	local q = Queue.new({
		send = scripted(sent, 5),
		now = clock.now,
		onDrop = function(text, code) dropped[#dropped + 1] = { text, code } end,
	})
	q:push("a")
	q:push("b")
	q:update()
	t.eq(#dropped, 1, "one drop")
	t.eq(dropped[1][1], "a", "dropped text")
	t.eq(dropped[1][2], 5, "dropped code")
	t.eq(#sent, 2, "queue went on to b")
	t.eq(sent[2][1], "b", "b sent")
	t.eq(q:pending(), 0, "nothing left")
	t.eq(q:budget(), 9, "a drop costs no budget, b cost one")
end)

t.test("a raising send drops the message, calls onDrop and continues", function()
	local clock = newClock()
	local sent, dropped = {}, {}
	local q = Queue.new({
		send = scripted(sent, "error"),
		now = clock.now,
		onDrop = function(text, code) dropped[#dropped + 1] = { text, code } end,
	})
	q:push("a")
	q:push("b")
	q:update()
	t.eq(#dropped, 1, "one drop")
	t.eq(dropped[1][1], "a", "dropped text")
	t.eq(#sent, 2, "queue went on to b")
	t.eq(sent[2][1], "b", "b sent")
	t.eq(q:pending(), 0, "nothing left")
end)

t.test("a drop without onDrop is fine", function()
	local clock = newClock()
	local sent = {}
	local q = Queue.new({ send = scripted(sent, 7), now = clock.now })
	q:push("a")
	q:update()
	t.eq(q:pending(), 0, "dropped")
end)

t.test("push never calls send", function()
	local clock = newClock()
	local sent = {}
	local q = Queue.new({ send = scripted(sent), now = clock.now })
	q:push("a")
	q:push("b")
	t.eq(#sent, 0, "nothing sent by push")
	t.eq(q:pending(), 2, "both waiting")
	t.eq(q:budget(), 10, "budget untouched")
end)

t.test("push rejects more than 255 bytes and accepts exactly 255", function()
	local clock = newClock()
	local q = Queue.new({ send = scripted({}), now = clock.now })
	local ok, err = q:push(string.rep("x", 256))
	t.eq(ok, nil, "256 bytes rejected")
	t.eq(err, "too_long", "reason")
	t.eq(q:pending(), 0, "not queued")
	t.eq(q:push(string.rep("x", 255)), true, "255 bytes accepted")
	t.eq(q:pending(), 1, "queued")
end)

t.test("push rejects the 201st waiting message with full", function()
	local clock = newClock()
	local q = Queue.new({ send = scripted({}), now = clock.now })
	for i = 1, 200 do
		t.eq(q:push("m" .. i), true, "accepted " .. i)
	end
	t.eq(q:pending(), 200, "200 waiting")
	local ok, err = q:push("one too many")
	t.eq(ok, nil, "rejected")
	t.eq(err, "full", "reason")
	t.eq(q:pending(), 200, "still 200")
end)

t.test("pending counts waiting messages and drops as they leave", function()
	local clock = newClock()
	local sent = {}
	local q = Queue.new({ send = scripted(sent), now = clock.now, capacity = 1 })
	q:push("a")
	q:push("b")
	t.eq(q:pending(), 2, "two waiting")
	q:update()
	t.eq(q:pending(), 1, "one sent")
	clock.t = 1
	q:update()
	t.eq(q:pending(), 0, "both sent")
end)
