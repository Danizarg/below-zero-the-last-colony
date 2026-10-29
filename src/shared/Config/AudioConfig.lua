--[[
	AudioConfig.lua

	No Roblox sound asset IDs are invented anywhere in this project. Every cue is
	declared here with `assetId = ""`. AudioController creates the Sound objects,
	wires the mixer groups and drives volume/pitch envelopes; a cue with an empty
	assetId is created but never played, and is reported once in the output so you
	know exactly what is still missing.

	To ship audio: paste real asset IDs into `assetId` and nothing else changes.
]]

local AudioConfig = {}

AudioConfig.Groups = {
	Master = { volume = 1 },
	Ambience = { volume = 0.55, parent = "Master" },
	SFX = { volume = 0.8, parent = "Master" },
	Music = { volume = 0.4, parent = "Master" },
	UI = { volume = 0.6, parent = "Master" },
	Voice = { volume = 0.9, parent = "Master" },
}

--[[
	kind     "ambience" | "sfx" | "music" | "ui"
	loop     whether the Sound loops
	group    mixer group name
	volume   base volume before group scaling
	pitch    { min, max } randomised playback speed, or nil
	rolloff  for 3D sounds: { min, max } distance
	cooldown minimum seconds between retriggers of the same cue
]]
AudioConfig.Cues = {
	-- ── Ambience ─────────────────────────────────────────────────────────────
	cave_ambience_day = {
		assetId = "",
		kind = "ambience",
		loop = true,
		group = "Ambience",
		volume = 0.5,
	},
	cave_ambience_night = {
		assetId = "",
		kind = "ambience",
		loop = true,
		group = "Ambience",
		volume = 0.65,
	},
	colony_ambience = {
		assetId = "",
		kind = "ambience",
		loop = true,
		group = "Ambience",
		volume = 0.45,
	},
	colony_activity = {
		assetId = "",
		kind = "ambience",
		loop = true,
		group = "Ambience",
		volume = 0.3,
		rolloff = { 20, 140 },
	},
	wind_through_tunnels = {
		assetId = "",
		kind = "ambience",
		loop = true,
		group = "Ambience",
		volume = 0.35,
	},

	-- ── Distant threat ───────────────────────────────────────────────────────
	distant_monster_call = {
		assetId = "",
		kind = "sfx",
		loop = false,
		group = "Ambience",
		volume = 0.55,
		pitch = { 0.9, 1.1 },
		cooldown = 18,
	},
	stalker_breath = {
		assetId = "",
		kind = "sfx",
		loop = true,
		group = "SFX",
		volume = 0.7,
		rolloff = { 10, 120 },
	},
	stalker_scream = {
		assetId = "",
		kind = "sfx",
		loop = false,
		group = "SFX",
		volume = 1,
		cooldown = 8,
	},
	crawler_chitter = {
		assetId = "",
		kind = "sfx",
		loop = false,
		group = "SFX",
		volume = 0.6,
		pitch = { 0.85, 1.2 },
		rolloff = { 8, 70 },
		cooldown = 3,
	},
	crawler_attack = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.8 },
	crawler_death = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.7 },

	-- ── World ────────────────────────────────────────────────────────────────
	rock_movement = {
		assetId = "",
		kind = "sfx",
		loop = false,
		group = "SFX",
		volume = 0.9,
		pitch = { 0.9, 1.05 },
	},
	maze_shift_rumble = {
		assetId = "",
		kind = "sfx",
		loop = false,
		group = "SFX",
		volume = 1,
	},
	warning_horn = {
		assetId = "",
		kind = "sfx",
		loop = false,
		group = "SFX",
		volume = 1,
	},
	night_tension_sting = {
		assetId = "",
		kind = "music",
		loop = false,
		group = "Music",
		volume = 0.7,
	},

	-- ── Player actions ───────────────────────────────────────────────────────
	mining_impact = {
		assetId = "",
		kind = "sfx",
		loop = false,
		group = "SFX",
		volume = 0.75,
		pitch = { 0.92, 1.12 },
		cooldown = 0.12,
	},
	harvest_soft = {
		assetId = "",
		kind = "sfx",
		loop = false,
		group = "SFX",
		volume = 0.6,
		pitch = { 0.95, 1.1 },
	},
	node_depleted = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.7 },
	footstep_stone = {
		assetId = "",
		kind = "sfx",
		loop = false,
		group = "SFX",
		volume = 0.35,
		pitch = { 0.9, 1.15 },
		cooldown = 0.2,
	},
	melee_swing = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.6 },
	melee_hit = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.75 },
	player_hurt = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.8 },
	player_downed = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.9 },
	revive_complete = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.8 },
	ability_activate = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.7 },

	-- ── Discovery and progression ───────────────────────────────────────────
	discovery_chime = { assetId = "", kind = "sfx", loop = false, group = "UI", volume = 0.8 },
	key_found = { assetId = "", kind = "sfx", loop = false, group = "UI", volume = 1 },
	gate_unlock = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 1 },
	extraction_complete = { assetId = "", kind = "music", loop = false, group = "Music", volume = 0.85 },
	building_placed = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.7 },
	building_upgraded = { assetId = "", kind = "sfx", loop = false, group = "SFX", volume = 0.8 },

	-- ── UI ───────────────────────────────────────────────────────────────────
	ui_click = { assetId = "", kind = "ui", loop = false, group = "UI", volume = 0.4, cooldown = 0.05 },
	ui_hover = { assetId = "", kind = "ui", loop = false, group = "UI", volume = 0.2, cooldown = 0.05 },
	ui_open = { assetId = "", kind = "ui", loop = false, group = "UI", volume = 0.45 },
	ui_close = { assetId = "", kind = "ui", loop = false, group = "UI", volume = 0.4 },
	ui_error = { assetId = "", kind = "ui", loop = false, group = "UI", volume = 0.5 },
	ui_reward = { assetId = "", kind = "ui", loop = false, group = "UI", volume = 0.6 },
}

--[[
	Dynamic music / ambience layers per expedition phase. AudioController
	crossfades between these as the clock advances. Hook points exist even with
	no assets loaded, so wiring real audio later is a data change only.
]]
AudioConfig.PhaseBeds = {
	prep = { ambience = "colony_ambience", intensity = 0.1 },
	day = { ambience = "cave_ambience_day", intensity = 0.25 },
	dusk = { ambience = "cave_ambience_day", intensity = 0.6, sting = "warning_horn" },
	night = { ambience = "cave_ambience_night", intensity = 1, sting = "night_tension_sting" },
}

--[[ Random one-shots fired while a phase is active, to keep the caves feeling
     occupied without a dedicated ambience track per room. ]]
AudioConfig.RandomAmbience = {
	day = { { cue = "rock_movement", every = { 45, 110 } } },
	dusk = {
		{ cue = "distant_monster_call", every = { 25, 55 } },
		{ cue = "rock_movement", every = { 20, 50 } },
	},
	night = {
		{ cue = "distant_monster_call", every = { 12, 30 } },
		{ cue = "rock_movement", every = { 15, 35 } },
	},
}

function AudioConfig.get(cue)
	return AudioConfig.Cues[cue]
end

--[[ Cues that still need a real asset. Logged once at startup. ]]
function AudioConfig.missingAssets()
	local missing = {}
	for name, cue in pairs(AudioConfig.Cues) do
		if cue.assetId == nil or cue.assetId == "" then
			table.insert(missing, name)
		end
	end
	table.sort(missing)
	return missing
end

return AudioConfig
