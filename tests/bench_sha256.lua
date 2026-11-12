-- Benchmark: microseconds per SHA-256 block, probe version versus Core version.
--   luajit tests/bench_sha256.lua
local function load(path)
	local ns = {}
	assert(loadfile(path))("GuildSlots", ns)
	return ns
end

local probe = load("probe/GuildSlotsProbe/Sha256.lua").sha256
local core = load("GuildSlots/Core/Sha256.lua").Sha256

local msg = string.rep("a", 64 * 400 - 9) -- 400 blocks after padding
local function bench(name, fn)
	fn(msg)
	local best = math.huge
	for _ = 1, 5 do
		local t0 = os.clock()
		for _ = 1, 10 do fn(msg) end
		best = math.min(best, (os.clock() - t0) / (10 * 400) * 1e6)
	end
	print(string.format("%-8s %.2f us/block", name, best))
end

bench("probe", probe)
bench("core", core.hex)
local keyed = core.keyed("key")
local short = "x"
local t0 = os.clock()
for _ = 1, 20000 do keyed(short) end
print(string.format("keyed    %.2f us per short message (2 blocks)", (os.clock() - t0) / 20000 * 1e6))
t0 = os.clock()
for _ = 1, 20000 do core.hmac("key", short) end
print(string.format("hmac     %.2f us per short message (incl. key setup, 4 blocks)", (os.clock() - t0) / 20000 * 1e6))
