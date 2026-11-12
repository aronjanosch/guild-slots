-- Minimal fake of the WoW API used by GuildSlots, for load/smoke tests outside the client.
-- Installs globals and returns a control table:
--   stub.fire(event, ...)   deliver an event to every frame that registered it
--   stub.tick(dt)           run OnUpdate on every visible frame
--   stub.slash(cmd, msg)    run a slash command like "/gs"
--   stub.combat, stub.mouseOver, stub.locale   switches
--   stub.sounds, stub.chat  what was played / printed
--   stub.unknown            method names called that the stub does not model (no-ops)
--
-- Arguments of the modelled methods are checked (numbers, anchor names), so a nil passed by
-- a typo fails here instead of in the client.

local stub = {
	combat = false,
	mouseOver = false,
	locale = "enUS",
	sounds = {},
	chat = {},
	unknown = {},
	frames = {},
}

local POINTS = {
	TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
	BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}
local LAYERS = { BACKGROUND = true, BORDER = true, ARTWORK = true, OVERLAY = true, HIGHLIGHT = true }

local function check(cond, msg)
	if not cond then error(msg, 3) end
end

local function isNum(v) return type(v) == "number" and v == v end

local Object = {}
local meta = {
	__index = function(self, k)
		local m = Object[k]
		if m then return m end
		if type(k) == "string" and k:match("^[A-Z]") then
			stub.unknown[k] = (stub.unknown[k] or 0) + 1
			return function() return nil end
		end
		return nil
	end,
}

local function new(kind, name, parent)
	local o = setmetatable({
		_kind = kind, _name = name, _parent = parent, _shown = true, _alpha = 1,
		_w = 0, _h = 0, _points = {}, _scripts = {}, _events = {}, _level = parent and (parent._level or 0) + 1 or 0,
	}, meta)
	if kind ~= "Texture" and kind ~= "FontString" then
		stub.frames[#stub.frames + 1] = o
	end
	if name then _G[name] = o end
	return o
end

function Object:GetName() return self._name end
function Object:GetParent() return self._parent end
function Object:GetObjectType() return self._kind end

function Object:SetSize(w, h)
	check(isNum(w) and isNum(h), "SetSize needs two numbers")
	self._w, self._h = w, h
end
function Object:SetWidth(w) check(isNum(w), "SetWidth needs a number"); self._w = w end
function Object:SetHeight(h) check(isNum(h), "SetHeight needs a number"); self._h = h end
function Object:GetWidth() return self._w end
function Object:GetHeight() return self._h end
function Object:GetSize() return self._w, self._h end

function Object:SetPoint(point, rel, relPoint, x, y)
	check(POINTS[point], "SetPoint: bad point " .. tostring(point))
	if type(rel) == "number" then -- SetPoint(point, x, y)
		rel, relPoint, x, y = self._parent, point, rel, relPoint
	end
	if rel == nil then rel = self._parent end
	check(type(rel) == "table", "SetPoint: bad relative frame")
	relPoint = relPoint or point
	check(POINTS[relPoint], "SetPoint: bad relative point " .. tostring(relPoint))
	check(x == nil or isNum(x), "SetPoint: bad x")
	check(y == nil or isNum(y), "SetPoint: bad y")
	self._points[#self._points + 1] = { point, rel, relPoint, x or 0, y or 0 }
end
function Object:SetAllPoints(rel) self._points = { { "ALL", rel or self._parent } } end
function Object:ClearAllPoints() self._points = {} end
function Object:GetPoint(i)
	local p = self._points[i or 1]
	if p then return p[1], p[2], p[3], p[4], p[5] end
end
function Object:GetNumPoints() return #self._points end

function Object:Show()
	local was = self:IsVisible()
	self._shown = true
	if not was and self:IsVisible() and self._scripts.OnShow then self._scripts.OnShow(self) end
end
function Object:Hide()
	local was = self:IsVisible()
	self._shown = false
	if was and self._scripts.OnHide then self._scripts.OnHide(self) end
end
function Object:SetShown(on) if on then self:Show() else self:Hide() end end
function Object:IsShown() return self._shown end
function Object:IsVisible()
	local o = self
	while o do
		if not o._shown then return false end
		o = o._parent
	end
	return true
end
function Object:SetAlpha(a)
	check(isNum(a), "SetAlpha needs a number")
	self._alpha = a
end
function Object:GetAlpha() return self._alpha end

function Object:SetScript(name, fn)
	check(type(name) == "string", "SetScript: bad name")
	check(fn == nil or type(fn) == "function", "SetScript: bad handler")
	self._scripts[name] = fn
end
function Object:GetScript(name) return self._scripts[name] end
function Object:HookScript(name, fn)
	local old = self._scripts[name]
	self._scripts[name] = function(...)
		if old then old(...) end
		fn(...)
	end
end
function Object:RegisterEvent(e) self._events[e] = true end
function Object:UnregisterEvent(e) self._events[e] = nil end

function Object:SetFrameLevel(l) check(isNum(l), "SetFrameLevel needs a number"); self._level = l end
function Object:GetFrameLevel() return self._level end
function Object:SetFrameStrata(s) check(type(s) == "string", "SetFrameStrata needs a string") end

function Object:CreateTexture(name, layer, template, sublevel)
	check(layer == nil or LAYERS[layer], "CreateTexture: bad layer " .. tostring(layer))
	check(sublevel == nil or (isNum(sublevel) and sublevel >= -8 and sublevel <= 7), "CreateTexture: bad sublevel")
	return new("Texture", name, self)
end
function Object:CreateFontString(name, layer)
	check(layer == nil or LAYERS[layer], "CreateFontString: bad layer " .. tostring(layer))
	return new("FontString", name, self)
end

function Object:SetTexture(path)
	check(path == nil or type(path) == "string" or isNum(path), "SetTexture: bad path")
	self._texture = path
end
function Object:GetTexture() return self._texture end
function Object:SetColorTexture(r, g, b, a)
	check(isNum(r) and isNum(g) and isNum(b) and (a == nil or isNum(a)), "SetColorTexture needs numbers")
	self._texture = "color"
end
function Object:SetTexCoord(a, b, c, d)
	check(isNum(a) and isNum(b) and isNum(c) and isNum(d), "SetTexCoord needs four numbers")
	check(a >= 0 and b <= 1 and c >= 0 and d <= 1 and a <= b and c <= d, "SetTexCoord out of range")
	self._coord = { a, b, c, d }
end
function Object:SetVertexColor(r, g, b) check(isNum(r) and isNum(g) and isNum(b), "SetVertexColor needs numbers") end

function Object:SetText(t)
	check(t == nil or type(t) == "string" or isNum(t), "SetText: bad value")
	self._text = t and tostring(t) or nil
end
function Object:GetText() return self._text end
function Object:SetTextColor(r, g, b) check(isNum(r) and isNum(g) and isNum(b), "SetTextColor needs numbers") end
function Object:SetFont(path, size, flags)
	check(type(path) == "string" and isNum(size), "SetFont: bad arguments")
	self._font = path
	return true
end
function Object:GetFont() return self._font, 12, "" end
function Object:SetFontObject(o) check(type(o) == "table", "SetFontObject: bad object") end
function Object:SetJustifyH(j) check(j == "LEFT" or j == "CENTER" or j == "RIGHT", "SetJustifyH: bad value") end

function Object:Click(button)
	if self._scripts.OnClick then self._scripts.OnClick(self, button or "LeftButton", false) end
end
function Object:EnableKeyboard(on)
	check(not stub.combat, "EnableKeyboard called in combat")
	self._keyboard = on and true or false
end
function Object:IsKeyboardEnabled() return self._keyboard end
function Object:SetPropagateKeyboardInput(on)
	check(not stub.combat, "SetPropagateKeyboardInput called in combat")
	self._propagate = on and true or false
end
function Object:IsMouseOver() return stub.mouseOver end
function Object:EnableMouse() end
function Object:SetMovable() end
function Object:RegisterForDrag() end
function Object:RegisterForClicks() end
function Object:StartMoving() end
function Object:StopMovingOrSizing() end
function Object:SetClampedToScreen() end
function Object:SetToplevel() end
function Object:SetClipsChildren() end

-- Globals --------------------------------------------------------------------------------

UIParent = new("Frame", "UIParent", nil)

function CreateFrame(kind, name, parent, template)
	check(type(kind) == "string", "CreateFrame: bad type")
	check(template == nil, "CreateFrame: no templates expected")
	return new(kind, name, parent or UIParent)
end

SlashCmdList = {}
UISpecialFrames = {}
GameFontNormal = new("Font", nil, nil)
SOUNDKIT = {
	IG_MAINMENU_OPTION_CHECKBOX_ON = 856, IG_MAINMENU_OPEN = 850, U_CHAT_SCROLL_BUTTON = 1115,
	LOOT_WINDOW_COIN_SOUND = 120, READY_CHECK = 8960, IG_QUEST_FAILED = 847,
}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, msg) stub.chat[#stub.chat + 1] = msg end }

local clock = 0
function GetTime() return clock end
function GetLocale() return stub.locale end
function InCombatLockdown() return stub.combat end
function PlaySound(id, channel)
	check(isNum(id), "PlaySound needs a soundkit id")
	stub.sounds[#stub.sounds + 1] = id
	return true
end
C_Timer = { After = function(_, fn) stub.timers = stub.timers or {}; table.insert(stub.timers, fn) end }

function stub.fire(event, ...)
	for _, f in ipairs(stub.frames) do
		if f._events[event] and f._scripts.OnEvent then
			f._scripts.OnEvent(f, event, ...)
		end
	end
end

function stub.tick(dt)
	clock = clock + dt
	for _, f in ipairs(stub.frames) do
		local fn = f._scripts.OnUpdate
		if fn and f:IsVisible() then fn(f, dt) end
	end
end

function stub.slash(cmd, msg)
	for key, fn in pairs(SlashCmdList) do
		for i = 1, 9 do
			local alias = _G["SLASH_" .. key .. i]
			if not alias then break end
			if alias == cmd then return fn(msg or "") end
		end
	end
	error("unknown slash command " .. cmd)
end

-- Loads the addon files listed in the TOC, in order, with (addonName, ns).
function stub.loadAddon(dir, name, ns)
	ns = ns or {}
	local toc = assert(io.open(dir .. "/" .. name .. ".toc"))
	for line in toc:lines() do
		line = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if line ~= "" and not line:match("^#") then
			local path = dir .. "/" .. line:gsub("\\", "/")
			assert(loadfile(path))(name, ns)
		end
	end
	toc:close()
	return ns
end

return stub
