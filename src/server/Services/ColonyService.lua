--[[
	ColonyService.lua

	Owns the persistent colony: the world, plot ownership, which zone a player is
	in, and the permission check every colony mutation runs through.

	Plot ownership model
	────────────────────
	The cavern holds nine plots. A player claims one when their profile loads and
	releases it when they leave; their buildings are rebuilt from the profile on
	claim and torn down on release, so the world is always a projection of saved
	data rather than a second source of truth.

	Permissions
	───────────
	`canManage(actor, plotIndex)` is the single gate. The owner always passes.
	Anyone the owner has added to `colony.builders` passes. Everyone else fails,
	which means a visitor can walk around a friend's colony and look at it but
	cannot place, upgrade, demolish, reassign a colonist, craft from their
	stations or touch their storage. There is no code path that spends another
	player's resources, because every spend reads the actor's own profile.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local BuildingConfig = require(Shared.Config.BuildingConfig)
local ColonyBuilder = require(script.Parent.Parent.World.ColonyBuilder)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)
local Theme = require(Shared.Config.Theme)

local log = Logger.new("ColonyService")

local ColonyService = {}
ColonyService.__index = ColonyService

function ColonyService.new()
	local self = setmetatable({}, ColonyService)
	self._plotByUser = {} -- [userId] = plotIndex
	self._ownerByPlot = {} -- [plotIndex] = userId
	self._zone = {} -- [userId] = Enums.Zone
	self._root = nil

	self.plotClaimed = Signal.new("plotClaimed")
	self.plotReleased = Signal.new("plotReleased")
	self.zoneChanged = Signal.new("zoneChanged")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Plots
-- ─────────────────────────────────────────────────────────────────────────────

function ColonyService:plotOf(player)
	return self._plotByUser[player.UserId]
end

function ColonyService:ownerOfPlot(plotIndex)
	return self._ownerByPlot[plotIndex]
end

function ColonyService:plotInstance(player)
	local index = self:plotOf(player)
	return index and ColonyBuilder.getPlot(index) or nil
end

function ColonyService:_claimPlot(player)
	if self._plotByUser[player.UserId] then
		return self._plotByUser[player.UserId]
	end

	local chosen
	for index = 1, GameConfig.Colony.MaxPlots do
		if not self._ownerByPlot[index] then
			chosen = index
			break
		end
	end

	if not chosen then
		--[[ More players than plots. The server cap is 8 and there are 9 plots,
		     so this needs a misconfiguration to happen; handle it rather than
		     crash on a nil index. ]]
		log:fault("no free colony plot for %s; they will spawn as a visitor", player.Name)
		return nil
	end

	self._plotByUser[player.UserId] = chosen
	self._ownerByPlot[chosen] = player.UserId

	local plot = ColonyBuilder.getPlot(chosen)
	if plot then
		local spawn = plot:FindFirstChild("Spawn")
		if spawn then
			spawn.Enabled = true
			player.RespawnLocation = spawn
		end
		self:_setNameplate(plot, player.Name, true)
		ColonyBuilder.setPlotClaimed(plot, true)
	end

	self.plotClaimed:Fire(player, chosen)
	log:info("%s claimed plot %d", player.Name, chosen)
	return chosen
end

function ColonyService:_releasePlot(player)
	local index = self._plotByUser[player.UserId]
	if not index then
		return
	end

	self._plotByUser[player.UserId] = nil
	self._ownerByPlot[index] = nil

	local plot = ColonyBuilder.getPlot(index)
	if plot then
		local spawn = plot:FindFirstChild("Spawn")
		if spawn then
			spawn.Enabled = false
		end
		--[[ Clear the world projection. The data lives in the profile, which has
		     already been saved by DataService's PlayerRemoving handler. ]]
		local buildings = plot:FindFirstChild("Buildings")
		if buildings then
			buildings:ClearAllChildren()
		end
		local colonists = plot:FindFirstChild("Colonists")
		if colonists then
			colonists:ClearAllChildren()
		end
		self:_setNameplate(plot, "UNCLAIMED", false)
		ColonyBuilder.setPlotClaimed(plot, false)
	end

	self.plotReleased:Fire(player, index)
end

function ColonyService:_setNameplate(plot, text, claimed)
	local anchor = plot:FindFirstChild("Nameplate")
	if not anchor then
		return
	end
	local billboard = anchor:FindFirstChild("OwnerLabel")
	local label = billboard and billboard:FindFirstChild("Text")
	if label then
		label.Text = claimed and (string.upper(text) .. "'S HOLLOW") or text
		label.TextColor3 = claimed and Theme.Color.Accent or Theme.Color.TextFaint
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Permissions
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	May `actor` change the colony on `plotIndex`?

	Visitors are read-only. This is the only place that answers the question, so
	widening or narrowing access is a one-line change rather than an audit.
]]
function ColonyService:canManage(actor, plotIndex)
	if not plotIndex then
		return false, Enums.Reject.BadRequest
	end
	local ownerId = self._ownerByPlot[plotIndex]
	if not ownerId then
		return false, Enums.Reject.NoPermission
	end
	if ownerId == actor.UserId then
		return true
	end

	local owner = Players:GetPlayerByUserId(ownerId)
	if owner then
		local ownerProfile = self.context.DataService:get(owner)
		local builders = ownerProfile and ownerProfile.colony.builders
		if builders and builders[tostring(actor.UserId)] then
			return true
		end
	end

	return false, Enums.Reject.NoPermission
end

--[[ Convenience for the common case: the actor acting on their own colony. ]]
function ColonyService:requireOwnPlot(player)
	local index = self:plotOf(player)
	if not index then
		return nil, Enums.Reject.NotLoaded
	end
	local allowed, reason = self:canManage(player, index)
	if not allowed then
		return nil, reason
	end
	return index
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Zones
-- ─────────────────────────────────────────────────────────────────────────────

function ColonyService:zoneOf(player)
	return self._zone[player.UserId] or Enums.Zone.Colony
end

function ColonyService:setZone(player, zone)
	if self._zone[player.UserId] == zone then
		return
	end
	self._zone[player.UserId] = zone
	self.zoneChanged:Fire(player, zone)
	Net.fire(player, Routes.Push.ZoneChanged, { zone = zone })
end

--[[ Put a player back in their own colony: respawn point, then a direct
     teleport so there is no death involved in coming home. ]]
function ColonyService:sendHome(player)
	local index = self:plotOf(player)
	if not index then
		return false
	end

	local plot = ColonyBuilder.getPlot(index)
	if plot then
		local spawn = plot:FindFirstChild("Spawn")
		if spawn then
			player.RespawnLocation = spawn
		end
	end

	self:setZone(player, Enums.Zone.Colony)

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		root.CFrame = CFrame.new(ColonyBuilder.plotSpawnPosition(index) + Vector3.new(0, 3, 0))
	end

	self:pushColony(player)
	return true
end

--[[ Walk-to-visit is the normal route, but a direct jump is friendlier when a
     friend is on the far side of the cavern. Visiting never grants permissions. ]]
function ColonyService:visit(player, targetUserId)
	local index = self._plotByUser[targetUserId]
	if not index then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "not_present" }
	end
	if self:zoneOf(player) ~= Enums.Zone.Colony then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end

	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return { ok = false, reason = Enums.Reject.Busy }
	end

	root.CFrame = CFrame.new(ColonyBuilder.plotSpawnPosition(index) + Vector3.new(0, 3, 0))
	return { ok = true, plotIndex = index, canManage = (self:canManage(player, index)) }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Colony state
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Colony level is the Town Hall's level: one visible number driven by one
     visible decision, rather than an opaque formula over everything built. ]]
function ColonyService:colonyLevel(player)
	local BuildingService = self.context.BuildingService
	if not BuildingService then
		return 1
	end
	return math.max(1, BuildingService:highestLevelOf(player, Enums.Building.TownHall))
end

function ColonyService:snapshot(player)
	local profile = self.context.DataService:get(player)
	if not profile then
		return nil
	end

	local BuildingService = self.context.BuildingService
	local NPCService = self.context.NPCService
	local effects = BuildingService and BuildingService:effectsFor(player) or {}

	local roster = {}
	for _, colonist in ipairs(profile.colony.colonists or {}) do
		table.insert(roster, {
			uid = colonist.uid,
			name = colonist.name,
			job = colonist.job,
			skill = colonist.skill,
			health = colonist.health,
		})
	end

	local placements = {}
	for _, placement in ipairs(profile.colony.buildings or {}) do
		local def = BuildingConfig.get(placement.id)
		local levelData = BuildingConfig.levelData(placement.id, placement.level)
		table.insert(placements, {
			uid = placement.uid,
			id = placement.id,
			gx = placement.gx,
			gz = placement.gz,
			rot = placement.rot,
			level = placement.level,
			health = placement.health,
			maxHealth = levelData and levelData.maxHealth or 0,
			maxLevel = def and #def.levels or 1,
		})
	end

	return {
		plotIndex = self:plotOf(player),
		colonyName = profile.colony.name,
		colonyLevel = self:colonyLevel(player),
		condition = profile.colony.condition,
		food = profile.colony.food,
		research = profile.colony.research,
		population = #roster,
		populationCap = effects.population or 0,
		foodPerTick = effects.foodPerTick or 0,
		productionMultiplier = effects.productionMult or 1,
		jobSlots = effects.jobSlots or {},
		jobUsage = NPCService and NPCService:jobUsage(player) or {},
		buildings = placements,
		colonists = roster,
		unlocked = BuildingService and BuildingService:unlockedBuildings(player) or {},
		keys = profile.escape.keys,
		gateStages = profile.escape.gateStagesUnlocked,
		level = profile.progression.level,
		xp = profile.progression.xp,
		roleMastery = profile.progression.roleMastery,
		selectedRole = profile.progression.selectedRole,
	}
end

function ColonyService:pushColony(player)
	local snapshot = self:snapshot(player)
	if snapshot then
		Net.fire(player, Routes.Push.ColonySync, snapshot)
	end
end

--[[ Everyone currently in the colony zone, used for colony-wide notices. ]]
function ColonyService:playersInColony()
	local out = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if self:zoneOf(player) == Enums.Zone.Colony then
			table.insert(out, player)
		end
	end
	return out
end

--[[ A list of other players' colonies the client can offer to visit. ]]
function ColonyService:directory(requester)
	local out = {}
	for userId, plotIndex in pairs(self._plotByUser) do
		if userId ~= requester.UserId then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(out, {
					userId = userId,
					name = player.Name,
					displayName = player.DisplayName,
					plotIndex = plotIndex,
					canManage = (self:canManage(requester, plotIndex)),
				})
			end
		end
	end
	table.sort(out, function(a, b)
		return a.plotIndex < b.plotIndex
	end)
	return out
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function ColonyService:init(context)
	self.context = context
end

function ColonyService:start()
	self._root = ColonyBuilder.build()
	log:info("colony cavern built with %d plots", GameConfig.Colony.MaxPlots)

	--[[ Claiming a plot is the trigger for projecting a profile into the world:
	     buildings, then colonists, then the first client snapshot. Ordering
	     matters because colonist job slots come from building effects. ]]
	self.context.DataService.profileLoaded:Connect(function(player)
		local index = self:_claimPlot(player)
		self:setZone(player, Enums.Zone.Colony)

		if index then
			self.context.BuildingService:rebuildPlot(player)
			self.context.NPCService:onColonyReady(player)
		end

		self.context.InventoryService:pushStorage(player)
		self.context.InventoryService:pushBag(player)
		self:pushColony(player)

		--[[ Players.CharacterAutoLoads is false (SurvivalService owns spawning),
		     so the first body is loaded here, once the plot exists to put it on.
		     CharacterAdded below handles placing it. ]]
		if not player.Character then
			local ok, err = pcall(function()
				player:LoadCharacter()
			end)
			if not ok then
				log:fault("LoadCharacter failed for %s: %s", player.Name, tostring(err))
			end
		else
			task.defer(function()
				self:sendHome(player)
			end)
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:_releasePlot(player)
		self._zone[player.UserId] = nil
	end)

	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			--[[ Respawning inside the colony returns the player to their plot.
			     Respawning while an expedition is live is handled by
			     SurvivalService, which decides between spectating and a rescue. ]]
			task.defer(function()
				if self:zoneOf(player) == Enums.Zone.Colony then
					self:sendHome(player)
				end
			end)
		end)
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		player.CharacterAdded:Connect(function()
			task.defer(function()
				if self:zoneOf(player) == Enums.Zone.Colony then
					self:sendHome(player)
				end
			end)
		end)
	end

	Net.handle(Routes.Request.GetProfile, function(player)
		local profile = self.context.DataService:get(player)
		if not profile then
			return { ok = false, reason = Enums.Reject.NotLoaded }
		end
		self.context.InventoryService:pushStorage(player)
		self.context.InventoryService:pushBag(player)
		self:pushColony(player)
		return {
			ok = true,
			colony = self:snapshot(player),
			settings = profile.settings,
			cosmetics = profile.cosmetics,
			readOnly = self.context.DataService:isReadOnly(player),
			readOnlyReason = self.context.DataService:readOnlyReason(player),
			--[[ Surfaced because a player whose session will not be saved
			     deserves to know before they spend an hour on it. ]]
			degraded = self.context.DataService:isEphemeral(player),
			directory = self:directory(player),
			version = GameConfig.Version,
		}
	end, Routes.limitsFor(Routes.Request.GetProfile))

	Net.handle(Routes.Request.GoHome, function(player)
		if self:zoneOf(player) ~= Enums.Zone.Colony then
			return { ok = false, reason = Enums.Reject.WrongZone }
		end
		local ok = self:sendHome(player)
		return { ok = ok }
	end)

	Net.handle(Routes.Request.VisitColony, function(player, payload)
		if type(payload) ~= "table" or type(payload.userId) ~= "number" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:visit(player, math.floor(payload.userId))
	end)

	Net.handle(Routes.Request.SetSetting, function(player, payload)
		if type(payload) ~= "table" or type(payload.key) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		local profile = self.context.DataService:get(player)
		if not profile then
			return { ok = false, reason = Enums.Reject.NotLoaded }
		end
		--[[ Only keys that already exist in the template may be set, and only to
		     the type they already hold. That keeps a client from writing
		     arbitrary data into a profile. ]]
		local current = profile.settings[payload.key]
		if current == nil then
			return { ok = false, reason = Enums.Reject.BadRequest, detail = "unknown_setting" }
		end
		local incoming = payload.value
		if typeof(incoming) ~= typeof(current) then
			return { ok = false, reason = Enums.Reject.BadRequest, detail = "type_mismatch" }
		end
		if type(incoming) == "number" then
			incoming = math.clamp(incoming, 0, 2)
		end
		profile.settings[payload.key] = incoming
		self.context.DataService:markDirty(player)
		return { ok = true, key = payload.key, value = incoming }
	end)

	log:info("ready")
end

return ColonyService.new()
