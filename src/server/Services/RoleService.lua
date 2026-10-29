--[[
	RoleService.lua
	Role selection, role stats applied to the character, and the active abilities.

	Where role power lives
	──────────────────────
	Nothing about a role is trusted to the client. WalkSpeed, MaxHealth and
	stamina capacity are written to the Humanoid by the server; ability cooldowns
	are tracked here; and every ability's effect is applied server-side. The
	client's only role-related message is "I pressed my ability key".

	MVP scope
	─────────
	Runner, Medic and Guardian are implemented end to end. Cook, Engineer and
	Researcher have config, UI entries and registered handlers, but those
	handlers return Reject.NotImplemented so nothing pretends to work. Flip
	GameConfig.MvpContentOnly to false to make them selectable once their
	handlers are written.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local PartFactory = require(Shared.Util.PartFactory)
local RoleConfig = require(Shared.Config.RoleConfig)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)

local log = Logger.new("RoleService")

local RoleService = {}
RoleService.__index = RoleService

local EFFECT_TICK = 0.25

function RoleService.new()
	local self = setmetatable({}, RoleService)
	self._resolved = {} -- [userId] = { stats, ability, extras, unlocked, roleId }
	self._cooldowns = {} -- [userId] = { [abilityId] = readyAt }
	self._activeEffects = {} -- [userId] = { [abilityId] = { endsAt, data } }
	self._accumulator = 0
	self.abilityUsed = Signal.new("abilityUsed")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Resolution
-- ─────────────────────────────────────────────────────────────────────────────

function RoleService:roleOf(player)
	local profile = self.context.DataService:get(player)
	if not profile then
		return RoleConfig.Default
	end
	local roleId = profile.progression.selectedRole
	return RoleConfig.isValid(roleId) and roleId or RoleConfig.Default
end

function RoleService:masteryOf(player, roleId)
	local profile = self.context.DataService:get(player)
	if not profile then
		return 0
	end
	return (profile.progression.roleMastery or {})[roleId or self:roleOf(player)] or 0
end

--[[ Recompute and cache a player's folded role stats. Called when a role is
     chosen, when mastery changes, and on spawn. ]]
function RoleService:refresh(player)
	local roleId = self:roleOf(player)
	local mastery = self:masteryOf(player, roleId)
	local stats, ability, extras, unlocked = RoleConfig.resolve(roleId, mastery)

	--[[ Passives that are simple flags rather than numbers are normalised here
	     so consumers do not have to go digging through the passive list. ]]
	local role = RoleConfig.get(roleId)
	for _, passive in ipairs(role.passives) do
		if passive.id == "steady_hands" then
			extras.steadyHands = true
		elseif passive.id == "trap_sense" then
			extras.trapSense = true
		elseif passive.id == "cartographer" then
			extras.cartographer = true
		elseif passive.id == "antiquarian" then
			extras.antiquarian = true
		end
	end

	self._resolved[player.UserId] = {
		roleId = roleId,
		mastery = mastery,
		stats = stats,
		ability = ability,
		extras = extras,
		unlocked = unlocked,
	}

	self.context.InventoryService:setBagCapacityFromRole(player, roleId, mastery)
	self.context.SurvivalService:setStaminaMax(player, stats.staminaMax)
	self:applyToCharacter(player, player.Character)
	self:push(player)
	return self._resolved[player.UserId]
end

function RoleService:resolvedFor(player)
	return self._resolved[player.UserId] or self:refresh(player)
end

function RoleService:statsFor(player)
	local resolved = self._resolved[player.UserId]
	return resolved and resolved.stats or nil
end

function RoleService:extrasFor(player)
	local resolved = self._resolved[player.UserId]
	return resolved and resolved.extras or nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Applying stats to the character
-- ─────────────────────────────────────────────────────────────────────────────

function RoleService:applyToCharacter(player, character)
	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local resolved = self._resolved[player.UserId]
	if not resolved then
		return
	end

	local previousFraction = humanoid.MaxHealth > 0 and (humanoid.Health / humanoid.MaxHealth) or 1
	humanoid.MaxHealth = resolved.stats.maxHealth
	humanoid.Health = math.clamp(resolved.stats.maxHealth * previousFraction, 1, resolved.stats.maxHealth)

	self:applyMovement(player)
	self:_applyAppearance(player, character, resolved)
end

--[[ WalkSpeed is recomputed rather than stored, so sprinting, role, downed
     state and active effects can never disagree about how fast someone is. ]]
function RoleService:applyMovement(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	if self.context.SurvivalService:isDowned(player) then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		return
	end

	local resolved = self._resolved[player.UserId]
	local base = resolved and resolved.stats.walkSpeed or 15
	local stats = self.context.SurvivalService:statsOf(player)

	local speed = base
	if stats.sprinting and stats.stamina > 0 then
		speed *= GameConfig.Survival.SprintSpeedMultiplier
	end

	humanoid.WalkSpeed = speed
	humanoid.JumpPower = 45
	humanoid.UseJumpPower = true
end

--[[ Role identity on the body: a tinted shoulder lamp and a coloured accent.
     Procedural, so it works with any avatar and needs no assets. ]]
function RoleService:_applyAppearance(_player, character, resolved)
	local existing = character:FindFirstChild("RoleKit")
	if existing then
		existing:Destroy()
	end

	local role = RoleConfig.get(resolved.roleId)
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	if not torso then
		return
	end

	local kit = Instance.new("Folder")
	kit.Name = "RoleKit"
	kit.Parent = character

	local lamp = PartFactory.glow({
		name = "RoleLamp",
		size = Vector3.new(0.6, 0.6, 0.6),
		shape = Enum.PartType.Ball,
		color = role.accent,
		lightColor = role.accent,
		range = 30,
		brightness = 1.4,
		parent = kit,
	})
	lamp.Massless = true

	local weld = Instance.new("Weld")
	weld.Part0 = torso
	weld.Part1 = lamp
	weld.C0 = CFrame.new(0.9, 0.4, -0.6)
	weld.Parent = lamp
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Effects queried by other services
-- ─────────────────────────────────────────────────────────────────────────────

local function effectActive(self, player, abilityId)
	local effects = self._activeEffects[player.UserId]
	local entry = effects and effects[abilityId]
	if not entry then
		return nil
	end
	if os.clock() >= entry.endsAt then
		effects[abilityId] = nil
		return nil
	end
	return entry
end

--[[ Incoming damage reduction, 0..1. Guardian's Last Stand applies to the
     Guardian and to allies inside its radius. ]]
function RoleService:damageReductionFor(player)
	local best = 0

	local own = effectActive(self, player, "last_stand")
	if own then
		best = math.max(best, own.data.damageReduction)
	end

	local root = player.Character and player.Character.PrimaryPart
	if root then
		for userId, effects in pairs(self._activeEffects) do
			local entry = effects["last_stand"]
			if entry and userId ~= player.UserId and os.clock() < entry.endsAt then
				local source = Players:GetPlayerByUserId(userId)
				local sourceRoot = source and source.Character and source.Character.PrimaryPart
				if sourceRoot and (sourceRoot.Position - root.Position).Magnitude <= entry.data.radius then
					--[[ Only allies in the same expedition benefit, so an aura
					     cannot leak between concurrent sessions. ]]
					if
						self.context.ExpeditionService:sessionIdOf(source)
						== self.context.ExpeditionService:sessionIdOf(player)
					then
						best = math.max(best, entry.data.damageReduction)
					end
				end
			end
		end
	end

	return math.clamp(best, 0, 0.9)
end

--[[
	How fast a downed player's timer runs, as a multiplier. 0 freezes it.

	Medic's Triage passive slows it for nearby downed allies; Field Stabilization
	stops it outright. Both are checked from the DOWNED player's point of view,
	so a medic running over mid-countdown immediately helps.
]]
function RoleService:downedTimerRateFor(downedPlayer)
	local root = downedPlayer.Character and downedPlayer.Character.PrimaryPart
	if not root then
		return 1
	end
	local sessionId = self.context.ExpeditionService:sessionIdOf(downedPlayer)
	local rate = 1

	for _, other in ipairs(Players:GetPlayers()) do
		if other == downedPlayer then
			continue
		end
		if self.context.ExpeditionService:sessionIdOf(other) ~= sessionId then
			continue
		end
		local otherRoot = other.Character and other.Character.PrimaryPart
		if not otherRoot then
			continue
		end
		local distance = (otherRoot.Position - root.Position).Magnitude

		local stabilization = effectActive(self, other, "field_stabilization")
		if stabilization and distance <= stabilization.data.radius then
			return 0
		end

		local extras = self._resolved[other.UserId] and self._resolved[other.UserId].extras
		if extras and extras.downedSlowRadius and distance <= extras.downedSlowRadius then
			rate = math.min(rate, extras.downedSlowMult or 1)
		end
	end

	return rate
end

--[[ Monster target preference. Guardian's Presence passive pulls aggro. ]]
function RoleService:aggroWeightFor(player, monsterPosition)
	local extras = self:extrasFor(player)
	if not extras or not extras.aggroRadius then
		return 1
	end
	local root = player.Character and player.Character.PrimaryPart
	if not root then
		return 1
	end
	if (root.Position - monsterPosition).Magnitude <= extras.aggroRadius then
		return extras.aggroWeight or 1
	end
	return 1
end

function RoleService:staggerSecondsFor(player)
	local extras = self:extrasFor(player)
	return (extras and extras.staggerSeconds) or 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Abilities
-- ─────────────────────────────────────────────────────────────────────────────

local abilityHandlers = {}

--[[ Runner — Pathfinder. Sends the route from the player's current room to the
     nearest extraction. The client draws it; the server computed it, so a
     modified client cannot ask for a route it has not earned. ]]
abilityHandlers.pathfinder = function(self, player, resolved, session)
	local positions, path = self.context.CaveService:routeToExtraction(player)
	if not positions or #positions == 0 then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "no_route" }
	end

	Net.fire(player, Routes.Push.RouteRevealed, {
		positions = positions,
		cells = path,
		duration = resolved.ability.duration,
	})

	--[[ Cartographer: the Runner's route is shared with the whole party, which
	     is what makes the role worth bringing rather than just fast. ]]
	if resolved.extras.cartographer and session then
		for _, other in ipairs(self.context.ExpeditionService:playersIn(session)) do
			if other ~= player then
				Net.fire(other, Routes.Push.RouteRevealed, {
					positions = positions,
					cells = path,
					duration = resolved.ability.duration,
					sharedBy = player.DisplayName,
				})
			end
		end
	end

	return { ok = true, roomsToExit = #path - 1 }
end

--[[ Medic — Field Stabilization. Freezes nearby downed timers and heals
     standing allies for the duration. ]]
abilityHandlers.field_stabilization = function(self, player, resolved, session)
	local root = player.Character and player.Character.PrimaryPart
	if not root then
		return { ok = false, reason = Enums.Reject.Busy }
	end

	self._activeEffects[player.UserId] = self._activeEffects[player.UserId] or {}
	self._activeEffects[player.UserId]["field_stabilization"] = {
		endsAt = os.clock() + resolved.ability.duration,
		data = {
			radius = resolved.ability.radius,
			healPerSecond = resolved.ability.healPerSecond,
		},
	}

	local affected = 0
	if session then
		for _, other in ipairs(self.context.ExpeditionService:playersIn(session)) do
			local otherRoot = other.Character and other.Character.PrimaryPart
			if otherRoot and (otherRoot.Position - root.Position).Magnitude <= resolved.ability.radius then
				affected += 1
			end
		end
	end

	return { ok = true, affected = affected, duration = resolved.ability.duration }
end

--[[ Guardian — Last Stand. Damage reduction for the Guardian and nearby allies.
     Queried by damageReductionFor rather than applied as a stat, so it layers
     correctly with role multipliers. ]]
abilityHandlers.last_stand = function(self, player, resolved, _session)
	self._activeEffects[player.UserId] = self._activeEffects[player.UserId] or {}
	self._activeEffects[player.UserId]["last_stand"] = {
		endsAt = os.clock() + resolved.ability.duration,
		data = {
			radius = resolved.ability.radius,
			damageReduction = resolved.ability.damageReduction,
		},
	}
	return { ok = true, duration = resolved.ability.duration, reduction = resolved.ability.damageReduction }
end

--[[ Architected, not implemented. These exist so the role is wired end to end
     the day its effect is written, and so nothing silently no-ops in the
     meantime. ]]
abilityHandlers.emergency_rations = function()
	return { ok = false, reason = Enums.Reject.NotImplemented, detail = "cook" }
end
abilityHandlers.emergency_beacon = function()
	return { ok = false, reason = Enums.Reject.NotImplemented, detail = "engineer" }
end
abilityHandlers.ancient_insight = function()
	return { ok = false, reason = Enums.Reject.NotImplemented, detail = "researcher" }
end

function RoleService:cooldownRemaining(player, abilityId)
	local cooldowns = self._cooldowns[player.UserId]
	local readyAt = cooldowns and cooldowns[abilityId]
	if not readyAt then
		return 0
	end
	return math.max(0, readyAt - os.clock())
end

function RoleService:useAbility(player)
	local session = self.context.ExpeditionService:sessionOf(player)
	if not session then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end

	local member = session.members[player.UserId]
	if not member or member.state ~= Enums.MemberState.Alive then
		return { ok = false, reason = Enums.Reject.Busy, detail = "not_alive" }
	end

	local resolved = self:resolvedFor(player)
	local ability = resolved.ability

	local remaining = self:cooldownRemaining(player, ability.id)
	if remaining > 0 then
		return { ok = false, reason = Enums.Reject.OnCooldown, remaining = remaining }
	end

	if ability.bannedPhases then
		for _, phase in ipairs(ability.bannedPhases) do
			if session.phase == phase then
				return { ok = false, reason = Enums.Reject.WrongZone, detail = "phase" }
			end
		end
	end

	local handler = abilityHandlers[ability.id]
	if not handler then
		return { ok = false, reason = Enums.Reject.NotImplemented }
	end

	if (ability.staminaCost or 0) > 0 then
		if not self.context.SurvivalService:spendStamina(player, ability.staminaCost) then
			return { ok = false, reason = Enums.Reject.Busy, detail = "no_stamina" }
		end
	end

	local result = handler(self, player, resolved, session)

	if not result.ok then
		--[[ A failed ability refunds its stamina and does not start the
		     cooldown. Charging for a no-op is the kind of small unfairness that
		     players remember. ]]
		if (ability.staminaCost or 0) > 0 then
			self.context.SurvivalService:restoreStamina(player, ability.staminaCost)
		end
		return result
	end

	self._cooldowns[player.UserId] = self._cooldowns[player.UserId] or {}
	self._cooldowns[player.UserId][ability.id] = os.clock() + ability.cooldown

	local root = player.Character and player.Character.PrimaryPart
	if root then
		self.context.MonsterService:reportNoise(session.id, root.Position, "ability")
	end

	Net.fireList(self.context.ExpeditionService:playersIn(session), Routes.Push.PlaySound, {
		cue = "ability_activate",
		position = root and root.Position or nil,
	})

	self:push(player)
	self.abilityUsed:Fire(player, ability.id, result)
	result.cooldown = ability.cooldown
	return result
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Selection
-- ─────────────────────────────────────────────────────────────────────────────

function RoleService:setRole(player, roleId)
	if not RoleConfig.isValid(roleId) then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	local role = RoleConfig.get(roleId)
	if GameConfig.MvpContentOnly and not role.implemented then
		return { ok = false, reason = Enums.Reject.NotImplemented }
	end

	--[[ Roles change between expeditions, never during one: swapping mid-run
	     would let a party carry one of everything and switch on demand. ]]
	if self.context.ExpeditionService:sessionOf(player) then
		return { ok = false, reason = Enums.Reject.WrongZone, detail = "in_expedition" }
	end

	local profile = self.context.DataService:get(player)
	if not profile then
		return { ok = false, reason = Enums.Reject.NotLoaded }
	end

	profile.progression.selectedRole = roleId
	profile.progression.roleMastery[roleId] = profile.progression.roleMastery[roleId] or 0
	self.context.DataService:markDirty(player)

	self:refresh(player)
	self.context.ColonyService:pushColony(player)
	return { ok = true, roleId = roleId }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Replication
-- ─────────────────────────────────────────────────────────────────────────────

function RoleService:push(player)
	local resolved = self._resolved[player.UserId]
	if not resolved then
		return
	end

	local roster = {}
	for _, roleId in ipairs(RoleConfig.Order) do
		local role = RoleConfig.get(roleId)
		table.insert(roster, {
			id = roleId,
			name = role.name,
			tagline = role.tagline,
			description = role.description,
			icon = role.icon,
			accent = role.accent,
			implemented = role.implemented,
			selectable = (not GameConfig.MvpContentOnly) or role.implemented,
			mastery = self:masteryOf(player, roleId),
			ability = {
				id = role.ability.id,
				name = role.ability.name,
				description = role.ability.description,
				cooldown = role.ability.cooldown,
			},
			passives = role.passives,
			upgrades = role.upgrades,
		})
	end

	Net.fire(player, Routes.Push.AbilityState, {
		roleId = resolved.roleId,
		mastery = resolved.mastery,
		stats = resolved.stats,
		ability = resolved.ability,
		unlocked = resolved.unlocked,
		cooldownRemaining = self:cooldownRemaining(player, resolved.ability.id),
		roles = roster,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function RoleService:onExpeditionStart(player)
	self._cooldowns[player.UserId] = {}
	self._activeEffects[player.UserId] = {}
	self:refresh(player)
end

function RoleService:init(context)
	self.context = context
end

function RoleService:start()
	Net.handle(Routes.Request.SetRole, function(player, payload)
		if type(payload) ~= "table" or type(payload.roleId) ~= "string" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:setRole(player, payload.roleId)
	end)

	Net.handle(Routes.Request.UseAbility, function(player)
		return self:useAbility(player)
	end, Routes.limitsFor(Routes.Request.UseAbility))

	self.context.DataService.profileLoaded:Connect(function(player)
		self:refresh(player)
	end)

	--[[ Field Stabilization heals over time, so active effects need a tick. One
	     loop covers every player's effects. ]]
	RunService.Heartbeat:Connect(function(deltaTime)
		self._accumulator += deltaTime
		if self._accumulator < EFFECT_TICK then
			return
		end
		local step = self._accumulator
		self._accumulator = 0

		for userId, effects in pairs(self._activeEffects) do
			local player = Players:GetPlayerByUserId(userId)
			if not player then
				self._activeEffects[userId] = nil
				continue
			end

			local stabilization = effects["field_stabilization"]
			if stabilization then
				if os.clock() >= stabilization.endsAt then
					effects["field_stabilization"] = nil
				elseif stabilization.data.healPerSecond and stabilization.data.healPerSecond > 0 then
					local root = player.Character and player.Character.PrimaryPart
					local session = self.context.ExpeditionService:sessionOf(player)
					if root and session then
						for _, other in ipairs(self.context.ExpeditionService:playersIn(session)) do
							local otherRoot = other.Character and other.Character.PrimaryPart
							if
								otherRoot
								and (otherRoot.Position - root.Position).Magnitude
									<= stabilization.data.radius
							then
								self.context.SurvivalService:heal(
									other,
									stabilization.data.healPerSecond * step,
									"field_stabilization"
								)
							end
						end
					end
				end
			end

			local lastStand = effects["last_stand"]
			if lastStand and os.clock() >= lastStand.endsAt then
				effects["last_stand"] = nil
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		self._resolved[player.UserId] = nil
		self._cooldowns[player.UserId] = nil
		self._activeEffects[player.UserId] = nil
	end)

	log:info("ready (%d roles, %d implemented)", #RoleConfig.Order, #RoleConfig.selectable(true))
end

return RoleService.new()
