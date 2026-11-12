local t, ns = ...
local Engine, Ledger, Tables, Sha256 = ns.Engine, ns.Ledger, ns.Tables, ns.Sha256

-- Checks Engine.round and Ledger against tests/vectors_t2.lua and tests/vectors_t3.lua, generated
-- by the independent Python reference in tools/ref/ (docs/table-t2-spec.md section 8,
-- docs/table-t3-spec.md). A missing file is skipped (one passing test).

-- Deep comparison in both directions; returns nil or the path of the first difference.
local function diff(got, want, path)
	if type(got) ~= "table" or type(want) ~= "table" then
		if got ~= want then
			return path .. ": got " .. tostring(got) .. ", want " .. tostring(want)
		end
		return nil
	end
	for k, v in pairs(want) do
		local d = diff(got[k], v, path .. "." .. tostring(k))
		if d then return d end
	end
	for k, v in pairs(got) do
		if want[k] == nil then
			return path .. "." .. tostring(k) .. ": got " .. tostring(v) .. ", want nothing"
		end
	end
	return nil
end

local function each(group, name, fn)
	t.test(name .. " (" .. #(group or {}) .. " vectors)", function()
		t.ok(group and #group > 0, "group " .. name .. " is empty or missing")
		for i, v in ipairs(group) do fn(v, name .. "[" .. i .. "]") end
	end)
end

for _, id in ipairs({ "T2", "T3" }) do
	local file = "vectors_" .. id:lower() .. ".lua"
	local fh = io.open("tests/" .. file)
	if not fh then
		t.test(file .. " not present", function() end)
	else
		fh:close()
		local V = t.load(file)
		local tbl = Tables.get(id)
		local pre = id:lower()

		each(V.rounds, pre .. ".rounds", function(v, at)
			local d = diff(Engine.round(v.K, v.n, v.contribs, tbl, v.stake, v.cap), v.round, "round")
			t.ok(not d, at .. ": " .. tostring(d))
			-- The keyed form gives the same round.
			d = diff(Engine.round(Sha256.keyed(v.K), v.n, v.contribs, tbl, v.stake, v.cap), v.round, "round")
			t.ok(not d, at .. " keyed: " .. tostring(d))
		end)

		each(V.accounts, pre .. ".accounts", function(v, at)
			local st, code, index = Ledger.replay(v.guild, v.player, v.entries)
			t.ok(st, at .. " replay: " .. tostring(code) .. " at entry " .. tostring(index))
			t.eq(st.balance, v.balance, at .. " balance")
			t.eq(st.head, v.head, at .. " head")
			t.eq(st.tbl.id, id, at .. " plays " .. id)
		end)

		each(V.invalid, pre .. ".invalid", function(v, at)
			local st, code, index = Ledger.replay(v.guild, v.player, v.entries)
			t.eq(st, nil, at .. " must fail (" .. v.note .. ")")
			t.eq(code, v.code, at .. " code (" .. v.note .. ")")
			t.eq(index, v.index, at .. " index (" .. v.note .. ")")
		end)

		t.test(pre .. ".stats match Tables.stats", function()
			local s = Tables.stats(tbl, 10, 0)
			for _, k in ipairs({ "rtp", "hit", "variance", "freeRate" }) do
				t.near(s[k], V.stats[k], 1e-12, id .. " " .. k)
			end
		end)
	end
end
