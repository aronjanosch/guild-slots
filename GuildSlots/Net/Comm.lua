local _, ns = ...

-- Transport: addon prefix registration, CHAT_MSG_ADDON in, the send queue out.
-- See docs/guild-spec.md section 4. The queue (ns.Queue) is created at Comm.start.

local Comm = {}
ns.Comm = Comm

local PREFIX = "GSLOTS"
local CHANNEL = "GUILD"

local queue, frame, handler

local function register()
	if C_ChatInfo and type(C_ChatInfo.RegisterAddonMessagePrefix) == "function" then
		C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
	elseif type(RegisterAddonMessagePrefix) == "function" then
		RegisterAddonMessagePrefix(PREFIX)
	end
end

-- Returns the result code; true or nil (older signature) counts as 0.
local function rawSend(text, channel, target)
	local fn
	if C_ChatInfo and type(C_ChatInfo.SendAddonMessage) == "function" then
		fn = C_ChatInfo.SendAddonMessage
	elseif type(SendAddonMessage) == "function" then
		fn = SendAddonMessage
	else
		error("no SendAddonMessage")
	end
	local code = fn(PREFIX, text, channel, target)
	if code == nil or code == true then
		return 0
	end
	if code == false then
		return 1
	end
	return code
end

local function onEvent(_, event, prefix, text, channel, sender)
	if event ~= "CHAT_MSG_ADDON" or prefix ~= PREFIX or not handler then
		return
	end
	if type(sender) == "string" then
		sender = sender:gsub("%-.*$", "")
	end
	handler(sender, text, channel)
end

function Comm.start(onMessage)
	handler = onMessage
	register()
	if not queue then
		queue = ns.Queue.new({ send = rawSend, now = GetTime })
	end
	if not frame then
		frame = CreateFrame("Frame")
		frame:RegisterEvent("CHAT_MSG_ADDON")
		frame:SetScript("OnEvent", onEvent)
		frame:SetScript("OnUpdate", function()
			queue:update()
		end)
	end
end

function Comm.send(text, channel, target)
	if not queue then
		return nil, "not_started"
	end
	return queue:push(text, channel or CHANNEL, target)
end

function Comm.budget()
	return queue and queue:budget() or 0
end
