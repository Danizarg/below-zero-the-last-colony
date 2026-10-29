--[[
	NodeService.lua
	Resource nodes in the caves, and server-validated harvesting.

	The client can only ever say "I swung at node X". The server decides whether
	that player is close enough, has the right tool, has the stamina, is off
	cooldown, and what the swing yields. Nothing about the amount comes from the
	client.

	Nodes are spawned once per expedition and are never re-rolled by a maze
	shift. That is deliberate: if a shift respawned nodes, standing in a room
	through two shifts would be an infinite resource exploit.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local PartFactory = require(Shared.Util.PartFactory)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local Rng = require(Shared.Lib.Rng)
local RoomLibrary = require(script.Parent.Parent.World.RoomLibrary)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)

local log = Logger.new("NodeService")

local NodeService = {}
NodeService.__index = NodeService

function NodeService.new()
	local self = setmetatable({}, NodeService)
	self._nodes = {} -- [nodeId] = node state
	self._bySession = {} -- [sessionId] = { nodeId, ... }
	self._lastSwing = {} -- [userId] = os.clock()
	self.harvested = Signal.new("harvested")
	self.nodeDepleted = Signal.new("nodeDepleted")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Spawning
-- ─────────────────────────────────────────────────────────────────────────────

local function buildNodeModel(def, origin, parent, _biome)
	local model = PartFactory.model(def.name, nil)

	local body = PartFactory.block({
		name = "Body",
		size = def.size,
		cframe = CFrame.new(origin + Vector3.new(0, def.size.Y / 2, 0)),
		color = def.color,
		material = def.material,
		parent = model,
	})

	--[[ A small cluster of chunks around the main body so a node reads as a
	     formation rather than a single box. ]]
	for index = 1, 3 do
		local angle = (index / 3) * math.pi * 2
		PartFactory.decor({
			name = "Chunk",
			size = def.size * 0.4,
			cframe = CFrame.new(
				origin
					+ Vector3.new(
						math.cos(angle) * def.size.X * 0.5,
						def.size.Y * 0.2,
						math.sin(angle) * def.size.Z * 0.5
					)
			) * CFrame.Angles(0, angle, 0.2),
			color = def.color,
			material = def.material,
			parent = model,
		})
	end

	if def.glow then
		PartFactory.glow({
			name = "NodeGlow",
			size = def.size * 0.45,
			position = origin + Vector3.new(0, def.size.Y * 0.7, 0),
			shape = Enum.PartType.Ball,
			color = def.glow,
			lightColor = def.glow,
			range = 26,
			brightness = 1.2,
			parent = model,
		})
	end

	local resource = ResourceConfig.get(def.resource)
	PartFactory.prompt(body, {
		name = "HarvestPrompt",
		actionText = "Harvest",
		objectText = ("%s (%s)"):format(def.name, resource and resource.name or def.resource),
		keyCode = Enum.KeyCode.E,
		maxDistance = GameConfig.Interaction.MaxRange,
		requiresLineOfSight = false,
	})

	model.PrimaryPart = body
	model.Parent = parent
	return model, body
end

--[[
	Fill a cave with nodes.

	Counts come from ResourceConfig.NodesPerRoom scaled by the difficulty's
	resourceNodeMultiplier, and the choice within a room is a seeded weighted
	pick biased by the biome. Same seed, same nodes.
]]
function NodeService:populate(cave, difficulty)
	local rng = Rng.new(cave.layout.seed + 31337)
	local biome = cave.built.biome
	local created = {}

	for _, key in ipairs(cave.layout.order) do
		local cell = cave.layout.cells[key]
		local roomModel = cave.built.rooms[key]
		if not roomModel then
			continue
		end
		local folder = roomModel:FindFirstChild("Nodes")
		if not folder then
			continue
		end

		local base = ResourceConfig.NodesPerRoom[cell.kind] or 0
		local target = math.floor(base * difficulty.resourceNodeMultiplier + rng:nextNumber())
		if target <= 0 then
			continue
		end

		local candidates = ResourceConfig.nodesForRoom(cell.kind)
		if #candidates == 0 then
			continue
		end

		local cellOrigin = RoomLibrary.cellOrigin(cave.origin, cell)
		local half = GameConfig.Cave.CellSize / 2

		for index = 1, target do
			local def = rng:pickWeighted(candidates, function(entry)
				local bias = (biome.nodeBias and biome.nodeBias[entry.id]) or 1
				return (entry.weight or 1) * bias
			end)
			if def then
				--[[ Nodes are placed on a ring away from the centre so they never
				     block a doorway or sit on top of the room's props. ]]
				local angle = (index / target) * math.pi * 2 + rng:nextRange(-0.5, 0.5)
				local distance = rng:nextRange(half * 0.35, half * 0.72)
				local position = cellOrigin
					+ Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)

				local nodeId = ("%s|%s|%d"):format(tostring(cave.sessionId), key, index)
				local model, body = buildNodeModel(def, position, folder, biome)
				model:SetAttribute("NodeId", nodeId)

				local hits = math.max(1, def.hits)
				self._nodes[nodeId] = {
					id = nodeId,
					sessionId = cave.sessionId,
					cellKey = key,
					def = def,
					model = model,
					body = body,
					position = position,
					hitsRemaining = hits,
					maxHits = hits,
					depleted = false,
					respawnAt = nil,
				}
				table.insert(created, nodeId)
			end
		end
	end

	self._bySession[cave.sessionId] = created
	log:info("populated session %s with %d nodes", tostring(cave.sessionId), #created)
	return #created
end

function NodeService:clearSession(sessionId)
	local list = self._bySession[sessionId]
	if list then
		for _, nodeId in ipairs(list) do
			self._nodes[nodeId] = nil
		end
	end
	self._bySession[sessionId] = nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Harvesting
-- ─────────────────────────────────────────────────────────────────────────────

local function quantise(rng, amount)
	local whole = math.floor(amount)
	local fraction = amount - whole
	if fraction > 0 and rng:chance(fraction) then
		whole += 1
	end
	return whole
end

function NodeService:_depleteNode(node, difficulty)
	node.depleted = true
	node.hitsRemaining = 0

	if node.model then
		--[[ Depleted nodes are hidden rather than destroyed, so a respawn is a
		     property flip instead of a rebuild, and the node keeps its id. ]]
		for _, part in ipairs(node.model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Transparency = 0.85
				part.CanCollide = false
			elseif part:IsA("ProximityPrompt") or part:IsA("PointLight") then
				part.Enabled = false
			end
		end
	end

	local respawn = node.def.respawnSeconds
	if respawn and respawn > 0 then
		local scaled = respawn * (difficulty and difficulty.resourceRespawnMultiplier or 1)
		node.respawnAt = os.clock() + scaled
		task.delay(scaled, function()
			if self._nodes[node.id] == node and node.depleted then
				self:_respawnNode(node)
			end
		end)
	end

	self.nodeDepleted:Fire(node)
end

function NodeService:_respawnNode(node)
	node.depleted = false
	node.hitsRemaining = node.maxHits
	node.respawnAt = nil

	if node.model then
		for _, part in ipairs(node.model:GetDescendants()) do
			if part:IsA("BasePart") then
				part.Transparency = 0
				--[[ Only the solid body blocks movement. The decorative chunks
				     and the glow were created non-colliding and must stay that
				     way, or a respawned node would grow an invisible wall. ]]
				part.CanCollide = part.Name == "Body"
			elseif part:IsA("ProximityPrompt") or part:IsA("PointLight") then
				part.Enabled = true
			end
		end
	end
end

--[[
	A harvest swing.

	Validation order, cheapest first:
		1. the player is in an expedition at all
		2. the node exists and belongs to that expedition
		3. the node is not depleted
		4. the swing is off cooldown (tool-specific)
		5. the player is actually within range — measured on the server
		6. the tool is good enough for this node
		7. there is stamina to spend
	Only then does anything change.
]]
function NodeService:harvest(player, nodeId)
	local session = self.context.ExpeditionService:sessionOf(player)
	if not session then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end

	local node = self._nodes[nodeId]
	if not node or node.sessionId ~= session.id then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end
	if node.depleted then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "depleted" }
	end

	local member = session.members[player.UserId]
	if not member or member.state ~= Enums.MemberState.Alive then
		return { ok = false, reason = Enums.Reject.Busy, detail = "not_alive" }
	end

	local tool = self.context.InventoryService:equippedTool(player)

	local now = os.clock()
	local last = self._lastSwing[player.UserId] or 0
	if now - last < tool.swingCooldown then
		return { ok = false, reason = Enums.Reject.OnCooldown }
	end

	local character = player.Character
	local root = character and character.PrimaryPart
	if not root then
		return { ok = false, reason = Enums.Reject.Busy }
	end

	local reach = GameConfig.Interaction.MaxRange + GameConfig.Interaction.RangeTolerance
	local distance = (root.Position - node.position).Magnitude
	if distance > reach then
		return { ok = false, reason = Enums.Reject.TooFar, detail = math.floor(distance) }
	end

	if tool.tier < node.def.tier then
		local needed
		for _, candidate in ipairs(ResourceConfig.ToolOrder) do
			local def = ResourceConfig.Tools[candidate]
			if def.tier >= node.def.tier then
				needed = def.name
				break
			end
		end
		return { ok = false, reason = Enums.Reject.NoPermission, detail = "needs_tool", tool = needed }
	end

	local staminaCost = GameConfig.Survival.StaminaMineCost
	if not self.context.SurvivalService:spendStamina(player, staminaCost) then
		return { ok = false, reason = Enums.Reject.Busy, detail = "no_stamina" }
	end

	self._lastSwing[player.UserId] = now

	-- Yield.
	local roleStats = self.context.RoleService:statsFor(player)
	local yield = node.def.yieldPerHit
		* (tool.harvestMultiplier or 1)
		* (roleStats and roleStats.harvestMult or 1)
		* session.difficulty.nodeYieldMultiplier

	local gained = quantise(session.rng, yield)
	local added = 0
	if gained > 0 then
		local result = self.context.InventoryService:addToBag(player, node.def.resource, gained)
		added = result.added
		if result.reason == Enums.Reject.InventoryFull and added == 0 then
			--[[ Refund the stamina: the swing did nothing, so charging for it
			     would be a bug the player experiences as unfairness. ]]
			self.context.SurvivalService:restoreStamina(player, staminaCost)
			return { ok = false, reason = Enums.Reject.InventoryFull }
		end
	end

	node.hitsRemaining -= 1
	self.context.InventoryService:wearTool(
		player,
		math.max(1, math.floor(1 * session.difficulty.durabilityLossMultiplier))
	)

	--[[ Mining is loud. The Stalker hunts by sound, so this is a real tactical
	     cost at night rather than flavour. ]]
	self.context.MonsterService:reportNoise(session.id, root.Position, "mine")

	Net.fire(player, Routes.Push.PlaySound, {
		cue = node.def.tier > 0 and "mining_impact" or "harvest_soft",
		position = node.position,
	})

	local depleted = false
	if node.hitsRemaining <= 0 then
		self:_depleteNode(node, session.difficulty)
		depleted = true
		Net.fireList(self.context.ExpeditionService:playersIn(session), Routes.Push.NodeDepleted, {
			nodeId = nodeId,
			respawns = node.def.respawnSeconds > 0,
		})
	end

	self.harvested:Fire(player, session, node, added)

	return {
		ok = true,
		nodeId = nodeId,
		resource = node.def.resource,
		gained = added,
		hitsRemaining = node.hitsRemaining,
		depleted = depleted,
	}
end

--[[ Loot containers and one-shot pickups reuse the harvest path, so there is a
     single validated way for an item to enter a bag. ]]
function NodeService:grantPickup(player, resourceId, amount, position)
	local session = self.context.ExpeditionService:sessionOf(player)
	if not session then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end
	if position then
		local root = player.Character and player.Character.PrimaryPart
		local reach = GameConfig.Interaction.MaxRange + GameConfig.Interaction.RangeTolerance
		if not root or (root.Position - position).Magnitude > reach then
			return { ok = false, reason = Enums.Reject.TooFar }
		end
	end
	local result = self.context.InventoryService:addToBag(player, resourceId, amount)
	return { ok = result.added > 0, gained = result.added, reason = result.reason }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function NodeService:init(context)
	self.context = context
end

function NodeService:start()
	Net.handle(Routes.Request.HarvestNode, function(player, payload)
		if type(payload) ~= "table" or type(payload.nodeId) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:harvest(player, payload.nodeId)
	end, Routes.limitsFor(Routes.Request.HarvestNode))

	log:info("ready")
end

return NodeService.new()
