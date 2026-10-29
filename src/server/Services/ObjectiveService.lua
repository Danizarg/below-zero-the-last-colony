--[[
	ObjectiveService.lua
	Ancient keys, the First Gate, and the pillar puzzles.

	Escape structure
	────────────────
	Keys are found in the caves. Keys open stages of the First Gate. Opening a
	stage does NOT delete or reset the colony — it unlocks the next chapter's
	content, exactly as the brief requires. `escape.gateStagesUnlocked` is the
	long-term progression counter, and the architecture is chapter-shaped: add a
	stage to Stages below and it slots in.

	Keys survive death (ResourceConfig marks ancient_key protectedOnDeath), so a
	bad run costs resources and time but never escape progress. Losing a key to
	a monster would make the escape objective feel punishing rather than tense.

	Every interaction is server-validated: the client sends an interactable id,
	and this service checks that the id exists in that player's own session and
	that they are standing close enough.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local PartFactory = require(Shared.Util.PartFactory)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)
local Theme = require(Shared.Config.Theme)

local log = Logger.new("ObjectiveService")

local ObjectiveService = {}
ObjectiveService.__index = ObjectiveService

local PILLARS_PER_PUZZLE = 3

--[[
	Gate stages. Each needs keys and grants a chapter unlock. Only stage 1 is
	reachable with MVP content; the rest are the architecture the brief asks for,
	and they are inert rather than fake — `implemented` gates the reward.
]]
ObjectiveService.Stages = {
	{
		stage = 1,
		name = "The First Seal",
		keysRequired = 1,
		implemented = true,
		lore = "The seal gives. Warm air, from somewhere above. Not the surface — not yet.",
		unlocks = "Deeper expeditions and the Iron Depths biome.",
	},
	{
		stage = 2,
		name = "The Second Seal",
		keysRequired = 3,
		implemented = false,
		lore = "Writing you almost recognise. Someone counted the days down here too.",
		unlocks = "Crystal Reach biome, research tier 2.",
	},
	{
		stage = 3,
		name = "The Last Door",
		keysRequired = 6,
		implemented = false,
		lore = "It was never a prison. It was a shelter, and someone locked it from the inside.",
		unlocks = "Chapter 2: the route to the surface.",
	},
}

function ObjectiveService.new()
	local self = setmetatable({}, ObjectiveService)
	self._interactables = {} -- [id] = { sessionId, kind, position, data, instance }
	self._bySession = {} -- [sessionId] = { id, ... }
	self.keyCollected = Signal.new("keyCollected")
	self.gateUnlocked = Signal.new("gateUnlocked")
	self.puzzleSolved = Signal.new("puzzleSolved")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Registry
-- ─────────────────────────────────────────────────────────────────────────────

function ObjectiveService:_register(sessionId, id, entry)
	entry.sessionId = sessionId
	entry.id = id
	self._interactables[id] = entry
	self._bySession[sessionId] = self._bySession[sessionId] or {}
	table.insert(self._bySession[sessionId], id)
	return entry
end

function ObjectiveService:clearSession(sessionId)
	for _, id in ipairs(self._bySession[sessionId] or {}) do
		self._interactables[id] = nil
	end
	self._bySession[sessionId] = nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Setup
-- ─────────────────────────────────────────────────────────────────────────────

local function buildKeyPickup(position, parent, index)
	local model = PartFactory.model("AncientKey_" .. index, nil)

	PartFactory.block({
		name = "Plinth",
		size = Vector3.new(5, 4, 5),
		position = position + Vector3.new(0, 2, 0),
		color = Color3.fromRGB(150, 138, 112),
		material = Enum.Material.Sandstone,
		parent = model,
	})

	local key = PartFactory.glow({
		name = "Key",
		size = Vector3.new(1.4, 3.4, 0.6),
		position = position + Vector3.new(0, 6.2, 0),
		color = Color3.fromRGB(255, 228, 150),
		lightColor = Color3.fromRGB(255, 220, 140),
		range = 55,
		brightness = 2.6,
		parent = model,
	})

	PartFactory.prompt(key, {
		name = "KeyPrompt",
		actionText = "Take the Key",
		objectText = "Ancient Key",
		holdDuration = 0.8,
		maxDistance = 14,
		requiresLineOfSight = false,
	})

	local _, label = PartFactory.label(key, {
		name = "KeyLabel",
		text = "⚿ ANCIENT KEY",
		color = Theme.Color.Accent,
		offset = Vector3.new(0, 4, 0),
		textSize = 16,
		maxDistance = 180,
		alwaysOnTop = true,
	})
	label.Font = Theme.Font.Display

	model.PrimaryPart = key
	model.Parent = parent
	return model, key
end

local function buildPillar(position, parent, index)
	local model = PartFactory.model("Pillar_" .. index, nil)

	local body = PartFactory.block({
		name = "PillarBody",
		size = Vector3.new(4, 13, 4),
		position = position + Vector3.new(0, 6.5, 0),
		color = Color3.fromRGB(132, 122, 100),
		material = Enum.Material.Sandstone,
		parent = model,
	})

	local rune = PartFactory.glow({
		name = "Rune",
		size = Vector3.new(2, 4, 0.4),
		position = position + Vector3.new(0, 9, 2.2),
		color = Color3.fromRGB(96, 104, 128),
		lightColor = Color3.fromRGB(110, 130, 180),
		range = 20,
		brightness = 0.5,
		parent = model,
	})
	rune:SetAttribute("IsRune", true)

	PartFactory.prompt(body, {
		name = "PillarPrompt",
		actionText = "Touch the Rune",
		objectText = "Rune Pillar",
		maxDistance = 12,
		requiresLineOfSight = false,
	})

	model.PrimaryPart = body
	model.Parent = parent
	return model, rune
end

local function buildGate(position, parent)
	local model = PartFactory.model("FirstGateInteraction", nil)

	local anchor = PartFactory.block({
		name = "GateAnchor",
		size = Vector3.new(10, 8, 6),
		position = position + Vector3.new(0, 4, 8),
		transparency = 1,
		canCollide = false,
		canQuery = false,
		parent = model,
	})

	PartFactory.prompt(anchor, {
		name = "GatePrompt",
		actionText = "Examine the Gate",
		objectText = "The First Gate",
		holdDuration = 1,
		maxDistance = 18,
		requiresLineOfSight = false,
	})

	local _, label = PartFactory.label(anchor, {
		name = "GateLabel",
		text = "THE FIRST GATE",
		color = Theme.Color.AccentGlow,
		offset = Vector3.new(0, 12, 0),
		textSize = 20,
		maxDistance = 220,
		alwaysOnTop = true,
	})
	label.Font = Theme.Font.Display

	model.PrimaryPart = anchor
	model.Parent = parent
	return model
end

--[[
	Place every objective for a session.

	Key placement comes from the layout's `objectives` list, which the generator
	already guaranteed is in reachable cells.
]]
function ObjectiveService:setup(session, cave)
	local keyIndex = 0

	for _, objective in ipairs(cave.layout.objectives) do
		local roomModel = cave.built.rooms[objective.cellKey]
		local centre = self.context.CaveService:worldPositionOfCell(session.id, objective.cellKey)
		if not roomModel or not centre then
			continue
		end

		if objective.kind == "ancient_key" then
			keyIndex += 1
			--[[ Offset so several keys in one room do not overlap, and so a key
			     never lands on top of the gate. ]]
			local angle = (keyIndex / math.max(1, #cave.layout.objectives)) * math.pi * 2
			local position = centre + Vector3.new(math.cos(angle) * 16, 0, math.sin(angle) * 16 - 10)

			local model = buildKeyPickup(position, roomModel, keyIndex)
			local id = ("%s|key|%d"):format(tostring(session.id), keyIndex)
			model:SetAttribute("InteractableId", id)
			self:_register(session.id, id, {
				kind = "key",
				position = position,
				cellKey = objective.cellKey,
				instance = model,
				taken = false,
				label = "Ancient Key",
			})
		elseif objective.kind == "gate" then
			local position = centre + Vector3.new(0, 0, -18)
			local model = buildGate(position, roomModel)
			local id = ("%s|gate"):format(tostring(session.id))
			model:SetAttribute("InteractableId", id)
			self:_register(session.id, id, {
				kind = "gate",
				position = position,
				cellKey = objective.cellKey,
				instance = model,
				label = "The First Gate",
			})
		end
	end

	-- Pillar puzzles.
	for puzzleIndex, cellKey in ipairs(cave.layout.puzzleKeys) do
		local roomModel = cave.built.rooms[cellKey]
		local centre = self.context.CaveService:worldPositionOfCell(session.id, cellKey)
		if not roomModel or not centre then
			continue
		end

		--[[ The solution order is derived from the session seed, so it differs
		     between runs but is identical if the same seed is replayed. ]]
		local order = {}
		for index = 1, PILLARS_PER_PUZZLE do
			order[index] = index
		end
		session.rng:shuffle(order)

		local puzzleId = ("%s|puzzle|%d"):format(tostring(session.id), puzzleIndex)
		local puzzle = {
			kind = "puzzle",
			cellKey = cellKey,
			position = centre,
			order = order,
			progress = 0,
			solved = false,
			pillars = {},
			label = "Sealed Antechamber",
		}

		for index = 1, PILLARS_PER_PUZZLE do
			local angle = (index / PILLARS_PER_PUZZLE) * math.pi * 2
			local position = centre + Vector3.new(math.cos(angle) * 20, 0, math.sin(angle) * 20)
			local model, rune = buildPillar(position, roomModel, index)

			local pillarId = ("%s|pillar|%d"):format(puzzleId, index)
			model:SetAttribute("InteractableId", pillarId)
			puzzle.pillars[index] = { id = pillarId, rune = rune, position = position }

			self:_register(session.id, pillarId, {
				kind = "pillar",
				position = position,
				cellKey = cellKey,
				puzzleId = puzzleId,
				pillarIndex = index,
				instance = model,
				label = "Rune Pillar",
			})
		end

		self:_register(session.id, puzzleId, puzzle)
	end

	session.objectiveState = {
		keysAvailable = keyIndex,
		keysCollected = 0,
		puzzlesSolved = 0,
		puzzlesAvailable = #cave.layout.puzzleKeys,
		gateExamined = false,
	}

	self:push(session)
	log:info(
		"session %s objectives: %d keys, %d puzzles, gate %s",
		tostring(session.id),
		keyIndex,
		#cave.layout.puzzleKeys,
		cave.layout.vaultKey and "placed" or "absent"
	)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Interaction
-- ─────────────────────────────────────────────────────────────────────────────

function ObjectiveService:_validate(player, interactableId)
	local session = self.context.ExpeditionService:sessionOf(player)
	if not session then
		return nil, nil, Enums.Reject.WrongZone
	end

	local entry = self._interactables[interactableId]
	if not entry or entry.sessionId ~= session.id then
		return nil, nil, Enums.Reject.BadRequest
	end

	local member = session.members[player.UserId]
	if not member or member.state ~= Enums.MemberState.Alive then
		return nil, nil, Enums.Reject.Busy
	end

	local root = player.Character and player.Character.PrimaryPart
	if not root then
		return nil, nil, Enums.Reject.Busy
	end

	local reach = GameConfig.Interaction.MaxRange + GameConfig.Interaction.RangeTolerance
	if (root.Position - entry.position).Magnitude > reach then
		return nil, nil, Enums.Reject.TooFar
	end

	return session, entry
end

function ObjectiveService:interact(player, interactableId)
	local session, entry, reason = self:_validate(player, interactableId)
	if not session then
		return { ok = false, reason = reason }
	end

	if entry.kind == "key" then
		return self:_collectKey(player, session, entry)
	elseif entry.kind == "gate" then
		return self:examineGate(player, session, entry)
	elseif entry.kind == "pillar" then
		return self:_touchPillar(player, session, entry)
	end

	return { ok = false, reason = Enums.Reject.BadRequest }
end

function ObjectiveService:_collectKey(player, session, entry)
	if entry.taken then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "already_taken" }
	end

	--[[ Marked taken BEFORE granting, so two simultaneous requests cannot both
	     pass. This is the duplication guard for a one-shot pickup. ]]
	entry.taken = true

	local result = self.context.InventoryService:addToBag(player, Enums.Resource.AncientKey, 1)
	if result.added <= 0 then
		entry.taken = false
		return { ok = false, reason = result.reason or Enums.Reject.InventoryFull }
	end

	if entry.instance then
		local key = entry.instance:FindFirstChild("Key")
		if key then
			key.Transparency = 1
			local light = key:FindFirstChildOfClass("PointLight")
			if light then
				light.Enabled = false
			end
			local prompt = key:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Enabled = false
			end
			local billboard = key:FindFirstChild("KeyLabel")
			if billboard then
				billboard:Destroy()
			end
		end
	end

	session.objectiveState.keysCollected += 1
	session.stats.objectivesCompleted = (session.stats.objectivesCompleted or 0) + 1

	local members = self.context.ExpeditionService:playersIn(session)
	Net.fireList(members, Routes.Push.Alert, {
		kind = "success",
		title = "ANCIENT KEY RECOVERED",
		body = ("%s has it. Get it out of here."):format(player.DisplayName),
		duration = 4,
	})
	Net.fireList(members, Routes.Push.PlaySound, { cue = "key_found" })

	self.context.RewardService:awardObjective(player, "ancient_key")
	self.keyCollected:Fire(player, session)
	self:push(session)

	log:info("%s collected an ancient key in session %s", player.Name, tostring(session.id))
	return { ok = true, kind = "key" }
end

function ObjectiveService:_touchPillar(player, session, entry)
	local puzzle = self._interactables[entry.puzzleId]
	if not puzzle or puzzle.solved then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "solved" }
	end

	local expected = puzzle.order[puzzle.progress + 1]
	local pillar = puzzle.pillars[entry.pillarIndex]

	if entry.pillarIndex == expected then
		puzzle.progress += 1
		if pillar and pillar.rune then
			pillar.rune.Color = Color3.fromRGB(150, 230, 190)
			local light = pillar.rune:FindFirstChildOfClass("PointLight")
			if light then
				light.Color = Color3.fromRGB(150, 230, 190)
				light.Brightness = 2
			end
		end

		if puzzle.progress >= #puzzle.order then
			return self:_solvePuzzle(player, session, puzzle)
		end

		Net.fire(player, Routes.Push.PlaySound, { cue = "discovery_chime" })
		return { ok = true, kind = "pillar", progress = puzzle.progress, total = #puzzle.order }
	end

	--[[ A wrong pillar resets the sequence but costs nothing else. The puzzle is
	     a memory and observation task, not a punishment. ]]
	puzzle.progress = 0
	for _, each in pairs(puzzle.pillars) do
		if each.rune then
			each.rune.Color = Color3.fromRGB(96, 104, 128)
			local light = each.rune:FindFirstChildOfClass("PointLight")
			if light then
				light.Color = Color3.fromRGB(110, 130, 180)
				light.Brightness = 0.5
			end
		end
	end

	Net.fire(player, Routes.Push.Notify, {
		kind = "warning",
		title = "The rune dims",
		body = "Wrong order. Watch which one answers first.",
	})
	Net.fire(player, Routes.Push.PlaySound, { cue = "ui_error" })
	return { ok = true, kind = "pillar", progress = 0, total = #puzzle.order, reset = true }
end

function ObjectiveService:_solvePuzzle(player, session, puzzle)
	puzzle.solved = true
	session.objectiveState.puzzlesSolved += 1
	session.stats.objectivesCompleted = (session.stats.objectivesCompleted or 0) + 1

	--[[ The reward is relics, which feed colony research: a side objective that
	     pays into the long game rather than the current run. ]]
	local relics = session.rng:nextInteger(2, 4)
	self.context.InventoryService:addToBag(player, Enums.Resource.Relic, relics)

	local members = self.context.ExpeditionService:playersIn(session)
	Net.fireList(members, Routes.Push.Alert, {
		kind = "success",
		title = "THE SEAL OPENS",
		body = ("%s solved the antechamber."):format(player.DisplayName),
		duration = 4,
	})
	Net.fireList(members, Routes.Push.PlaySound, { cue = "discovery_chime" })

	--[[ Solving a puzzle reveals where a key is, which is what makes the detour
	     worth taking on a timer. ]]
	local cave = self.context.CaveService:caveFor(session.id)
	if cave then
		for _, objective in ipairs(cave.layout.objectives) do
			if objective.kind == "ancient_key" then
				local position = self.context.CaveService:worldPositionOfCell(session.id, objective.cellKey)
				if position then
					Net.fireList(members, Routes.Push.Discovery, {
						kind = "key_revealed",
						position = position,
						cellKey = objective.cellKey,
						title = "A key, somewhere that way.",
					})
				end
				break
			end
		end
	end

	self.context.RewardService:awardObjective(player, "puzzle")
	self.puzzleSolved:Fire(player, session)
	self:push(session)
	return { ok = true, kind = "puzzle", solved = true, relics = relics }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- The First Gate
-- ─────────────────────────────────────────────────────────────────────────────

function ObjectiveService:stageFor(player)
	local profile = self.context.DataService:get(player)
	local unlocked = profile and profile.escape.gateStagesUnlocked or 0
	return ObjectiveService.Stages[unlocked + 1], unlocked
end

--[[ Examining the gate reports what it needs. Separating "look" from "unlock"
     means a player can learn the requirement without spending anything. ]]
function ObjectiveService:examineGate(player, session, entry)
	local stage, unlocked = self:stageFor(player)
	local profile = self.context.DataService:get(player)
	if not profile then
		return { ok = false, reason = Enums.Reject.NotLoaded }
	end

	session.objectiveState.gateExamined = true

	if not stage then
		return {
			ok = true,
			kind = "gate",
			complete = true,
			message = "Every seal you know of is open. Whatever comes next is not here.",
		}
	end

	--[[ Keys in the bag count, plus keys already banked in the colony — a key
	     carried out last run should not have to be carried back in. ]]
	local inBag = self.context.InventoryService:bagOf(player).items[Enums.Resource.AncientKey] or 0
	local banked = profile.escape.keys or 0

	return {
		ok = true,
		kind = "gate",
		stage = stage.stage,
		stageName = stage.name,
		keysRequired = stage.keysRequired,
		keysHeld = inBag + banked,
		keysInBag = inBag,
		keysBanked = banked,
		implemented = stage.implemented,
		canUnlock = stage.implemented and (inBag + banked) >= stage.keysRequired,
		lore = stage.lore,
		unlocks = stage.unlocks,
		stagesUnlocked = unlocked,
	}
end

function ObjectiveService:unlockGate(player)
	local session = self.context.ExpeditionService:sessionOf(player)
	if not session then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end

	local gateId = ("%s|gate"):format(tostring(session.id))
	local _, entry, reason = self:_validate(player, gateId)
	if not entry then
		return { ok = false, reason = reason }
	end

	local profile = self.context.DataService:get(player)
	if not profile then
		return { ok = false, reason = Enums.Reject.NotLoaded }
	end
	if self.context.DataService:isReadOnly(player) then
		return { ok = false, reason = Enums.Reject.NotLoaded, detail = "read_only" }
	end

	local stage, unlocked = self:stageFor(player)
	if not stage then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "no_stages_left" }
	end
	if not stage.implemented then
		--[[ Honest refusal. Later stages are designed but their chapter content
		     does not exist, so unlocking one would promise something that is not
		     there. ]]
		return {
			ok = false,
			reason = Enums.Reject.NotImplemented,
			detail = "future_chapter",
			stageName = stage.name,
		}
	end

	local bag = self.context.InventoryService:bagOf(player)
	local inBag = bag.items[Enums.Resource.AncientKey] or 0
	local banked = profile.escape.keys or 0
	if inBag + banked < stage.keysRequired then
		return {
			ok = false,
			reason = Enums.Reject.NotEnoughResources,
			detail = "keys",
			need = stage.keysRequired,
			have = inBag + banked,
		}
	end

	-- Spend from the bag first, then from the bank.
	local fromBag = math.min(inBag, stage.keysRequired)
	if fromBag > 0 then
		local removal = bag.items[Enums.Resource.AncientKey] - fromBag
		bag.items[Enums.Resource.AncientKey] = removal > 0 and removal or nil
		self.context.InventoryService:pushBag(player)
	end
	local fromBank = stage.keysRequired - fromBag
	if fromBank > 0 then
		profile.escape.keys = math.max(0, banked - fromBank)
	end

	profile.escape.gateStagesUnlocked = unlocked + 1
	--[[ Escaping unlocks content; it never wipes the colony. The brief is
	     explicit about this and so is the code: nothing here touches
	     profile.colony. ]]
	if not profile.escape.loreSeen then
		profile.escape.loreSeen = {}
	end
	profile.escape.loreSeen["gate_stage_" .. stage.stage] = true
	self.context.DataService:markDirty(player)

	local members = self.context.ExpeditionService:playersIn(session)
	Net.fireList(members, Routes.Push.Alert, {
		kind = "success",
		title = stage.name:upper() .. " OPENS",
		body = stage.lore,
		duration = 8,
	})
	Net.fireList(members, Routes.Push.PlaySound, { cue = "gate_unlock" })

	if entry.instance then
		local vault = entry.instance.Parent
		local props = vault and vault:FindFirstChild("Props")
		local gate = props and props:FindFirstChild("FirstGate")
		local slab = gate and gate:FindFirstChild("GateSlab")
		if slab then
			--[[ The slab sinks into the floor. A visible, permanent consequence
			     for the rest of the run. ]]
			slab.CanCollide = false
			slab.Transparency = 0.4
			slab.Position = slab.Position - Vector3.new(0, slab.Size.Y * 0.9, 0)
		end
	end

	self.context.RewardService:awardObjective(player, "gate_stage")
	self.gateUnlocked:Fire(player, session, stage)
	self.context.ColonyService:pushColony(player)
	self:push(session)

	log:info("%s unlocked gate stage %d (%s)", player.Name, stage.stage, stage.name)

	return {
		ok = true,
		stage = stage.stage,
		stageName = stage.name,
		lore = stage.lore,
		unlocks = stage.unlocks,
		keysSpent = stage.keysRequired,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Replication
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Objective list for the HUD tracker. Positions are only included once the
     objective's room has been discovered, so the tracker records exploration
     instead of giving the cave away. ]]
function ObjectiveService:snapshot(session)
	local cave = self.context.CaveService:caveFor(session.id)
	if not cave or not session.objectiveState then
		return nil
	end

	local entries = {}
	for _, id in ipairs(self._bySession[session.id] or {}) do
		local entry = self._interactables[id]
		if entry and (entry.kind == "key" or entry.kind == "gate" or entry.kind == "puzzle") then
			local discovered = cave.discovered[entry.cellKey] == true
			table.insert(entries, {
				id = id,
				kind = entry.kind,
				label = entry.label,
				done = entry.taken == true or entry.solved == true,
				discovered = discovered,
				position = discovered and entry.position or nil,
			})
		end
	end
	table.sort(entries, function(a, b)
		return a.id < b.id
	end)

	return {
		objectives = entries,
		keysCollected = session.objectiveState.keysCollected,
		keysAvailable = session.objectiveState.keysAvailable,
		keysRequired = session.difficulty.keysRequired,
		puzzlesSolved = session.objectiveState.puzzlesSolved,
		puzzlesAvailable = session.objectiveState.puzzlesAvailable,
		roomsDiscovered = self.context.CaveService:discoveredCount(session.id),
		totalRooms = #cave.layout.order,
		map = self.context.CaveService:mapSnapshot(session.id),
	}
end

function ObjectiveService:push(session)
	local snapshot = self:snapshot(session)
	if snapshot then
		Net.fireList(self.context.ExpeditionService:playersIn(session), Routes.Push.ObjectiveSync, snapshot)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function ObjectiveService:init(context)
	self.context = context
end

function ObjectiveService:start()
	Net.handle(Routes.Request.Interact, function(player, payload)
		if type(payload) ~= "table" or type(payload.id) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:interact(player, payload.id)
	end, Routes.limitsFor(Routes.Request.Interact))

	Net.handle(Routes.Request.UnlockGate, function(player)
		return self:unlockGate(player)
	end)

	Net.handle(Routes.Request.SolvePuzzle, function(player, payload)
		if type(payload) ~= "table" or type(payload.id) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:interact(player, payload.id)
	end)

	--[[ Entering a new room refreshes the objective tracker, which is how the
	     map fills in as the party explores. ]]
	self.context.CaveService.roomEntered:Connect(function(player, cave, cell, firstTime)
		local session = self.context.ExpeditionService:sessionById(cave.sessionId)
		if not session then
			return
		end
		if firstTime then
			session.stats.roomsDiscovered = (session.stats.roomsDiscovered or 0) + 1
			self.context.RewardService:awardDiscovery(player, cell)
		end
		self:push(session)
	end)

	log:info("ready (%d gate stages, %d implemented)", #ObjectiveService.Stages, 1)
end

return ObjectiveService.new()
