--[[
	MonsterConfig.lua

	Two monsters for the MVP, built to require different answers rather than
	different amounts of patience:

	  Cave Crawler - low health, fast wind-up, telegraphed lunge. Fought.
	  The Stalker  - cannot be killed by MVP weapons, tracks noise, loses you in
	                 light and in occupied rooms. Avoided.

	Both run a shared state machine (see server/AI/MonsterBase.lua). States are
	declared here so the AI module has no monster-specific branching.
]]

local Enums = require(script.Parent.Parent.Enums)
local M = Enums.Monster

local MonsterConfig = {}

MonsterConfig.Monsters = {
	[M.CaveCrawler] = {
		id = M.CaveCrawler,
		name = "Cave Crawler",
		description = "Pale, many-legged, and never alone for long.",

		maxHealth = 55,
		walkSpeed = 11,
		chaseSpeed = 17,
		damage = 12,

		--[[ Senses. Daytime values are reduced by `dayAwarenessMult` so daytime
		     exploration is genuinely calmer, per the design brief. ]]
		sightRange = 48,
		hearingRange = 26,
		loseTargetRange = 70,
		loseTargetSeconds = 5,
		dayAwarenessMult = 0.55,

		--[[ Combat. A wind-up long enough to read and dodge. ]]
		attackRange = 7,
		attackWindup = 0.55,
		attackCooldown = 1.8,
		staggerable = true,

		--[[ Patrol. Crawlers belong to the room they spawned in and return to it. ]]
		territoryRadius = 60,
		patrolRadius = 26,
		patrolPauseRange = { 1.5, 4 },

		killable = true,
		xpValue = 12,
		drops = { { resource = Enums.Resource.Fiber, min = 1, max = 3, chance = 0.6 } },

		-- Appearance (procedural; no external assets).
		body = {
			torso = Vector3.new(3.2, 1.6, 4.4),
			color = Color3.fromRGB(176, 168, 150),
			accent = Color3.fromRGB(96, 90, 78),
			eyeColor = Color3.fromRGB(255, 196, 120),
			legCount = 6,
			scale = 1,
		},

		spawnRooms = {
			Enums.RoomKind.MonsterNest,
			Enums.RoomKind.MiningChamber,
			Enums.RoomKind.Junction,
			Enums.RoomKind.CorridorStraight,
			Enums.RoomKind.CorridorCurve,
			Enums.RoomKind.DeadEnd,
		},
		spawnWeight = 10,
		nestBonusCount = 2,

		states = { "idle", "patrol", "investigate", "chase", "attack", "stagger", "return" },
	},

	[M.Stalker] = {
		id = M.Stalker,
		name = "The Stalker",
		description = "You hear it before anything else. By then it already knows where you are.",

		--[[ Deliberately unkillable with MVP gear. Damage reduces its interest,
		     not its health: hitting it buys you a retreat, it does not win the
		     fight. This is what makes it a different problem from the Crawler. ]]
		maxHealth = 400,
		killable = false,
		damageInterestLoss = 0.35, -- interest removed by a "solid" hit
		--[[ What counts as a solid hit, in damage. Interest loss scales against
		     this (clamped to 0.3x..1.5x), so an Iron Blade drives the Stalker
		     off in roughly three hits and bare hands take about ten. Matches the
		     Iron Blade's damage so the best melee weapon is the reference. ]]
		interestLossReferenceDamage = 26,

		walkSpeed = 9,
		chaseSpeed = 20,
		damage = 34,

		--[[ The Stalker is nearly blind and hunts sound: sprinting, mining and
		     combat all generate noise events it can follow. ]]
		sightRange = 16,
		hearingRange = 110,
		loseTargetRange = 150,
		loseTargetSeconds = 9,
		dayAwarenessMult = 1,

		attackRange = 8,
		attackWindup = 0.8,
		attackCooldown = 3.2,
		staggerable = false,

		territoryRadius = 10000, -- roams the whole cave
		patrolRadius = 140,
		patrolPauseRange = { 0.5, 2 },

		--[[ Counterplay: standing in bright light or in a room with two or more
		     living players makes it break off. ]]
		lightAversionThreshold = 0.55,
		crowdAversionCount = 2,
		breakOffSeconds = 12,
		breakOffCooldown = 25,

		--[[ Only appears at dusk/night, and only after the first maze shift. ]]
		spawnPhases = { Enums.Phase.Dusk, Enums.Phase.Night },
		requiresShiftCount = 1,
		maxConcurrent = 1,

		xpValue = 0,
		drops = {},

		body = {
			torso = Vector3.new(3, 5.5, 2.2),
			color = Color3.fromRGB(26, 24, 30),
			accent = Color3.fromRGB(12, 11, 14),
			eyeColor = Color3.fromRGB(236, 72, 72),
			legCount = 4,
			scale = 1.6,
		},

		spawnRooms = {}, -- spawns at the furthest room from any player
		spawnWeight = 0,

		states = { "idle", "patrol", "investigate", "chase", "attack", "breakoff", "despawn" },
	},
}

MonsterConfig.Order = { M.CaveCrawler, M.Stalker }

--[[ Baseline monster budget per room before difficulty and party scaling. ]]
MonsterConfig.BaseCountPerRoom = {
	[Enums.RoomKind.Entrance] = 0,
	[Enums.RoomKind.ExtractionChamber] = 0,
	[Enums.RoomKind.AncientVault] = 1,
	[Enums.RoomKind.MonsterNest] = 3,
	[Enums.RoomKind.MiningChamber] = 1,
	[Enums.RoomKind.ResourceChamber] = 1,
	[Enums.RoomKind.Junction] = 1,
	[Enums.RoomKind.CorridorStraight] = 0,
	[Enums.RoomKind.CorridorCurve] = 0,
	[Enums.RoomKind.DeadEnd] = 1,
	[Enums.RoomKind.PuzzleRoom] = 0,
}

--[[ Noise events the Stalker listens for: radius in studs, and how much
     interest each adds. ]]
MonsterConfig.Noise = {
	sprint = { radius = 55, interest = 0.08 },
	mine = { radius = 80, interest = 0.25 },
	attack = { radius = 95, interest = 0.35 },
	hurt = { radius = 70, interest = 0.3 },
	ability = { radius = 60, interest = 0.15 },
	revive = { radius = 45, interest = 0.1 },
}

--[[ Interest decays toward zero; above ChaseThreshold the Stalker commits. ]]
MonsterConfig.StalkerInterest = {
	DecayPerSecond = 0.035,
	InvestigateThreshold = 0.25,
	ChaseThreshold = 0.6,
	Max = 1.5,
}

--[[ AI heartbeat. Monsters far from every player tick slowly; this is the main
     performance lever for monster count. ]]
MonsterConfig.Ticks = {
	NearRadius = 150,
	NearInterval = 0.15,
	FarInterval = 1.2,
	--[[ Monsters beyond this distance from all players are frozen entirely. ]]
	SleepRadius = 420,
}

MonsterConfig.Pathfinding = {
	--[[ PathfindingService is used for navigation when the target is not in
	     direct line of sight; otherwise the monster steers directly, which is
	     both cheaper and reads better in tight corridors. ]]
	Enabled = true,
	RecomputeInterval = 1.1,
	AgentRadius = 2.5,
	AgentHeight = 5,
	WaypointReachedRadius = 4,
	MaxWaypointsFollowed = 12,
}

function MonsterConfig.get(id)
	return MonsterConfig.Monsters[id]
end

function MonsterConfig.isValid(id)
	return MonsterConfig.Monsters[id] ~= nil
end

return MonsterConfig
