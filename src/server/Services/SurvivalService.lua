--[[
	SurvivalService.lua
	Health, stamina, hunger, the downed state, reviving and death.

	Design rules the brief asks for, and how they are met:

	"Players must understand why they died."
		Every damage event carries a source string, the last few are kept per
		player, and the downed/death push includes them. The death screen can
		therefore say "Cave Crawler x3, then starvation" rather than "you died".

	"Avoid unpredictable instant deaths."
		Nothing can kill a standing player outright. All damage is clamped so the
		worst single hit leaves them downed, not dead, and the only route from
		downed to dead is the revive timer expiring — which is visible and
		counted down on screen. Fall damage is computed from fall height with a
		generous threshold and is also clamped.

	"Survival mechanics should add meaningful choices without creating
	 repetitive maintenance chores."
		Hunger drains slowly enough that a full bar outlasts a Medium expedition.
		It is a supply decision made before the run, not a chore during it.

	Characters are loaded explicitly (Players.CharacterAutoLoads is false) so a
	death inside an expedition does not silently respawn the player in the
	colony. Spawning is a decision this service makes.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)

local log = Logger.new("SurvivalService")

local SurvivalService = {}
SurvivalService.__index = SurvivalService

local SURVIVAL = GameConfig.Survival
local REVIVE_CHECK_INTERVAL = 0.2
local DAMAGE_LOG_LENGTH = 6

function SurvivalService.new()
	local self = setmetatable({}, SurvivalService)
	self._stats = {} -- [userId] = { stamina, hunger, sprinting, lastStaminaUse, damageLog }
	self._downed = {} -- [userId] = { endsAt, pausedUntil, remaining }
	self._revives = {} -- [reviverUserId] = { targetUserId, endsAt }
	self._fallTracking = {} -- [userId] = highestY while airborne
	self._accumulator = 0
	self._reviveAccumulator = 0

	self.downed = Signal.new("downed")
	self.revived = Signal.new("revived")
	self.died = Signal.new("died")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Stat access
-- ─────────────────────────────────────────────────────────────────────────────

function SurvivalService:statsOf(player)
	local stats = self._stats[player.UserId]
	if not stats then
		stats = {
			stamina = SURVIVAL.StaminaMax,
			staminaMax = SURVIVAL.StaminaMax,
			hunger = SURVIVAL.HungerMax,
			sprinting = false,
			lastStaminaUse = 0,
			damageLog = {},
		}
		self._stats[player.UserId] = stats
	end
	return stats
end

--[[ Called by RoleService when a role is applied, so stamina capacity follows
     the role rather than being a global constant. ]]
function SurvivalService:setStaminaMax(player, value)
	local stats = self:statsOf(player)
	stats.staminaMax = value
	stats.stamina = math.min(stats.stamina, value)
end

function SurvivalService:resetFor(player, full)
	local stats = self:statsOf(player)
	stats.stamina = stats.staminaMax
	stats.sprinting = false
	stats.damageLog = {}
	if full then
		stats.hunger = SURVIVAL.HungerMax
	end
	self._downed[player.UserId] = nil
	self:pushStats(player)
end

function SurvivalService:spendStamina(player, amount)
	local stats = self:statsOf(player)
	if stats.stamina < amount then
		return false
	end
	stats.stamina -= amount
	stats.lastStaminaUse = os.clock()
	self:pushStats(player)
	return true
end

function SurvivalService:restoreStamina(player, amount)
	local stats = self:statsOf(player)
	stats.stamina = math.min(stats.staminaMax, stats.stamina + amount)
	self:pushStats(player)
end

function SurvivalService:isDowned(player)
	return self._downed[player.UserId] ~= nil
end

function SurvivalService:downedRemaining(player)
	local entry = self._downed[player.UserId]
	if not entry then
		return nil
	end
	return math.max(0, entry.endsAt - os.clock())
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Damage
-- ─────────────────────────────────────────────────────────────────────────────

local function humanoidOf(player)
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid") or nil
end

function SurvivalService:_logDamage(player, source, amount)
	local stats = self:statsOf(player)
	table.insert(stats.damageLog, {
		source = source,
		amount = math.floor(amount + 0.5),
		at = os.clock(),
	})
	while #stats.damageLog > DAMAGE_LOG_LENGTH do
		table.remove(stats.damageLog, 1)
	end
end

--[[ A readable account of what hurt the player most recently. ]]
function SurvivalService:damageSummary(player)
	local stats = self:statsOf(player)
	local totals = {}
	local order = {}
	for _, entry in ipairs(stats.damageLog) do
		if not totals[entry.source] then
			totals[entry.source] = 0
			table.insert(order, entry.source)
		end
		totals[entry.source] += entry.amount
	end
	local parts = {}
	for _, source in ipairs(order) do
		table.insert(parts, ("%s (%d)"):format(source, totals[source]))
	end
	return parts
end

--[[
	Apply damage to a player. The ONLY route from full health to downed.

	@param source string  human-readable cause, shown on the death screen
	@return number damage actually dealt
]]
function SurvivalService:applyDamage(player, amount, source, attackerPosition)
	amount = tonumber(amount) or 0
	if amount <= 0 then
		return 0
	end

	local humanoid = humanoidOf(player)
	if not humanoid or humanoid.Health <= 0 then
		return 0
	end
	if self:isDowned(player) then
		--[[ A downed player cannot be damaged further. Monsters finishing off a
		     downed teammate would make the revive window meaningless. ]]
		return 0
	end

	local roleStats = self.context.RoleService:statsFor(player)
	local multiplier = roleStats and roleStats.damageTakenMult or 1

	-- Guardian's Last Stand and similar effects reduce incoming damage.
	local reduction = self.context.RoleService:damageReductionFor(player)
	local dealt = amount * multiplier * (1 - reduction)

	--[[ Clamp so a hit can never kill outright: the floor is 1 HP, which puts
	     the player into the downed state instead. Predictability over drama. ]]
	local survivable = math.max(0, humanoid.Health - SURVIVAL.DownedHealth)
	dealt = math.min(dealt, survivable + 0.001)

	humanoid.Health = math.max(SURVIVAL.DownedHealth, humanoid.Health - dealt)
	self:_logDamage(player, source or "unknown", dealt)

	Net.fire(player, Routes.Push.PlaySound, { cue = "player_hurt" })
	if attackerPosition then
		self.context.MonsterService:reportNoise(
			self.context.ExpeditionService:sessionIdOf(player),
			attackerPosition,
			"hurt"
		)
	end

	if humanoid.Health <= SURVIVAL.DownedHealth then
		self:down(player, source or "unknown")
	else
		self:pushStats(player)
	end

	return dealt
end

function SurvivalService:heal(player, amount, source)
	local humanoid = humanoidOf(player)
	if not humanoid or humanoid.Health <= 0 then
		return 0
	end
	if self:isDowned(player) then
		return 0
	end
	local before = humanoid.Health
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + amount)
	self:pushStats(player)
	return humanoid.Health - before
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Downed state
-- ─────────────────────────────────────────────────────────────────────────────

function SurvivalService:down(player, cause)
	if self:isDowned(player) then
		return
	end

	local session = self.context.ExpeditionService:sessionOf(player)
	if not session then
		--[[ Outside an expedition there is no downed state — being reduced to
		     nothing in your own colony just heals you up. There is nothing to
		     rescue you from. ]]
		local humanoid = humanoidOf(player)
		if humanoid then
			humanoid.Health = humanoid.MaxHealth
		end
		return
	end

	local member = session.members[player.UserId]
	if not member then
		return
	end

	local window = session.difficulty.downedSeconds
	--[[ Infirmary level extends the window: a colony investment that pays off
	     inside the caves, which is the loop the whole game is built on. ]]
	local effects = self.context.BuildingService:effectsFor(player)
	window += (effects.reviveWindowBonus or 0)

	member.state = Enums.MemberState.Downed
	self._downed[player.UserId] = { endsAt = os.clock() + window, window = window, cause = cause }

	local humanoid = humanoidOf(player)
	if humanoid then
		humanoid.Health = SURVIVAL.DownedHealth
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.JumpHeight = 0
		humanoid.PlatformStand = true
	end

	local players = self.context.ExpeditionService:playersIn(session)
	Net.fireList(players, Routes.Push.Downed, {
		userId = player.UserId,
		name = player.DisplayName,
		seconds = window,
		cause = cause,
	})
	Net.fire(player, Routes.Push.PlaySound, { cue = "player_downed" })

	self.downed:Fire(player, session, cause)
	log:info("%s is down (%s), %.0fs window", player.Name, tostring(cause), window)
end

--[[
	Bring a downed player back up.
	@param byPlayer Player|nil  nil for a free/paid rescue
]]
function SurvivalService:revive(player, byPlayer)
	local entry = self._downed[player.UserId]
	if not entry then
		return false
	end

	self._downed[player.UserId] = nil

	local session = self.context.ExpeditionService:sessionOf(player)
	if session then
		local member = session.members[player.UserId]
		if member then
			member.state = Enums.MemberState.Alive
			member.revivedCount = (member.revivedCount or 0) + 1
		end
	end

	local humanoid = humanoidOf(player)
	if humanoid then
		humanoid.PlatformStand = false
		humanoid.Health = math.max(1, humanoid.MaxHealth * SURVIVAL.ReviveGrantedHealthFraction)
		self.context.RoleService:applyMovement(player)
	end

	local players = session and self.context.ExpeditionService:playersIn(session) or { player }
	Net.fireList(players, Routes.Push.Revived, {
		userId = player.UserId,
		name = player.DisplayName,
		byUserId = byPlayer and byPlayer.UserId or nil,
		byName = byPlayer and byPlayer.DisplayName or nil,
	})
	Net.fireList(players, Routes.Push.PlaySound, { cue = "revive_complete" })

	self.revived:Fire(player, byPlayer)
	self:pushStats(player)
	return true
end

--[[ The downed timer ran out. The player becomes a spectator and may use a free
     rescue; they are never locked out of the game. ]]
function SurvivalService:_die(player)
	local entry = self._downed[player.UserId]
	local cause = entry and entry.cause or "unknown"
	self._downed[player.UserId] = nil

	local session = self.context.ExpeditionService:sessionOf(player)
	if session then
		local member = session.members[player.UserId]
		if member then
			member.state = Enums.MemberState.Dead
			member.diedAt = os.clock()
		end
	end

	local character = player.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = 0
		end
		--[[ Give the death a moment to read on screen, then clear the body.
		     CharacterAutoLoads is false, so nothing respawns behind our back. ]]
		task.delay(2, function()
			if character and character.Parent then
				character:Destroy()
			end
		end)
	end

	local rescuesLeft = self.context.ExpeditionService:rescuesRemaining(player)
	Net.fire(player, Routes.Push.ExpeditionEnded, {
		spectating = true,
		cause = cause,
		damageSummary = self:damageSummary(player),
		freeRescuesRemaining = rescuesLeft,
	})

	if session then
		local players = self.context.ExpeditionService:playersIn(session)
		Net.fireList(players, Routes.Push.Notify, {
			kind = "danger",
			title = ("%s has fallen"):format(player.DisplayName),
			body = ("Cause: %s"):format(tostring(cause)),
		})
	end

	self.died:Fire(player, session, cause)
	log:info("%s died (%s)", player.Name, tostring(cause))

	if session then
		self.context.ExpeditionService:onMemberDied(session, player)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Reviving (server-channelled)
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Start a revive channel. The server re-checks distance every tick, so walking
	away cancels it; the client cannot shortcut the hold.
]]
function SurvivalService:beginRevive(reviver, target)
	if reviver == target then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	local session = self.context.ExpeditionService:sessionOf(reviver)
	local targetSession = self.context.ExpeditionService:sessionOf(target)
	if not session or session ~= targetSession then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end
	if not self:isDowned(target) then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "not_downed" }
	end
	if self:isDowned(reviver) then
		return { ok = false, reason = Enums.Reject.Busy }
	end

	local reviverRoot = reviver.Character and reviver.Character.PrimaryPart
	local targetRoot = target.Character and target.Character.PrimaryPart
	if not reviverRoot or not targetRoot then
		return { ok = false, reason = Enums.Reject.Busy }
	end
	if (reviverRoot.Position - targetRoot.Position).Magnitude > SURVIVAL.ReviveRange then
		return { ok = false, reason = Enums.Reject.TooFar }
	end

	local roleStats = self.context.RoleService:statsFor(reviver)
	local speed = math.max(0.25, roleStats and roleStats.reviveSpeedMult or 1)
	local duration = SURVIVAL.ReviveHoldSeconds / speed

	--[[ The Medic's "Steady Hands" passive makes reviving free; everyone else
	     pays stamina, so a medic genuinely changes how a rescue goes. ]]
	local extras = self.context.RoleService:extrasFor(reviver)
	if not (extras and extras.steadyHands) then
		if not self:spendStamina(reviver, 15) then
			return { ok = false, reason = Enums.Reject.Busy, detail = "no_stamina" }
		end
	end

	self._revives[reviver.UserId] = {
		targetUserId = target.UserId,
		endsAt = os.clock() + duration,
		duration = duration,
	}

	self.context.MonsterService:reportNoise(session.id, reviverRoot.Position, "revive")

	return { ok = true, duration = duration, targetUserId = target.UserId }
end

function SurvivalService:_tickRevives()
	for reviverUserId, channel in pairs(self._revives) do
		local reviver = Players:GetPlayerByUserId(reviverUserId)
		local target = Players:GetPlayerByUserId(channel.targetUserId)

		local cancel = false
		if not reviver or not target then
			cancel = true
		elseif not self:isDowned(target) then
			cancel = true
		else
			local a = reviver.Character and reviver.Character.PrimaryPart
			local b = target.Character and target.Character.PrimaryPart
			if not a or not b or (a.Position - b.Position).Magnitude > SURVIVAL.ReviveRange + 2 then
				cancel = true
			end
		end

		if cancel then
			self._revives[reviverUserId] = nil
			if reviver then
				Net.fire(reviver, Routes.Push.Notify, {
					kind = "warning",
					title = "Revive interrupted",
					body = "Stay close to your teammate.",
				})
			end
		elseif os.clock() >= channel.endsAt then
			self._revives[reviverUserId] = nil
			self:revive(target, reviver)
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Consumables
-- ─────────────────────────────────────────────────────────────────────────────

function SurvivalService:applyConsumable(player, def)
	local stats = self:statsOf(player)
	local extras = self.context.RoleService:extrasFor(player)
	local healingMult = (extras and extras.healingMult) or 1

	local applied = {}
	if (def.hunger or 0) > 0 then
		stats.hunger = math.min(SURVIVAL.HungerMax, stats.hunger + def.hunger)
		applied.hunger = def.hunger
	end
	if (def.stamina or 0) > 0 then
		self:restoreStamina(player, def.stamina)
		applied.stamina = def.stamina
	end
	if (def.health or 0) > 0 then
		applied.health = self:heal(player, def.health * healingMult, "consumable")
	end

	self:pushStats(player)
	return applied
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-tick simulation
-- ─────────────────────────────────────────────────────────────────────────────

function SurvivalService:_tickStats(deltaTime)
	for _, player in ipairs(Players:GetPlayers()) do
		local stats = self._stats[player.UserId]
		if not stats then
			continue
		end

		local session = self.context.ExpeditionService:sessionOf(player)
		local inExpedition = session ~= nil
		local humanoid = humanoidOf(player)

		-- Downed countdown.
		local downedEntry = self._downed[player.UserId]
		if downedEntry then
			--[[ A Medic's Triage passive and Field Stabilization both slow or
			     freeze this countdown, which is the whole point of the role. ]]
			local rate = self.context.RoleService:downedTimerRateFor(player)
			if rate < 1 then
				downedEntry.endsAt += deltaTime * (1 - rate)
			end
			if os.clock() >= downedEntry.endsAt then
				self:_die(player)
			else
				self:pushStats(player)
			end
			continue
		end

		-- Stamina.
		local sinceUse = os.clock() - (stats.lastStaminaUse or 0)
		if stats.sprinting and humanoid and humanoid.MoveDirection.Magnitude > 0.1 then
			stats.stamina = math.max(0, stats.stamina - SURVIVAL.StaminaSprintDrainPerSecond * deltaTime)
			stats.lastStaminaUse = os.clock()
			if stats.stamina <= 0 then
				stats.sprinting = false
				self.context.RoleService:applyMovement(player)
			end
			if inExpedition then
				local root = player.Character and player.Character.PrimaryPart
				if root then
					self.context.MonsterService:reportNoise(session.id, root.Position, "sprint")
				end
			end
		elseif sinceUse >= SURVIVAL.StaminaRegenDelayAfterUse then
			local roleStats = self.context.RoleService:statsFor(player)
			local regen = SURVIVAL.StaminaRegenPerSecond * ((roleStats and roleStats.staminaRegen) or 1)
			if stats.hunger <= SURVIVAL.HungerStarvingThreshold then
				regen *= SURVIVAL.StarvingStaminaRegenMultiplier
			end
			stats.stamina = math.min(stats.staminaMax, stats.stamina + regen * deltaTime)
		end

		-- Hunger, only inside an expedition.
		if inExpedition then
			local drain = SURVIVAL.HungerDrainPerSecond * session.difficulty.hungerDrainMultiplier
			stats.hunger = math.max(0, stats.hunger - drain * deltaTime)

			if stats.hunger <= 0 then
				--[[ Starvation is a slow drain with a visible warning, never a
				     sudden death: it will down you, and the clamp in
				     applyDamage means it cannot do more than that. ]]
				self:applyDamage(player, SURVIVAL.StarvingHealthDrainPerSecond * deltaTime, "starvation")
			end
		else
			-- The colony feeds you. Infirmaries heal you while you are home.
			local effects = self.context.BuildingService:effectsFor(player)
			stats.hunger = math.min(SURVIVAL.HungerMax, stats.hunger + 4 * deltaTime)
			if humanoid and humanoid.Health < humanoid.MaxHealth and (effects.healRate or 0) > 0 then
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + effects.healRate * deltaTime)
			end
		end

		self:pushStats(player)
	end
end

--[[ Fall damage, tracked from the peak of a fall rather than from velocity, so
     the number the player takes matches the height they can see they fell. ]]
function SurvivalService:_trackFalls()
	for _, player in ipairs(Players:GetPlayers()) do
		local humanoid = humanoidOf(player)
		local root = player.Character and player.Character.PrimaryPart
		if not humanoid or not root then
			self._fallTracking[player.UserId] = nil
			continue
		end

		local state = humanoid:GetState()
		if state == Enum.HumanoidStateType.Freefall then
			local peak = self._fallTracking[player.UserId]
			self._fallTracking[player.UserId] = math.max(peak or root.Position.Y, root.Position.Y)
		elseif self._fallTracking[player.UserId] then
			local fell = self._fallTracking[player.UserId] - root.Position.Y
			self._fallTracking[player.UserId] = nil
			if fell > SURVIVAL.FallDamageMinHeight then
				local extras = self.context.RoleService:extrasFor(player)
				local multiplier = (extras and extras.fallDamageMult) or 1
				local damage = (fell - SURVIVAL.FallDamageMinHeight) * SURVIVAL.FallDamagePerStud * multiplier
				self:applyDamage(player, damage, ("a %d stud fall"):format(math.floor(fell)))
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Replication
-- ─────────────────────────────────────────────────────────────────────────────

function SurvivalService:pushStats(player)
	local stats = self._stats[player.UserId]
	if not stats then
		return
	end
	local humanoid = humanoidOf(player)
	local session = self.context.ExpeditionService:sessionOf(player)
	local member = session and session.members[player.UserId]

	Net.fire(player, Routes.Push.StatsSync, {
		health = humanoid and math.floor(humanoid.Health) or 0,
		maxHealth = humanoid and math.floor(humanoid.MaxHealth) or 100,
		stamina = math.floor(stats.stamina),
		staminaMax = math.floor(stats.staminaMax),
		hunger = math.floor(stats.hunger),
		hungerMax = SURVIVAL.HungerMax,
		state = member and member.state or Enums.MemberState.Alive,
		downedRemaining = self:downedRemaining(player),
		downedWindow = self._downed[player.UserId] and self._downed[player.UserId].window or nil,
		sprinting = stats.sprinting,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function SurvivalService:init(context)
	self.context = context
end

function SurvivalService:start()
	--[[ We own spawning. Without this, a death inside an expedition would
	     respawn the player in the colony three seconds later and quietly skip
	     the spectate-and-rescue flow. ]]
	Players.CharacterAutoLoads = false

	Net.handle(Routes.Request.Revive, function(player, payload)
		if type(payload) ~= "table" or type(payload.userId) ~= "number" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		local target = Players:GetPlayerByUserId(math.floor(payload.userId))
		if not target then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:beginRevive(player, target)
	end, Routes.limitsFor(Routes.Request.Revive))

	Net.listen(Routes.Event.SetSprinting, function(player, payload)
		if type(payload) ~= "table" then
			return
		end
		local stats = self:statsOf(player)
		local wanted = payload.sprinting == true
		--[[ The client asks to sprint; the server decides whether it can, and
		     owns the resulting WalkSpeed. A modified client cannot set its own
		     speed because it never touches the Humanoid. ]]
		if wanted and stats.stamina <= 1 then
			return
		end
		if stats.sprinting ~= wanted then
			stats.sprinting = wanted
			self.context.RoleService:applyMovement(player)
		end
	end, Routes.limitsFor(Routes.Event.SetSprinting))

	RunService.Heartbeat:Connect(function(deltaTime)
		self._accumulator += deltaTime
		self._reviveAccumulator += deltaTime

		if self._accumulator >= SURVIVAL.StatTickRate then
			local step = self._accumulator
			self._accumulator = 0
			local ok, err = pcall(function()
				self:_tickStats(step)
				self:_trackFalls()
			end)
			if not ok then
				log:fault("stat tick failed: %s", tostring(err))
			end
		end

		if self._reviveAccumulator >= REVIVE_CHECK_INTERVAL then
			self._reviveAccumulator = 0
			local ok, err = pcall(function()
				self:_tickRevives()
			end)
			if not ok then
				log:fault("revive tick failed: %s", tostring(err))
			end
		end
	end)

	--[[ Shared by PlayerAdded and the catch-up loop below, so a player who was
	     already in the server when this service started is wired identically. ]]
	local function bindCharacterEvents(player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid", 5)
			if humanoid then
				--[[ Breaking joints on death throws the body around, which looks
				     like a bug next to a deliberate downed state. ]]
				humanoid.BreakJointsOnDeath = false

				humanoid.HealthChanged:Connect(function(health)
					--[[ Safety net. All gameplay damage goes through
					     applyDamage, which clamps; this catches anything else
					     (a stray script, an engine edge case) and converts it
					     into the downed state rather than a death. ]]
					if health <= 0 and not self:isDowned(player) then
						local session = self.context.ExpeditionService:sessionOf(player)
						if session then
							humanoid.Health = SURVIVAL.DownedHealth
							self:down(player, "unknown")
						end
					end
				end)
			end
			self:resetFor(player, false)
			self.context.RoleService:applyToCharacter(player, character)
		end)
	end

	Players.PlayerAdded:Connect(bindCharacterEvents)
	for _, player in ipairs(Players:GetPlayers()) do
		bindCharacterEvents(player)
	end

	Players.PlayerRemoving:Connect(function(player)
		self._stats[player.UserId] = nil
		self._downed[player.UserId] = nil
		self._revives[player.UserId] = nil
		self._fallTracking[player.UserId] = nil
		for reviverUserId, channel in pairs(self._revives) do
			if channel.targetUserId == player.UserId then
				self._revives[reviverUserId] = nil
			end
		end
	end)

	log:info("ready")
end

return SurvivalService.new()
