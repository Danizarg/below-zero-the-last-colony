--[[
	RewardService.lua
	Experience, levels, role mastery and the expedition results screen.

	Rewards are accumulated per member during a run and granted once, at
	settlement. Two reasons: a level-up mid-fight is a distraction, and granting
	once means there is exactly one place where progression can be written —
	which makes "rewards are server-calculated" a structural property rather
	than a convention.

	Allocation is personal. Each player's XP comes from what they personally did,
	plus a shared completion bonus, so there is nothing to compete over and no
	way for a party member to take someone else's reward.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local RoleConfig = require(Shared.Config.RoleConfig)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)

local log = Logger.new("RewardService")

local RewardService = {}
RewardService.__index = RewardService

local REWARDS = GameConfig.Rewards

function RewardService.new()
	local self = setmetatable({}, RewardService)
	self.leveledUp = Signal.new("leveledUp")
	self.masteryGained = Signal.new("masteryGained")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Curves
-- ─────────────────────────────────────────────────────────────────────────────

--[[ XP needed to go from `level` to `level + 1`. ]]
function RewardService.xpForNextLevel(level)
	return math.floor(REWARDS.BaseXp * (level ^ REWARDS.Exponent))
end

--[[ Apply XP and resolve any level-ups.
     @return newLevel, levelsGained, xpIntoLevel, xpForNext ]]
function RewardService:_applyXp(profile, amount)
	profile.progression.xp = (profile.progression.xp or 0) + math.max(0, math.floor(amount))

	local levelsGained = 0
	local guard = 0
	while guard < 200 do
		guard += 1
		local needed = RewardService.xpForNextLevel(profile.progression.level)
		if profile.progression.xp < needed then
			break
		end
		profile.progression.xp -= needed
		profile.progression.level += 1
		levelsGained += 1
	end

	return profile.progression.level,
		levelsGained,
		profile.progression.xp,
		RewardService.xpForNextLevel(profile.progression.level)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- In-run accumulation
-- ─────────────────────────────────────────────────────────────────────────────

local function accumulate(self, player, amount, bucket)
	local session = self.context.ExpeditionService:sessionOf(player)
	if not session then
		return
	end
	local member = session.members[player.UserId]
	if not member then
		return
	end
	member.xpEarned = (member.xpEarned or 0) + amount
	member.xpBreakdown = member.xpBreakdown or {}
	member.xpBreakdown[bucket] = (member.xpBreakdown[bucket] or 0) + amount
end

function RewardService:awardMonsterKill(player, monsterDef)
	local xp = monsterDef.xpValue or REWARDS.XpPerMonsterKill
	if xp <= 0 then
		return
	end
	accumulate(self, player, xp, "combat")

	local profile = self.context.DataService:get(player)
	if profile then
		profile.progression.monstersDefeated = (profile.progression.monstersDefeated or 0) + 1
		self.context.DataService:markDirty(player)
	end
end

function RewardService:awardObjective(player, kind)
	local xp = REWARDS.XpPerObjective
	if kind == "gate_stage" then
		xp *= 3
	elseif kind == "puzzle" then
		xp = math.floor(xp * 0.6)
	end
	accumulate(self, player, xp, "objectives")
end

function RewardService:awardDiscovery(player, cell)
	accumulate(self, player, REWARDS.XpPerRoomDiscovered, "exploration")

	local profile = self.context.DataService:get(player)
	if profile then
		profile.progression.roomsDiscovered = (profile.progression.roomsDiscovered or 0) + 1
		if cell and cell.depth and cell.depth > (profile.progression.deepestDepthReached or 0) then
			profile.progression.deepestDepthReached = cell.depth
		end
		self.context.DataService:markDirty(player)
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Mastery
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Mastery is earned per expedition, not per XP point: one point for finishing a
	run in that role, one more for getting out alive. That keeps the progression
	legible ("two more runs as Medic") and stops a long grinding session in one
	role from trivialising the unlock tiers.
]]
function RewardService:_applyMastery(profile, roleId, outcome)
	if not RoleConfig.isValid(roleId) then
		return 0, 0
	end

	profile.progression.roleMastery = profile.progression.roleMastery or {}
	local before = profile.progression.roleMastery[roleId] or 0
	if before >= REWARDS.MaxRoleMastery then
		return before, 0
	end

	local gain = 1
	if outcome == "extracted" then
		gain += 1
	end

	local after = math.min(REWARDS.MaxRoleMastery, before + gain)
	profile.progression.roleMastery[roleId] = after
	return after, after - before
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Settlement
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Finalise one player's run and build their results screen.

	@param info {
		outcome    "extracted" | "timeout" | "died" | "wiped" | "abandoned"
		deposited  { [resourceId] = n }  what reached colony storage
		overflow   { [resourceId] = n }  what storage could not hold
		lost       { [resourceId] = n }  what the failure cost
		bagBefore  Inventory snapshot taken before the deposit
		keptFraction number|nil
	}
	@return results table, sent to the client as Routes.Push.Results
]]
function RewardService:settle(player, session, info)
	local profile = self.context.DataService:get(player)
	if not profile then
		return { ok = false, reason = Enums.Reject.NotLoaded }
	end

	local member = session.members[player.UserId] or {}
	local outcome = info.outcome or "timeout"
	local extracted = outcome == "extracted"

	-- Resource XP, from what actually came home.
	local resourceUnits = 0
	for _, amount in pairs(info.deposited or {}) do
		resourceUnits += amount
	end

	local baseXp = (member.xpEarned or 0) + resourceUnits * REWARDS.XpPerResourceExtracted
	if extracted then
		baseXp += REWARDS.XpExtractionBonus
	end

	--[[ Difficulty multiplies the payout, which is what makes Hard worth the
	     scarcer resources and shorter revive window. ]]
	local totalXp = math.floor(baseXp * session.difficulty.rewardMultiplier)

	local levelBefore = profile.progression.level
	local level, levelsGained, xpIntoLevel, xpForNext = self:_applyXp(profile, totalXp)
	local masteryAfter, masteryGained = self:_applyMastery(profile, member.roleId, outcome)

	-- Run counters.
	if extracted then
		profile.progression.expeditionsExtracted = (profile.progression.expeditionsExtracted or 0) + 1
		local order = { Enums.Difficulty.Easy, Enums.Difficulty.Medium, Enums.Difficulty.Hard }
		local currentIndex = table.find(order, session.difficultyId) or 1
		local bestIndex = table.find(order, profile.progression.highestDifficultyCleared) or 0
		if currentIndex > bestIndex then
			profile.progression.highestDifficultyCleared = session.difficultyId
		end
	else
		profile.progression.expeditionsFailed = (profile.progression.expeditionsFailed or 0) + 1
	end

	self.context.DataService:markDirty(player)

	-- Build a readable results payload.
	local function toList(map)
		local list = {}
		for resourceId, amount in pairs(map or {}) do
			local def = ResourceConfig.get(resourceId) or ResourceConfig.Consumables[resourceId]
			table.insert(list, {
				id = resourceId,
				name = def and def.name or resourceId,
				icon = def and def.icon or "?",
				count = amount,
				rarity = def and def.rarity or "common",
			})
		end
		table.sort(list, function(a, b)
			return a.name < b.name
		end)
		return list
	end

	local role = RoleConfig.get(member.roleId)
	local cave = self.context.CaveService:caveFor(session.id)

	local results = {
		ok = true,
		outcome = outcome,
		extracted = extracted,
		difficultyId = session.difficultyId,
		difficultyName = session.difficulty.name,
		seed = session.seed,
		durationSeconds = math.floor(os.clock() - session.startedAt),

		extractedResources = toList(info.deposited),
		lostResources = toList(info.lost),
		overflowResources = toList(info.overflow),
		keptFraction = info.keptFraction,

		monstersDefeated = member.kills or 0,
		objectivesCompleted = session.stats.objectivesCompleted or 0,
		roomsDiscovered = session.stats.roomsDiscovered or 0,
		totalRooms = cave and #cave.layout.order or 0,
		shiftsSurvived = session.shiftsApplied or 0,
		revivesReceived = member.revivedCount or 0,
		rescued = member.rescued == true,

		xpGained = totalXp,
		xpBreakdown = member.xpBreakdown or {},
		levelBefore = levelBefore,
		level = level,
		levelsGained = levelsGained,
		xpIntoLevel = xpIntoLevel,
		xpForNextLevel = xpForNext,

		roleId = member.roleId,
		roleName = role and role.name or member.roleId,
		masteryLevel = masteryAfter,
		masteryGained = masteryGained,
		masteryUnlocks = {},

		colonyLevel = self.context.ColonyService:colonyLevel(player),
		keysBanked = profile.escape.keys,
		gateStages = profile.escape.gateStagesUnlocked,
	}

	--[[ Call out any mastery upgrade this run unlocked, so progression is
	     visible at the moment it happens rather than buried in a menu. ]]
	if role and masteryGained > 0 then
		for _, upgrade in ipairs(role.upgrades) do
			if upgrade.mastery > (masteryAfter - masteryGained) and upgrade.mastery <= masteryAfter then
				table.insert(results.masteryUnlocks, { id = upgrade.id, name = upgrade.name })
			end
		end
	end

	if levelsGained > 0 then
		self.leveledUp:Fire(player, level, levelsGained)
	end
	if masteryGained > 0 then
		self.masteryGained:Fire(player, member.roleId, masteryAfter)
		--[[ Mastery changes role stats, so refresh immediately: the next run
		     should use the upgrade that was just earned. ]]
		self.context.RoleService:refresh(player)
	end

	self.context.ColonyService:pushColony(player)

	log:info(
		"%s settled session %d (%s): %d XP, level %d, %s mastery %d",
		player.Name,
		session.id,
		outcome,
		totalXp,
		level,
		tostring(member.roleId),
		masteryAfter
	)

	return results
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function RewardService:init(context)
	self.context = context
end

function RewardService:start()
	--[[ A level-up is worth a moment on screen even though its effects are
	     applied silently. ]]
	self.leveledUp:Connect(function(player, level, gained)
		Net.fire(player, Routes.Push.Notify, {
			kind = "success",
			title = gained > 1 and ("%d levels gained"):format(gained) or "Level up",
			body = ("You are now level %d."):format(level),
		})
		Net.fire(player, Routes.Push.PlaySound, { cue = "ui_reward" })
	end)

	log:info("ready")
end

return RewardService.new()
