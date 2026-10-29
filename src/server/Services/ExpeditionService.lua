--[[
	ExpeditionService.lua
	The expedition lifecycle: start, the day/night clock, the shift schedule,
	extraction, failure and results.

	Transport
	─────────
	GameConfig.TransportMode decides how a player reaches the caves.

	  "local"    colony and caves coexist in one Place at different coordinates
	             and the player is moved between them. Works in Studio with no
	             published experience, and is the only mode implemented end to
	             end. This is the MVP default.

	  "teleport" reserved for a multi-Place deployment. The code path exists and
	             is guarded, but it refuses to run with a clear message rather
	             than half-working, because the destination Place does not exist
	             and inventing a PlaceId would be worse than refusing.

	The clock
	─────────
	prep → day → dusk → night → ended, with durations from DifficultyConfig.
	Maze shifts begin as night falls and repeat on an interval. Every shift is
	announced twice before it happens.

	Failure is never a dead end
	───────────────────────────
	A player who dies becomes a spectator and may take a free rescue. A party
	that is wiped still returns to the colony with the difficulty's recovery
	fraction of their haul, and always keeps their ancient keys. There is no
	state from which the only option is to stop playing.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local DifficultyConfig = require(Shared.Config.DifficultyConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Inventory = require(Shared.Lib.Inventory)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local Rng = require(Shared.Lib.Rng)
local RoomConfig = require(Shared.Config.RoomConfig)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)

local log = Logger.new("ExpeditionService")

local ExpeditionService = {}
ExpeditionService.__index = ExpeditionService

local CLOCK_TICK = 0.5
local SHIFT_WARNINGS = { 30, 10 }

function ExpeditionService.new()
	local self = setmetatable({}, ExpeditionService)
	self._sessions = {} -- [sessionId] = session
	self._byUser = {} -- [userId] = sessionId
	self._nextId = 1
	self._accumulator = 0

	self.sessionStarted = Signal.new("sessionStarted")
	self.sessionEnded = Signal.new("sessionEnded")
	self.phaseChanged = Signal.new("phaseChanged")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lookup
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionService:sessionOf(player)
	local sessionId = self._byUser[player.UserId]
	local session = sessionId and self._sessions[sessionId]
	if session and session.phase ~= Enums.Phase.Ended then
		return session
	end
	return nil
end

function ExpeditionService:sessionIdOf(player)
	local session = self:sessionOf(player)
	return session and session.id or nil
end

function ExpeditionService:sessionById(sessionId)
	return self._sessions[sessionId]
end

--[[ Everyone still attached to a session, including spectators, because they
     should keep seeing what happens to the party. ]]
function ExpeditionService:playersIn(session)
	local out = {}
	if not session then
		return out
	end
	for userId in pairs(session.members) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			table.insert(out, player)
		end
	end
	return out
end

function ExpeditionService:livingPlayersIn(session)
	local out = {}
	for userId, member in pairs(session.members) do
		if member.state == Enums.MemberState.Alive or member.state == Enums.MemberState.Downed then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				table.insert(out, player)
			end
		end
	end
	return out
end

function ExpeditionService:rescuesRemaining(player)
	local session = self:sessionOf(player)
	if not session then
		return 0
	end
	local member = session.members[player.UserId]
	if not member then
		return 0
	end
	local free = GameConfig.Monetization.FreeRescuesPerExpedition - (member.freeRescuesUsed or 0)
	return math.max(0, free)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Starting
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionService:_newSeed()
	--[[ Seeds are recorded in each player's profile diagnostics, so a reported
	     problem can be reproduced exactly. ]]
	return math.floor(os.clock() * 1000) % 2000000000 + math.random(1, 100000)
end

--[[ Named `beginExpedition` rather than `start` because `start` is the service
     lifecycle hook every service exposes; two methods of the same name on one
     table would silently overwrite each other. ]]
function ExpeditionService:beginExpedition(leader, options)
	options = type(options) == "table" and options or {}

	if GameConfig.TransportMode == "teleport" then
		if GameConfig.ExpeditionPlaceId == 0 then
			return {
				ok = false,
				reason = Enums.Reject.NotImplemented,
				detail = "teleport_place_unset",
				message = "Teleport transport is configured but no expedition Place exists. "
					.. "Set GameConfig.TransportMode to 'local' to play in a single Place.",
			}
		end
	end

	if self:sessionOf(leader) then
		return { ok = false, reason = Enums.Reject.WrongZone, detail = "already_in_expedition" }
	end
	if not self.context.DataService:isLoaded(leader) then
		return { ok = false, reason = Enums.Reject.NotLoaded }
	end

	local party = self.context.PartyService:ensureParty(leader)
	if party.leaderUserId ~= leader.UserId then
		return { ok = false, reason = Enums.Reject.NoPermission, detail = "not_leader" }
	end
	if not self.context.PartyService:allReady(party) then
		return { ok = false, reason = Enums.Reject.Busy, detail = "not_all_ready" }
	end
	if not self.context.CaveService:hasCapacity() then
		return { ok = false, reason = Enums.Reject.Busy, detail = "server_full_of_expeditions" }
	end

	local difficultyId = options.difficultyId or party.difficultyId
	if not DifficultyConfig.isValid(difficultyId) then
		difficultyId = DifficultyConfig.Default
	end

	local partyPlayers = self.context.PartyService:membersOf(party)
	--[[ Anyone already in an expedition is dropped from this one rather than
	     silently pulled out of their current run. ]]
	local eligible = {}
	for _, player in ipairs(partyPlayers) do
		if not self:sessionOf(player) and self.context.DataService:isLoaded(player) then
			table.insert(eligible, player)
		end
	end
	if #eligible == 0 then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "no_eligible_members" }
	end

	local difficulty = DifficultyConfig.resolve(difficultyId, #eligible)
	local seed = options.seed and math.floor(options.seed) or self:_newSeed()

	local sessionId = self._nextId
	self._nextId += 1

	local session = {
		id = sessionId,
		seed = seed,
		difficultyId = difficultyId,
		difficulty = difficulty,
		rng = Rng.new(seed),
		leaderUserId = leader.UserId,
		partyCode = party.code,
		members = {},
		phase = Enums.Phase.Prep,
		phaseIndex = 1,
		phaseEndsAt = os.clock() + difficulty.phaseDurations.prep,
		startedAt = os.clock(),
		nextShiftAt = nil,
		shiftWarningsGiven = {},
		shiftsApplied = 0,
		stalkerAttemptedAt = 0,
		stats = {
			monstersKilled = 0,
			roomsDiscovered = 0,
			objectivesCompleted = 0,
			damageTaken = 0,
		},
		ended = false,
	}

	local cave, caveError = self.context.CaveService:createCave(sessionId, {
		seed = seed,
		roomCount = difficulty.roomCount,
		loopConnections = difficulty.loopConnections,
		keysRequired = difficulty.keysRequired,
		puzzleRooms = difficulty.puzzleRooms,
		difficultyId = difficultyId,
	})

	if not cave then
		return { ok = false, reason = caveError or "generation_failed" }
	end

	session.caveSessionId = sessionId
	self._sessions[sessionId] = session

	for _, player in ipairs(eligible) do
		session.members[player.UserId] = {
			userId = player.UserId,
			state = Enums.MemberState.Alive,
			roleId = self.context.RoleService:roleOf(player),
			kills = 0,
			revivedCount = 0,
			freeRescuesUsed = 0,
			joinedAt = os.clock(),
		}
		self._byUser[player.UserId] = sessionId
	end

	-- World content, after members exist so party-size scaling is already folded in.
	self.context.NodeService:populate(cave, difficulty)
	self.context.MonsterService:populate(cave, difficulty)
	self.context.ObjectiveService:setup(session, cave)

	party.expeditionStarted = true
	self.context.PartyService:push(party)

	for _, player in ipairs(eligible) do
		self:_sendIntoCave(player, session)

		local profile = self.context.DataService:get(player)
		if profile then
			profile.progression.expeditionsStarted = (profile.progression.expeditionsStarted or 0) + 1
			profile.diagnostics.lastExpeditionSeed = seed
			profile.diagnostics.lastExpeditionDifficulty = difficultyId
			self.context.DataService:markDirty(player)
		end
	end

	self:pushSession(session)
	self.sessionStarted:Fire(session)

	log:info(
		"session %d started: %s, %d players, seed %d, %d rooms",
		sessionId,
		difficultyId,
		#eligible,
		seed,
		#cave.layout.order
	)

	return {
		ok = true,
		sessionId = sessionId,
		seed = seed,
		difficultyId = difficultyId,
		roomCount = #cave.layout.order,
		biome = cave.biomeId,
	}
end

function ExpeditionService:_sendIntoCave(player, session)
	self.context.ColonyService:setZone(player, Enums.Zone.Expedition)
	self.context.CaveService:bindPlayer(player, session.id)
	self.context.RoleService:onExpeditionStart(player)
	self.context.SurvivalService:resetFor(player, true)

	if not player.Character then
		local ok, err = pcall(function()
			player:LoadCharacter()
		end)
		if not ok then
			log:fault("LoadCharacter failed for %s on expedition start: %s", player.Name, tostring(err))
			return
		end
		--[[ CharacterAdded handlers apply role stats; give them a frame before
		     moving the body, or the teleport can race the spawn. ]]
		task.wait(0.1)
	end

	local spawnPoint = self.context.CaveService:entranceSpawn(session.id)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if root and spawnPoint then
		root.CFrame = CFrame.new(spawnPoint)
	end

	local cave = self.context.CaveService:caveFor(session.id)
	Net.fire(player, Routes.Push.ZoneChanged, {
		zone = Enums.Zone.Expedition,
		biome = cave and cave.biomeId,
		biomeName = cave and RoomConfig.biome(cave.biomeId).name,
	})
end

function ExpeditionService:_returnToColony(player)
	self.context.CaveService:unbindPlayer(player)
	self.context.ColonyService:setZone(player, Enums.Zone.Colony)

	if not player.Character then
		local ok, err = pcall(function()
			player:LoadCharacter()
		end)
		if not ok then
			log:fault("LoadCharacter failed for %s on return: %s", player.Name, tostring(err))
		end
		task.wait(0.1)
	end

	self.context.SurvivalService:resetFor(player, true)
	self.context.ColonyService:sendHome(player)
	self.context.InventoryService:pushStorage(player)
	self.context.InventoryService:pushBag(player)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- The clock
-- ─────────────────────────────────────────────────────────────────────────────

local PHASE_SEQUENCE = { Enums.Phase.Prep, Enums.Phase.Day, Enums.Phase.Dusk, Enums.Phase.Night }

function ExpeditionService:_advancePhase(session)
	session.phaseIndex += 1
	local nextPhase = PHASE_SEQUENCE[session.phaseIndex]

	if not nextPhase then
		--[[ Night is over. Anyone still underground has missed their window. ]]
		self:endSession(session, "timeout")
		return
	end

	session.phase = nextPhase
	session.phaseEndsAt = os.clock() + session.difficulty.phaseDurations[nextPhase]

	local players = self:playersIn(session)
	Net.fireList(players, Routes.Push.PhaseChanged, {
		phase = nextPhase,
		duration = session.difficulty.phaseDurations[nextPhase],
		endsAt = session.phaseEndsAt,
	})

	if nextPhase == Enums.Phase.Dusk then
		--[[ Dusk is the warning phase. The brief asks for these exact beats, and
		     they are the player's cue that the run has a deadline. ]]
		Net.fireList(players, Routes.Push.Alert, {
			kind = "warning",
			title = "WARNING: THE CAVES ARE SHIFTING",
			body = "RETURN TO THE COLONY.",
			duration = 6,
		})
		Net.fireList(players, Routes.Push.PlaySound, { cue = "warning_horn" })

		--[[ The first shift lands as night falls, so dusk is pure warning with
		     no geometry changes — enough time to actually act on it. ]]
		session.nextShiftAt = os.clock() + session.difficulty.phaseDurations.dusk
	elseif nextPhase == Enums.Phase.Night then
		Net.fireList(players, Routes.Push.Alert, {
			kind = "danger",
			title = "NIGHT",
			body = "Something else is awake down here.",
			duration = 5,
		})
		self.context.MonsterService:nightSurge(session)
		self.context.MonsterService:trySpawnStalker(session)
	end

	self.phaseChanged:Fire(session, nextPhase)
	self:pushSession(session)
	log:info("session %d entered %s", session.id, nextPhase)
end

function ExpeditionService:_tickShifts(session)
	if not session.nextShiftAt then
		return
	end

	local remaining = session.nextShiftAt - os.clock()

	for _, lead in ipairs(SHIFT_WARNINGS) do
		local key = ("%d:%d"):format(session.shiftsApplied, lead)
		if remaining <= lead and remaining > lead - CLOCK_TICK * 2 and not session.shiftWarningsGiven[key] then
			session.shiftWarningsGiven[key] = true
			self.context.CaveService:warnShift(session.id, self:playersIn(session), lead)
		end
	end

	if remaining > 0 then
		return
	end

	local result = self.context.CaveService:applyShift(
		session.id,
		self:playersIn(session),
		session.difficulty.shiftCount
	)
	session.shiftsApplied += 1

	if not result.ok then
		--[[ A failed shift leaves the cave intact. Retrying on the normal
		     interval is better than a loop that keeps failing. ]]
		log:warn("session %d shift %d failed (%s)", session.id, session.shiftsApplied, tostring(result.reason))
	end

	session.nextShiftAt = os.clock() + session.difficulty.shiftIntervalSeconds

	--[[ The Stalker needs one shift to have happened before it can appear, so
	     this is the natural place to try again. ]]
	self.context.MonsterService:trySpawnStalker(session)
end

function ExpeditionService:_tick()
	for _, session in pairs(self._sessions) do
		if session.ended then
			continue
		end

		if os.clock() >= session.phaseEndsAt then
			self:_advancePhase(session)
			if session.ended then
				continue
			end
		end

		if session.phase == Enums.Phase.Dusk or session.phase == Enums.Phase.Night then
			self:_tickShifts(session)
		end

		--[[ Everyone out or down for good: end the run rather than making the
		     last spectator sit through the rest of the night. ]]
		local anyActive = false
		for _, member in pairs(session.members) do
			if member.state == Enums.MemberState.Alive or member.state == Enums.MemberState.Downed then
				anyActive = true
				break
			end
		end
		if not anyActive then
			local allExtracted = true
			for _, member in pairs(session.members) do
				if member.state ~= Enums.MemberState.Extracted then
					allExtracted = false
					break
				end
			end
			self:endSession(session, allExtracted and "extracted" or "wiped")
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Extraction
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionService:requestExtraction(player)
	local session = self:sessionOf(player)
	if not session then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end

	local member = session.members[player.UserId]
	if not member or member.state ~= Enums.MemberState.Alive then
		return { ok = false, reason = Enums.Reject.Busy, detail = "not_alive" }
	end

	--[[ Extraction requires standing in an extraction room, verified from the
	     server's own view of where the player is. ]]
	local cave = self.context.CaveService:caveFor(session.id)
	local roomKey = self.context.CaveService:roomOf(player)
	if not cave or not roomKey then
		return { ok = false, reason = Enums.Reject.TooFar }
	end

	local isExtraction = false
	for _, key in ipairs(cave.layout.extractionKeys) do
		if key == roomKey then
			isExtraction = true
			break
		end
	end
	if not isExtraction then
		return { ok = false, reason = Enums.Reject.TooFar, detail = "not_at_extraction" }
	end

	return self:_extract(player, session, member)
end

function ExpeditionService:_extract(player, session, member)
	member.state = Enums.MemberState.Extracted
	member.extractedAt = os.clock()

	--[[ A clean extraction keeps everything. This is the moment expedition loot
	     becomes permanent, which is the rule the whole risk/reward loop rests
	     on. ]]
	local bagBefore = Inventory.clone(self.context.InventoryService:bagOf(player))
	local deposit = self.context.InventoryService:depositBag(player, nil)

	local results = self.context.RewardService:settle(player, session, {
		outcome = "extracted",
		deposited = deposit.deposited,
		overflow = deposit.overflow,
		lost = {},
		bagBefore = bagBefore,
	})

	self:_returnToColony(player)
	Net.fire(player, Routes.Push.Results, results)

	local others = self:playersIn(session)
	Net.fireList(others, Routes.Push.Notify, {
		kind = "success",
		title = ("%s extracted"):format(player.DisplayName),
		body = "They made it out.",
	})
	Net.fireList(others, Routes.Push.PlaySound, { cue = "extraction_complete" })

	self:pushSession(session)
	log:info("%s extracted from session %d", player.Name, session.id)
	return { ok = true, results = results }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Rescue
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	A free rescue puts a dead player back at the entrance with their bag intact.

	Free rescues are always available first, and nothing about this path requires
	a purchase. MonetizationService can grant an additional rescue, but only
	after a real receipt, and never as a requirement to keep playing.
]]
function ExpeditionService:requestRescue(player, paid)
	local session = self:sessionOf(player)
	if not session then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end

	local member = session.members[player.UserId]
	if not member or member.state ~= Enums.MemberState.Dead then
		return { ok = false, reason = Enums.Reject.BadRequest, detail = "not_dead" }
	end
	if session.phase == Enums.Phase.Ended then
		return { ok = false, reason = Enums.Reject.Busy, detail = "expedition_over" }
	end

	if paid then
		--[[ Paid rescues are consumed from a balance that only a verified
		     receipt can top up. If none is held, this is a refusal, not a
		     purchase prompt that grants anything optimistically. ]]
		if not self.context.MonetizationService:consumeRescue(player) then
			return { ok = false, reason = Enums.Reject.NotEnoughResources, detail = "no_paid_rescue" }
		end
	else
		if self:rescuesRemaining(player) <= 0 then
			return { ok = false, reason = Enums.Reject.LimitReached, detail = "no_free_rescue" }
		end
		member.freeRescuesUsed = (member.freeRescuesUsed or 0) + 1
	end

	member.state = Enums.MemberState.Alive
	member.rescued = true

	if not player.Character then
		local ok, err = pcall(function()
			player:LoadCharacter()
		end)
		if not ok then
			log:fault("LoadCharacter failed during rescue for %s: %s", player.Name, tostring(err))
			return { ok = false, reason = "server_error" }
		end
		task.wait(0.1)
	end

	self.context.SurvivalService:resetFor(player, false)
	local spawnPoint = self.context.CaveService:entranceSpawn(session.id)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if root and spawnPoint then
		root.CFrame = CFrame.new(spawnPoint)
	end
	self.context.CaveService:bindPlayer(player, session.id)
	self.context.ColonyService:setZone(player, Enums.Zone.Expedition)

	Net.fireList(self:playersIn(session), Routes.Push.Notify, {
		kind = "info",
		title = ("%s was pulled out of the dark"):format(player.DisplayName),
		body = "They are back at the tunnel mouth.",
	})

	self:pushSession(session)
	log:info("%s rescued (%s) in session %d", player.Name, paid and "paid" or "free", session.id)
	return { ok = true, free = not paid, rescuesRemaining = self:rescuesRemaining(player) }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Death and leaving
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionService:onMemberDied(session, player)
	self:pushSession(session)
end

--[[ Voluntarily abandon a run. The bag is treated as a failure, not a clean
     extraction, so leaving is never a way to dodge the loss rules. ]]
function ExpeditionService:leaveExpedition(player)
	local session = self:sessionOf(player)
	if not session then
		return { ok = false, reason = Enums.Reject.WrongZone }
	end

	local member = session.members[player.UserId]
	if not member then
		return { ok = false, reason = Enums.Reject.BadRequest }
	end

	self:_settleFailure(player, session, member, "abandoned")
	self:pushSession(session)
	return { ok = true }
end

function ExpeditionService:_settleFailure(player, session, member, outcome)
	local fraction = (outcome == "timeout") and session.difficulty.lootKeptOnTimeoutFraction
		or session.difficulty.lootKeptOnDeathFraction

	local bagBefore = Inventory.clone(self.context.InventoryService:bagOf(player))
	local deposit = self.context.InventoryService:depositBag(player, fraction)

	--[[ Ancient keys found this run are banked here rather than being left in a
	     bag that no longer exists, so escape progress survives a failed run. ]]
	local profile = self.context.DataService:get(player)
	if profile then
		local keys = deposit.deposited[Enums.Resource.AncientKey] or 0
		if keys > 0 then
			profile.escape.keys = (profile.escape.keys or 0) + keys
			local storage = self.context.InventoryService:storageOf(player)
			if storage then
				local remaining = (storage.items[Enums.Resource.AncientKey] or 0) - keys
				storage.items[Enums.Resource.AncientKey] = remaining > 0 and remaining or nil
			end
			self.context.DataService:markDirty(player)
		end
	end

	member.state = (outcome == "abandoned") and Enums.MemberState.Extracted or Enums.MemberState.Dead

	local results = self.context.RewardService:settle(player, session, {
		outcome = outcome,
		deposited = deposit.deposited,
		overflow = deposit.overflow,
		lost = deposit.lost,
		bagBefore = bagBefore,
		keptFraction = fraction,
	})

	self:_returnToColony(player)
	Net.fire(player, Routes.Push.Results, results)
	return results
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Ending
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionService:endSession(session, outcome)
	if session.ended then
		return
	end
	session.ended = true
	session.phase = Enums.Phase.Ended

	--[[ Anyone still underground is settled with the appropriate loss. Nobody is
	     left standing in a cave that is about to be deleted. ]]
	for userId, member in pairs(session.members) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			if member.state == Enums.MemberState.Alive or member.state == Enums.MemberState.Downed then
				self:_settleFailure(player, session, member, outcome == "extracted" and "timeout" or outcome)
			elseif member.state == Enums.MemberState.Dead then
				self:_settleFailure(player, session, member, "died")
			end
			self._byUser[userId] = nil
		else
			self._byUser[userId] = nil
		end
	end

	-- Tear down the world content.
	self.context.MonsterService:clearSession(session.id)
	self.context.NodeService:clearSession(session.id)
	self.context.ObjectiveService:clearSession(session.id)
	self.context.CaveService:destroyCave(session.id)

	--[[ Release the party so it can run again. The lobby stays together, which
	     is what a group actually wants after a run. ]]
	local leader = Players:GetPlayerByUserId(session.leaderUserId)
	local party = leader and self.context.PartyService:partyOf(leader)
	if party then
		party.expeditionStarted = false
		for _, entry in pairs(party.members) do
			entry.ready = false
		end
		self.context.PartyService:push(party)
	end

	self._sessions[session.id] = nil
	self.sessionEnded:Fire(session, outcome)
	log:info("session %d ended (%s)", session.id, outcome)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Replication
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionService:snapshot(session, viewer)
	local team = {}
	for userId, member in pairs(session.members) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			local humanoid = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
			table.insert(team, {
				userId = userId,
				name = player.DisplayName,
				roleId = member.roleId,
				state = member.state,
				health = humanoid and math.floor(humanoid.Health) or 0,
				maxHealth = humanoid and math.floor(humanoid.MaxHealth) or 100,
				downedRemaining = self.context.SurvivalService:downedRemaining(player),
				isLeader = session.leaderUserId == userId,
				kills = member.kills,
			})
		end
	end
	table.sort(team, function(a, b)
		return a.userId < b.userId
	end)

	local cave = self.context.CaveService:caveFor(session.id)
	local roomKey = viewer and self.context.CaveService:roomOf(viewer)
	local roomName
	local atExtraction = false
	if cave and roomKey then
		local cell = cave.layout.cells[roomKey]
		local def = cell and RoomConfig.get(cell.kind)
		roomName = def and def.name or nil
		atExtraction = def and def.isExtraction or false
	end

	return {
		sessionId = session.id,
		difficultyId = session.difficultyId,
		difficultyName = session.difficulty.name,
		seed = session.seed,
		phase = session.phase,
		phaseEndsAt = session.phaseEndsAt,
		phaseDuration = session.difficulty.phaseDurations[session.phase],
		nextShiftIn = session.nextShiftAt and math.max(0, session.nextShiftAt - os.clock()) or nil,
		shiftsApplied = session.shiftsApplied,
		team = team,
		stats = session.stats,
		roomName = roomName,
		atExtraction = atExtraction,
		biomeName = cave and RoomConfig.biome(cave.biomeId).name or nil,
		freeRescuesRemaining = viewer and self:rescuesRemaining(viewer) or 0,
		paidRescuesHeld = viewer and self.context.MonetizationService:rescueBalance(viewer) or 0,
	}
end

function ExpeditionService:pushSession(session)
	for _, player in ipairs(self:playersIn(session)) do
		Net.fire(player, Routes.Push.ExpeditionSync, self:snapshot(session, player))
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionService:init(context)
	self.context = context
end

function ExpeditionService:start()
	Net.handle(Routes.Request.StartExpedition, function(player, payload)
		payload = type(payload) == "table" and payload or {}
		--[[ A client-supplied seed is accepted only in debug builds. In
		     production a chosen seed would let a player scout a layout and then
		     replay it with foreknowledge. ]]
		local seed = GameConfig.Debug and tonumber(payload.seed) or nil
		return self:beginExpedition(player, { difficultyId = payload.difficultyId, seed = seed })
	end, Routes.limitsFor(Routes.Request.StartExpedition))

	Net.handle(Routes.Request.LeaveExpedition, function(player)
		return self:leaveExpedition(player)
	end)

	Net.handle(Routes.Request.RequestExtraction, function(player)
		return self:requestExtraction(player)
	end, Routes.limitsFor(Routes.Request.RequestExtraction))

	Net.handle(Routes.Request.RequestRescue, function(player, payload)
		payload = type(payload) == "table" and payload or {}
		return self:requestRescue(player, payload.paid == true)
	end, Routes.limitsFor(Routes.Request.RequestRescue))

	RunService.Heartbeat:Connect(function(deltaTime)
		self._accumulator += deltaTime
		if self._accumulator < CLOCK_TICK then
			return
		end
		self._accumulator = 0

		--[[ Settling a run can yield (LoadCharacter needs a frame), and Roblox
		     runs each event handler on its own thread, so without this guard a
		     long settlement could overlap with the next tick. ]]
		if self._ticking then
			return
		end
		self._ticking = true

		local ok, err = pcall(function()
			self:_tick()
			for _, session in pairs(self._sessions) do
				self:pushSession(session)
			end
		end)

		self._ticking = false
		if not ok then
			log:fault("expedition tick failed: %s", tostring(err))
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local session = self:sessionOf(player)
		if session then
			local member = session.members[player.UserId]
			if member then
				--[[ A disconnect mid-run is treated as a death for loot purposes
				     but does not block the rest of the party. The profile save
				     on leave carries whatever was banked. ]]
				if member.state == Enums.MemberState.Alive or member.state == Enums.MemberState.Downed then
					local fraction = session.difficulty.lootKeptOnDeathFraction
					self.context.InventoryService:depositBag(player, fraction)
				end
				member.state = Enums.MemberState.Dead
			end
			self._byUser[player.UserId] = nil
			self.context.CaveService:unbindPlayer(player)
			self:pushSession(session)
		end
	end)

	log:info("ready (transport=%s)", GameConfig.TransportMode)
end

return ExpeditionService.new()
