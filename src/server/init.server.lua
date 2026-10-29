--[[
	BELOW ZERO: THE LAST COLONY — server bootstrap

	Loads every service, hands each one a registry of its siblings, then starts
	them in dependency order.

	Two-phase startup (`init` then `start`) exists so services can hold
	references to each other without circular `require` chains: by the time any
	`init` runs, every module has already been required, and by the time any
	`start` runs, every service has its references.

	Network routes are registered in `start`, after the transport is up, so no
	route can be hit before its service is ready to answer.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("BelowZero")
local GameConfig = require(Shared.Config.GameConfig)
local AudioConfig = require(Shared.Config.AudioConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)

local log = Logger.new("Bootstrap")

local startedAt = os.clock()
log:info("BELOW ZERO: THE LAST COLONY v%s starting", GameConfig.Version)

--[[ Set before anything else can spawn a body. SurvivalService owns spawning so
     a death inside an expedition goes to the spectate-and-rescue flow instead
     of silently respawning the player in their colony. default.project.json
     also sets this; doing it here means the behaviour survives being synced
     into a place that already had it true. ]]
game:GetService("Players").CharacterAutoLoads = false

-- The transport must exist before any service registers a route.
Net.start()

--[[
	Load order matters only in that every module is required before any init
	runs. The list is written in rough dependency order anyway, because reading
	it top to bottom is a decent summary of how the game is put together.
]]
local LOAD_ORDER = {
	{ name = "DataService", path = { "Services", "DataService" } },
	{ name = "InventoryService", path = { "Services", "InventoryService" } },
	{ name = "ColonyService", path = { "Services", "ColonyService" } },
	{ name = "BuildingService", path = { "Services", "BuildingService" } },
	{ name = "NPCService", path = { "Services", "NPCService" } },
	{ name = "RoleService", path = { "Services", "RoleService" } },
	{ name = "PartyService", path = { "Services", "PartyService" } },
	{ name = "SurvivalService", path = { "Services", "SurvivalService" } },
	{ name = "CombatService", path = { "Services", "CombatService" } },
	{ name = "NodeService", path = { "Services", "NodeService" } },
	{ name = "MonsterService", path = { "Services", "MonsterService" } },
	{ name = "ObjectiveService", path = { "Services", "ObjectiveService" } },
	{ name = "CaveService", path = { "Services", "CaveService" } },
	{ name = "RewardService", path = { "Services", "RewardService" } },
	{ name = "ExpeditionService", path = { "Services", "ExpeditionService" } },
	{ name = "MonetizationService", path = { "Services", "MonetizationService" } },
}

local context = {
	shared = Shared,
	services = {},
}

local function resolve(path)
	local current = script
	for _, segment in ipairs(path) do
		current = current:FindFirstChild(segment)
		if not current then
			return nil, table.concat(path, "/")
		end
	end
	return current
end

-- ── Phase 1: require ─────────────────────────────────────────────────────────

local loaded = {}

for _, descriptor in ipairs(LOAD_ORDER) do
	local module, missing = resolve(descriptor.path)
	if not module then
		log:fault("module %s is missing; %s will be unavailable", tostring(missing), descriptor.name)
	else
		local ok, service = pcall(require, module)
		if not ok then
			log:fault("require %s failed: %s", descriptor.name, tostring(service))
		else
			context[descriptor.name] = service
			context.services[descriptor.name] = service
			table.insert(loaded, { name = descriptor.name, service = service })
		end
	end
end

-- ── Phase 2: init ────────────────────────────────────────────────────────────

for _, entry in ipairs(loaded) do
	if type(entry.service.init) == "function" then
		local ok, err = pcall(entry.service.init, entry.service, context)
		if not ok then
			log:fault("%s:init failed: %s", entry.name, tostring(err))
		end
	end
end

-- ── Phase 3: start ───────────────────────────────────────────────────────────

for _, entry in ipairs(loaded) do
	if type(entry.service.start) == "function" then
		local ok, err = pcall(entry.service.start, entry.service)
		if not ok then
			log:fault("%s:start failed: %s", entry.name, tostring(err))
		end
	end
end

-- ── Startup report ───────────────────────────────────────────────────────────

local routes = Net.registeredRoutes()
log:info(
	"started %d services, %d request routes, %d event routes in %.2fs",
	#loaded,
	#routes.requests,
	#routes.events,
	os.clock() - startedAt
)

local missingAudio = AudioConfig.missingAssets()
if #missingAudio > 0 then
	--[[ Reported once, on purpose: the project ships with no sound asset IDs,
	     and pretending otherwise would be worse than a startup notice. ]]
	log:info(
		"audio: %d of %d cues have no asset ID yet and will stay silent (see src/shared/Config/AudioConfig.lua)",
		#missingAudio,
		#missingAudio
	)
end

if GameConfig.TransportMode == "teleport" and GameConfig.ExpeditionPlaceId == 0 then
	log:warn(
		"TransportMode is 'teleport' but ExpeditionPlaceId is 0. Expeditions will refuse to start. "
			.. "Set GameConfig.TransportMode = 'local' for single-place play."
	)
end
