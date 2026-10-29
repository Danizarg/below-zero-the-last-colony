--[[
	GameConfig.lua
	Global tunables and world layout constants.

	Everything here is data, never behaviour. Server and client both read it, so
	it must stay free of Roblox service calls at require time.
]]

local GameConfig = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Build / feature flags
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.Version = "0.1.0-mvp"

--[[ Data layout version. Bump when ProfileTemplate changes shape and add a
     matching migration step in Data/Migrations.lua. ]]
GameConfig.DataVersion = 1

--[[ When true, only the MVP subset of content (3 roles, 5 buildings) is
     selectable. Flip to false once the remaining content is implemented. ]]
GameConfig.MvpContentOnly = true

--[[ Expedition transport mode.
     "local"  - colony and caves coexist in one Place at different coordinates.
                Works in Studio with no published experience. This is the MVP
                default and the only mode currently implemented end to end.
     "teleport" - reserved for multi-Place deployment via TeleportService.
                  ExpeditionService recognises it but will refuse to start and
                  log a clear message, because the destination PlaceId does not
                  exist yet. ]]
GameConfig.TransportMode = "local"

--[[ Reserved PlaceId for the expedition Place in "teleport" mode. 0 = unset.
     Do not invent a value; fill this in only after publishing the Place. ]]
GameConfig.ExpeditionPlaceId = 0

--[[ Set false to run with an in-memory data store (no DataStore calls). The
     server auto-falls back to this when DataStores are unavailable, e.g. in
     Studio without "Enable Studio Access to API Services". ]]
GameConfig.UseDataStore = true

GameConfig.DataStoreName = "BelowZero_Profiles_v1"

--[[ Verbose server logging. Leave on during development. ]]
GameConfig.Debug = true

-- ─────────────────────────────────────────────────────────────────────────────
-- Colony world layout
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.Colony = {
	--[[ Each player owns one plot. Plots are laid out on a grid inside the
	     starting cavern, so visiting a friend's colony is a walk, not a
	     teleport. This is the simplest reliable implementation of "friends can
	     visit"; documented as a deliberate choice in GAME_DESIGN.md. ]]
	PlotSize = 352, -- studs, square
	PlotSpacing = 416, -- centre-to-centre
	PlotGridWidth = 3, -- 3x3 = 9 plots, comfortably above the 8-player cap
	MaxPlots = 9,

	--[[ Build grid resolution inside a plot. Buildings snap to this. ]]
	GridStep = 8,

	FloorY = 0,
	CavernHeight = 190,

	--[[ Where a player spawns when they arrive in their own colony. Offset from
	     plot centre. ]]
	SpawnOffset = Vector3.new(0, 4, 118),

	--[[ Cave entrance position, offset from plot centre. Interacting with it
	     opens the expedition panel. ]]
	CaveEntranceOffset = Vector3.new(0, 0, -150),

	--[[ Max simultaneous buildings per plot (guards against grief / bloat). ]]
	MaxBuildings = 48,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Inventory capacity
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.Inventory = {
	--[[ Colony storage is measured in units and extended by buildings that
	     declare a `storageBonus` effect. ]]
	BaseColonyStorage = 200,

	--[[ The expedition bag is measured in weight, so heavy crystals cost more
	     room than fungal fiber. Roughly three full mining chambers' worth, which
	     makes "do I push deeper or go home" a real decision rather than a
	     formality. ]]
	BaseBagCapacity = 180,

	--[[ Supplies a player may carry in from the colony before a run. ]]
	MaxSuppliesPerType = 8,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Expedition world layout
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.Cave = {
	--[[ Cave cells are square in plan. Rooms are built as a floor slab, a
	     ceiling slab and four walls with doorway gaps. ]]
	CellSize = 72,
	WallThickness = 4,
	RoomHeight = 34,
	DoorWidth = 20,
	DoorHeight = 18,

	--[[ Expedition instances are built far below the colony so the two never
	     share geometry or lighting volumes. Each concurrent session gets its own
	     X slot. ]]
	WorldOrigin = Vector3.new(6144, -1024, 0),
	SessionStrideX = 3072,
	MaxConcurrentSessions = 6,

	--[[ Grid bounds the generator may use. Room count comes from difficulty. ]]
	GridWidth = 7,
	GridHeight = 7,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Party / matchmaking
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.Party = {
	MvpMaxSize = 4, -- enforced now
	DesignMaxSize = 8, -- long-term target, see GAME_DESIGN.md
	InviteTimeout = 45,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Survival
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.Survival = {
	StatTickRate = 0.5, -- seconds between server stat updates

	StaminaMax = 100,
	StaminaRegenPerSecond = 7,
	StaminaSprintDrainPerSecond = 13,
	StaminaMineCost = 6,
	StaminaAttackCost = 9,
	StaminaRegenDelayAfterUse = 1.2,

	HungerMax = 100,
	--[[ Full hunger bar lasts ~18 minutes of expedition time at 0.09/s, which
	     is slightly longer than a Medium run. Food is a buffer, not a chore. ]]
	HungerDrainPerSecond = 0.09,
	HungerStarvingThreshold = 15,
	StarvingHealthDrainPerSecond = 0.8,
	StarvingStaminaRegenMultiplier = 0.35,

	SprintSpeedMultiplier = 1.5,

	--[[ Downed state. Difficulty scales the window; see DifficultyConfig. ]]
	DownedHealth = 1,
	ReviveRange = 9,
	ReviveHoldSeconds = 4,
	ReviveGrantedHealthFraction = 0.4,

	--[[ Falling / environmental damage is always telegraphed. No instant kills:
	     the lowest survivable fall leaves the player downed, not dead. ]]
	FallDamageMinHeight = 22,
	FallDamagePerStud = 2.6,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Interaction
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.Interaction = {
	--[[ Server-side tolerance when validating a client-claimed interaction. The
	     client proposes, the server measures. ]]
	MaxRange = 14,
	RangeTolerance = 4, -- added to MaxRange to absorb latency
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Networking guard rails
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.Net = {
	--[[ Default budget per route, per player: Burst requests, refilled at
	     Burst/Window per second. Individual routes override these. ]]
	DefaultBurst = 10,
	DefaultWindow = 1,

	--[[ A player exceeding this many rejected requests in a row is logged for
	     review. Nothing is auto-punished; exploit response is a manual call. ]]
	SuspicionThreshold = 40,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- NPC colonists
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.NPC = {
	StartingColonists = 3,
	--[[ Housing capacity gates population; see BuildingConfig. ]]
	AbsoluteMaxColonists = 24,

	--[[ Production is a simulation tick, not per-NPC AI. Distant colonists are
	     numbers; nearby ones get a visible rig that wanders between waypoints. ]]
	ProductionTickSeconds = 10,
	VisibleRadius = 220,
	MaxVisibleRigs = 10,

	--[[ Offline production. The colony keeps working while the player is away,
	     but capped so logging off is never the optimal strategy and never a
	     catastrophe either. ]]
	OfflineProductionEnabled = true,
	OfflineProductionMaxHours = 8,
	OfflineProductionEfficiency = 0.5,

	--[[ Colony condition decays slowly without upkeep but is floored, so a
	     colony can never be destroyed by absence. ]]
	ConditionDecayPerHour = 1.5,
	ConditionFloor = 55,
	ConditionMax = 100,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Rewards
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.Rewards = {
	--[[ XP curve: level N requires BaseXp * N ^ Exponent cumulative. ]]
	BaseXp = 120,
	Exponent = 1.35,
	MaxRoleMastery = 20,

	XpPerResourceExtracted = 1,
	XpPerMonsterKill = 12,
	XpPerObjective = 60,
	XpPerRoomDiscovered = 8,
	XpExtractionBonus = 50,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Monetization (disabled until the flow is verified against a real product)
-- ─────────────────────────────────────────────────────────────────────────────

GameConfig.Monetization = {
	--[[ HARD OFF by default. Nothing in the codebase simulates a successful
	     purchase; with this false the shop renders products as "unavailable" and
	     ProcessReceipt is never relied upon for progression. ]]
	Enabled = false,

	--[[ Free rescues per expedition, always available, never purchasable away. ]]
	FreeRescuesPerExpedition = 1,

	--[[ Target price for the optional extra rescue. Recorded here for design
	     reference only; the real price lives on the Developer Product. ]]
	RescueTargetPriceRobux = 29,

	--[[ Paid rescues are excluded from any competitive/ranked mode. ]]
	PaidRescueAllowedInRanked = false,
}

return GameConfig
