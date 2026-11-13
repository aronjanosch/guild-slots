local _, ns = ...

-- Recalculates an account for a payout and reports findings (docs/core-spec.md section 7).
-- Pure Lua 5.1. Verify.run never raises on bad account data: every problem is a finding.

local Ledger, Engine, Tables = ns.Ledger, ns.Engine, ns.Tables

local sub, sqrt = string.sub, math.sqrt

local Verify = {}
ns.Verify = Verify

local RANK = { green = 0, yellow = 1, red = 2 }
local MIN_SPINS, MIN_STEPS, LOOKAHEAD = 30, 10, 20

-- Luck index ------------------------------------------------------------------------------------

local function newLuck()
	return { spins = 0, steps = 0, won = 0, maxWin = 0, e = {}, m = {}, mu = {}, var = {} }
end

-- Below 2 green, below 3 yellow, else red; only upward deviations count. Not enough data: green.
local function value(z, enough)
	local light = "green"
	if enough and z then
		if z >= 3 then
			light = "red"
		elseif z >= 2 then
			light = "yellow"
		end
	end
	return { z = z, light = light, enough = enough }
end

local function luckIndex(l)
	local count, e, m, mu, var = l.spins, l.e, l.m, l.mu, l.var
	local num, den, sumE = 0, 0, 0
	for i = 1, count do
		num = num + e[i] * (m[i] - mu[i])
		den = den + e[i] * e[i] * var[i]
		sumE = sumE + e[i]
	end
	local enough = count >= MIN_SPINS
	local total = value(den > 0 and num / sqrt(den) or nil, enough)

	local timing = nil
	if count > 0 then
		local ebar = sumE / count
		num, den = 0, 0
		for i = 1, count do
			local d = e[i] - ebar
			num = num + d * (m[i] - mu[i])
			den = den + d * d * var[i]
		end
		if den > 0 then
			timing = value(num / sqrt(den), enough)
		end
	end

	local risk = nil
	if l.steps > 0 then
		risk = value((l.won - l.steps / 2) / sqrt(l.steps / 4), l.steps >= MIN_STEPS)
	end
	return { spins = count, steps = l.steps, maxWin = l.maxWin, total = total, timing = timing, risk = risk }
end

-- Look-ahead (level 0): the next 20 spins with the current key and no contributions. For a lines
-- table the multiplier is the uncapped round win / stake, which does not depend on the stake;
-- the round is played at a stake of one line bet per line.
local function lookahead(state)
	local tbl, sum = state.tbl, 0
	for k = 1, LOOKAHEAD do
		if tbl.kind == "lines" then
			local stake = tbl.lineCount
			sum = sum + Engine.round(state.keyed, state.n + k, "", tbl, stake, 0).win / stake
		else
			sum = sum + Tables.multiplier(tbl, Engine.spin(state.keyed, state.n + k, "", tbl))
		end
	end
	return { count = LOOKAHEAD, sum = sum, expected = LOOKAHEAD * Tables.stats(tbl, 1, 0).rtp }
end

-- Check 7. rows = input.audit; recs/recList = the level-1/2 spins and steps of the replay.
-- Adds the findings and returns the number of ok entries with an unconfirmed contribution.
local function audit(rows, recs, recList, add)
	local confirmed = {}
	if type(rows) == "table" then
		for _, row in ipairs(rows) do
			local rec = type(row) == "table" and recs[tostring(row.kind) .. "|" .. tostring(row.n) .. "|" ..
				tostring(row.g or 0)]
			if rec then
				local have = rec.values[row.witness]
				if row.value ~= nil then
					confirmed[rec.index .. "|" .. tostring(row.witness)] = true
					if have ~= nil and have ~= row.value then
						add(7, "red", "witness_mismatch", rec.index)
					end
				end
				if row.answered == true then
					if not rec.ok then
						rec.answers = rec.answers + 1
					elseif have == nil then
						add(7, "yellow", "omitted", rec.index)
					end
				end
			end
		end
	end
	local unconfirmed = 0
	for _, rec in ipairs(recList) do
		if rec.ok then
			for _, c in ipairs(rec.list) do
				if not confirmed[rec.index .. "|" .. c.name] then
					unconfirmed = unconfirmed + 1
					break
				end
			end
		elseif rec.answers >= rec.needed then
			add(7, "yellow", "void_with_answers", rec.index)
		end
	end
	return unconfirmed
end

-- Alerts (docs/follow-spec.md section 4): the well-formed rows, one yellow finding per code.
local ALERT_CODES = { rewritten = true, bad_entry = true, bad_res = true, omitted = true, bad_value = true }

local function alerts(rows, add)
	local list, codes = {}, {}
	if type(rows) ~= "table" then
		return list
	end
	for _, row in ipairs(rows) do
		if type(row) == "table" and ALERT_CODES[row.code] then
			list[#list + 1] = row
			if not codes[row.code] then
				codes[row.code] = true
				add(7, "yellow", "alert_" .. row.code, nil)
			end
		end
	end
	return list
end

function Verify.run(input)
	local findings = {}
	local function add(check, level, code, index)
		findings[#findings + 1] = { check = check, level = level, code = code, index = index }
	end

	local entries = type(input.entries) == "table" and input.entries or {}
	local known = type(input.known) == "table" and input.known or {}
	local isOfficer = type(input.isOfficer) == "function" and input.isOfficer or function() return nil end
	-- With a start state the officer trusts (docs/follow-spec.md section 5) the entries are the
	-- ones after it; the replay runs on a copy.
	local start = type(input.start) == "table" and input.start or nil
	local state = start and Ledger.copy(start) or Ledger.start(input.guild, input.player)
	local failed = false
	local lastTime = nil -- time of the last purchase or payout, for isOfficer on witnesses

	-- Check 1: the anchor is resolved when its B/P entry is replayed. One at or before the start
	-- is resolved by the start state.
	local anchor = type(input.anchor) == "table" and input.anchor or nil
	local anchorCount = anchor and anchor.anchors
	if anchor and type(anchorCount) ~= "number" then
		anchorCount = -1 -- malformed: never reached
	end
	local anchorIndex, anchorOk = nil, false
	if anchorCount and anchorCount >= 0 and (anchorCount < state.anchors or (start and anchorCount == state.anchors)) then
		anchorOk = true -- covered by the start state, which may lie after the anchor's entry
	elseif anchorCount == state.anchors then
		anchorOk = Ledger.shortHead(state) == anchor.head
	end
	local unknown = {} -- check 3: { index, number of B/P entries up to it }

	-- Check 4: the SPIN/GAM heard live; one at or before the start is not checked.
	local heard = nil
	if type(input.heard) == "table" and type(input.heard.n) == "number" and not (start and input.heard.n <= state.n) then
		local g = input.heard.g
		heard = { n = input.heard.n, g = type(g) == "number" and g or 0, head = input.heard.head }
	end
	local heardFound = false

	-- Check 7: spins and steps at level 1/2 by "kind|n|g", and in account order.
	local recs, recList = {}, {}

	-- Luck index: ok spins and steps since the last payout.
	local luck = newLuck()

	for i = 1, #entries do
		local e = entries[i]
		if type(e) == "string" then
			local d, code = Ledger.decode(e)
			if not d then
				add(6, "red", code, i)
				failed = true
				break
			end
			e = d
		end
		local before = state.head
		local info, code = Ledger.apply(state, e)
		if not info then
			local t = type(e) == "table" and e.type
			local check = 6
			if t == "S" or t == "G" then
				check = 5
			elseif code == "bad_commit" or code == "dup_buy" then
				check = 2
			end
			add(check, "red", code, i)
			failed = true
			break
		end
		local kind = e.type
		if kind == "S" or kind == "G" then
			local g = kind == "G" and e.g or 0
			if heard and heard.n == e.n and heard.g == g then
				heardFound = true
				if sub(before, 1, 32) ~= heard.head then
					add(4, "red", "rewritten", i)
				end
			end
			local s = state.settings
			local list = Engine.parseContribs(e.contribs)
			if s.L == 2 then
				for _, c in ipairs(list) do
					if isOfficer(c.name, lastTime) == false then
						add(5, "red", "witness_not_officer", i)
					end
				end
			end
			if s.L > 0 then
				local values = {}
				for _, c in ipairs(list) do
					values[c.name] = c.value
				end
				local rec = { index = i, ok = e.status == "ok", values = values, list = list,
					needed = s.L == 1 and s.W or 1, answers = 0 }
				recs[(kind == "S" and "spin|" or "gam|") .. e.n .. "|" .. g] = rec
				recList[#recList + 1] = rec
			end
			if e.status == "ok" then
				if kind == "S" then
					local st = Tables.stats(state.tbl, e.stake, s.C)
					local n = luck.spins + 1
					luck.spins, luck.e[n], luck.m[n], luck.mu[n], luck.var[n] =
						n, e.stake, info.win / e.stake, st.rtp, st.variance
					if info.win > luck.maxWin then
						luck.maxWin = info.win
					end
				else
					luck.steps = luck.steps + 1
					if info.won then
						luck.won = luck.won + 1
					end
				end
			end
		else
			lastTime = e.time
			if kind == "P" then
				luck = newLuck()
			end
		end
		if kind == "B" or kind == "P" then
			if state.anchors == anchorCount then
				anchorIndex = i
				anchorOk = Ledger.shortHead(state) == anchor.head
			end
			local seenAt = known[kind == "B" and e.buyId or e.payId]
			if not seenAt then
				unknown[#unknown + 1] = { i, state.anchors }
			elseif type(seenAt) == "number" and seenAt ~= state.anchors then
				add(3, "red", "replayed", i)
			end
			if kind == "B" then
				local officer = isOfficer(e.officer, e.time)
				if officer == false then
					add(2, "red", "not_officer", i)
				elseif officer == nil then
					add(2, "yellow", "officer_unknown", i)
				end
			end
		end
		if input.onStep then
			input.onStep(i)
		end
	end

	if not anchor then
		add(1, "yellow", "no_anchor", nil)
	elseif not anchorOk then
		add(1, "red", "anchor_mismatch", anchorIndex)
	end
	if heard and not heardFound and not failed then
		if heard.n > state.n or (heard.n == state.n and heard.g > state.g) then
			add(4, "yellow", "incomplete", nil)
		else
			add(4, "red", "rewritten", nil)
		end
	end
	local unconfirmed = audit(input.audit, recs, recList, add)
	local alertList = alerts(input.alerts, add)
	if not failed and type(input.amount) == "number" and input.amount > state.balance then
		add(8, "red", "amount_too_high", nil)
	end
	for _, u in ipairs(unknown) do
		if anchorOk and u[2] <= anchorCount then
			add(3, "yellow", "not_seen", u[1])
		else
			add(3, "red", "unconfirmed", u[1])
		end
	end

	local light = "green"
	for _, f in ipairs(findings) do
		if RANK[f.level] > RANK[light] then
			light = f.level
		end
	end
	local report = { findings = findings, light = light, unconfirmed = unconfirmed, alerts = alertList }
	if not failed then
		report.balance, report.state = state.balance, state
		-- A start state without entries gives nothing to judge the luck by.
		if not start or #entries > 0 then
			report.luck = luckIndex(luck)
		end
		if state.settings and state.settings.L == 0 then
			report.lookahead = lookahead(state)
		end
	end
	return report
end
