-- Test runner for everything under GuildSlots/Core. No dependencies besides LuaJIT.
--
--   luajit tests/run.lua              run all tests (LuaJIT `bit`: signed results)
--   luajit tests/run.lua --unsigned   same, with `bit` wrapped to return unsigned results
--                                     like the WoW Forever client does
--   luajit tests/run.lua engine       only test files whose name contains "engine"
--
-- Core files are loaded the way the game loads them: each chunk gets (addonName, ns).
-- A test file is tests/test_<name>.lua and receives (t, ns):
--   t.test("name", function() ... end)
--   t.eq(got, want, msg)   t.ok(cond, msg)   t.near(got, want, eps, msg)   t.raises(fn, msg)
--   t.load("vectors.lua")  loads tests/<file> and returns its value

local unsigned, filter = false, nil
for _, a in ipairs(arg) do
	if a == "--unsigned" then unsigned = true else filter = a end
end

if unsigned then
	local real, wrapped, M = bit, {}, 4294967296
	for name, f in pairs(real) do
		wrapped[name] = function(...)
			local r = f(...)
			if type(r) == "number" then return r % M end
			return r
		end
	end
	-- The client has neither of these.
	wrapped.ror, wrapped.rol, wrapped.tobit, wrapped.tohex, wrapped.bswap = nil, nil, nil, nil, nil
	bit = wrapped
end

local CORE = { "Sha256", "Tables", "Settings", "Engine", "Ledger", "Verify", "Proto" }
local ns = {}
for _, name in ipairs(CORE) do
	local path = "GuildSlots/Core/" .. name .. ".lua"
	local fh = io.open(path)
	if fh then
		fh:close()
		assert(loadfile(path))("GuildSlots", ns)
	end
end
-- Pure files outside Core (no WoW API), loaded after Core.
local PURE = { "Game/Solo.lua", "Game/Guild.lua", "UI/Anim.lua", "Net/Queue.lua" }
for _, file in ipairs(PURE) do
	assert(loadfile("GuildSlots/" .. file))("GuildSlots", ns)
end

local passed, failed = 0, 0
local t = {}

local function fail(msg) error(msg, 3) end

function t.eq(got, want, msg)
	if got ~= want then
		fail((msg and (msg .. ": ") or "") .. "got " .. tostring(got) .. ", want " .. tostring(want))
	end
end

function t.ok(cond, msg)
	if not cond then fail(msg or "expected a true value") end
end

function t.near(got, want, eps, msg)
	if type(got) ~= "number" or math.abs(got - want) > (eps or 1e-9) then
		fail((msg and (msg .. ": ") or "") .. "got " .. tostring(got) .. ", want about " .. tostring(want))
	end
end

function t.raises(fn, msg)
	if pcall(fn) then fail(msg or "expected an error") end
end

function t.load(file)
	return assert(loadfile("tests/" .. file))()
end

local current
function t.test(name, fn)
	local ok, err = xpcall(fn, debug.traceback)
	if ok then
		passed = passed + 1
	else
		failed = failed + 1
		io.write("FAIL ", current, ": ", name, "\n", err, "\n")
	end
end

local files = {}
local p = io.popen("ls tests/test_*.lua 2>/dev/null")
for line in p:lines() do files[#files + 1] = line end
p:close()

for _, file in ipairs(files) do
	if not filter or file:find(filter, 1, true) then
		current = file
		assert(loadfile(file))(t, ns)
	end
end

io.write(string.format("%s bit: %d passed, %d failed\n", unsigned and "unsigned" or "signed", passed, failed))
os.exit(failed == 0 and 0 or 1)
