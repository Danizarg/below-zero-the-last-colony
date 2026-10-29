--[[
	MonsterBase.lua
	One state machine for every monster. Behaviour differences come from
	MonsterConfig data, not from branching on monster id.

	States
	──────
		idle         standing still, sensing
		patrol       wandering inside its territory
		investigate  moving to a remembered noise or last-known position
		chase        actively pursuing a target it can sense
		attack       committed to a telegraphed swing
		stagger      interrupted (Guardian's Heavy Swing)
		breakoff     giving up and withdrawing (the Stalker's counterplay)
		return       walking home after losing a target
		despawn      marked for removal

	Why two monsters feel different
	───────────────────────────────
	The Cave Crawler has a short sight range, a readable wind-up and little
	health: it is a fight. The Stalker is nearly blind but hears across the whole
	cave, cannot be killed with MVP weapons, and breaks off in bright light or
	when it finds two players together: it is a problem to be avoided. Neither
	difference is a bigger health bar, which the brief rules out explicitly.

	Movement uses a Humanoid so corridors, doorways and player collision come
	from the engine. PathfindingService is used only when the target is out of
	line of sight; in sight, the monster steers directly, which both costs less
	and reads better in a tight tunnel.
]]

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local MonsterConfig = require(Shared.Config.MonsterConfig)
local PartFactory = require(Shared.Util.PartFactory)

local Monster = {}
Monster.__index = Monster

local RAY_PARAMS = RaycastParams.new()
RAY_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
RAY_PARAMS.IgnoreWater = true

-- ─────────────────────────────────────────────────────────────────────────────
-- Rig construction
-- ─────────────────────────────────────────────────────────────────────────────

local function buildRig(def, position, parent)
	local body = def.body
	local scale = body.scale or 1
	local torsoSize = body.torso * scale

	local model = Instance.new("Model")
	model.Name = def.name

	--[[ A Humanoid needs a part called HumanoidRootPart; everything else is
	     welded to it, so the whole creature moves as one rigid body. ]]
	local root = PartFactory.block({
		name = "HumanoidRootPart",
		size = torsoSize,
		position = position,
		color = body.color,
		material = Enum.Material.SmoothPlastic,
		anchored = false,
		canCollide = true,
		parent = model,
	})
	root.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.4, 0.2, 1, 1)

	local function attach(part)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = part
		part.Massless = true
		part.CanCollide = false
	end

	-- Head.
	local head = PartFactory.block({
		name = "Head",
		size = Vector3.new(torsoSize.X * 0.6, torsoSize.Y * 0.7, torsoSize.Z * 0.5),
		position = position + Vector3.new(0, torsoSize.Y * 0.4, -torsoSize.Z * 0.5),
		color = body.accent,
		material = Enum.Material.SmoothPlastic,
		anchored = false,
		parent = model,
	})
	attach(head)

	-- Eyes: the single most useful readability cue in a dark cave.
	for _, sign in ipairs({ -1, 1 }) do
		local eye = PartFactory.glow({
			name = "Eye",
			size = Vector3.new(0.35, 0.35, 0.35) * scale,
			shape = Enum.PartType.Ball,
			position = position
				+ Vector3.new(sign * torsoSize.X * 0.2, torsoSize.Y * 0.5, -torsoSize.Z * 0.75),
			color = body.eyeColor,
			lightColor = body.eyeColor,
			range = 14 * scale,
			brightness = 1.6,
			light = sign == 1,
			parent = model,
		})
		eye.Anchored = false
		attach(eye)
	end

	-- Legs, splayed around the torso.
	local legCount = body.legCount or 4
	for index = 1, legCount do
		local side = (index % 2 == 0) and 1 or -1
		local along = math.floor((index - 1) / 2) / math.max(1, (legCount / 2) - 1)
		local leg = PartFactory.block({
			name = "Leg",
			size = Vector3.new(0.4 * scale, torsoSize.Y * 1.1, 0.4 * scale),
			cframe = CFrame.new(
				position
					+ Vector3.new(
						side * torsoSize.X * 0.65,
						-torsoSize.Y * 0.35,
						(along - 0.5) * torsoSize.Z * 0.9
					)
			) * CFrame.Angles(0, 0, math.rad(side * 25)),
			color = body.accent,
			material = Enum.Material.SmoothPlastic,
			anchored = false,
			parent = model,
		})
		attach(leg)
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = def.maxHealth
	humanoid.Health = def.maxHealth
	humanoid.WalkSpeed = def.walkSpeed
	humanoid.JumpPower = 0
	humanoid.AutoRotate = true
	humanoid.BreakJointsOnDeath = false
	humanoid.HipHeight = torsoSize.Y * 0.55
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.HealthDisplayDistance = def.killable and 70 or 0
	humanoid.NameDisplayDistance = 0
	humanoid.Parent = model

	model.PrimaryPart = root
	model.Parent = parent
	return model, root, humanoid
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Construction
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	@param options {
		def, sessionId, cellKey, position, parent, difficulty, context, id
	}
]]
function Monster.new(options)
	local def = options.def
	local difficulty = options.difficulty

	local self = setmetatable({}, Monster)
	self.id = options.id
	self.def = def
	self.sessionId = options.sessionId
	self.homeCellKey = options.cellKey
	self.homePosition = options.position
	self.context = options.context
	self.difficulty = difficulty

	local model, root, humanoid = buildRig(def, options.position, options.parent)
	self.model = model
	self.root = root
	self.humanoid = humanoid

	--[[ Difficulty scales health and damage here, once, so no combat code has
	     to remember to apply a multiplier. ]]
	local maxHealth = math.max(1, def.maxHealth * difficulty.monsterHealthMultiplier)
	humanoid.MaxHealth = maxHealth
	humanoid.Health = maxHealth
	self.damage = def.damage * difficulty.monsterDamageMultiplier

	self.state = "idle"
	self.stateEnteredAt = os.clock()
	self.target = nil
	self.lastKnownPosition = nil
	self.lastSensedAt = 0
	self.lastAttackAt = 0
	self.staggerUntil = 0
	self.breakOffUntil = 0
	self.interest = 0
	self.wanderTarget = nil
	self.pauseUntil = 0
	self.path = nil
	self.pathWaypoints = nil
	self.pathIndex = 1
	self.pathComputedAt = 0
	self.pathPending = false
	self.dead = false

	model:SetAttribute("MonsterId", self.id)
	model:SetAttribute("MonsterType", def.id)
	model:SetAttribute("Killable", def.killable == true)

	return self
end

function Monster:destroy()
	self.dead = true
	if self.model then
		self.model:Destroy()
		self.model = nil
	end
end

function Monster:isAlive()
	return not self.dead
		and self.humanoid
		and self.humanoid.Health > 0
		and self.model
		and self.model.Parent ~= nil
end

function Monster:position()
	return self.root and self.root.Position or self.homePosition
end

function Monster:setState(state)
	if self.state == state then
		return
	end
	self.state = state
	self.stateEnteredAt = os.clock()
end

function Monster:timeInState()
	return os.clock() - self.stateEnteredAt
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Senses
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Daytime awareness is reduced, so "cave monsters are less aggressive during
     the day" is a real mechanical difference rather than flavour text. ]]
function Monster:_awareness(phase)
	if phase == Enums.Phase.Day or phase == Enums.Phase.Prep then
		return self.def.dayAwarenessMult or 1
	end
	if phase == Enums.Phase.Night then
		return 1.2
	end
	return 1
end

function Monster:_hasLineOfSight(targetPosition)
	local origin = self:position()
	local direction = targetPosition - origin
	local distance = direction.Magnitude
	if distance < 0.5 then
		return true
	end

	RAY_PARAMS.FilterDescendantsInstances = { self.model }
	local result = workspace:Raycast(origin + Vector3.new(0, 2, 0), direction.Unit * distance, RAY_PARAMS)
	if not result then
		return true
	end
	--[[ Hitting the target's own character counts as seeing it. ]]
	local hitCharacter = result.Instance:FindFirstAncestorOfClass("Model")
	return hitCharacter ~= nil and Players:GetPlayerFromCharacter(hitCharacter) ~= nil
end

--[[ Pick a target among candidate players, weighted by the Guardian's Presence
     passive so a tank can actually hold attention. ]]
function Monster:_selectTarget(candidates, phase)
	local awareness = self:_awareness(phase)
	local sightRange = self.def.sightRange * awareness
	local best, bestScore

	for _, player in ipairs(candidates) do
		local root = player.Character and player.Character.PrimaryPart
		if root and not self.context.SurvivalService:isDowned(player) then
			local distance = (root.Position - self:position()).Magnitude
			if distance <= sightRange and self:_hasLineOfSight(root.Position) then
				local weight = self.context.RoleService:aggroWeightFor(player, self:position())
				--[[ Closer is better, and a Guardian's weight effectively makes
				     them feel closer than they are. ]]
				local score = weight / math.max(1, distance)
				if not bestScore or score > bestScore then
					best, bestScore = player, score
				end
			end
		end
	end

	return best
end

--[[ A noise the monster may react to. The Stalker accumulates interest;
     everything else treats a loud noise as a point to investigate. ]]
function Monster:onNoise(position, noiseKind)
	local noise = MonsterConfig.Noise[noiseKind]
	if not noise then
		return
	end

	local distance = (position - self:position()).Magnitude
	local hearing = math.min(self.def.hearingRange, noise.radius)
	if distance > hearing then
		return
	end

	if self.def.id == Enums.Monster.Stalker then
		--[[ Interest falls off with distance, so a noise across the cave is a
		     hint and a noise next door is a commitment. ]]
		local falloff = 1 - (distance / math.max(1, hearing))
		self.interest = math.min(MonsterConfig.StalkerInterest.Max, self.interest + noise.interest * falloff)
		self.lastKnownPosition = position
		self.lastSensedAt = os.clock()
	elseif self.state == "idle" or self.state == "patrol" then
		self.lastKnownPosition = position
		self.lastSensedAt = os.clock()
		self:setState("investigate")
	end
end

--[[ Damage response. The Crawler can be staggered and killed; the Stalker
     cannot be killed, but a solid hit costs it interest, which is what buys a
     retreat. ]]
function Monster:onDamaged(amount, byPlayer)
	if not self:isAlive() then
		return
	end

	if self.def.killable then
		if self.def.staggerable and byPlayer then
			local stagger = self.context.RoleService:staggerSecondsFor(byPlayer)
			if stagger > 0 then
				self.staggerUntil = os.clock() + stagger
				self:setState("stagger")
			end
		end
		if byPlayer then
			self.target = byPlayer
			local root = byPlayer.Character and byPlayer.Character.PrimaryPart
			if root then
				self.lastKnownPosition = root.Position
				self.lastSensedAt = os.clock()
			end
			if self.state ~= "stagger" then
				self:setState("chase")
			end
		end
	else
		--[[ An unkillable monster loses INTEREST rather than health, and how
		     much depends on how hard it was hit. A flat loss per hit would make
		     bare hands exactly as good as an iron blade at driving the Stalker
		     off, which would make the weapon choice meaningless in the one
		     encounter where running is the answer. ]]
		local reference = self.def.interestLossReferenceDamage or 26
		local weight = math.clamp(amount / reference, 0.3, 1.5)
		self.interest = math.max(0, self.interest - (self.def.damageInterestLoss or 0.3) * weight)

		if self.interest < MonsterConfig.StalkerInterest.InvestigateThreshold then
			self.breakOffUntil = os.clock() + (self.def.breakOffCooldown or 20)
			self.target = nil
			self:setState("breakoff")
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Movement
-- ─────────────────────────────────────────────────────────────────────────────

function Monster:_moveTo(position)
	if not self:isAlive() then
		return
	end
	self.humanoid:MoveTo(position)
end

--[[
	Navigate toward a position: straight if visible, pathfound if not.

	Recomputing a path is the expensive operation here, so it is rate-limited
	and only requested when the direct route is blocked.
]]
function Monster:_navigateTo(position)
	if self:_hasLineOfSight(position) then
		self.pathWaypoints = nil
		self:_moveTo(position)
		return
	end

	if not MonsterConfig.Pathfinding.Enabled then
		self:_moveTo(position)
		return
	end

	local now = os.clock()
	local stale = now - self.pathComputedAt > MonsterConfig.Pathfinding.RecomputeInterval

	if stale and not self.pathPending then
		self.pathPending = true
		self.pathComputedAt = now
		local origin = self:position()
		--[[ ComputeAsync yields, so it runs off the AI tick. The monster keeps
		     moving toward its last waypoint in the meantime rather than
		     stopping dead while it thinks. ]]
		task.spawn(function()
			local path = PathfindingService:CreatePath({
				AgentRadius = MonsterConfig.Pathfinding.AgentRadius,
				AgentHeight = MonsterConfig.Pathfinding.AgentHeight,
				AgentCanJump = false,
				WaypointSpacing = 8,
			})
			local ok = pcall(function()
				path:ComputeAsync(origin, position)
			end)
			if ok and path.Status == Enum.PathStatus.Success and self:isAlive() then
				local waypoints = path:GetWaypoints()
				if #waypoints > MonsterConfig.Pathfinding.MaxWaypointsFollowed then
					--[[ A very long path means the target is effectively
					     unreachable; following all of it would have the monster
					     touring the cave. Follow the first stretch only. ]]
					local trimmed = {}
					for index = 1, MonsterConfig.Pathfinding.MaxWaypointsFollowed do
						trimmed[index] = waypoints[index]
					end
					waypoints = trimmed
				end
				self.pathWaypoints = waypoints
				self.pathIndex = 2 -- waypoint 1 is where we already are
			else
				self.pathWaypoints = nil
			end
			self.pathPending = false
		end)
	end

	if self.pathWaypoints and self.pathWaypoints[self.pathIndex] then
		local waypoint = self.pathWaypoints[self.pathIndex]
		local flat =
			Vector3.new(waypoint.Position.X - self:position().X, 0, waypoint.Position.Z - self:position().Z)
		if flat.Magnitude <= MonsterConfig.Pathfinding.WaypointReachedRadius then
			self.pathIndex += 1
		end
		local next_ = self.pathWaypoints[self.pathIndex]
		self:_moveTo(next_ and next_.Position or waypoint.Position)
	else
		self:_moveTo(position)
	end
end

function Monster:_wander(rng)
	local now = os.clock()
	if now < self.pauseUntil then
		return
	end

	local arrived = not self.wanderTarget
		or (Vector3.new(self.wanderTarget.X, 0, self.wanderTarget.Z) - Vector3.new(
				self:position().X,
				0,
				self:position().Z
			)).Magnitude
			< 4

	if arrived then
		local pause = self.def.patrolPauseRange or { 1, 3 }
		self.pauseUntil = now + rng:nextRange(pause[1], pause[2])
		local angle = rng:nextRange(0, math.pi * 2)
		local distance = rng:nextRange(6, self.def.patrolRadius)
		self.wanderTarget = self.homePosition
			+ Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
	else
		self:_navigateTo(self.wanderTarget)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Attacking
-- ─────────────────────────────────────────────────────────────────────────────

function Monster:_tryAttack(target)
	local root = target.Character and target.Character.PrimaryPart
	if not root then
		return false
	end

	local now = os.clock()
	if now - self.lastAttackAt < self.def.attackCooldown then
		return false
	end
	if (root.Position - self:position()).Magnitude > self.def.attackRange then
		return false
	end

	self.lastAttackAt = now
	self:setState("attack")
	self.humanoid.WalkSpeed = 0

	--[[ The wind-up is the whole fight. It is long enough to read and dodge, and
	     the damage only lands if the target is STILL in range when it
	     resolves — so backing off actually works. ]]
	local windup = self.def.attackWindup
	self.context.MonsterService:signalAttack(self, target, windup)

	task.delay(windup, function()
		if not self:isAlive() then
			return
		end
		self.humanoid.WalkSpeed = self.def.chaseSpeed

		if self.state == "stagger" then
			return -- interrupted mid-swing
		end

		local stillThere = target.Character and target.Character.PrimaryPart
		if stillThere and (stillThere.Position - self:position()).Magnitude <= self.def.attackRange + 2 then
			self.context.CombatService:monsterAttack(self, target)
		end

		if self.state == "attack" then
			self:setState("chase")
		end
	end)

	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Update
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	One AI step.

	@param context { candidates = { Player }, phase = string, rng = Rng,
	                 lightLevelAt = function(position) -> 0..1 }
]]
function Monster:update(deltaTime, tickContext)
	if not self:isAlive() then
		return
	end

	local now = os.clock()
	local candidates = tickContext.candidates
	local phase = tickContext.phase
	local rng = tickContext.rng

	-- Stagger overrides everything.
	if now < self.staggerUntil then
		self:setState("stagger")
		self.humanoid.WalkSpeed = 0
		return
	elseif self.state == "stagger" then
		self:setState("chase")
	end

	-- Break-off: withdraw and ignore everything for a while.
	if now < self.breakOffUntil then
		self:setState("breakoff")
		self.humanoid.WalkSpeed = self.def.walkSpeed
		self:_navigateTo(self.homePosition)
		return
	end

	-- Interest decay for the Stalker.
	if self.def.id == Enums.Monster.Stalker then
		self.interest = math.max(0, self.interest - MonsterConfig.StalkerInterest.DecayPerSecond * deltaTime)
	end

	-- Sensing.
	local sensed = self:_selectTarget(candidates, phase)
	if sensed then
		self.target = sensed
		local root = sensed.Character and sensed.Character.PrimaryPart
		if root then
			self.lastKnownPosition = root.Position
		end
		self.lastSensedAt = now
	end

	--[[ The Stalker's counterplay, checked before it commits: bright light, or
	     two or more living players together, and it breaks off. This is why the
	     Stalker is a problem to solve rather than a fight to win. ]]
	if self.def.id == Enums.Monster.Stalker and self.target then
		local root = self.target.Character and self.target.Character.PrimaryPart
		if root then
			local light = tickContext.lightLevelAt and tickContext.lightLevelAt(root.Position) or 0
			if light >= (self.def.lightAversionThreshold or 1) then
				self.breakOffUntil = now + (self.def.breakOffCooldown or 20)
				self.target = nil
				self:setState("breakoff")
				return
			end

			local nearby = 0
			for _, player in ipairs(candidates) do
				local otherRoot = player.Character and player.Character.PrimaryPart
				if otherRoot and (otherRoot.Position - root.Position).Magnitude < 28 then
					if not self.context.SurvivalService:isDowned(player) then
						nearby += 1
					end
				end
			end
			if nearby >= (self.def.crowdAversionCount or 99) then
				self.breakOffUntil = now + (self.def.breakOffCooldown or 20)
				self.target = nil
				self:setState("breakoff")
				return
			end
		end
	end

	-- Decide what to do.
	local hasTarget = self.target ~= nil
	local targetRoot = hasTarget and self.target.Character and self.target.Character.PrimaryPart or nil

	if hasTarget and targetRoot then
		local distance = (targetRoot.Position - self:position()).Magnitude
		local lostByRange = distance > self.def.loseTargetRange
		local lostByTime = (now - self.lastSensedAt) > self.def.loseTargetSeconds
		local lostByDowned = self.context.SurvivalService:isDowned(self.target)

		--[[ A monster loses interest in a downed player. Standing over a
		     downed teammate waiting to deny the revive is not tension, it is a
		     dead end. ]]
		if lostByRange or lostByTime or lostByDowned then
			self.target = nil
			self:setState("return")
		else
			local commits = true
			if self.def.id == Enums.Monster.Stalker then
				commits = self.interest >= MonsterConfig.StalkerInterest.ChaseThreshold
			end

			if commits then
				if self.state ~= "attack" then
					self:setState("chase")
					self.humanoid.WalkSpeed = self.def.chaseSpeed
					if not self:_tryAttack(self.target) then
						self:_navigateTo(targetRoot.Position)
					end
				end
				return
			end
		end
	end

	-- No committed target: investigate, go home, or patrol.
	if self.lastKnownPosition and (now - self.lastSensedAt) < self.def.loseTargetSeconds * 2 then
		local shouldInvestigate = true
		if self.def.id == Enums.Monster.Stalker then
			shouldInvestigate = self.interest >= MonsterConfig.StalkerInterest.InvestigateThreshold
		end
		if shouldInvestigate then
			self:setState("investigate")
			self.humanoid.WalkSpeed = self.def.walkSpeed
			self:_navigateTo(self.lastKnownPosition)
			if (self.lastKnownPosition - self:position()).Magnitude < 8 then
				self.lastKnownPosition = nil
			end
			return
		end
	end

	local distanceHome = (self.homePosition - self:position()).Magnitude
	if distanceHome > self.def.territoryRadius then
		self:setState("return")
		self.humanoid.WalkSpeed = self.def.walkSpeed
		self:_navigateTo(self.homePosition)
		return
	end

	self:setState("patrol")
	self.humanoid.WalkSpeed = self.def.walkSpeed
	self:_wander(rng)
end

return Monster
