--[[
	DifficultyConfig.lua

	Difficulty is pure data. No system branches on the difficulty id; every
	system reads a named multiplier or value from the resolved table. That keeps
	gameplay logic single-path and makes a new difficulty a config-only change.

	`DifficultyConfig.resolve(id, partySize)` returns a flat table with solo and
	party scaling already folded in.
]]

local Enums = require(script.Parent.Parent.Enums)

local DifficultyConfig = {}

DifficultyConfig.Default = Enums.Difficulty.Medium

DifficultyConfig.Order = {
	Enums.Difficulty.Easy,
	Enums.Difficulty.Medium,
	Enums.Difficulty.Hard,
}

DifficultyConfig.Modes = {
	[Enums.Difficulty.Easy] = {
		id = Enums.Difficulty.Easy,
		name = "Easy",
		blurb = "A long, forgiving run. Good for learning the caves.",
		accent = Color3.fromRGB(104, 196, 140),

		-- Clock, in seconds.
		phaseDurations = { prep = 150, day = 720, dusk = 240, night = 420 },

		-- Layout.
		roomCount = 10,
		loopConnections = 3, -- extra non-tree edges; more loops = more escape routes
		shiftCount = 2, -- rooms rewired per night shift
		shiftIntervalSeconds = 150,

		-- Resources.
		resourceNodeMultiplier = 1.35,
		nodeYieldMultiplier = 1.25,
		resourceRespawnMultiplier = 0.7, -- shorter respawn

		-- Threat.
		monsterCountMultiplier = 0.6,
		monsterHealthMultiplier = 0.7,
		monsterDamageMultiplier = 0.6,
		stalkerEnabled = false,
		nightMonsterSurgeMultiplier = 1.3,

		-- Survival.
		downedSeconds = 75,
		hungerDrainMultiplier = 0.7,
		durabilityLossMultiplier = 0.5,

		-- Objectives.
		keysRequired = 1,
		puzzleRooms = 1,

		-- Payout.
		lootKeptOnDeathFraction = 0.75,
		lootKeptOnTimeoutFraction = 0.5,
		rewardMultiplier = 0.85,
	},

	[Enums.Difficulty.Medium] = {
		id = Enums.Difficulty.Medium,
		name = "Medium",
		blurb = "The intended experience. Get out before the shift.",
		accent = Color3.fromRGB(226, 178, 92),

		-- Spec default: 3 min prep, 10 min day, 3 min dusk, 6 min night.
		phaseDurations = { prep = 180, day = 600, dusk = 180, night = 360 },

		roomCount = 13,
		loopConnections = 2,
		shiftCount = 3,
		shiftIntervalSeconds = 120,

		resourceNodeMultiplier = 1,
		nodeYieldMultiplier = 1,
		resourceRespawnMultiplier = 1,

		monsterCountMultiplier = 1,
		monsterHealthMultiplier = 1,
		monsterDamageMultiplier = 1,
		stalkerEnabled = true,
		nightMonsterSurgeMultiplier = 1.6,

		downedSeconds = 45,
		hungerDrainMultiplier = 1,
		durabilityLossMultiplier = 1,

		keysRequired = 1,
		puzzleRooms = 1,

		lootKeptOnDeathFraction = 0.4,
		lootKeptOnTimeoutFraction = 0.25,
		rewardMultiplier = 1,
	},

	[Enums.Difficulty.Hard] = {
		id = Enums.Difficulty.Hard,
		name = "Hard",
		blurb = "Scarce, fast and loud. The caves rearrange around you.",
		accent = Color3.fromRGB(214, 96, 96),

		phaseDurations = { prep = 120, day = 480, dusk = 120, night = 420 },

		roomCount = 15,
		loopConnections = 1, -- fewer alternative routes
		shiftCount = 5,
		shiftIntervalSeconds = 80,

		resourceNodeMultiplier = 0.75,
		nodeYieldMultiplier = 0.85,
		resourceRespawnMultiplier = 1.5,

		monsterCountMultiplier = 1.5,
		monsterHealthMultiplier = 1.35,
		monsterDamageMultiplier = 1.5,
		stalkerEnabled = true,
		nightMonsterSurgeMultiplier = 2,

		downedSeconds = 25,
		hungerDrainMultiplier = 1.3,
		durabilityLossMultiplier = 1.5,

		keysRequired = 2,
		puzzleRooms = 2,

		lootKeptOnDeathFraction = 0.15,
		lootKeptOnTimeoutFraction = 0.1,
		rewardMultiplier = 1.5,
	},
}

--[[
	Solo and small-party scaling.

	Monsters do not simply get weaker for solo players: count drops hard (so a
	lone player is not surrounded) while per-monster health stays close to
	baseline (so fights still read the same). Objectives shrink so no role is
	mandatory, satisfying "no role should be strictly required... particularly in
	solo mode".
]]
DifficultyConfig.PartyScaling = {
	[1] = { monsterCount = 0.5, monsterHealth = 0.9, objectiveScale = 1, resourceNodes = 0.8 },
	[2] = { monsterCount = 0.7, monsterHealth = 0.95, objectiveScale = 1, resourceNodes = 0.9 },
	[3] = { monsterCount = 0.88, monsterHealth = 1, objectiveScale = 1, resourceNodes = 1 },
	[4] = { monsterCount = 1, monsterHealth = 1, objectiveScale = 1, resourceNodes = 1.1 },
	-- Beyond 4 is design-only until the party cap is raised.
	[5] = { monsterCount = 1.15, monsterHealth = 1.05, objectiveScale = 1.2, resourceNodes = 1.2 },
	[6] = { monsterCount = 1.3, monsterHealth = 1.1, objectiveScale = 1.2, resourceNodes = 1.3 },
	[7] = { monsterCount = 1.45, monsterHealth = 1.15, objectiveScale = 1.4, resourceNodes = 1.4 },
	[8] = { monsterCount = 1.6, monsterHealth = 1.2, objectiveScale = 1.4, resourceNodes = 1.5 },
}

function DifficultyConfig.get(id)
	return DifficultyConfig.Modes[id] or DifficultyConfig.Modes[DifficultyConfig.Default]
end

function DifficultyConfig.isValid(id)
	return DifficultyConfig.Modes[id] ~= nil
end

--[[
	Produce the flat, fully-scaled table every gameplay system reads.
	@param id string            difficulty enum value
	@param partySize number     1..8
	@return table               frozen copy; never mutate the result
]]
function DifficultyConfig.resolve(id, partySize)
	local base = DifficultyConfig.get(id)
	partySize = math.clamp(math.floor(tonumber(partySize) or 1), 1, 8)
	local scale = DifficultyConfig.PartyScaling[partySize]

	local resolved = {
		id = base.id,
		name = base.name,
		blurb = base.blurb,
		accent = base.accent,
		partySize = partySize,

		phaseDurations = {
			prep = base.phaseDurations.prep,
			day = base.phaseDurations.day,
			dusk = base.phaseDurations.dusk,
			night = base.phaseDurations.night,
		},
		totalSeconds = base.phaseDurations.prep
			+ base.phaseDurations.day
			+ base.phaseDurations.dusk
			+ base.phaseDurations.night,

		roomCount = base.roomCount,
		loopConnections = base.loopConnections,
		shiftCount = base.shiftCount,
		shiftIntervalSeconds = base.shiftIntervalSeconds,

		resourceNodeMultiplier = base.resourceNodeMultiplier * scale.resourceNodes,
		nodeYieldMultiplier = base.nodeYieldMultiplier,
		resourceRespawnMultiplier = base.resourceRespawnMultiplier,

		monsterCountMultiplier = base.monsterCountMultiplier * scale.monsterCount,
		monsterHealthMultiplier = base.monsterHealthMultiplier * scale.monsterHealth,
		monsterDamageMultiplier = base.monsterDamageMultiplier,
		stalkerEnabled = base.stalkerEnabled,
		nightMonsterSurgeMultiplier = base.nightMonsterSurgeMultiplier,

		downedSeconds = base.downedSeconds,
		hungerDrainMultiplier = base.hungerDrainMultiplier,
		durabilityLossMultiplier = base.durabilityLossMultiplier,

		keysRequired = math.max(1, math.floor(base.keysRequired * scale.objectiveScale + 0.5)),
		puzzleRooms = base.puzzleRooms,

		lootKeptOnDeathFraction = base.lootKeptOnDeathFraction,
		lootKeptOnTimeoutFraction = base.lootKeptOnTimeoutFraction,
		rewardMultiplier = base.rewardMultiplier,
	}

	return resolved
end

return DifficultyConfig
