local _, ns = ...

-- Guild bank deposits for officers: when an officer opens the guild vault, the money log is read
-- and the deposits not dealt with yet are offered in the officer window ("someone paid in, tokens
-- can be granted now"). The add-on only READS the log; it never moves gold or items. Players hand
-- gold over by themselves.
--
-- Client calls (docs/forever-api-probe.md, test 12, measured in this client):
--   QueryGuildBankLog(MAX_GUILDBANK_TABS + 1)   asks the server for the money log
--   GetNumGuildBankMoneyTransactions()           entries, oldest first
--   GetGuildBankMoneyTransaction(i)              kind, name, amount (copper), years, months,
--                                                days, hours ("deposit" / "withdraw"; names
--                                                "First Last" without realm; whole hours)
-- read 2 s after the vault opened and again on GUILDBANKLOG_UPDATE while it is open. Every call
-- is type-checked and wrapped: without the API the feature is simply empty.
--
-- The first read for a guild on a client (no record yet) counts deposits a day old or older as
-- handled (BankBook.seed), so old donations do not flood the list.
--
-- Officers only: members never read or store the log. Per guild, GuildSlotsDB.bank[guild] holds
-- the last read deposits (log, readAt) and the book of handled ones (Guild/BankBook.lua).

local BankBook, Roster = ns.BankBook, ns.Roster

local Bank = {}
ns.Bank = Bank

local READ_DELAY = 2 -- seconds after opening the vault

local listeners = {}
-- open: the vault is open. announce: a chat line is still due for this visit. told: keys of
-- open deposits already announced.
local B = { open = false, announce = false, told = {} }
Bank.state = B

local function L()
	return ns.L
end

local function officer()
	return ns.Main ~= nil and ns.Main.isOfficer() or false
end

local function session()
	return ns.Main and ns.Main.session() or nil
end

local function serverTime()
	if type(GetServerTime) ~= "function" then
		return nil
	end
	local ok, t = pcall(GetServerTime)
	return ok and type(t) == "number" and t or nil
end

-- The guild's bank data; created only when create is true (an officer's read).
local function store(create)
	local guild = Roster.guild()
	if not guild then
		return nil
	end
	if type(GuildSlotsDB) ~= "table" then
		if not create then return nil end
		GuildSlotsDB = {}
	end
	local all = GuildSlotsDB.bank
	if type(all) ~= "table" then
		if not create then return nil end
		all = {}
		GuildSlotsDB.bank = all
	end
	local b = all[guild]
	if type(b) ~= "table" then
		if not create then return nil end
		b = { records = {}, log = {} }
		all[guild] = b
	end
	if type(b.log) ~= "table" then b.log = {} end
	return b
end

local function fire()
	for _, fn in ipairs(listeners) do
		pcall(fn)
	end
end

-- fn() after every change of the open deposits.
function Bank.onChange(fn)
	listeners[#listeners + 1] = fn
end

local function chat(text)
	local ui = ns.SlotFrame and ns.SlotFrame.ui
	if ui and ui.chat then
		ui.chat(text)
	end
end

---------------------------------------------------------------------------------------------
-- Queries

-- Open deposits, newest first: { name, copper, hour, hoursAgo, key }. Empty for members.
function Bank.deposits()
	if not officer() then
		return {}
	end
	local b, now = store(false), serverTime()
	if not b or not now then
		return {}
	end
	return BankBook.open(b, b.log, now)
end

function Bank.openCount()
	return #Bank.deposits()
end

-- Server time of the last read, or nil.
function Bank.readAt()
	local b = officer() and store(false)
	return b and type(b.readAt) == "number" and b.readAt or nil
end

function Bank.isOpen()
	return B.open
end

---------------------------------------------------------------------------------------------
-- Handling

-- The officer granted tokens for a deposit (buyId of the purchase) or dismissed it (nil).
function Bank.handle(dep, buyId)
	local b, now = store(false), serverTime()
	if not b or not now or type(dep) ~= "table" then
		return false
	end
	BankBook.handle(b, dep, now, buyId)
	fire()
	return true
end

function Bank.dismiss(dep)
	return Bank.handle(dep, nil)
end

-- Dismisses several deposits (a list from Bank.deposits()), each recorded like one dismissal.
function Bank.dismissAll(deps)
	local b, now = store(false), serverTime()
	if not b or not now or type(deps) ~= "table" then
		return 0
	end
	for _, d in ipairs(deps) do
		BankBook.handle(b, d, now)
	end
	fire()
	return #deps
end

-- Grants still running whose purchase is gone (after a /reload) or ended unseen.
local function reconcile(b)
	local pending = BankBook.pending(b)
	local s = session()
	if #pending == 0 or not s then
		return false
	end
	local status = {}
	for _, p in ipairs(s:purchases()) do
		if p.role == "officer" and p.buyId then
			status[p.buyId] = p.status
		end
	end
	local changed = false
	for _, id in ipairs(pending) do
		local st = status[id]
		if st == "done" then
			BankBook.settle(b, id)
		elseif st == nil or st == "failed" or st == "timeout" then
			changed = BankBook.release(b, id) or changed
		end
	end
	return changed
end

local function onPurchase(data)
	if type(data) ~= "table" or data.role ~= "officer" or not data.buyId then
		return
	end
	local b = store(false)
	if not b then
		return
	end
	if data.status == "done" then
		BankBook.settle(b, data.buyId)
	elseif data.status == "failed" or data.status == "timeout" then
		if BankBook.release(b, data.buyId) then
			fire()
		end
	end
end

---------------------------------------------------------------------------------------------
-- Reading the log

local function num(v)
	return type(v) == "number" and v or 0
end

local function cutRealm(name)
	if type(name) ~= "string" then
		return nil
	end
	return (name:gsub("%-.*$", ""))
end

local function readEntries()
	if type(GetNumGuildBankMoneyTransactions) ~= "function" or type(GetGuildBankMoneyTransaction) ~= "function" then
		return nil
	end
	local ok, n = pcall(GetNumGuildBankMoneyTransactions)
	if not ok or type(n) ~= "number" then
		return nil
	end
	local entries = {}
	for i = 1, n do
		local ok2, kind, name, amount, years, months, days, hours = pcall(GetGuildBankMoneyTransaction, i)
		if ok2 then
			entries[#entries + 1] = {
				kind = kind, name = cutRealm(name), copper = amount,
				hoursAgo = num(years) * 365 * 24 + num(months) * 30 * 24 + num(days) * 24 + num(hours),
			}
		end
	end
	return entries
end

local function announce(list)
	local new = 0
	for _, d in ipairs(list) do
		if not B.told[d.key] then
			B.told[d.key] = true
			new = new + 1
		end
	end
	if B.announce and new > 0 then
		B.announce = false
		chat(string.format(L().BANK_CHAT, new))
	end
end

local function read()
	if not B.open or not officer() then
		return
	end
	local entries = readEntries()
	local now = serverTime()
	if not entries or not now then
		return
	end
	local first = store(false) == nil
	local b = store(true)
	if not b then
		return
	end
	b.log = BankBook.deposits(entries, now)
	b.readAt = now
	if first then
		-- The first read for this guild on this client: old donations count as handled.
		BankBook.seed(b, b.log, now)
	end
	BankBook.prune(b, now)
	reconcile(b)
	announce(BankBook.open(b, b.log, now))
	fire()
end

-- A timer frame, shown only while a read is due.
local timer = CreateFrame("Frame")
timer:Hide()
local due = 0
timer:SetScript("OnUpdate", function(self, elapsed)
	due = due - (tonumber(elapsed) or 0)
	if due <= 0 then
		self:Hide()
		pcall(read)
	end
end)

local function query()
	if type(QueryGuildBankLog) == "function" then
		local tabs = type(MAX_GUILDBANK_TABS) == "number" and MAX_GUILDBANK_TABS or 8
		pcall(QueryGuildBankLog, tabs + 1)
	end
	due = READ_DELAY
	timer:Show()
end

local function opened()
	if B.open or not officer() then
		return
	end
	B.open, B.announce = true, true
	query()
end

local function closed()
	B.open, B.announce = false, false
	timer:Hide()
end

local function isBanker(itype)
	local e = type(Enum) == "table" and type(Enum.PlayerInteractionType) == "table" and Enum.PlayerInteractionType
	local banker = e and e.GuildBanker
	return banker ~= nil and itype == banker
end

local events = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_LOGIN", "GUILDBANKFRAME_OPENED", "GUILDBANKFRAME_CLOSED", "GUILDBANKLOG_UPDATE",
	"PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" }) do
	pcall(events.RegisterEvent, events, e)
end
events:SetScript("OnEvent", function(_, event, arg1)
	pcall(function()
		if event == "GUILDBANKFRAME_OPENED" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and isBanker(arg1)) then
			opened()
		elseif event == "GUILDBANKFRAME_CLOSED" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" and isBanker(arg1)) then
			closed()
		elseif event == "GUILDBANKLOG_UPDATE" then
			if B.open and not timer:IsShown() then
				read()
			end
		elseif event == "PLAYER_LOGIN" and ns.Main and not B.subscribed then
			B.subscribed = true
			ns.Main.subscribe(function(name, data)
				if name == "purchase" then
					onPurchase(data)
				end
			end)
		end
	end)
end)
