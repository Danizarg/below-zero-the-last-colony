--[[
	BuildingService.lua

	Construction, upgrades, repairs and the colony effect table.

	Everything a client can ask for here is a *proposal*: a building id, a grid
	cell and a rotation. The server decides whether that is legal, what it costs
	and whether the actor is allowed to do it. Nothing reads a cost, a level or a
	resource amount out of a payload.

	Validation order is deliberate — cheapest and most likely to fail first, with
	the resource spend last, so a rejected placement never leaves a partial
	charge behind:

		1. actor has a plot and permission on it
		2. building exists, is implemented, and is unlocked
		3. count and uniqueness limits
		4. footprint fits inside the plot
		5. footprint does not overlap an existing building
		6. actor can afford it
		7. spend, record, build
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local BuildingBuilder = require(script.Parent.Parent.World.BuildingBuilder)
local BuildingConfig = require(Shared.Config.BuildingConfig)
local ColonyBuilder = require(script.Parent.Parent.World.ColonyBuilder)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)
local TableUtil = require(Shared.Util.TableUtil)

local log = Logger.new("BuildingService")

local BuildingService = {}
BuildingService.__index = BuildingService

local VALID_ROTATIONS = { [0] = true, [90] = true, [180] = true, [270] = true }

function BuildingService.new()
	local self = setmetatable({}, BuildingService)
	self._models = {} -- [userId] = { [uid] = Model }
	self._effectCache = {} -- [userId] = effects table
	self.buildingChanged = Signal.new("buildingChanged")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Queries
-- ─────────────────────────────────────────────────────────────────────────────

function BuildingService:placements(player)
	local profile = self.context.DataService:get(player)
	if not profile then
		return {}
	end
	profile.colony.buildings = profile.colony.buildings or {}
	return profile.colony.buildings
end

function BuildingService:findPlacement(player, uid)
	for index, placement in ipairs(self:placements(player)) do
		if placement.uid == uid then
			return placement, index
		end
	end
	return nil, nil
end

function BuildingService:countOf(player, buildingId)
	local count = 0
	for _, placement in ipairs(self:placements(player)) do
		if placement.id == buildingId then
			count += 1
		end
	end
	return count
end

function BuildingService:highestLevelOf(player, buildingId)
	local best = 0
	for _, placement in ipairs(self:placements(player)) do
		if placement.id == buildingId then
			best = math.max(best, placement.level or 1)
		end
	end
	return best
end

--[[
	Aggregate every placed building's effects into one table.

	Systems read named keys from here and never look at building ids, so adding
	a building that grants population or storage needs no change outside config.

	Cached per player and invalidated on any change; the colony snapshot and the
	NPC production tick both read it every few seconds.
]]
function BuildingService:effectsFor(player)
	local cached = self._effectCache[player.UserId]
	if cached then
		return cached
	end

	local effects = {
		population = 0,
		foodPerTick = 0,
		storageBonus = 0,
		healRate = 0,
		researchPerTick = 0,
		productionMult = 1,
		reviveWindowBonus = 0,
		shiftWarningBonus = 0,
		jobSlots = {},
		craftStations = {},
	}

	for _, placement in ipairs(self:placements(player)) do
		local levelData = BuildingConfig.levelData(placement.id, placement.level)
		if levelData and levelData.effects then
			local source = levelData.effects

			--[[ A damaged building contributes proportionally less. Condition
			     therefore matters without ever switching a building off
			     entirely, which would feel like a punishment spiral. ]]
			local condition = 1
			if levelData.maxHealth and levelData.maxHealth > 0 then
				condition =
					math.clamp((placement.health or levelData.maxHealth) / levelData.maxHealth, 0.35, 1)
			end

			effects.population += math.floor((source.population or 0) * condition)
			effects.foodPerTick += (source.foodPerTick or 0) * condition
			effects.storageBonus += math.floor((source.storageBonus or 0) * condition)
			effects.healRate += (source.healRate or 0) * condition
			effects.researchPerTick += (source.researchPerTick or 0) * condition
			effects.reviveWindowBonus += (source.reviveWindowBonus or 0)
			effects.shiftWarningBonus += (source.shiftWarningBonus or 0)

			if source.productionMult then
				effects.productionMult *= source.productionMult
			end

			for job, slots in pairs(source.jobSlots or {}) do
				effects.jobSlots[job] = (effects.jobSlots[job] or 0) + math.floor(slots * condition)
			end

			if source.craftStation then
				local existing = effects.craftStations[source.craftStation] or 0
				effects.craftStations[source.craftStation] = math.max(existing, placement.level or 1)
			end
		end
	end

	effects.population = math.min(effects.population, GameConfig.NPC.AbsoluteMaxColonists)
	self._effectCache[player.UserId] = effects
	return effects
end

function BuildingService:invalidate(player)
	self._effectCache[player.UserId] = nil
end

--[[
	Which buildings the player may place right now, and why not when they cannot.
	`requires` is the authoritative gate; the `unlocks` lists in BuildingConfig
	are documentation of the intended progression order.
]]
function BuildingService:unlockedBuildings(player)
	local out = {}
	for _, buildingId in ipairs(BuildingConfig.Order) do
		local def = BuildingConfig.get(buildingId)
		local entry = {
			id = buildingId,
			name = def.name,
			description = def.description,
			icon = def.icon,
			footprint = def.footprint,
			maxLevel = #def.levels,
			cost = def.levels[1].cost,
			count = self:countOf(player, buildingId),
			maxCount = def.unique and 1 or def.maxCount,
			implemented = def.implemented,
		}

		if GameConfig.MvpContentOnly and not def.implemented then
			entry.locked = true
			entry.lockReason = "coming_soon"
		else
			for requiredId, requiredLevel in pairs(def.requires or {}) do
				if self:highestLevelOf(player, requiredId) < requiredLevel then
					local requiredDef = BuildingConfig.get(requiredId)
					entry.locked = true
					entry.lockReason = "requires"
					entry.requiresText = ("%s Lv%d"):format(
						requiredDef and requiredDef.name or requiredId,
						requiredLevel
					)
					break
				end
			end
		end

		if not entry.locked and entry.maxCount and entry.count >= entry.maxCount then
			entry.atLimit = true
		end

		table.insert(out, entry)
	end
	return out
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Footprint maths
-- ─────────────────────────────────────────────────────────────────────────────

local function rectFor(placement)
	local w, d = BuildingBuilder.footprintCells(placement.id, placement.rot or 0)
	local halfW, halfD = w / 2, d / 2
	return {
		minX = placement.gx - halfW,
		maxX = placement.gx + halfW,
		minZ = placement.gz - halfD,
		maxZ = placement.gz + halfD,
	}
end

local function overlaps(a, b)
	--[[ Strictly-less comparisons: two buildings sharing an edge do not overlap,
	     so a player can place flush rows without fighting the grid. ]]
	return a.minX < b.maxX and b.minX < a.maxX and a.minZ < b.maxZ and b.minZ < a.maxZ
end

function BuildingService:_footprintFree(player, candidate, ignoreUid)
	local candidateRect = rectFor(candidate)
	for _, placement in ipairs(self:placements(player)) do
		if placement.uid ~= ignoreUid then
			if overlaps(candidateRect, rectFor(placement)) then
				return false, placement
			end
		end
	end
	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- World projection
-- ─────────────────────────────────────────────────────────────────────────────

function BuildingService:_buildingsFolder(player)
	local plot = self.context.ColonyService:plotInstance(player)
	return plot and plot:FindFirstChild("Buildings") or nil
end

function BuildingService:_spawnModel(player, placement)
	local plotIndex = self.context.ColonyService:plotOf(player)
	local folder = self:_buildingsFolder(player)
	if not plotIndex or not folder then
		return nil
	end

	local origin = ColonyBuilder.gridToWorld(plotIndex, placement.gx, placement.gz)
	origin = Vector3.new(origin.X, GameConfig.Colony.FloorY + 2, origin.Z)

	local model = BuildingBuilder.build(placement, origin, folder)
	if model then
		self._models[player.UserId] = self._models[player.UserId] or {}
		self._models[player.UserId][placement.uid] = model
	end
	return model
end

function BuildingService:_destroyModel(player, uid)
	local models = self._models[player.UserId]
	if not models then
		return
	end
	local model = models[uid]
	if model then
		model:Destroy()
		models[uid] = nil
	end
end

--[[ Rebuild the whole plot from the profile. Called when a plot is claimed, and
     after any change that alters a building's appearance. ]]
function BuildingService:rebuildPlot(player)
	local folder = self:_buildingsFolder(player)
	if not folder then
		return
	end
	folder:ClearAllChildren()
	self._models[player.UserId] = {}

	local placements = self:placements(player)

	--[[ A colony with no Town Hall has no centre, so a new player (or one whose
	     hall was somehow lost) is granted one free. BuildingConfig marks it
	     grantedFree; cost only applies to deliberate rebuilds. ]]
	local hasTownHall = false
	for _, placement in ipairs(placements) do
		if placement.id == Enums.Building.TownHall then
			hasTownHall = true
			break
		end
	end

	if not hasTownHall then
		local def = BuildingConfig.get(Enums.Building.TownHall)
		local profile = self.context.DataService:get(player)
		if def and profile then
			local uid = "b" .. tostring(profile.colony.nextBuildingUid or 1)
			profile.colony.nextBuildingUid = (profile.colony.nextBuildingUid or 1) + 1
			table.insert(placements, {
				uid = uid,
				id = Enums.Building.TownHall,
				gx = 0,
				gz = 0,
				rot = 0,
				level = 1,
				health = def.levels[1].maxHealth,
			})
			self.context.DataService:markDirty(player)
			log:info("granted a starting Town Hall to %s", player.Name)
		end
	end

	for _, placement in ipairs(placements) do
		self:_spawnModel(player, placement)
	end

	self:invalidate(player)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Actions
-- ─────────────────────────────────────────────────────────────────────────────

function BuildingService:place(player, buildingId, gx, gz, rotation)
	-- 1. Permission.
	local plotIndex, permissionReason = self.context.ColonyService:requireOwnPlot(player)
	if not plotIndex then
		return { ok = false, reason = permissionReason }
	end
	if self.context.ColonyService:zoneOf(player) ~= Enums.Zone.Colony then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end
	if self.context.DataService:isReadOnly(player) then
		return { ok = false, reason = Enums.Reject.NotLoaded, detail = "read_only" }
	end

	-- 2. Building definition and unlock state.
	local def = BuildingConfig.get(buildingId)
	if not def then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	if GameConfig.MvpContentOnly and not def.implemented then
		return { ok = false, reason = Enums.Reject.NotImplemented }
	end
	for requiredId, requiredLevel in pairs(def.requires or {}) do
		if self:highestLevelOf(player, requiredId) < requiredLevel then
			return { ok = false, reason = Enums.Reject.NoPermission, detail = "requires" }
		end
	end

	-- 3. Limits.
	local placements = self:placements(player)
	if #placements >= GameConfig.Colony.MaxBuildings then
		return { ok = false, reason = Enums.Reject.LimitReached, detail = "plot_full" }
	end
	local limit = def.unique and 1 or def.maxCount
	if limit and self:countOf(player, buildingId) >= limit then
		return { ok = false, reason = Enums.Reject.LimitReached, detail = "building_limit" }
	end

	-- 4. Geometry: integral grid cell, legal rotation, inside the plot.
	gx = math.floor(tonumber(gx) or 0)
	gz = math.floor(tonumber(gz) or 0)
	rotation = math.floor(tonumber(rotation) or 0) % 360
	if not VALID_ROTATIONS[rotation] then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "rotation" }
	end

	local w, d = BuildingBuilder.footprintCells(buildingId, rotation)
	if not ColonyBuilder.footprintInBounds(gx, gz, w, d) then
		return { ok = false, reason = Enums.Reject.TooFar, detail = "out_of_plot" }
	end

	-- 5. Overlap.
	local candidate = { id = buildingId, gx = gx, gz = gz, rot = rotation, uid = "__candidate" }
	local free, blocker = self:_footprintFree(player, candidate)
	if not free then
		return { ok = false, reason = Enums.Reject.Occupied, detail = blocker and blocker.id or nil }
	end

	-- 6 and 7. Pay, then record. Paying last means a rejection never charges.
	local cost = def.grantedFree and self:countOf(player, buildingId) == 0 and {} or def.levels[1].cost
	local payment = self.context.InventoryService:spendFromStorage(player, cost)
	if not payment.paid then
		return { ok = false, reason = Enums.Reject.NotEnoughResources, missing = payment.missing }
	end

	local profile = self.context.DataService:get(player)
	local uid = "b" .. tostring(profile.colony.nextBuildingUid or 1)
	profile.colony.nextBuildingUid = (profile.colony.nextBuildingUid or 1) + 1

	local placement = {
		uid = uid,
		id = buildingId,
		gx = gx,
		gz = gz,
		rot = rotation,
		level = 1,
		health = def.levels[1].maxHealth,
	}
	table.insert(placements, placement)

	self.context.DataService:markDirty(player)
	self:_spawnModel(player, placement)
	self:invalidate(player)
	self:_afterChange(player, "placed", placement)

	return { ok = true, placement = placement }
end

function BuildingService:remove(player, uid)
	local plotIndex, permissionReason = self.context.ColonyService:requireOwnPlot(player)
	if not plotIndex then
		return { ok = false, reason = permissionReason }
	end
	if self.context.DataService:isReadOnly(player) then
		return { ok = false, reason = Enums.Reject.NotLoaded, detail = "read_only" }
	end

	local placement, index = self:findPlacement(player, uid)
	if not placement then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	local def = BuildingConfig.get(placement.id)
	if def and def.unique and placement.id == Enums.Building.TownHall then
		--[[ The Town Hall is the colony's anchor and the thing that unlocks
		     everything else. Removing it would strand the player, so it is not
		     demolishable. ]]
		return { ok = false, reason = Enums.Reject.NoPermission, detail = "cannot_demolish" }
	end

	--[[ Refund half of the cumulative build cost, rounded down. Generous enough
	     that experimenting with a layout is not punished, mean enough that
	     demolition is not a resource laundry. ]]
	local refund = {}
	for level = 1, (placement.level or 1) do
		local levelData = BuildingConfig.levelData(placement.id, level)
		if levelData then
			refund = TableUtil.addMaps(refund, levelData.cost)
		end
	end
	refund = TableUtil.scaleMap(refund, 0.5, math.floor)

	table.remove(self:placements(player), index)
	self:_destroyModel(player, uid)
	self.context.DataService:markDirty(player)
	self:invalidate(player)

	for resourceId, amount in pairs(refund) do
		self.context.InventoryService:addToStorage(player, resourceId, amount)
	end

	self:_afterChange(player, "removed", placement)
	return { ok = true, refund = refund }
end

function BuildingService:upgrade(player, uid)
	local plotIndex, permissionReason = self.context.ColonyService:requireOwnPlot(player)
	if not plotIndex then
		return { ok = false, reason = permissionReason }
	end
	if self.context.DataService:isReadOnly(player) then
		return { ok = false, reason = Enums.Reject.NotLoaded, detail = "read_only" }
	end

	local placement = self:findPlacement(player, uid)
	if not placement then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	local cost, nextLevel = BuildingConfig.upgradeCost(placement.id, placement.level or 1)
	if not cost then
		return { ok = false, reason = Enums.Reject.LimitReached, detail = "max_level" }
	end

	local payment = self.context.InventoryService:spendFromStorage(player, cost)
	if not payment.paid then
		return { ok = false, reason = Enums.Reject.NotEnoughResources, missing = payment.missing }
	end

	placement.level = nextLevel
	local levelData = BuildingConfig.levelData(placement.id, nextLevel)
	--[[ An upgrade restores condition: you have just rebuilt it. ]]
	placement.health = levelData and levelData.maxHealth or placement.health

	self.context.DataService:markDirty(player)
	self:_destroyModel(player, uid)
	self:_spawnModel(player, placement)
	self:invalidate(player)
	self:_afterChange(player, "upgraded", placement)

	return { ok = true, placement = placement }
end

function BuildingService:repair(player, uid)
	local plotIndex, permissionReason = self.context.ColonyService:requireOwnPlot(player)
	if not plotIndex then
		return { ok = false, reason = permissionReason }
	end
	--[[ Same gate as place, upgrade and remove; repair spends resources too. ]]
	if self.context.DataService:isReadOnly(player) then
		return { ok = false, reason = Enums.Reject.NotLoaded, detail = "read_only" }
	end

	local placement = self:findPlacement(player, uid)
	if not placement then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	local levelData = BuildingConfig.levelData(placement.id, placement.level)
	if not levelData then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	if (placement.health or 0) >= levelData.maxHealth then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "not_damaged" }
	end

	local cost = BuildingConfig.repairCost(placement.id, placement.level, placement.health or 0)
	local payment = self.context.InventoryService:spendFromStorage(player, cost)
	if not payment.paid then
		return { ok = false, reason = Enums.Reject.NotEnoughResources, missing = payment.missing }
	end

	placement.health = levelData.maxHealth
	self.context.DataService:markDirty(player)
	self:invalidate(player)
	self:_afterChange(player, "repaired", placement)

	return { ok = true, placement = placement, cost = cost }
end

--[[ Apply wear to a building, used by NPC condition decay. Floors at 35% of max
     so a neglected colony degrades but never collapses. ]]
function BuildingService:damage(player, uid, amount)
	local placement = self:findPlacement(player, uid)
	if not placement then
		return
	end
	local levelData = BuildingConfig.levelData(placement.id, placement.level)
	if not levelData then
		return
	end
	local floor = levelData.maxHealth * 0.35
	placement.health = math.max(floor, (placement.health or levelData.maxHealth) - amount)
	self.context.DataService:markDirty(player)
	self:invalidate(player)
end

function BuildingService:heal(player, uid, amount)
	local placement = self:findPlacement(player, uid)
	if not placement then
		return
	end
	local levelData = BuildingConfig.levelData(placement.id, placement.level)
	if not levelData then
		return
	end
	placement.health = math.min(levelData.maxHealth, (placement.health or 0) + amount)
	self.context.DataService:markDirty(player)
	self:invalidate(player)
end

function BuildingService:_afterChange(player, action, placement)
	self.buildingChanged:Fire(player, action, placement)

	--[[ Workers are reassigned BEFORE the snapshot goes out.
	     `onBuildingsChanged` idles any colonist whose building just
	     vanished, and it announces that with a Notify only — it never
	     pushes a colony snapshot of its own. So pushing first meant the
	     client was told the job usage of a building that had already been
	     demolished, and kept being told it until some later colony push
	     (the ten-second production tick, or the player's next action)
	     happened to correct it. ]]
	if self.context.NPCService then
		self.context.NPCService:onBuildingsChanged(player)
	end

	self.context.ColonyService:pushColony(player)
	self.context.InventoryService:pushStorage(player)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function BuildingService:init(context)
	self.context = context
end

function BuildingService:start()
	Net.handle(Routes.Request.PlaceBuilding, function(player, payload)
		if type(payload) ~= "table" or type(payload.buildingId) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:place(player, payload.buildingId, payload.gx, payload.gz, payload.rot)
	end, Routes.limitsFor(Routes.Request.PlaceBuilding))

	Net.handle(Routes.Request.RemoveBuilding, function(player, payload)
		if type(payload) ~= "table" or type(payload.uid) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:remove(player, payload.uid)
	end, Routes.limitsFor(Routes.Request.RemoveBuilding))

	Net.handle(Routes.Request.UpgradeBuilding, function(player, payload)
		if type(payload) ~= "table" or type(payload.uid) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:upgrade(player, payload.uid)
	end, Routes.limitsFor(Routes.Request.UpgradeBuilding))

	Net.handle(Routes.Request.RepairBuilding, function(player, payload)
		if type(payload) ~= "table" or type(payload.uid) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:repair(player, payload.uid)
	end, Routes.limitsFor(Routes.Request.RepairBuilding))

	self.context.ColonyService.plotReleased:Connect(function(player)
		self._models[player.UserId] = nil
		self._effectCache[player.UserId] = nil
	end)

	log:info("ready")
end

return BuildingService.new()
