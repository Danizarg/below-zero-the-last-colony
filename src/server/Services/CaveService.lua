--[[
	CaveService.lua
	Owns the cave side of an expedition: its layout, its geometry, where everyone
	is standing, and the night-time maze shift.

	The shift is the game's defining mechanic, so its contract is spelled out and
	enforced rather than assumed:

	  1. Players are warned. `warnShift` fires at the configured lead time and
	     again at the last few seconds, with text the HUD shows full-screen.
	  2. Rooms containing players are never rearranged, and their floors are
	     never rebuilt, so nobody is standing in geometry that disappears.
	  3. Objective and extraction rooms are frozen.
	  4. The layout is mutated and VALIDATED before any geometry moves. If
	     validation fails the shift is rolled back and logged — a broken cave is
	     worse than a static one.
	  5. Trapped players are given an alternative: any occupied room left with a
	     single doorway gets a second one where the grid allows it.
	  6. Nothing teleports. Players stay exactly where they are; only walls move.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local CaveBuilder = require(script.Parent.Parent.World.CaveBuilder)
local CaveLayout = require(Shared.Lib.CaveLayout)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)
local Rng = require(Shared.Lib.Rng)
local RoomConfig = require(Shared.Config.RoomConfig)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)
local TableUtil = require(Shared.Util.TableUtil)

local log = Logger.new("CaveService")

local CaveService = {}
CaveService.__index = CaveService

local ROOM_TRACK_INTERVAL = 0.4

function CaveService.new()
	local self = setmetatable({}, CaveService)
	self._caves = {} -- [sessionId] = cave
	self._slots = {} -- [slot] = sessionId
	self._playerRoom = {} -- [userId] = cellKey
	self._playerSession = {} -- [userId] = sessionId
	self._accumulator = 0

	self.roomEntered = Signal.new("roomEntered")
	self.shiftApplied = Signal.new("shiftApplied")
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Session slots
-- ─────────────────────────────────────────────────────────────────────────────

function CaveService:_takeSlot(sessionId)
	for slot = 1, GameConfig.Cave.MaxConcurrentSessions do
		if not self._slots[slot] then
			self._slots[slot] = sessionId
			return slot
		end
	end
	return nil
end

function CaveService:_releaseSlot(slot)
	if slot then
		self._slots[slot] = nil
	end
end

function CaveService:activeSessionCount()
	return TableUtil.count(self._caves)
end

function CaveService:hasCapacity()
	return self:activeSessionCount() < GameConfig.Cave.MaxConcurrentSessions
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Creation and teardown
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	@param options {
		seed, roomCount, loopConnections, keysRequired, puzzleRooms, difficultyId
	}
	@return cave|nil, reason
]]
function CaveService:createCave(sessionId, options)
	if self._caves[sessionId] then
		return self._caves[sessionId]
	end

	local slot = self:_takeSlot(sessionId)
	if not slot then
		return nil, Enums.Reject.Busy
	end

	--[[ Biome is chosen from the difficulty's permitted list using the session
	     seed, so a seed fully determines the run. ]]
	local seedRng = Rng.new(options.seed)
	local biomePool = RoomConfig.BiomesByDifficulty[options.difficultyId]
		or RoomConfig.BiomesByDifficulty[Enums.Difficulty.Medium]
	local biomeId = biomePool[seedRng:nextInteger(1, #biomePool)]

	local layout, validation = CaveLayout.generate({
		seed = options.seed,
		roomCount = options.roomCount,
		loopConnections = options.loopConnections,
		gridWidth = GameConfig.Cave.GridWidth,
		gridHeight = GameConfig.Cave.GridHeight,
		keysRequired = options.keysRequired,
		puzzleRooms = options.puzzleRooms,
	})

	if not validation.ok then
		--[[ Refuse rather than build something broken. In practice the
		     generator's invariants make this unreachable; if it ever fires, the
		     seed is in the log and reproduces exactly. ]]
		self:_releaseSlot(slot)
		log:fault(
			"layout validation failed for seed %d: %s",
			options.seed,
			table.concat(validation.errors, " | ")
		)
		return nil, "generation_failed"
	end

	for _, warning in ipairs(validation.warnings) do
		log:debug("layout note: %s", warning)
	end

	local origin = CaveBuilder.originForSlot(slot)
	local container = workspace:FindFirstChild("Expeditions")
	if not container then
		container = Instance.new("Folder")
		container.Name = "Expeditions"
		container.Parent = workspace
	end

	local sessionFolder = Instance.new("Folder")
	sessionFolder.Name = "Session_" .. sessionId
	sessionFolder.Parent = container

	local built = CaveBuilder.build(layout, origin, biomeId, sessionFolder)

	local cave = {
		sessionId = sessionId,
		slot = slot,
		layout = layout,
		built = built,
		origin = origin,
		biomeId = biomeId,
		folder = sessionFolder,
		rng = Rng.new(options.seed + 7777),
		discovered = {},
		shiftCount = 0,
	}

	self._caves[sessionId] = cave
	return cave
end

function CaveService:destroyCave(sessionId)
	local cave = self._caves[sessionId]
	if not cave then
		return
	end

	for userId, mapped in pairs(self._playerSession) do
		if mapped == sessionId then
			self._playerSession[userId] = nil
			self._playerRoom[userId] = nil
		end
	end

	if cave.folder then
		cave.folder:Destroy()
	end
	self:_releaseSlot(cave.slot)
	self._caves[sessionId] = nil
	log:info("destroyed cave for session %s", tostring(sessionId))
end

function CaveService:caveFor(sessionId)
	return self._caves[sessionId]
end

function CaveService:caveForPlayer(player)
	local sessionId = self._playerSession[player.UserId]
	return sessionId and self._caves[sessionId] or nil
end

function CaveService:bindPlayer(player, sessionId)
	self._playerSession[player.UserId] = sessionId
	self._playerRoom[player.UserId] = nil
end

function CaveService:unbindPlayer(player)
	self._playerSession[player.UserId] = nil
	self._playerRoom[player.UserId] = nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Spatial queries
-- ─────────────────────────────────────────────────────────────────────────────

function CaveService:entranceSpawn(sessionId)
	local cave = self._caves[sessionId]
	if not cave then
		return nil
	end
	local cell = cave.layout.cells[cave.layout.entranceKey]
	return CaveBuilder.spawnPointIn(cave.origin, cell)
end

function CaveService:roomOf(player)
	return self._playerRoom[player.UserId]
end

function CaveService:cellKeyAtPosition(sessionId, position)
	local cave = self._caves[sessionId]
	if not cave then
		return nil
	end
	return CaveBuilder.cellKeyAt(cave.layout, cave.origin, position)
end

function CaveService:worldPositionOfCell(sessionId, cellKey)
	local cave = self._caves[sessionId]
	if not cave then
		return nil
	end
	local cell = cave.layout.cells[cellKey]
	if not cell then
		return nil
	end
	return CaveBuilder.cellCentre(cave.origin, cell)
end

--[[ Rooms that currently contain a living player. These are what a shift must
     not rearrange. ]]
function CaveService:occupiedCells(sessionId)
	local occupied = {}
	for userId, mapped in pairs(self._playerSession) do
		if mapped == sessionId then
			local key = self._playerRoom[userId]
			if key then
				occupied[key] = true
			end
		end
	end
	return occupied
end

--[[
	Route from a player's room to the nearest extraction, as world positions.
	Backs the Runner's Pathfinder ability.
]]
function CaveService:routeToExtraction(player)
	local cave = self:caveForPlayer(player)
	if not cave then
		return nil
	end
	local fromKey = self._playerRoom[player.UserId] or cave.layout.entranceKey
	local path = CaveLayout.pathToExtraction(cave.layout, fromKey)
	if not path then
		return nil
	end

	local positions = {}
	for _, key in ipairs(path) do
		local cell = cave.layout.cells[key]
		if cell then
			table.insert(positions, CaveBuilder.cellCentre(cave.origin, cell) + Vector3.new(0, 3, 0))
		end
	end
	return positions, path
end

--[[ Furthest reachable room from every player, used to place the Stalker so it
     never materialises in someone's face. ]]
function CaveService:furthestCellFromPlayers(sessionId)
	local cave = self._caves[sessionId]
	if not cave then
		return nil
	end

	local occupied = self:occupiedCells(sessionId)
	if next(occupied) == nil then
		return cave.layout.vaultKey or cave.layout.entranceKey
	end

	--[[ Multi-source BFS from every occupied room; the last cell reached is the
	     furthest from all of them. ]]
	local distance = {}
	local queue = {}
	for key in pairs(occupied) do
		distance[key] = 0
		table.insert(queue, key)
	end

	local head = 1
	local furthest = queue[1]
	while head <= #queue do
		local key = queue[head]
		head += 1
		local cell = cave.layout.cells[key]
		if cell then
			for _, other in ipairs(CaveLayout.openNeighbours(cave.layout, cell)) do
				if distance[other.key] == nil then
					distance[other.key] = distance[key] + 1
					furthest = other.key
					table.insert(queue, other.key)
				end
			end
		end
	end

	return furthest
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Discovery
-- ─────────────────────────────────────────────────────────────────────────────

function CaveService:_trackRooms()
	for userId, sessionId in pairs(self._playerSession) do
		local player = Players:GetPlayerByUserId(userId)
		local cave = self._caves[sessionId]
		if player and cave then
			local character = player.Character
			local root = character and character.PrimaryPart
			if root then
				local key = CaveBuilder.cellKeyAt(cave.layout, cave.origin, root.Position)
				if key and key ~= self._playerRoom[userId] then
					self._playerRoom[userId] = key
					local cell = cave.layout.cells[key]
					local firstTime = not cave.discovered[key]
					if firstTime then
						cave.discovered[key] = true
					end
					self.roomEntered:Fire(player, cave, cell, firstTime)
				end
			end
		end
	end
end

function CaveService:discoveredCount(sessionId)
	local cave = self._caves[sessionId]
	if not cave then
		return 0
	end
	return TableUtil.count(cave.discovered)
end

--[[ A client-safe view of the cave, for the HUD's objective tracker and map.
     Only rooms the party has actually entered are included, so the map is a
     record of exploration rather than a free solution. ]]
function CaveService:mapSnapshot(sessionId)
	local cave = self._caves[sessionId]
	if not cave then
		return nil
	end

	local cells = {}
	for key in pairs(cave.discovered) do
		local cell = cave.layout.cells[key]
		if cell then
			local def = RoomConfig.get(cell.kind)
			table.insert(cells, {
				key = key,
				x = cell.x,
				y = cell.y,
				kind = cell.kind,
				name = def and def.name or cell.kind,
				doors = {
					N = cell.doors.N,
					E = cell.doors.E,
					S = cell.doors.S,
					W = cell.doors.W,
				},
				isExtraction = def and def.isExtraction or false,
			})
		end
	end

	return {
		gridWidth = cave.layout.gridWidth,
		gridHeight = cave.layout.gridHeight,
		entrance = cave.layout.entranceKey,
		cells = cells,
		totalRooms = #cave.layout.order,
		discovered = #cells,
		shifts = cave.layout.shiftsApplied,
		biome = cave.biomeId,
		biomeName = RoomConfig.biome(cave.biomeId).name,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Maze shift
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Broadcast a warning to a session's players. Called by ExpeditionService on
     the dusk/night schedule. ]]
function CaveService:warnShift(sessionId, players, secondsRemaining)
	local messages = {
		[30] = { title = "30 SECONDS UNTIL THE SHIFT", body = "Find a route or find a room." },
		[10] = { title = "10 SECONDS", body = "Hold still. The walls are moving." },
	}
	local message = messages[secondsRemaining]
		or { title = "WARNING: THE CAVES ARE SHIFTING", body = "RETURN TO THE COLONY." }

	Net.fireList(players, Routes.Push.ShiftWarning, {
		secondsRemaining = secondsRemaining,
		title = message.title,
		body = message.body,
	})
	Net.fireList(players, Routes.Push.PlaySound, { cue = "warning_horn" })
end

--[[
	Apply one maze shift.

	@param sessionId
	@param players   array of Players in this session (for messaging)
	@param count     rooms to rearrange, from difficulty
	@return result   { ok, changed, opened, closed, repairs, rebuilt } or
	                 { ok = false, reason }
]]
function CaveService:applyShift(sessionId, players, count)
	local cave = self._caves[sessionId]
	if not cave then
		return { ok = false, reason = "no_cave" }
	end

	--[[ Snapshot enough to roll back. Only doors and kinds change, so that is
	     all we need to keep — far cheaper than copying the whole layout. ]]
	local snapshot = {}
	for _, key in ipairs(cave.layout.order) do
		local cell = cave.layout.cells[key]
		snapshot[key] = {
			kind = cell.kind,
			doors = { N = cell.doors.N, E = cell.doors.E, S = cell.doors.S, W = cell.doors.W },
		}
	end

	local occupied = self:occupiedCells(sessionId)
	local result = CaveLayout.shift(cave.layout, cave.rng, {
		count = count,
		protectedKeys = occupied,
	})

	if not result.validation.ok then
		-- Roll back and keep the cave as it was.
		for key, saved in pairs(snapshot) do
			local cell = cave.layout.cells[key]
			cell.kind = saved.kind
			cell.doors.N = saved.doors.N
			cell.doors.E = saved.doors.E
			cell.doors.S = saved.doors.S
			cell.doors.W = saved.doors.W
		end
		CaveLayout.computeDepths(cave.layout, cave.layout.entranceKey)
		cave.layout.shiftsApplied = math.max(0, cave.layout.shiftsApplied - 1)

		log:fault(
			"shift validation failed for session %s (seed %d); rolled back. Errors: %s",
			tostring(sessionId),
			cave.layout.seed,
			table.concat(result.validation.errors, " | ")
		)
		return { ok = false, reason = "validation_failed" }
	end

	local rebuilt = CaveBuilder.rebuildCells(cave.built, cave.layout, result.changed)
	cave.shiftCount += 1

	--[[ Any room a player is in may have gained or lost a doorway, so their map
	     view is refreshed along with the announcement. ]]
	Net.fireList(players, Routes.Push.ShiftApplied, {
		changed = #result.changed,
		opened = result.opened,
		closed = result.closed,
		shiftNumber = cave.shiftCount,
		map = self:mapSnapshot(sessionId),
	})
	Net.fireList(players, Routes.Push.PlaySound, { cue = "maze_shift_rumble" })
	Net.fireList(players, Routes.Push.Alert, {
		kind = "danger",
		title = "THE CAVES HAVE SHIFTED",
		body = ("%d passages changed."):format(result.opened + result.closed),
		duration = 4,
	})

	log:info(
		"session %s shift %d: %d cells changed, %d opened, %d closed, %d repairs, %d rebuilt",
		tostring(sessionId),
		cave.shiftCount,
		#result.changed,
		result.opened,
		result.closed,
		result.repairs,
		rebuilt
	)

	self.shiftApplied:Fire(cave, result)

	return {
		ok = true,
		changed = result.changed,
		opened = result.opened,
		closed = result.closed,
		repairs = result.repairs,
		rebuilt = rebuilt,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function CaveService:init(context)
	self.context = context
end

function CaveService:start()
	RunService.Heartbeat:Connect(function(deltaTime)
		self._accumulator += deltaTime
		if self._accumulator < ROOM_TRACK_INTERVAL then
			return
		end
		self._accumulator = 0
		local ok, err = pcall(function()
			self:_trackRooms()
		end)
		if not ok then
			log:fault("room tracking failed: %s", tostring(err))
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:unbindPlayer(player)
	end)

	log:info("ready (%d concurrent cave slots)", GameConfig.Cave.MaxConcurrentSessions)
end

return CaveService.new()
