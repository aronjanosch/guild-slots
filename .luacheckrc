-- Luacheck configuration for the GuildSlots addon.
std = "lua51"
max_line_length = 120

-- Globals the addon itself writes (SavedVariables).
globals = { "GuildSlotsDB" }

-- WoW client API the addon reads.
read_globals = {
	"bit",
	"CreateFrame",
	"SlashCmdList",
	"UIParent",
	"C_Timer",
	"GetLocale",
	"PlaySound",
}

exclude_files = {
	"probe/**",
	"tests/vectors.lua",
}
