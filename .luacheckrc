-- Luacheck configuration for the GuildSlots addon (CI: luacheck GuildSlots).
std = "lua51"
max_line_length = 130
max_comment_line_length = false

ignore = {
	"212/sender", -- message handlers share one signature
	"431", -- shadowing an upvalue (`local tm = tm()`) is used on purpose
	"581", -- `not (a < b)`: names compare by byte with `<` (docs/core-spec.md section 1)
}

-- Globals the addon itself writes: SavedVariables and the slash command.
globals = {
	"GuildSlotsDB",
	"SLASH_GUILDSLOTS1",
	"SLASH_GUILDSLOTS2",
	"SlashCmdList",
}

-- WoW client API the addon reads (availability: docs/forever-api-probe.md).
read_globals = {
	"bit",
	"C_AddOns",
	"C_ChatInfo",
	"C_CurrencyInfo",
	"C_GuildInfo",
	"C_Timer",
	"CreateFrame",
	"debugprofilestop",
	"DEFAULT_CHAT_FRAME",
	"Enum",
	"GameTooltip",
	"GetAddOnMetadata",
	"GetCoinTextureString",
	"GetCursorPosition",
	"GetGuildBankMoneyTransaction",
	"GetGuildInfo",
	"GetGuildInfoText",
	"GetGuildRosterInfo",
	"GetLocale",
	"GetNumGuildBankMoneyTransactions",
	"GetNumGuildMembers",
	"GetServerTime",
	"GetTime",
	"GetUnitName",
	"GuildRoster",
	"InCombatLockdown",
	"IsInGuild",
	"MAX_GUILDBANK_TABS",
	"Minimap",
	"PlaySound",
	"PlaySoundFile",
	"QueryGuildBankLog",
	"RegisterAddonMessagePrefix",
	"SendAddonMessage",
	"SOUNDKIT",
	"StopSound",
	"UIParent",
	"UISpecialFrames",
	"UnitGUID",
	"UnitName",
}

-- Translated strings are long by nature.
files["GuildSlots/Locale/*.lua"] = { max_line_length = false }

exclude_files = {
	"probe/**",
	"tests/vectors.lua",
}
