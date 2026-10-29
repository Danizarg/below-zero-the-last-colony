--[[
	MonsterService.lua
	Spawns monsters, routes noise to them, and ticks their AI with distance-based
	level of detail.

	Performance model
	─────────────────
	Monster count is the easiest way to wreck a Roblox server, so ticking is
	budgeted rather than uniform:

		near (within NearRadius of a player)   every NearInterval
		far                                    every FarInterval
		beyond SleepRadius                     not ticked at all, and the
		                                       Humanoid is parked

	A sleeping monster still exists and still holds its position, so walking back
	into a room finds what you left there.

	Spawn budget
	────────────
	Each room's baseline count comes from MonsterConfig.BaseCountPerRoom, scaled
	by the difficulty and party size. Solo players face far fewer monsters rather
	than weaker ones, so a fight still reads the same — it just is not six at
	once.

	The Stalker
	───────────
	One per session at most, only at dusk or night, only after the first maze
	shift, and always spawned in the room furthest from every player. It never
	materialises in someone's face.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local Logger = require(Shared.Util.Logger)
local MonsterBase = require(script.Parent.Parent.AI.MonsterBase)
local MonsterConfig = require(Shared.Config.MonsterConfig)
local Net = require(Shared.Util.Net)
local Rng = require(Shared.Lib.Rng)
local RoomConfig = require(Shared.Config.RoomConfig)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)

local log = Logger.new("MonsterService")

local MonsterService = {}
MonsterService.__index = MonsterService

function MonsterService.new()
	local self = setmetatable({}, MonsterService)
	self._bySession = {} -- [sessionId] = { [monsterId] = Monster }
	self._nextId = 1
	self._accumulator = 0
	self.monsterKilled = Signal.new("monsterKilled")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Spawning
-- ─────────────────────────────────────────────────────────────────────────────

function MonsterService:_sessionTable(sessionId)
	local table_ = self._bySession[sessionId]
	if not table_ then
		table_ = {}
		self._bySession[sessionId] = table_
	end
	return table_
end

function MonsterService:countFor(sessionId, monsterType)
	local count = 0
	for _, monster in pairs(self._bySession[sessionId] or {}) do
		if monster:isAlive() and (not monsterType or monster.def.id == monsterType) then
			count += 1
		end
	end
	return count
end

function MonsterService:_spawn(cave, def, cellKey, position, difficulty)
	local roomModel = cave.built.rooms[cellKey]
	local parent = roomModel and roomModel:FindFirstChild("Monsters") or cave.folder
	if not parent then
		return nil
	end

	local id = "m" .. tostring(self._nextId)
	self._nextId += 1

	local ok, monster = pcall(function()
		return MonsterBase.new({
			id = id,
			def = def,
			sessionId = cave.sessionId,
			cellKey = cellKey,
			position = position,
			parent = parent,
			difficulty = difficulty,
			context = self.context,
		})
	end)

	if not ok then
		log:fault("failed to spawn %s: %s", def.id, tostring(monster))
		return nil
	end

	self:_sessionTable(cave.sessionId)[id] = monster

	--[[ A killable monster's death is the signal for loot and XP; the Stalker is
	     not killable so it never fires this. ]]
	if def.killable then
		monster.humanoid.Died:Connect(function()
			self:_onMonsterDied(monster)
		end)
	end

	return monster
end

--[[
	Populate a cave at expedition start.
	@return number spawned
]]
function MonsterService:populate(cave, difficulty)
	local rng = Rng.new(cave.layout.seed + 909090)
	local spawned = 0

	for _, key in ipairs(cave.layout.order) do
		local cell = cave.layout.cells[key]
		local base = MonsterConfig.BaseCountPerRoom[cell.kind] or 0
		if base <= 0 then
			continue
		end

		local target = base * difficulty.monsterCountMultiplier
		--[[ Fractional budget becomes a chance, so a 0.6 multiplier on a
		     one-monster room means 60% of such rooms have one rather than every
		     room having none. ]]
		local whole = math.floor(target)
		if rng:chance(target - whole) then
			whole += 1
		end
		if whole <= 0 then
			continue
		end

		local candidates = {}
		for _, monsterType in ipairs(MonsterConfig.Order) do
			local def = MonsterConfig.get(monsterType)
			if def.spawnWeight > 0 then
				for _, allowed in ipairs(def.spawnRooms) do
					if allowed == cell.kind then
						table.insert(candidates, def)
						break
					end
				end
			end
		end
		if #candidates == 0 then
			continue
		end

		local cellCentre = self.context.CaveService:worldPositionOfCell(cave.sessionId, key)
		if not cellCentre then
			continue
		end

		for index = 1, whole do
			local def = rng:pickWeighted(candidates, function(entry)
				return entry.spawnWeight
			end)
			if def then
				local angle = rng:nextRange(0, math.pi * 2)
				local distance = rng:nextRange(6, 22)
				local position = cellCentre
					+ Vector3.new(math.cos(angle) * distance, def.body.torso.Y, math.sin(angle) * distance)
				if self:_spawn(cave, def, key, position, difficulty) then
					spawned += 1
				end
			end
		end
	end

	log:info("populated session %s with %d monsters", tostring(cave.sessionId), spawned)
	return spawned
end

--[[
	Night surge: extra monsters as the clock turns, placed away from players.
	Called by ExpeditionService on the phase change.
]]
function MonsterService:nightSurge(session)
	local cave = self.context.CaveService:caveFor(session.id)
	if not cave then
		return 0
	end

	local def = MonsterConfig.get(Enums.Monster.CaveCrawler)
	local extra = math.floor(
		#cave.layout.order * 0.15 * session.difficulty.monsterCountMultiplier * session.difficulty.nightMonsterSurgeMultiplier
	)
	if extra <= 0 then
		return 0
	end

	local occupied = self.context.CaveService:occupiedCells(session.id)
	local spawned = 0

	for _, key in ipairs(session.rng:shuffled(cave.layout.order)) do
		if spawned >= extra then
			break
		end
		--[[ Never spawn into a room with players in it. A monster appearing
		     inside your room is a cheap shock, not tension. ]]
		if occupied[key] then
			continue
		end
		local cell = cave.layout.cells[key]
		local roomDef = RoomConfig.get(cell.kind)
		if roomDef and roomDef.safeZone then
			continue
		end

		local centre = self.context.CaveService:worldPositionOfCell(session.id, key)
		if centre then
			local angle = session.rng:nextRange(0, math.pi * 2)
			local position = centre
				+ Vector3.new(math.cos(angle) * 16, def.body.torso.Y, math.sin(angle) * 16)
			if self:_spawn(cave, def, key, position, session.difficulty) then
				spawned += 1
			end
		end
	end

	if spawned > 0 then
		log:info("night surge spawned %d extra monsters in session %s", spawned, tostring(session.id))
	end
	return spawned
end

--[[ Try to introduce the Stalker. Returns true if it spawned. ]]
function MonsterService:trySpawnStalker(session)
	local def = MonsterConfig.get(Enums.Monster.Stalker)
	if not session.difficulty.stalkerEnabled then
		return false
	end
	if self:countFor(session.id, Enums.Monster.Stalker) >= (def.maxConcurrent or 1) then
		return false
	end

	local phaseAllowed = false
	for _, phase in ipairs(def.spawnPhases or {}) do
		if session.phase == phase then
			phaseAllowed = true
			break
		end
	end
	if not phaseAllowed then
		return false
	end

	local cave = self.context.CaveService:caveFor(session.id)
	if not cave then
		return false
	end
	if cave.layout.shiftsApplied < (def.requiresShiftCount or 0) then
		return false
	end

	local key = self.context.CaveService:furthestCellFromPlayers(session.id)
	local centre = key and self.context.CaveService:worldPositionOfCell(session.id, key)
	if not centre then
		return false
	end

	local monster = self:_spawn(cave, def, key, centre + Vector3.new(0, def.body.torso.Y, 0), session.difficulty)
	if not monster then
		return false
	end

	Net.fireList(self.context.ExpeditionService:playersIn(session), Routes.Push.Alert, {
		kind = "danger",
		title = "SOMETHING ELSE IS DOWN HERE",
		body = "It hunts by sound. Stop running.",
		duration = 5,
	})
	Net.fireList(self.context.ExpeditionService:playersIn(session), Routes.Push.PlaySound, {
		cue = "stalker_scream",
	})

	log:info("Stalker entered session %s at %s", tostring(session.id), tostring(key))
	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Noise
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Broadcast a noise to every monster in a session. This is the Stalker's
     primary sense and a secondary one for everything else. ]]
function MonsterService:reportNoise(sessionId, position, noiseKind)
	if not sessionId or not position then
		return
	end
	for _, monster in pairs(self._bySession[sessionId] or {}) do
		if monster:isAlive() then
			monster:onNoise(position, noiseKind)
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Combat hooks
-- ─────────────────────────────────────────────────────────────────────────────

function MonsterService:monsterById(sessionId, monsterId)
	local monster = (self._bySession[sessionId] or {})[monsterId]
	if monster and monster:isAlive() then
		return monster
	end
	return nil
end

--[[ Tell the clients a wind-up has started, so the attack can be read and
     dodged rather than being a surprise. ]]
function MonsterService:signalAttack(monster, target, windup)
	local session = self.context.ExpeditionService:sessionById(monster.sessionId)
	if not session then
		return
	end
	Net.fireList(self.context.ExpeditionService:playersIn(session), Routes.Push.PlaySound, {
		cue = monster.def.id == Enums.Monster.Stalker and "stalker_scream" or "crawler_attack",
		position = monster:position(),
	})
	Net.fire(target, Routes.Push.Notify, {
		kind = "combat",
		title = "",
		body = "",
		telegraph = { monsterId = monster.id, windup = windup, position = monster:position() },
	})
end

function MonsterService:_onMonsterDied(monster)
	local session = self.context.ExpeditionService:sessionById(monster.sessionId)
	local killer = monster.lastDamagedBy

	if session and killer then
		session.stats.monstersKilled = (session.stats.monstersKilled or 0) + 1
		local member = session.members[killer.UserId]
		if member then
			member.kills = (member.kills or 0) + 1
		end

		-- Drops go to the killer's bag, so there is nothing to compete over.
		for _, drop in ipairs(monster.def.drops or {}) do
			if session.rng:chance(drop.chance or 1) then
				local amount = session.rng:nextInteger(drop.min or 1, drop.max or 1)
				if amount > 0 then
					self.context.InventoryService:addToBag(killer, drop.resource, amount)
				end
			end
		end

		self.context.RewardService:awardMonsterKill(killer, monster.def)
	end

	Net.fireList(
		session and self.context.ExpeditionService:playersIn(session) or {},
		Routes.Push.PlaySound,
		{ cue = "crawler_death", position = monster:position() }
	)

	self.monsterKilled:Fire(monster, killer)

	--[[ Leave the body briefly so the kill reads, then clean up. ]]
	task.delay(3, function()
		local table_ = self._bySession[monster.sessionId]
		if table_ then
			table_[monster.id] = nil
		end
		monster:destroy()
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Environment queries
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	How lit a position is, 0..1.

	Derived from the room's configured light level rather than by sampling
	lights, which would be far too expensive per tick. The useful consequence:
	extraction rooms are brightly lit (0.7+) and therefore above the Stalker's
	aversion threshold, so the exits are genuinely safe ground.
]]
function MonsterService:lightLevelAt(sessionId, position)
	local key = self.context.CaveService:cellKeyAtPosition(sessionId, position)
	if not key then
		return 0
	end
	local cave = self.context.CaveService:caveFor(sessionId)
	local cell = cave and cave.layout.cells[key]
	if not cell then
		return 0
	end
	local def = RoomConfig.get(cell.kind)
	return def and def.lightLevel or 0
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Ticking
-- ─────────────────────────────────────────────────────────────────────────────

function MonsterService:_tick()
	local now = os.clock()

	for sessionId, monsters in pairs(self._bySession) do
		local session = self.context.ExpeditionService:sessionById(sessionId)
		if not session then
			continue
		end

		local candidates = {}
		for _, player in ipairs(self.context.ExpeditionService:playersIn(session)) do
			local member = session.members[player.UserId]
			if member and member.state ~= Enums.MemberState.Dead and member.state ~= Enums.MemberState.Extracted then
				if player.Character and player.Character.PrimaryPart then
					table.insert(candidates, player)
				end
			end
		end

		local tickContext = {
			candidates = candidates,
			phase = session.phase,
			rng = session.rng,
			lightLevelAt = function(position)
				return self:lightLevelAt(sessionId, position)
			end,
		}

		for id, monster in pairs(monsters) do
			if not monster:isAlive() then
				continue
			end

			-- Nearest player distance drives the level of detail.
			local nearest = math.huge
			for _, player in ipairs(candidates) do
				local root = player.Character.PrimaryPart
				local distance = (root.Position - monster:position()).Magnitude
				if distance < nearest then
					nearest = distance
				end
			end

			if nearest > MonsterConfig.Ticks.SleepRadius then
				--[[ Park it: zero the walk speed so the Humanoid stops doing
				     anything, and skip the tick entirely. ]]
				if monster.humanoid.WalkSpeed ~= 0 then
					monster.humanoid.WalkSpeed = 0
					monster.humanoid:MoveTo(monster:position())
				end
				continue
			end

			local interval = nearest <= MonsterConfig.Ticks.NearRadius and MonsterConfig.Ticks.NearInterval
				or MonsterConfig.Ticks.FarInterval

			monster._nextTickAt = monster._nextTickAt or 0
			if now < monster._nextTickAt then
				continue
			end
			local elapsed = monster._lastTickAt and (now - monster._lastTickAt) or interval
			monster._lastTickAt = now
			monster._nextTickAt = now + interval

			local ok, err = pcall(function()
				monster:update(elapsed, tickContext)
			end)
			if not ok then
				log:fault("monster %s update failed: %s", id, tostring(err))
			end
		end
	end
end

function MonsterService:clearSession(sessionId)
	for _, monster in pairs(self._bySession[sessionId] or {}) do
		monster:destroy()
	end
	self._bySession[sessionId] = nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function MonsterService:init(context)
	self.context = context
end

function MonsterService:start()
	--[[ One Heartbeat for every monster on the server. Per-monster intervals are
	     enforced inside the loop, so adding monsters never adds connections. ]]
	RunService.Heartbeat:Connect(function(deltaTime)
		self._accumulator += deltaTime
		if self._accumulator < MonsterConfig.Ticks.NearInterval then
			return
		end
		self._accumulator = 0
		local ok, err = pcall(function()
			self:_tick()
		end)
		if not ok then
			log:fault("monster tick failed: %s", tostring(err))
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		--[[ Drop references to a leaving player so a monster does not hold a
		     stale target and keep chasing a ghost. ]]
		for _, monsters in pairs(self._bySession) do
			for _, monster in pairs(monsters) do
				if monster.target == player then
					monster.target = nil
				end
				if monster.lastDamagedBy == player then
					monster.lastDamagedBy = nil
				end
			end
		end
	end)

	log:info("ready")
end

return MonsterService.new()
