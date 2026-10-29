--[[
	InventoryService.lua

	Owns every change to what a player holds: colony storage, the expedition bag,
	tools and consumables, plus crafting.

	The whole service exists to be the only path through which item counts move.
	Clients send intents ("craft this recipe", "equip this tool"); they never send
	amounts, and nothing here reads a quantity out of a payload. That is what
	makes duplication exploits a question of auditing one file rather than
	auditing the codebase.

	Two inventories per player:
	  storage  persisted in the profile, capacity in units, survives everything
	  bag      runtime only, capacity in weight, partially lost on a failed run

	Resources gathered during an expedition land in the bag. They only reach
	storage on a successful extraction (or via the difficulty's recovery fraction
	on a failure), which is the rule the brief asks for.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Inventory = require(Shared.Lib.Inventory)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local RoleConfig = require(Shared.Config.RoleConfig)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)

local log = Logger.new("InventoryService")

local InventoryService = {}
InventoryService.__index = InventoryService

function InventoryService.new()
	local self = setmetatable({}, InventoryService)
	self._bags = {} -- [userId] = Inventory
	self._bagCapacity = {} -- [userId] = number
	self.bagChanged = Signal.new("bagChanged")
	self.storageChanged = Signal.new("storageChanged")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Capacity
-- ─────────────────────────────────────────────────────────────────────────────

function InventoryService:storageCapacity(player)
	local base = GameConfig.Inventory.BaseColonyStorage
	local effects = self.context.BuildingService and self.context.BuildingService:effectsFor(player)
	return base + ((effects and effects.storageBonus) or 0)
end

function InventoryService:bagCapacity(player)
	return self._bagCapacity[player.UserId] or GameConfig.Inventory.BaseBagCapacity
end

--[[ Recalculated when a player picks a role, because carry capacity is a role
     stat. Called by RoleService. ]]
function InventoryService:setBagCapacityFromRole(player, roleId, mastery)
	local stats = RoleConfig.resolve(roleId, mastery)
	self._bagCapacity[player.UserId] = GameConfig.Inventory.BaseBagCapacity + (stats.carryBonus or 0)
end

local function storageLimits(self, player)
	return {
		capacity = self:storageCapacity(player),
		measure = "units",
		defs = ResourceConfig.Resources,
		consumableDefs = ResourceConfig.Consumables,
	}
end

local function bagLimits(self, player)
	return {
		capacity = self:bagCapacity(player),
		measure = "weight",
		defs = ResourceConfig.Resources,
		consumableDefs = ResourceConfig.Consumables,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Storage (persisted)
-- ─────────────────────────────────────────────────────────────────────────────

--[[ The profile's storage tables wrapped in the Inventory shape, pointing at the
     same tables so a mutation persists. ]]
function InventoryService:storageOf(player)
	local profile = self.context.DataService:get(player)
	if not profile then
		return nil
	end
	profile.colony.storage = profile.colony.storage or {}
	profile.colony.consumables = profile.colony.consumables or {}
	return { items = profile.colony.storage, consumables = profile.colony.consumables }
end

function InventoryService:addToStorage(player, resourceId, amount)
	local storage = self:storageOf(player)
	if not storage then
		return { added = 0, reason = Enums.Reject.NotLoaded }
	end
	local def = ResourceConfig.get(resourceId)
	if not def then
		return { added = 0, reason = Enums.Reject.BadRequest }
	end

	local limits = storageLimits(self, player)
	limits.stackLimit = def.stackLimit
	local result = Inventory.add(storage, resourceId, amount, limits)

	if result.added > 0 then
		self.context.DataService:markDirty(player)
		self.storageChanged:Fire(player)
		self:pushStorage(player)
	end
	return result
end

function InventoryService:spendFromStorage(player, cost)
	local storage = self:storageOf(player)
	if not storage then
		return { paid = false, reason = Enums.Reject.NotLoaded }
	end
	local result = Inventory.pay(storage, cost)
	if result.paid then
		self.context.DataService:markDirty(player)
		self.storageChanged:Fire(player)
		self:pushStorage(player)
	end
	return result
end

function InventoryService:canAffordFromStorage(player, cost)
	local storage = self:storageOf(player)
	if not storage then
		return false, {}
	end
	return Inventory.canAfford(storage, cost)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Bag (runtime)
-- ─────────────────────────────────────────────────────────────────────────────

function InventoryService:bagOf(player)
	local bag = self._bags[player.UserId]
	if not bag then
		bag = Inventory.new()
		self._bags[player.UserId] = bag
	end
	return bag
end

function InventoryService:clearBag(player)
	self._bags[player.UserId] = Inventory.new()
	self:pushBag(player)
end

function InventoryService:addToBag(player, resourceId, amount)
	local def = ResourceConfig.get(resourceId)
	if not def then
		return { added = 0, reason = Enums.Reject.BadRequest }
	end
	local limits = bagLimits(self, player)
	limits.stackLimit = def.stackLimit

	local result = Inventory.add(self:bagOf(player), resourceId, amount, limits)
	if result.added > 0 then
		self.bagChanged:Fire(player)
		self:pushBag(player)
	end
	return result
end

function InventoryService:addConsumableToBag(player, consumableId, amount)
	local def = ResourceConfig.Consumables[consumableId]
	if not def then
		return { added = 0, reason = Enums.Reject.BadRequest }
	end
	local limits = bagLimits(self, player)
	limits.stackLimit = def.stackLimit

	local result = Inventory.addConsumable(self:bagOf(player), consumableId, amount, limits)
	if result.added > 0 then
		self.bagChanged:Fire(player)
		self:pushBag(player)
	end
	return result
end

--[[
	Move the bag into storage. Called on a successful extraction.

	@param keptFraction number|nil  nil = keep everything (clean extraction)
	@return { deposited = { [id] = n }, lost = { [id] = n }, overflow = { [id] = n } }
]]
function InventoryService:depositBag(player, keptFraction)
	local bag = self:bagOf(player)
	local storage = self:storageOf(player)
	if not storage then
		return { deposited = {}, lost = {}, overflow = {} }
	end

	local lost = {}
	local toDeposit = bag

	if keptFraction ~= nil and keptFraction < 1 then
		--[[ Ancient keys are flagged protectedOnDeath in ResourceConfig, so a
		     failed run never costs the player their escape progress. ]]
		local protectedIds = {}
		for id, def in pairs(ResourceConfig.Resources) do
			if def.protectedOnDeath then
				protectedIds[id] = true
			end
		end
		local split = Inventory.applyLoss(bag, keptFraction, protectedIds)
		toDeposit = split.kept
		lost = split.lost
	end

	local merge = Inventory.merge(storage, toDeposit, function(id)
		local def = ResourceConfig.get(id) or ResourceConfig.Consumables[id]
		local limits = storageLimits(self, player)
		limits.stackLimit = def and def.stackLimit or nil
		return limits
	end)

	self._bags[player.UserId] = Inventory.new()
	self.context.DataService:markDirty(player)
	self.storageChanged:Fire(player)
	self:pushStorage(player)
	self:pushBag(player)

	if merge.anyOverflow then
		--[[ Storage full. Overflow is reported so the results screen can say
		     "your storage overflowed" rather than quietly eating the haul. ]]
		log:info("%s overflowed colony storage on deposit", player.Name)
	end

	return { deposited = merge.moved, lost = lost, overflow = merge.leftover }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tools
-- ─────────────────────────────────────────────────────────────────────────────

function InventoryService:equippedTool(player)
	local profile = self.context.DataService:get(player)
	if not profile then
		return ResourceConfig.Tools.bare_hands
	end
	local toolId = profile.colony.equippedTool or "bare_hands"
	local owned = profile.colony.tools and profile.colony.tools[toolId]
	if not owned then
		return ResourceConfig.Tools.bare_hands
	end
	return ResourceConfig.Tools[toolId] or ResourceConfig.Tools.bare_hands
end

function InventoryService:toolDurability(player, toolId)
	local profile = self.context.DataService:get(player)
	if not profile then
		return 0
	end
	local entry = profile.colony.tools and profile.colony.tools[toolId]
	return entry and entry.durability or 0
end

--[[
	Spend durability. A tool at zero durability is removed and the player falls
	back to bare hands, which is a setback rather than a dead end — there is
	always a way to keep playing.
]]
function InventoryService:wearTool(player, amount)
	local profile = self.context.DataService:get(player)
	if not profile then
		return
	end
	local toolId = profile.colony.equippedTool
	local def = ResourceConfig.Tools[toolId]
	if not def or def.maxDurability <= 0 then
		return -- bare hands never wear out
	end

	local entry = profile.colony.tools[toolId]
	if not entry then
		return
	end

	entry.durability = math.max(0, (entry.durability or 0) - amount)
	self.context.DataService:markDirty(player)

	if entry.durability <= 0 then
		profile.colony.tools[toolId] = nil
		profile.colony.equippedTool = "bare_hands"
		self:push(player, Routes.Push.Notify, {
			kind = "warning",
			title = "Tool broken",
			body = ("Your %s has broken. Back to bare hands."):format(def.name),
		})
		log:info("%s broke their %s", player.Name, def.name)
	end

	self:pushStorage(player)
end

function InventoryService:grantTool(player, toolId)
	local def = ResourceConfig.Tools[toolId]
	if not def then
		return false
	end
	local profile = self.context.DataService:get(player)
	if not profile then
		return false
	end
	profile.colony.tools = profile.colony.tools or {}
	profile.colony.tools[toolId] = { durability = def.maxDurability }
	profile.colony.equippedTool = toolId
	self.context.DataService:markDirty(player)
	self:pushStorage(player)
	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Crafting
-- ─────────────────────────────────────────────────────────────────────────────

function InventoryService:recipeById(recipeId)
	for _, recipe in ipairs(ResourceConfig.Recipes) do
		if recipe.id == recipeId then
			return recipe
		end
	end
	return nil
end

--[[ Recipes that are currently craftable, with their blockers, so the UI can
     show a greyed-out row with a reason instead of hiding it. ]]
function InventoryService:availableRecipes(player)
	local out = {}
	local storage = self:storageOf(player)
	for _, recipe in ipairs(ResourceConfig.Recipes) do
		local hasStation, stationReason = self:_hasStation(player, recipe)
		local affordable, missing = true, {}
		if storage then
			affordable, missing = Inventory.canAfford(storage, recipe.cost)
		end
		table.insert(out, {
			id = recipe.id,
			name = recipe.name,
			cost = recipe.cost,
			station = recipe.station,
			stationLevel = recipe.stationLevel or 1,
			available = hasStation and affordable,
			blockedBy = (not hasStation) and stationReason or ((not affordable) and "resources" or nil),
			missing = missing,
		})
	end
	return out
end

function InventoryService:_hasStation(player, recipe)
	if not recipe.station then
		return true
	end
	local BuildingService = self.context.BuildingService
	if not BuildingService then
		return false, "station"
	end
	local level = BuildingService:highestLevelOf(player, recipe.station)
	if level <= 0 then
		return false, "station"
	end
	if level < (recipe.stationLevel or 1) then
		return false, "station_level"
	end
	return true
end

function InventoryService:craft(player, recipeId)
	local recipe = self:recipeById(recipeId)
	if not recipe then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	--[[ Crafting happens in the colony only. Allowing it mid-expedition would
	     let a player conjure a fresh pick at the bottom of the caves, which
	     removes the point of durability. ]]
	if self.context.ColonyService:zoneOf(player) ~= Enums.Zone.Colony then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end

	if self.context.DataService:isReadOnly(player) then
		return { ok = false, reason = Enums.Reject.NotLoaded, detail = "read_only" }
	end

	local hasStation, stationReason = self:_hasStation(player, recipe)
	if not hasStation then
		return { ok = false, reason = Enums.Reject.NoPermission, detail = stationReason }
	end

	local payment = self:spendFromStorage(player, recipe.cost)
	if not payment.paid then
		return { ok = false, reason = Enums.Reject.NotEnoughResources, missing = payment.missing }
	end

	if recipe.grantsTool then
		self:grantTool(player, recipe.grantsTool)
	end

	if recipe.grantsConsumable then
		local storage = self:storageOf(player)
		local def = ResourceConfig.Consumables[recipe.grantsConsumable.id]
		local limits = storageLimits(self, player)
		limits.stackLimit = def and def.stackLimit or nil
		Inventory.addConsumable(storage, recipe.grantsConsumable.id, recipe.grantsConsumable.count, limits)
		self.context.DataService:markDirty(player)
		self:pushStorage(player)
	end

	log:info("%s crafted %s", player.Name, recipe.id)
	return { ok = true, recipeId = recipe.id }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Consumables
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Use a consumable from the bag (in an expedition) or from storage (in the
     colony). Effects are applied by SurvivalService, which owns the stats. ]]
function InventoryService:useConsumable(player, consumableId)
	local def = ResourceConfig.Consumables[consumableId]
	if not def then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	local inColony = self.context.ColonyService:zoneOf(player) == Enums.Zone.Colony
	local source = inColony and self:storageOf(player) or self:bagOf(player)
	if not source then
		return { ok = false, reason = Enums.Reject.NotLoaded }
	end

	local removal = Inventory.removeConsumable(source, consumableId, 1)
	if removal.removed <= 0 then
		return { ok = false, reason = Enums.Reject.NotEnoughResources }
	end

	if inColony then
		self.context.DataService:markDirty(player)
		self:pushStorage(player)
	else
		self:pushBag(player)
	end

	local applied = self.context.SurvivalService:applyConsumable(player, def)
	return { ok = true, consumableId = consumableId, applied = applied }
end

--[[
	Load supplies from storage into the bag before a run.
	@param requested { [consumableId] = count }
]]
function InventoryService:loadSupplies(player, requested)
	if type(requested) ~= "table" then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	if self.context.ColonyService:zoneOf(player) ~= Enums.Zone.Colony then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end

	local storage = self:storageOf(player)
	if not storage then
		return { ok = false, reason = Enums.Reject.NotLoaded }
	end

	local loaded = {}
	--[[ Deterministic order so a partially-full bag always takes the same items,
	     and the client's preview matches the result. ]]
	local ids = {}
	for id in pairs(requested) do
		if ResourceConfig.Consumables[id] then
			table.insert(ids, id)
		end
	end
	table.sort(ids)

	for _, id in ipairs(ids) do
		local want = math.clamp(math.floor(tonumber(requested[id]) or 0), 0, GameConfig.Inventory.MaxSuppliesPerType)
		if want > 0 then
			local held = Inventory.consumableCount(storage, id)
			local take = math.min(want, held)
			if take > 0 then
				local removal = Inventory.removeConsumable(storage, id, take)
				if removal.removed > 0 then
					local added = self:addConsumableToBag(player, id, removal.removed)
					if added.added < removal.removed then
						-- Bag could not take it all; put the remainder back.
						local returned = removal.removed - added.added
						Inventory.addConsumable(storage, id, returned, storageLimits(self, player))
					end
					if added.added > 0 then
						loaded[id] = added.added
					end
				end
			end
		end
	end

	self.context.DataService:markDirty(player)
	self:pushStorage(player)
	return { ok = true, loaded = loaded }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Replication
-- ─────────────────────────────────────────────────────────────────────────────

function InventoryService:push(player, route, payload)
	Net.fire(player, route, payload)
end

function InventoryService:pushStorage(player)
	local storage = self:storageOf(player)
	if not storage then
		return
	end
	local profile = self.context.DataService:get(player)
	Net.fire(player, Routes.Push.InventorySync, {
		storage = storage.items,
		consumables = storage.consumables,
		capacity = self:storageCapacity(player),
		used = Inventory.totalUnits(storage),
		tools = profile and profile.colony.tools or {},
		equippedTool = profile and profile.colony.equippedTool or "bare_hands",
		recipes = self:availableRecipes(player),
	})
end

function InventoryService:pushBag(player)
	local bag = self:bagOf(player)
	Net.fire(player, Routes.Push.InventorySync, {
		bag = bag.items,
		bagConsumables = bag.consumables,
		bagCapacity = self:bagCapacity(player),
		bagUsed = Inventory.totalWeight(bag, ResourceConfig.Resources, ResourceConfig.Consumables),
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function InventoryService:init(context)
	self.context = context
end

function InventoryService:start()
	Net.handle(Routes.Request.Craft, function(player, payload)
		if type(payload) ~= "table" or type(payload.recipeId) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:craft(player, payload.recipeId)
	end, Routes.limitsFor(Routes.Request.Craft))

	Net.handle(Routes.Request.EquipTool, function(player, payload)
		if type(payload) ~= "table" or type(payload.toolId) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		local profile = self.context.DataService:get(player)
		if not profile then
			return { ok = false, reason = Enums.Reject.NotLoaded }
		end
		if payload.toolId ~= "bare_hands" and not (profile.colony.tools or {})[payload.toolId] then
			return { ok = false, reason = Enums.Reject.BadRequest, detail = "not_owned" }
		end
		profile.colony.equippedTool = payload.toolId
		self.context.DataService:markDirty(player)
		self:pushStorage(player)
		return { ok = true, toolId = payload.toolId }
	end)

	Net.handle(Routes.Request.UseConsumable, function(player, payload)
		if type(payload) ~= "table" or type(payload.consumableId) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:useConsumable(player, payload.consumableId)
	end, Routes.limitsFor(Routes.Request.UseConsumable))

	Net.handle(Routes.Request.LoadoutSupplies, function(player, payload)
		if type(payload) ~= "table" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:loadSupplies(player, payload.supplies or {})
	end)

	Net.handle(Routes.Request.DepositBag, function(player)
		if self.context.ColonyService:zoneOf(player) ~= Enums.Zone.Colony then
			return { ok = false, reason = Enums.Reject.WrongZone }
		end
		local result = self:depositBag(player, nil)
		return { ok = true, deposited = result.deposited, overflow = result.overflow }
	end)

	self.context.DataService.profileLoaded:Connect(function(player)
		self._bags[player.UserId] = Inventory.new()
		self._bagCapacity[player.UserId] = GameConfig.Inventory.BaseBagCapacity
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._bags[player.UserId] = nil
		self._bagCapacity[player.UserId] = nil
	end)

	log:info("ready")
end

return InventoryService.new()
