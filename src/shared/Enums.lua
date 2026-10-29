--[[
	Enums.lua
	Canonical string identifiers used across server, client and saved data.

	Rule: these string values are PERSISTED in player profiles. Never rename a
	value without adding a migration in Data/Migrations.lua. Adding new values is
	always safe.
]]

local Enums = {}

Enums.Resource = {
	Stone = "stone",
	Fiber = "fiber",
	Iron = "iron",
	Coal = "coal",
	Mushroom = "mushroom",
	Herb = "herb",
	Crystal = "crystal",
	Relic = "relic",
	AncientKey = "ancient_key",
}

Enums.Building = {
	TownHall = "town_hall",
	Housing = "housing",
	Farm = "farm",
	Workshop = "workshop",
	Infirmary = "infirmary",
	-- Defined for later expansion, not buildable while GameConfig.MvpContentOnly.
	Kitchen = "kitchen",
	Barracks = "barracks",
	ResearchLab = "research_lab",
	Watchtower = "watchtower",
	Generator = "generator",
}

Enums.Role = {
	Runner = "runner",
	Medic = "medic",
	Guardian = "guardian",
	-- Architected, abilities stubbed. See RoleConfig.
	Cook = "cook",
	Engineer = "engineer",
	Researcher = "researcher",
}

Enums.Job = {
	Farmer = "farmer",
	Cook = "cook",
	Medic = "medic",
	Builder = "builder",
	Miner = "miner",
	Guard = "guard",
	Researcher = "researcher",
	Idle = "idle",
}

Enums.Monster = {
	CaveCrawler = "cave_crawler",
	Stalker = "stalker",
}

Enums.Difficulty = {
	Easy = "easy",
	Medium = "medium",
	Hard = "hard",
}

--[[ Expedition clock phases, in order. ]]
Enums.Phase = {
	Prep = "prep",
	Day = "day",
	Dusk = "dusk",
	Night = "night",
	Ended = "ended",
}

Enums.PhaseOrder = { "prep", "day", "dusk", "night" }

Enums.RoomKind = {
	Entrance = "entrance",
	CorridorStraight = "corridor_straight",
	CorridorCurve = "corridor_curve",
	Junction = "junction",
	DeadEnd = "dead_end",
	MiningChamber = "mining_chamber",
	ResourceChamber = "resource_chamber",
	MonsterNest = "monster_nest",
	PuzzleRoom = "puzzle_room",
	AncientVault = "ancient_vault",
	ExtractionChamber = "extraction_chamber",
}

Enums.Biome = {
	FungalHollow = "fungal_hollow",
	IronDepths = "iron_depths",
	CrystalReach = "crystal_reach",
}

--[[ Per-player state inside an expedition. ]]
Enums.MemberState = {
	Alive = "alive",
	Downed = "downed",
	Dead = "dead",
	Extracted = "extracted",
}

Enums.Zone = {
	Colony = "colony",
	Expedition = "expedition",
}

--[[ Cardinal directions used by the cave grid. Values are grid deltas. ]]
Enums.Direction = {
	North = "N",
	East = "E",
	South = "S",
	West = "W",
}

Enums.DirectionList = { "N", "E", "S", "W" }

Enums.DirectionDelta = {
	N = { x = 0, y = -1 },
	E = { x = 1, y = 0 },
	S = { x = 0, y = 1 },
	W = { x = -1, y = 0 },
}

Enums.DirectionOpposite = {
	N = "S",
	E = "W",
	S = "N",
	W = "E",
}

--[[ Reason codes reported to the client when an action is rejected. ]]
Enums.Reject = {
	RateLimited = "rate_limited",
	NotLoaded = "not_loaded",
	BadRequest = "bad_request",
	NoPermission = "no_permission",
	NotEnoughResources = "not_enough_resources",
	InventoryFull = "inventory_full",
	WrongZone = "wrong_zone",
	TooFar = "too_far",
	OnCooldown = "on_cooldown",
	NotImplemented = "not_implemented",
	Busy = "busy",
	Occupied = "occupied",
	LimitReached = "limit_reached",
}

return Enums
