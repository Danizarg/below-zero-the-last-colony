--[[
	NPCService.lua
	Colonists, job assignment and the colony production simulation.

	Simulation, not AI
	──────────────────
	The brief is explicit: run a production simulation rather than expensive AI
	routines for every colonist. So production is a pure arithmetic tick over the
	roster every GameConfig.NPC.ProductionTickSeconds, and it is completely
	independent of whether a colonist has a visible body. A colony with
	twenty-four workers costs the same CPU as one with three.

	Visible colonists are a presentation layer on top: at most
	GameConfig.NPC.MaxVisibleRigs bodies per plot, moved by one shared 10 Hz
	loop with simple interpolation. No Humanoids, no pathfinding, no per-NPC
	scripts — a plot full of workers would otherwise cost more than the whole
	expedition system.

	Offline production
	──────────────────
	The colony keeps working while the player is away, capped at
	OfflineProductionMaxHours and scaled by OfflineProductionEfficiency, so
	logging off is never the optimal strategy. Condition decays over the same
	period but is floored at ConditionFloor, so a colony can never be lost to
	absence — which the brief requires.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local BuildingConfig = require(Shared.Config.BuildingConfig)
local ColonyBuilder = require(script.Parent.Parent.World.ColonyBuilder)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local JobConfig = require(Shared.Config.JobConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local PartFactory = require(Shared.Util.PartFactory)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local Rng = require(Shared.Lib.Rng)
local Routes = require(Shared.Routes)
local Theme = require(Shared.Config.Theme)

local log = Logger.new("NPCService")

local NPCService = {}
NPCService.__index = NPCService

local NPC = GameConfig.NPC
local RIG_UPDATE_RATE = 0.1
local RECRUIT_FOOD_COST = 25

function NPCService.new()
	local self = setmetatable({}, NPCService)
	self._rigs = {} -- [userId] = { [colonistUid] = { model, target, speed, pauseUntil } }
	self._accumulator = 0
	self._productionAccumulator = 0
	self._rng = Rng.new(os.time() % 2147483647)
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Roster
-- ─────────────────────────────────────────────────────────────────────────────

function NPCService:roster(player)
	local profile = self.context.DataService:get(player)
	if not profile then
		return {}
	end
	profile.colony.colonists = profile.colony.colonists or {}
	return profile.colony.colonists
end

function NPCService:findColonist(player, uid)
	for index, colonist in ipairs(self:roster(player)) do
		if colonist.uid == uid then
			return colonist, index
		end
	end
	return nil, nil
end

--[[ How many colonists are doing each job right now. ]]
function NPCService:jobUsage(player)
	local usage = {}
	for _, colonist in ipairs(self:roster(player)) do
		usage[colonist.job] = (usage[colonist.job] or 0) + 1
	end
	return usage
end

function NPCService:_createColonist(player)
	local profile = self.context.DataService:get(player)
	if not profile then
		return nil
	end

	local uid = "c" .. tostring(profile.colony.nextColonistUid or 1)
	profile.colony.nextColonistUid = (profile.colony.nextColonistUid or 1) + 1

	--[[ Names come from a fixed pool, suffixed when it wraps, so a large colony
	     never shows two bare duplicates. ]]
	local pool = JobConfig.NamePool
	local existing = #self:roster(player)
	local name = pool[(existing % #pool) + 1]
	if existing >= #pool then
		name = name .. " " .. tostring(math.floor(existing / #pool) + 1)
	end

	local colonist = {
		uid = uid,
		name = name,
		job = Enums.Job.Idle,
		skill = 1,
		health = 100,
	}
	table.insert(profile.colony.colonists, colonist)
	self.context.DataService:markDirty(player)
	return colonist
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Job assignment
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Free slots for a job, from building effects minus current assignments. ]]
function NPCService:freeSlots(player, jobId)
	if jobId == Enums.Job.Idle then
		return math.huge
	end
	local effects = self.context.BuildingService:effectsFor(player)
	local total = (effects.jobSlots or {})[jobId] or 0
	local used = self:jobUsage(player)[jobId] or 0
	return total - used
end

function NPCService:assignJob(player, colonistUid, jobId)
	local plotIndex, permissionReason = self.context.ColonyService:requireOwnPlot(player)
	if not plotIndex then
		return { ok = false, reason = permissionReason }
	end
	if not JobConfig.isValid(jobId) then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	local colonist = self:findColonist(player, colonistUid)
	if not colonist then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	if colonist.job == jobId then
		return { ok = true, colonist = colonist }
	end

	local job = JobConfig.get(jobId)
	if job.requires and self.context.BuildingService:highestLevelOf(player, job.requires) <= 0 then
		return { ok = false, reason = Enums.Reject.NoPermission, detail = "needs_building" }
	end
	if jobId ~= Enums.Job.Idle and self:freeSlots(player, jobId) <= 0 then
		return { ok = false, reason = Enums.Reject.LimitReached, detail = "no_slots" }
	end

	colonist.job = jobId
	self.context.DataService:markDirty(player)
	self:_refreshRigLabel(player, colonist)
	self.context.ColonyService:pushColony(player)

	return { ok = true, colonist = colonist }
end

--[[ A building removal can orphan workers. Rather than silently dropping their
     output, they are moved to Idle and the player is told. ]]
function NPCService:onBuildingsChanged(player)
	local reassigned = 0
	for _, colonist in ipairs(self:roster(player)) do
		if colonist.job ~= Enums.Job.Idle then
			local job = JobConfig.get(colonist.job)
			local lostBuilding = job.requires
				and self.context.BuildingService:highestLevelOf(player, job.requires) <= 0
			local lostSlot = self:freeSlots(player, colonist.job) < 0
			if lostBuilding or lostSlot then
				colonist.job = Enums.Job.Idle
				reassigned += 1
				self:_refreshRigLabel(player, colonist)
			end
		end
	end

	if reassigned > 0 then
		self.context.DataService:markDirty(player)
		Net.fire(player, Routes.Push.Notify, {
			kind = "warning",
			title = "Workers idle",
			body = ("%d colonist%s lost their workplace and are now unassigned."):format(
				reassigned,
				reassigned == 1 and "" or "s"
			),
		})
	end

	self:_syncRigs(player)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Recruitment
-- ─────────────────────────────────────────────────────────────────────────────

function NPCService:recruit(player)
	local plotIndex, permissionReason = self.context.ColonyService:requireOwnPlot(player)
	if not plotIndex then
		return { ok = false, reason = permissionReason }
	end
	--[[ Recruiting spends food and adds a colonist to the profile. ]]
	if self.context.DataService:isReadOnly(player) then
		return { ok = false, reason = Enums.Reject.NotLoaded, detail = "read_only" }
	end

	local profile = self.context.DataService:get(player)
	if not profile then
		return { ok = false, reason = Enums.Reject.NotLoaded }
	end

	local effects = self.context.BuildingService:effectsFor(player)
	local cap = math.min(effects.population or 0, NPC.AbsoluteMaxColonists)
	if #self:roster(player) >= cap then
		return { ok = false, reason = Enums.Reject.LimitReached, detail = "needs_housing" }
	end
	if (profile.colony.food or 0) < RECRUIT_FOOD_COST then
		return { ok = false, reason = Enums.Reject.NotEnoughResources, detail = "food" }
	end

	profile.colony.food -= RECRUIT_FOOD_COST
	local colonist = self:_createColonist(player)
	if not colonist then
		return { ok = false, reason = Enums.Reject.NotLoaded }
	end

	self:_syncRigs(player)
	self.context.ColonyService:pushColony(player)
	return { ok = true, colonist = colonist, foodSpent = RECRUIT_FOOD_COST }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Production
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Turn a fractional amount into a whole number without losing the remainder
	over time: the fractional part becomes its own probability.

	A researcher consuming 0.05 relics per tick cannot spend a twentieth of a
	relic, and flooring would make them free. Instead they have a 5% chance of
	spending one each tick, so the expected cost is exactly right while storage
	stays integral. The same applies to production: a farmer yielding 1.4
	mushrooms per tick gets 1 most ticks and 2 some, rather than losing 0.4 every
	time.
]]
local function quantise(rng, amount)
	if amount <= 0 then
		return 0
	end
	local whole = math.floor(amount)
	local fraction = amount - whole
	if fraction > 0 and rng:chance(fraction) then
		whole += 1
	end
	return whole
end

--[[
	Run `ticks` production ticks for one colony.

	@param efficiencyScale number  1 for live play, OfflineProductionEfficiency
	                               for catch-up on join
	@return summary { produced = {...}, foodDelta, conditionDelta, researchDelta }
]]
function NPCService:simulate(player, ticks, efficiencyScale)
	local profile = self.context.DataService:get(player)
	if not profile or ticks <= 0 then
		return nil
	end

	local storage = self.context.InventoryService:storageOf(player)
	if not storage then
		return nil
	end

	local effects = self.context.BuildingService:effectsFor(player)
	local rng = self._rng
	local produced = {}
	local consumedShort = false
	local spentAny = false
	local foodDelta = 0
	local researchDelta = 0
	local conditionRepair = 0

	local conditionFactor = math.clamp((profile.colony.condition or 100) / 100, 0.4, 1)
	local globalMult = (effects.productionMult or 1) * conditionFactor * efficiencyScale

	for _ = 1, ticks do
		local foodUse = 0
		local foodValue = effects.foodPerTick or 0

		for _, colonist in ipairs(self:roster(player)) do
			local job = JobConfig.get(colonist.job)
			local works = colonist.job ~= Enums.Job.Idle
			if works and job.requires then
				works = self.context.BuildingService:highestLevelOf(player, job.requires) > 0
			end

			foodUse += job.foodUse or 0

			if works then
				local efficiency = JobConfig.efficiency(colonist.skill) * globalMult

				--[[ Inputs are resolved to whole units first, then checked, then
				     spent. A job that cannot pay produces nothing and spends
				     nothing — never a partial deduction. ]]
				local toSpend = {}
				local canWork = true
				for resourceId, perTick in pairs(job.consumes or {}) do
					local units = quantise(rng, perTick * efficiency)
					if units > 0 then
						if (storage.items[resourceId] or 0) < units then
							canWork = false
							consumedShort = true
							break
						end
						toSpend[resourceId] = units
					end
				end

				if canWork then
					for resourceId, units in pairs(toSpend) do
						local remaining = (storage.items[resourceId] or 0) - units
						storage.items[resourceId] = remaining > 0 and remaining or nil
						spentAny = true
					end

					for resourceId, perTick in pairs(job.produces or {}) do
						local units = quantise(rng, perTick * efficiency)
						if units > 0 then
							produced[resourceId] = (produced[resourceId] or 0) + units
						end
					end

					foodValue += (job.foodValuePerTick or 0) * efficiency
					researchDelta += (job.researchPerTick or 0) * efficiency
					conditionRepair += (job.conditionRepairPerTick or 0) * efficiency

					if job.repairPerTick and job.repairPerTick > 0 then
						self:_repairWorstBuilding(player, job.repairPerTick * efficiency)
					end

					colonist.skill =
						math.min(JobConfig.MaxSkill, (colonist.skill or 1) + (job.skillGain or 0))
				end
			end
		end

		foodDelta += foodValue - foodUse
	end

	-- Food.
	local foodBefore = profile.colony.food or 0
	profile.colony.food = math.max(0, foodBefore + foodDelta)

	--[[ Starvation costs condition, not colonists. Losing a worker to a missed
	     login would be the kind of punishment that makes people stop playing. ]]
	local starvationPenalty = 0
	if foodBefore + foodDelta < 0 then
		starvationPenalty = math.min(8, math.abs(foodBefore + foodDelta) * 0.1)
	end

	-- Condition.
	local decayPerTick = (NPC.ConditionDecayPerHour / 3600) * NPC.ProductionTickSeconds
	local conditionDelta = conditionRepair - decayPerTick * ticks - starvationPenalty
	profile.colony.condition =
		math.clamp((profile.colony.condition or 100) + conditionDelta, NPC.ConditionFloor, NPC.ConditionMax)

	-- Research.
	profile.colony.research = (profile.colony.research or 0)
		+ researchDelta
		+ (effects.researchPerTick or 0) * ticks

	--[[ Production was already quantised per tick, so these are whole units.

	     `produced` is then rewritten to what storage ACTUALLY took.
	     addToStorage truncates at the colony's capacity, and `produced` is
	     what the offline notice reads out to the player. Left as the simulated
	     figure it over-reports by however much the cap refused: Offline.spec
	     measured a returning player being told their colonists had made 5,295
	     mushrooms when five units fit. The overflow is still lost — a full
	     store is the cap doing its job — but it is no longer lost inside a
	     number the player can check against their own inventory and find
	     wrong.

	     Writing back into `produced` while iterating it is safe: the keys are
	     already there and only their values change. ]]
	local depositedAny = false
	for resourceId, amount in pairs(produced) do
		if amount > 0 then
			local result = self.context.InventoryService:addToStorage(player, resourceId, amount)
			produced[resourceId] = result.added
			if result.added > 0 then
				depositedAny = true
			end
		end
	end

	--[[ A tick that only SPENT has moved storage without pushing it. The spend
	     above writes `storage.items` directly rather than going through
	     InventoryService:spendFromStorage — the affordability check is already
	     resolved into `toSpend`, and routing it back through `Inventory.pay`
	     would redo that check and push once per job per tick instead of once
	     per tick. But that leaves the deposit loop's addToStorage as the only
	     push in here, and it is guarded on `result.added > 0`, while the
	     colony snapshot the online tick sends afterwards carries no storage at
	     all. So a Cook eating the larder down showed the player nothing: the
	     resource strip, the units line and `recipes[].available` all kept
	     their last-pushed values, and the Craft button stayed enabled for a
	     recipe the server would refuse.

	     One push covers the whole tick. `depositedAny` is the right guard
	     because every spend happens inside the tick loop and every deposit
	     after it, so a push from the deposit loop has already carried the
	     post-spend state — which keeps a normally staffed colony at exactly
	     the traffic it had before. ]]
	if spentAny and not depositedAny then
		self.context.InventoryService:pushStorage(player)
	end

	profile.colony.lastProductionAt = os.time()
	self.context.DataService:markDirty(player)

	return {
		produced = produced,
		foodDelta = foodDelta,
		conditionDelta = conditionDelta,
		researchDelta = researchDelta,
		depositedAny = depositedAny,
		inputsShort = consumedShort,
	}
end

function NPCService:_repairWorstBuilding(player, amount)
	local worst, worstRatio = nil, 1
	for _, placement in ipairs(self.context.BuildingService:placements(player)) do
		local levelData = BuildingConfig.levelData(placement.id, placement.level)
		if levelData and levelData.maxHealth > 0 then
			local ratio = (placement.health or levelData.maxHealth) / levelData.maxHealth
			if ratio < worstRatio then
				worst, worstRatio = placement, ratio
			end
		end
	end
	if worst and worstRatio < 0.999 then
		self.context.BuildingService:heal(player, worst.uid, amount)
	end
end

--[[ Grant the production that happened while the player was away. ]]
function NPCService:_settleOffline(player)
	if not NPC.OfflineProductionEnabled then
		return
	end
	local profile = self.context.DataService:get(player)
	if not profile then
		return
	end

	--[[ A read-only session is never written back, so settling one would hand
	     the player up to eight hours of resources, announce them as earned,
	     and then throw the lot away the moment they left.

	     profileLoaded fires for a read-only entry exactly as it does for a
	     healthy one — DataService logs "[read-only]" on the line above the
	     Fire — so nothing upstream of here stops it. A session that was locked
	     out gets a fresh template and so has no absence to pay for anyway; the
	     one that does is a profile whose migration was REFUSED, which keeps the
	     real stored data and the real lastProductionAt.

	     Skipping also leaves lastProductionAt alone, so the absence is still
	     owed and is paid in full by the next session that can actually bank it.
	     ColonyService already tells the client the session is read-only, so
	     there is nothing to announce from here. ]]
	if self.context.DataService:isReadOnly(player) then
		log:info("not settling offline production for %s: this session is read-only", player.Name)
		return
	end

	local last = profile.colony.lastProductionAt or 0
	if last <= 0 then
		profile.colony.lastProductionAt = os.time()
		return
	end

	local elapsed = math.max(0, os.time() - last)
	local capped = math.min(elapsed, NPC.OfflineProductionMaxHours * 3600)
	local ticks = math.floor(capped / NPC.ProductionTickSeconds)
	if ticks <= 0 then
		return
	end

	local summary = self:simulate(player, ticks, NPC.OfflineProductionEfficiency)
	if not summary then
		return
	end

	local lines = {}
	for resourceId, amount in pairs(summary.produced) do
		if amount > 0 then
			local def = ResourceConfig.get(resourceId)
			table.insert(lines, ("%s +%d"):format(def and def.name or resourceId, amount))
		end
	end
	table.sort(lines)

	Net.fire(player, Routes.Push.Notify, {
		kind = "info",
		title = "While you were away",
		body = #lines > 0 and ("Your colonists produced: " .. table.concat(lines, ", "))
			or "Your colonists held the colony together, but produced nothing new.",
		detail = ("%.1f hours of work at %d%% efficiency"):format(
			capped / 3600,
			math.floor(NPC.OfflineProductionEfficiency * 100)
		),
	})

	log:info("settled %d offline ticks for %s", ticks, player.Name)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Visible colonists
-- ─────────────────────────────────────────────────────────────────────────────

local function buildRig(colonist, origin, parent)
	local model = PartFactory.model("Colonist_" .. colonist.uid, nil)
	local job = JobConfig.get(colonist.job)

	local torso = PartFactory.block({
		name = "Torso",
		size = Vector3.new(1.8, 2.4, 1),
		cframe = CFrame.new(0, 3.2, 0),
		color = Color3.fromRGB(92, 82, 70),
		material = Enum.Material.Fabric,
		canCollide = false,
		parent = model,
	})

	PartFactory.decor({
		name = "Head",
		size = Vector3.new(1.2, 1.2, 1.2),
		cframe = CFrame.new(0, 5, 0),
		color = Color3.fromRGB(206, 178, 150),
		material = Enum.Material.SmoothPlastic,
		parent = model,
	})

	for _, sign in ipairs({ -1, 1 }) do
		PartFactory.decor({
			name = "Leg",
			size = Vector3.new(0.6, 2, 0.6),
			cframe = CFrame.new(sign * 0.5, 1, 0),
			color = Color3.fromRGB(64, 58, 50),
			material = Enum.Material.Fabric,
			parent = model,
		})
		PartFactory.decor({
			name = "Arm",
			size = Vector3.new(0.5, 1.9, 0.5),
			cframe = CFrame.new(sign * 1.2, 3.2, 0),
			color = Color3.fromRGB(86, 76, 64),
			material = Enum.Material.Fabric,
			parent = model,
		})
	end

	--[[ A small coloured lamp tinted to the colonist's job: readable at a
	     distance, and the only light each rig carries. ]]
	PartFactory.glow({
		name = "JobLamp",
		size = Vector3.new(0.6, 0.6, 0.6),
		position = Vector3.new(0.9, 3.9, 0.6),
		shape = Enum.PartType.Ball,
		color = job.accent,
		lightColor = job.accent,
		range = 12,
		brightness = 0.8,
		parent = model,
	})

	local _, label = PartFactory.label(torso, {
		name = "ColonistLabel",
		text = ("%s  %s"):format(colonist.name, job.icon),
		color = Theme.Color.TextMuted,
		offset = Vector3.new(0, 3.4, 0),
		textSize = 12,
		maxDistance = 80,
	})
	label.Font = Theme.Font.Body

	model.PrimaryPart = torso
	model:PivotTo(CFrame.new(origin))
	model.Parent = parent
	return model
end

function NPCService:_refreshRigLabel(player, colonist)
	local rigs = self._rigs[player.UserId]
	local entry = rigs and rigs[colonist.uid]
	if not entry or not entry.model.Parent then
		return
	end
	local torso = entry.model.PrimaryPart
	local billboard = torso and torso:FindFirstChild("ColonistLabel")
	local label = billboard and billboard:FindFirstChild("Text")
	if label then
		local job = JobConfig.get(colonist.job)
		label.Text = ("%s  %s"):format(colonist.name, job.icon)
	end
	local lamp = entry.model:FindFirstChild("JobLamp")
	if lamp then
		local job = JobConfig.get(colonist.job)
		lamp.Color = job.accent
		local light = lamp:FindFirstChildOfClass("PointLight")
		if light then
			light.Color = job.accent
		end
	end
end

--[[ Bring the visible rigs in line with the roster, respecting the cap. ]]
function NPCService:_syncRigs(player)
	local plotIndex = self.context.ColonyService:plotOf(player)
	local plot = plotIndex and ColonyBuilder.getPlot(plotIndex)
	local folder = plot and plot:FindFirstChild("Colonists")
	if not folder then
		return
	end

	local rigs = self._rigs[player.UserId]
	if not rigs then
		rigs = {}
		self._rigs[player.UserId] = rigs
	end

	local roster = self:roster(player)
	local wanted = {}
	for index = 1, math.min(#roster, NPC.MaxVisibleRigs) do
		wanted[roster[index].uid] = roster[index]
	end

	-- Remove rigs for colonists that no longer qualify.
	for uid, entry in pairs(rigs) do
		if not wanted[uid] then
			if entry.model then
				entry.model:Destroy()
			end
			rigs[uid] = nil
		end
	end

	-- Add rigs for the ones that do.
	local centre = ColonyBuilder.plotCentre(plotIndex)
	for uid, colonist in pairs(wanted) do
		if not rigs[uid] then
			local spread = GameConfig.Colony.PlotSize * 0.3
			local origin = centre
				+ Vector3.new(self._rng:nextRange(-spread, spread), 2, self._rng:nextRange(-spread, spread))
			local model = buildRig(colonist, origin, folder)
			rigs[uid] = {
				model = model,
				home = centre,
				target = origin,
				speed = self._rng:nextRange(3.5, 6),
				pauseUntil = 0,
			}
		end
	end
end

--[[
	One loop drives every visible colonist on the server.

	Movement is a lerp toward a wander target with a pause on arrival. No
	Humanoid, no pathfinding: the plot is a flat open pad, so there is nothing to
	path around, and a hundred Humanoids would cost more than the entire cave.
]]
function NPCService:_updateRigs(deltaTime)
	for userId, rigs in pairs(self._rigs) do
		local player = Players:GetPlayerByUserId(userId)
		if not player then
			continue
		end

		--[[ Skip plots with nobody near them. The rigs stay where they are and
		     resume when someone comes back, which nobody can observe. ]]
		local plotIndex = self.context.ColonyService:plotOf(player)
		if not plotIndex then
			continue
		end
		local centre = ColonyBuilder.plotCentre(plotIndex)
		local observed = false
		for _, other in ipairs(Players:GetPlayers()) do
			local character = other.Character
			local root = character and character.PrimaryPart
			if root and (root.Position - centre).Magnitude < NPC.VisibleRadius then
				observed = true
				break
			end
		end
		if not observed then
			continue
		end

		local now = os.clock()
		local spread = GameConfig.Colony.PlotSize * 0.33

		for _, entry in pairs(rigs) do
			local model = entry.model
			if not model or not model.Parent or not model.PrimaryPart then
				continue
			end

			local current = model:GetPivot().Position
			if now < entry.pauseUntil then
				continue
			end

			local toTarget = entry.target - current
			local flat = Vector3.new(toTarget.X, 0, toTarget.Z)

			if flat.Magnitude < 1.5 then
				entry.pauseUntil = now + self._rng:nextRange(1.5, 5)
				entry.target = centre
					+ Vector3.new(
						self._rng:nextRange(-spread, spread),
						2,
						self._rng:nextRange(-spread, spread)
					)
			else
				local step = flat.Unit * math.min(entry.speed * deltaTime, flat.Magnitude)
				local nextPosition = current + step
				--[[ Face the direction of travel so the rigs read as walking
				     rather than sliding. ]]
				model:PivotTo(CFrame.lookAt(nextPosition, nextPosition + flat.Unit))
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function NPCService:onColonyReady(player)
	local profile = self.context.DataService:get(player)
	if not profile then
		return
	end

	-- Seed the starting roster once.
	if #self:roster(player) == 0 then
		for _ = 1, NPC.StartingColonists do
			self:_createColonist(player)
		end
		log:info("seeded %d colonists for %s", NPC.StartingColonists, player.Name)
	end

	self:_settleOffline(player)
	self:_syncRigs(player)
end

function NPCService:init(context)
	self.context = context
end

function NPCService:start()
	Net.handle(Routes.Request.AssignJob, function(player, payload)
		if type(payload) ~= "table" or type(payload.uid) ~= "string" or type(payload.job) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:assignJob(player, payload.uid, payload.job)
	end, Routes.limitsFor(Routes.Request.AssignJob))

	Net.handle(Routes.Request.RecruitColonist, function(player)
		return self:recruit(player)
	end)

	--[[ One heartbeat drives both the production tick and the rig movement, so
	     the colony costs exactly one connection regardless of player count. ]]
	RunService.Heartbeat:Connect(function(deltaTime)
		self._accumulator += deltaTime
		self._productionAccumulator += deltaTime

		if self._accumulator >= RIG_UPDATE_RATE then
			local step = self._accumulator
			self._accumulator = 0
			local ok, err = pcall(function()
				self:_updateRigs(step)
			end)
			if not ok then
				log:fault("rig update failed: %s", tostring(err))
			end
		end

		if self._productionAccumulator >= NPC.ProductionTickSeconds then
			self._productionAccumulator = 0
			for _, player in ipairs(Players:GetPlayers()) do
				--[[ Loaded AND writable. `isLoaded` does not consider readOnly, so a
				     read-only session — a profile whose migration was refused, still
				     holding its real data — ticked here for the whole session: storage
				     spent, output deposited, food, condition, research and skill all
				     advanced and pushed to the client, and none of it ever written.
				     The online twin of the guard in _settleOffline. The player is
				     already told the session is read-only when it loads, and this
				     fires every ten seconds, so there is deliberately no log here. ]]
				if
					self.context.DataService:isLoaded(player)
					and not self.context.DataService:isReadOnly(player)
				then
					local ok, err = pcall(function()
						self:simulate(player, 1, 1)
						self.context.ColonyService:pushColony(player)
					end)
					if not ok then
						log:fault("production tick failed for %s: %s", player.Name, tostring(err))
					end
				end
			end
		end
	end)

	self.context.ColonyService.plotReleased:Connect(function(player)
		local rigs = self._rigs[player.UserId]
		if rigs then
			for _, entry in pairs(rigs) do
				if entry.model then
					entry.model:Destroy()
				end
			end
		end
		self._rigs[player.UserId] = nil
	end)

	log:info(
		"ready (production every %ds, up to %d visible rigs per plot)",
		NPC.ProductionTickSeconds,
		NPC.MaxVisibleRigs
	)
end

return NPCService.new()
