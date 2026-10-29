--[[
	CombatService.lua
	Server-authoritative melee.

	The client sends "I swung at monster X". The server validates range, line of
	sight, cooldown and stamina, then computes the damage from the equipped tool
	and the player's role. No damage number, hit confirmation or target position
	is ever taken from the client.

	Deliberately melee-only for the MVP: one validated attack path is easier to
	keep honest than several, and both MVP monsters are designed around close
	quarters.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)

local log = Logger.new("CombatService")

local CombatService = {}
CombatService.__index = CombatService

--[[ A little more reach than the visual, so a hit that looks like it connected
     does connect. Latency makes the alternative feel broken. ]]
local MELEE_REACH_BONUS = 4

function CombatService.new()
	local self = setmetatable({}, CombatService)
	self._lastSwing = {} -- [userId] = os.clock()
	self.playerAttacked = Signal.new("playerAttacked")
	return self
end

local RAY_PARAMS = RaycastParams.new()
RAY_PARAMS.FilterType = Enum.RaycastFilterType.Exclude
RAY_PARAMS.IgnoreWater = true

local function hasLineOfSight(fromPosition, toPosition, ignoreList)
	local direction = toPosition - fromPosition
	local distance = direction.Magnitude
	if distance < 1 then
		return true
	end
	RAY_PARAMS.FilterDescendantsInstances = ignoreList
	local result = workspace:Raycast(fromPosition, direction.Unit * distance, RAY_PARAMS)
	return result == nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Player attacks
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Validation order:
		1. the player is in an expedition and alive
		2. the swing is off cooldown for their equipped tool
		3. they have the stamina
		4. the target monster exists in THEIR session
		5. the target is within reach, measured on the server
		6. nothing solid is in the way

	A swing that fails validation costs nothing, so a mis-timed click is not
	punished twice.
]]
function CombatService:attack(player, monsterId)
	local session = self.context.ExpeditionService:sessionOf(player)
	if not session then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end

	local member = session.members[player.UserId]
	if not member or member.state ~= Enums.MemberState.Alive then
		return { ok = false, reason = Enums.Reject.Busy, detail = "not_alive" }
	end

	local tool = self.context.InventoryService:equippedTool(player)
	local now = os.clock()
	if now - (self._lastSwing[player.UserId] or 0) < tool.swingCooldown then
		return { ok = false, reason = Enums.Reject.OnCooldown }
	end

	local character = player.Character
	local root = character and character.PrimaryPart
	if not root then
		return { ok = false, reason = Enums.Reject.Busy }
	end

	--[[ The swing itself is spent whether or not it lands, which is what makes
	     wild swinging a real cost. ]]
	if not self.context.SurvivalService:spendStamina(player, GameConfig.Survival.StaminaAttackCost) then
		return { ok = false, reason = Enums.Reject.Busy, detail = "no_stamina" }
	end
	self._lastSwing[player.UserId] = now

	Net.fireList(self.context.ExpeditionService:playersIn(session), Routes.Push.PlaySound, {
		cue = "melee_swing",
		position = root.Position,
	})
	self.context.MonsterService:reportNoise(session.id, root.Position, "attack")

	if type(monsterId) ~= "string" then
		return { ok = true, hit = false, reason = "missed" }
	end

	local monster = self.context.MonsterService:monsterById(session.id, monsterId)
	if not monster then
		return { ok = true, hit = false, reason = "no_target" }
	end

	local reach = tool.tier >= 1 and 10 or 8
	reach += MELEE_REACH_BONUS
	local distance = (monster:position() - root.Position).Magnitude
	if distance > reach then
		return { ok = true, hit = false, reason = "out_of_reach", distance = math.floor(distance) }
	end

	if
		not hasLineOfSight(
			root.Position + Vector3.new(0, 2, 0),
			monster:position(),
			{ character, monster.model }
		)
	then
		return { ok = true, hit = false, reason = "blocked" }
	end

	local roleStats = self.context.RoleService:statsFor(player)
	local damage = tool.damage * ((roleStats and roleStats.damageMult) or 1)

	monster.lastDamagedBy = player
	local before = monster.humanoid.Health

	if monster.def.killable then
		monster.humanoid:TakeDamage(damage)
	end
	monster:onDamaged(damage, player)

	self.context.InventoryService:wearTool(
		player,
		math.max(1, math.floor(2 * session.difficulty.durabilityLossMultiplier))
	)

	Net.fireList(self.context.ExpeditionService:playersIn(session), Routes.Push.PlaySound, {
		cue = "melee_hit",
		position = monster:position(),
	})

	local killed = monster.def.killable and monster.humanoid.Health <= 0
	self.playerAttacked:Fire(player, monster, damage, killed)

	return {
		ok = true,
		hit = true,
		monsterId = monsterId,
		damage = math.floor(damage + 0.5),
		killable = monster.def.killable,
		--[[ Telling the client the Stalker cannot be killed is a design choice:
		     the player should learn to run, not keep swinging into a health bar
		     that never moves. ]]
		remainingHealth = monster.def.killable and math.max(0, math.floor(monster.humanoid.Health)) or nil,
		killed = killed,
		deflected = (not monster.def.killable) and before == monster.humanoid.Health or false,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Monster attacks
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Called by MonsterBase after its wind-up resolves. Damage is already
     difficulty-scaled on the monster; role mitigation happens in
     SurvivalService.applyDamage, which is the only place health goes down. ]]
function CombatService:monsterAttack(monster, player)
	local session = self.context.ExpeditionService:sessionById(monster.sessionId)
	if not session then
		return 0
	end
	local member = session.members[player.UserId]
	if not member or member.state ~= Enums.MemberState.Alive then
		return 0
	end

	local dealt =
		self.context.SurvivalService:applyDamage(player, monster.damage, monster.def.name, monster:position())

	if dealt > 0 then
		session.stats.damageTaken = (session.stats.damageTaken or 0) + dealt
	end
	return dealt
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function CombatService:init(context)
	self.context = context
end

function CombatService:start()
	Net.handle(Routes.Request.Attack, function(player, payload)
		if type(payload) ~= "table" then
			return { ok = false, reason = Enums.Reject.BadRequest }
		end
		return self:attack(player, payload.monsterId)
	end, Routes.limitsFor(Routes.Request.Attack))

	log:info("ready")
end

return CombatService.new()
