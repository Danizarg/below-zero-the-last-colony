--[[
	CaveLayout.lua

	Procedural cave layout: generation, night-time rearrangement, pathfinding and
	validation. Pure logic over a grid of cells — no Roblox datatypes, no
	Instances, no services. CaveBuilder turns a layout into geometry; this module
	never knows geometry exists.

	Keeping it pure is deliberate: the maze shift is the defining mechanic and the
	easiest thing in the project to get subtly wrong, so it needs to be testable
	in isolation and reproducible from a seed.

	── Layout shape ────────────────────────────────────────────────────────────
	layout = {
		seed            number
		gridWidth       number
		gridHeight      number
		cells           { [key] = cell }
		order           { key, ... }      deterministic iteration order
		entranceKey     key
		vaultKey        key
		extractionKeys  { key, ... }      always contains entranceKey
		puzzleKeys      { key, ... }
		objectives      { { id, cellKey, kind }, ... }
		shiftsApplied   number
	}

	cell = {
		key    string "x,y"
		x, y   number grid coordinates, 0-indexed
		kind   string Enums.RoomKind
		doors  { N=bool, E=bool, S=bool, W=bool }
		depth  number BFS distance from the entrance, -1 if unreachable
	}

	── Invariants ──────────────────────────────────────────────────────────────
	1. Doors are symmetric: cell.doors[d] implies neighbour.doors[opposite(d)].
	2. No door ever points at a cell that does not exist.
	3. Every cell is reachable from the entrance.
	4. At least one extraction point exists and is reachable from every cell.
	5. Objective rooms are never removed or rearranged by a shift.

	`validate()` checks 1-4 and is called after every generate and every shift.
]]

local Enums = require(script.Parent.Parent.Enums)
local RoomRules = require(script.Parent.RoomRules)
local Rng = require(script.Parent.Rng)

local CaveLayout = {}

local DIRS = Enums.DirectionList
local DELTA = Enums.DirectionDelta
local OPPOSITE = Enums.DirectionOpposite
local K = Enums.RoomKind

-- ─────────────────────────────────────────────────────────────────────────────
-- Keys and traversal helpers
-- ─────────────────────────────────────────────────────────────────────────────

function CaveLayout.key(x, y)
	return x .. "," .. y
end

function CaveLayout.cellAt(layout, x, y)
	return layout.cells[CaveLayout.key(x, y)]
end

--[[ The cell on the other side of `dir`, whether or not a door exists. ]]
function CaveLayout.neighbour(layout, cell, dir)
	local d = DELTA[dir]
	if not d then
		return nil
	end
	return layout.cells[CaveLayout.key(cell.x + d.x, cell.y + d.y)]
end

--[[ Cells reachable from `cell` through open doors. ]]
function CaveLayout.openNeighbours(layout, cell)
	local out = {}
	for _, dir in ipairs(DIRS) do
		if cell.doors[dir] then
			local other = CaveLayout.neighbour(layout, cell, dir)
			if other then
				table.insert(out, other)
			end
		end
	end
	return out
end

--[[ Directions in which a neighbouring cell exists at all. ]]
function CaveLayout.potentialDirections(layout, cell)
	local out = {}
	for _, dir in ipairs(DIRS) do
		if CaveLayout.neighbour(layout, cell, dir) then
			table.insert(out, dir)
		end
	end
	return out
end

local function newDoors()
	return { N = false, E = false, S = false, W = false }
end

local function setEdge(layout, cell, dir, open)
	local other = CaveLayout.neighbour(layout, cell, dir)
	if not other then
		return false
	end
	cell.doors[dir] = open
	other.doors[OPPOSITE[dir]] = open
	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Breadth-first search
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Recompute every cell's `depth` from `fromKey`. Unreachable cells get -1. ]]
function CaveLayout.computeDepths(layout, fromKey)
	fromKey = fromKey or layout.entranceKey
	for _, key in ipairs(layout.order) do
		layout.cells[key].depth = -1
	end

	local origin = layout.cells[fromKey]
	if not origin then
		return 0
	end

	origin.depth = 0
	local queue = { fromKey }
	local head = 1
	local reached = 1

	while head <= #queue do
		local cell = layout.cells[queue[head]]
		head += 1
		for _, other in ipairs(CaveLayout.openNeighbours(layout, cell)) do
			if other.depth < 0 then
				other.depth = cell.depth + 1
				reached += 1
				table.insert(queue, other.key)
			end
		end
	end

	return reached
end

--[[
	Shortest path through open doors.
	@param fromKey string
	@param isTarget function(cell) -> boolean
	@return { key, ... } from `fromKey` to the target inclusive, or nil
]]
function CaveLayout.findPath(layout, fromKey, isTarget)
	local origin = layout.cells[fromKey]
	if not origin then
		return nil
	end
	if isTarget(origin) then
		return { fromKey }
	end

	local cameFrom = { [fromKey] = true }
	local queue = { fromKey }
	local head = 1

	while head <= #queue do
		local cell = layout.cells[queue[head]]
		head += 1
		for _, other in ipairs(CaveLayout.openNeighbours(layout, cell)) do
			if not cameFrom[other.key] then
				cameFrom[other.key] = cell.key
				if isTarget(other) then
					-- Walk the parent chain back to the origin.
					local path = { other.key }
					local cursor = cell.key
					while cursor ~= fromKey do
						table.insert(path, 1, cursor)
						cursor = cameFrom[cursor]
					end
					table.insert(path, 1, fromKey)
					return path
				end
				table.insert(queue, other.key)
			end
		end
	end

	return nil
end

--[[ Shortest path from a cell to the nearest extraction point. ]]
function CaveLayout.pathToExtraction(layout, fromKey)
	local isExtraction = {}
	for _, key in ipairs(layout.extractionKeys) do
		isExtraction[key] = true
	end
	return CaveLayout.findPath(layout, fromKey, function(cell)
		return isExtraction[cell.key] == true
	end)
end

--[[ Connected components over open doors. Returns map key -> index, and count. ]]
function CaveLayout.components(layout)
	local componentOf = {}
	local count = 0

	for _, key in ipairs(layout.order) do
		if not componentOf[key] then
			count += 1
			componentOf[key] = count
			local queue = { key }
			local head = 1
			while head <= #queue do
				local cell = layout.cells[queue[head]]
				head += 1
				for _, other in ipairs(CaveLayout.openNeighbours(layout, cell)) do
					if not componentOf[other.key] then
						componentOf[other.key] = count
						table.insert(queue, other.key)
					end
				end
			end
		end
	end

	return componentOf, count
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Generation
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	@param options {
		seed             number
		roomCount        number  target cells
		loopConnections  number  extra non-tree edges, for alternative routes
		gridWidth        number
		gridHeight       number
		keysRequired     number
		puzzleRooms      number
		windingBias      number  0..1; higher = longer corridors, less branching
	}
	@return layout, validationResult
]]
function CaveLayout.generate(options)
	options = options or {}

	local gridWidth = math.max(3, math.floor(options.gridWidth or 7))
	local gridHeight = math.max(3, math.floor(options.gridHeight or 7))
	local roomCount = math.clamp(math.floor(options.roomCount or 13), 4, gridWidth * gridHeight)
	local loopConnections = math.max(0, math.floor(options.loopConnections or 2))
	local keysRequired = math.max(1, math.floor(options.keysRequired or 1))
	local puzzleRooms = math.max(0, math.floor(options.puzzleRooms or 1))
	local windingBias = math.clamp(options.windingBias or 0.72, 0, 1)
	local seed = math.floor(options.seed or 1)

	local rng = Rng.new(seed)

	local layout = {
		seed = seed,
		gridWidth = gridWidth,
		gridHeight = gridHeight,
		cells = {},
		order = {},
		entranceKey = nil,
		vaultKey = nil,
		extractionKeys = {},
		puzzleKeys = {},
		objectives = {},
		shiftsApplied = 0,
	}

	local function inBounds(x, y)
		return x >= 0 and y >= 0 and x < gridWidth and y < gridHeight
	end

	local function addCell(x, y)
		local key = CaveLayout.key(x, y)
		local cell = { key = key, x = x, y = y, doors = newDoors(), kind = nil, depth = -1 }
		layout.cells[key] = cell
		table.insert(layout.order, key)
		return cell
	end

	-- ── 1. Grow the cell set ─────────────────────────────────────────────────
	-- Randomised growth from a perimeter cell. Picking from the end of the
	-- active list most of the time produces winding tunnels; picking at random
	-- the rest of the time produces side branches. That mix reads as a cave
	-- rather than as a maze printout.

	local startCell = addCell(math.floor(gridWidth / 2), gridHeight - 1)
	layout.entranceKey = startCell.key

	local active = { startCell.key }

	while #layout.order < roomCount and #active > 0 do
		local pickIndex
		if rng:chance(windingBias) then
			pickIndex = #active
		else
			pickIndex = rng:nextInteger(1, #active)
		end

		local cell = layout.cells[active[pickIndex]]
		local candidates = {}
		for _, dir in ipairs(DIRS) do
			local d = DELTA[dir]
			local nx, ny = cell.x + d.x, cell.y + d.y
			if inBounds(nx, ny) and not layout.cells[CaveLayout.key(nx, ny)] then
				table.insert(candidates, dir)
			end
		end

		if #candidates == 0 then
			table.remove(active, pickIndex)
		else
			local dir = candidates[rng:nextInteger(1, #candidates)]
			local d = DELTA[dir]
			local created = addCell(cell.x + d.x, cell.y + d.y)
			setEdge(layout, cell, dir, true)
			table.insert(active, created.key)
		end
	end

	-- ── 2. Loop connections ──────────────────────────────────────────────────
	-- Extra edges are what give a trapped player somewhere else to go after a
	-- shift. Only E and S are considered so each adjacency is offered once.

	local spareEdges = {}
	for _, key in ipairs(layout.order) do
		local cell = layout.cells[key]
		for _, dir in ipairs({ "E", "S" }) do
			local other = CaveLayout.neighbour(layout, cell, dir)
			if other and not cell.doors[dir] then
				table.insert(spareEdges, { key = key, dir = dir })
			end
		end
	end
	rng:shuffle(spareEdges)

	local loopsAdded = 0
	for _, edge in ipairs(spareEdges) do
		if loopsAdded >= loopConnections then
			break
		end
		if setEdge(layout, layout.cells[edge.key], edge.dir, true) then
			loopsAdded += 1
		end
	end

	CaveLayout.computeDepths(layout, layout.entranceKey)

	-- ── 3. Place the special rooms ───────────────────────────────────────────

	local reserved = { [layout.entranceKey] = true }
	startCell.kind = K.Entrance
	table.insert(layout.extractionKeys, layout.entranceKey)

	--[[ Cells sorted deepest first, tie-broken by key so the ordering is stable
	     across runs with the same seed. ]]
	local byDepth = {}
	for _, key in ipairs(layout.order) do
		table.insert(byDepth, key)
	end
	table.sort(byDepth, function(a, b)
		local ca, cb = layout.cells[a], layout.cells[b]
		if ca.depth == cb.depth then
			return a < b
		end
		return ca.depth > cb.depth
	end)

	local function doorCount(cell)
		return RoomRules.doorCount(cell.doors)
	end

	--[[ The vault holds the key objective, so it goes as far from the entrance
	     as the layout allows, and prefers a quiet corner (few doors). ]]
	local vaultKey
	for _, key in ipairs(byDepth) do
		if not reserved[key] and doorCount(layout.cells[key]) <= 2 then
			vaultKey = key
			break
		end
	end
	vaultKey = vaultKey or byDepth[1]
	if vaultKey and vaultKey ~= layout.entranceKey then
		layout.vaultKey = vaultKey
		layout.cells[vaultKey].kind = K.AncientVault
		reserved[vaultKey] = true
	end

	--[[ A secondary extraction, far from the entrance but not the vault. Its job
	     is structural: with two exits in different parts of the map, no single
	     shift can corner the party. ]]
	local minSecondaryDepth = 2
	for _, key in ipairs(byDepth) do
		if not reserved[key] then
			local cell = layout.cells[key]
			if doorCount(cell) <= 2 and cell.depth >= minSecondaryDepth then
				cell.kind = K.ExtractionChamber
				reserved[key] = true
				table.insert(layout.extractionKeys, key)
				break
			end
		end
	end

	--[[ Puzzle rooms sit at mid depth: far enough in to be a detour, close
	     enough out to be worth the trip. ]]
	local maxDepth = layout.cells[byDepth[1]].depth
	local midTarget = math.max(1, math.floor(maxDepth * 0.5))
	local byMidDistance = {}
	for _, key in ipairs(layout.order) do
		if not reserved[key] then
			table.insert(byMidDistance, key)
		end
	end
	table.sort(byMidDistance, function(a, b)
		local da = math.abs(layout.cells[a].depth - midTarget)
		local db = math.abs(layout.cells[b].depth - midTarget)
		if da == db then
			return a < b
		end
		return da < db
	end)

	local puzzlesPlaced = 0
	for _, key in ipairs(byMidDistance) do
		if puzzlesPlaced >= puzzleRooms then
			break
		end
		local cell = layout.cells[key]
		if RoomRules.doorsSatisfy(K.PuzzleRoom, cell.doors) then
			cell.kind = K.PuzzleRoom
			reserved[key] = true
			table.insert(layout.puzzleKeys, key)
			puzzlesPlaced += 1
		end
	end

	-- ── 4. Fill the rest ─────────────────────────────────────────────────────
	-- A cell's kind must fit its door signature, which is why kinds are assigned
	-- after the topology rather than before it.

	for _, key in ipairs(layout.order) do
		local cell = layout.cells[key]
		if not cell.kind then
			local candidates = RoomRules.kindsFor(cell.doors)
			if #candidates == 0 then
				--[[ Should be unreachable: MiningChamber accepts 1-4 doors, so
				     every non-zero signature has at least one home. A zero-door
				     cell means the topology step broke an invariant. ]]
				cell.kind = K.MiningChamber
			else
				local chosen = rng:pickWeighted(candidates, function(kind)
					local rule = RoomRules.get(kind)
					return rule and rule.weight or 0
				end)
				cell.kind = chosen or candidates[1]
			end
		end
	end

	-- ── 5. Honour the chamber guarantees ─────────────────────────────────────
	-- A run with no resource chamber and no nest would be mechanically flat, so
	-- convert eligible corridors until the minimums are met.

	local function countKind(kind)
		local n = 0
		for _, key in ipairs(layout.order) do
			if layout.cells[key].kind == kind then
				n += 1
			end
		end
		return n
	end

	local convertible = { K.CorridorStraight, K.CorridorCurve, K.Junction, K.DeadEnd }
	local isConvertible = {}
	for _, kind in ipairs(convertible) do
		isConvertible[kind] = true
	end

	for _, guarantee in ipairs(RoomRules.Guarantees) do
		local needed = guarantee.min - countKind(guarantee.kind)
		if needed > 0 then
			local pool = {}
			for _, key in ipairs(layout.order) do
				local cell = layout.cells[key]
				if
					not reserved[key]
					and isConvertible[cell.kind]
					and RoomRules.doorsSatisfy(guarantee.kind, cell.doors)
				then
					table.insert(pool, key)
				end
			end
			rng:shuffle(pool)
			for index = 1, math.min(needed, #pool) do
				layout.cells[pool[index]].kind = guarantee.kind
			end
		end
	end

	-- ── 6. Objectives ────────────────────────────────────────────────────────
	-- One key always in the vault; extras in puzzle rooms, then deep rooms. The
	-- gate itself is in the vault, so the vault is both the reward and the lock.

	local objectiveCells = {}
	if layout.vaultKey then
		table.insert(objectiveCells, layout.vaultKey)
	end
	for _, key in ipairs(layout.puzzleKeys) do
		table.insert(objectiveCells, key)
	end
	for _, key in ipairs(byDepth) do
		if #objectiveCells >= keysRequired then
			break
		end
		if key ~= layout.entranceKey and not table.find(objectiveCells, key) then
			table.insert(objectiveCells, key)
		end
	end

	for index = 1, keysRequired do
		local cellKey = objectiveCells[index] or objectiveCells[#objectiveCells] or layout.entranceKey
		table.insert(layout.objectives, {
			id = "key_" .. index,
			kind = "ancient_key",
			cellKey = cellKey,
		})
	end

	if layout.vaultKey then
		table.insert(layout.objectives, {
			id = "first_gate",
			kind = "gate",
			cellKey = layout.vaultKey,
			keysRequired = keysRequired,
		})
	end

	CaveLayout.computeDepths(layout, layout.entranceKey)

	local validation = CaveLayout.validate(layout)
	return layout, validation
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Night-time maze shift
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Rearrange part of the cave.

	Contract, which validate() enforces afterwards:
	  * No cell is created or destroyed. Only doorways change, so a player can
	    never be left standing in deleted geometry.
	  * Objective and extraction rooms, and every edge touching them, are frozen.
	  * Cells listed in `protectedKeys` (rooms with players in them) keep their
	    geometry; their doorways may change, but the repair pass guarantees they
	    end up with a route to an extraction point and, where the grid allows, a
	    second doorway as an alternative.
	  * The result is always one connected component.

	@param layout table
	@param rng    Rng instance (pass the session's rng so shifts follow the seed)
	@param opts   { count = number, protectedKeys = { [key] = true } }
	@return {
		changed      { key, ... }  cells whose doorways or kind changed
		closed       number        doorways closed
		opened       number        doorways opened
		repairs      number        doorways opened by the repair pass
		validation   table         result of validate()
	}
]]
function CaveLayout.shift(layout, rng, opts)
	opts = opts or {}
	rng = rng or Rng.new(layout.seed + layout.shiftsApplied + 1)
	local count = math.max(0, math.floor(opts.count or 3))
	local protectedKeys = opts.protectedKeys or {}

	local changed = {}
	local opened, closed, repairs = 0, 0, 0

	--[[ A cell is frozen if its kind is objective-critical. Edges touching a
	     frozen cell are left alone so the vault and the exits keep their shape
	     and their door counts stay legal. ]]
	local function isFrozen(cell)
		return RoomRules.isShiftProtected(cell.kind)
	end

	-- Candidates: rewireable, and not a room someone is standing in.
	local candidates = {}
	for _, key in ipairs(layout.order) do
		local cell = layout.cells[key]
		if not isFrozen(cell) and not protectedKeys[key] then
			table.insert(candidates, key)
		end
	end
	rng:shuffle(candidates)

	local shiftedCount = 0
	for _, key in ipairs(candidates) do
		if shiftedCount >= count then
			break
		end

		local cell = layout.cells[key]

		-- Only edges whose far side is also rewireable may be touched.
		local editable = {}
		for _, dir in ipairs(CaveLayout.potentialDirections(layout, cell)) do
			local other = CaveLayout.neighbour(layout, cell, dir)
			if other and not isFrozen(other) then
				table.insert(editable, dir)
			end
		end

		--[[ With fewer than two editable edges there is nothing interesting to
		     rewire; skipping keeps the shift count meaningful. ]]
		if #editable >= 2 then
			local before = {}
			for _, dir in ipairs(DIRS) do
				before[dir] = cell.doors[dir]
			end

			-- Reroll each editable edge, then make sure at least one is open.
			local anyOpen = false
			for _, dir in ipairs(editable) do
				local open = rng:chance(0.5)
				setEdge(layout, cell, dir, open)
				anyOpen = anyOpen or open
			end
			if not anyOpen then
				local dir = editable[rng:nextInteger(1, #editable)]
				setEdge(layout, cell, dir, true)
			end

			-- Record what actually moved, on both sides of each edge.
			local touched = false
			for _, dir in ipairs(editable) do
				if before[dir] ~= cell.doors[dir] then
					touched = true
					if cell.doors[dir] then
						opened += 1
					else
						closed += 1
					end
					local other = CaveLayout.neighbour(layout, cell, dir)
					if other then
						changed[other.key] = true
					end
				end
			end

			if touched then
				changed[key] = true
				shiftedCount += 1
			end
		end
	end

	-- ── Repair pass: reconnect, then give trapped rooms a second way out ─────

	repairs = CaveLayout._reconnect(layout, changed)

	--[[ Any room with players in it gets a second doorway where the grid allows
	     one. A single-exit room during a shift is how players get cornered, and
	     the brief is explicit that trapped players must be given an alternative. ]]
	for key in pairs(protectedKeys) do
		local cell = layout.cells[key]
		if cell and RoomRules.doorCount(cell.doors) < 2 then
			local options = {}
			for _, dir in ipairs(CaveLayout.potentialDirections(layout, cell)) do
				if not cell.doors[dir] then
					table.insert(options, dir)
				end
			end
			if #options > 0 then
				local dir = options[rng:nextInteger(1, #options)]
				local other = CaveLayout.neighbour(layout, cell, dir)
				setEdge(layout, cell, dir, true)
				opened += 1
				changed[key] = true
				if other then
					changed[other.key] = true
				end
			end
		end
	end

	-- ── Re-fit room kinds to their new door signatures ───────────────────────

	for key in pairs(changed) do
		local cell = layout.cells[key]
		if cell and not isFrozen(cell) and not table.find(layout.puzzleKeys, key) then
			if not RoomRules.doorsSatisfy(cell.kind, cell.doors) then
				local candidateKinds = RoomRules.kindsFor(cell.doors)
				if #candidateKinds > 0 then
					local chosen = rng:pickWeighted(candidateKinds, function(kind)
						local rule = RoomRules.get(kind)
						return rule and rule.weight or 0
					end)
					cell.kind = chosen or candidateKinds[1]
				end
			end
		end
	end

	CaveLayout.computeDepths(layout, layout.entranceKey)
	layout.shiftsApplied += 1

	local changedList = {}
	for key in pairs(changed) do
		table.insert(changedList, key)
	end
	table.sort(changedList)

	return {
		changed = changedList,
		opened = opened,
		closed = closed,
		repairs = repairs,
		validation = CaveLayout.validate(layout),
	}
end

--[[
	Force the layout back to a single connected component by opening doorways
	across component boundaries.

	Terminates because the cell set is connected under grid adjacency by
	construction: any split of a grid-connected set has at least one adjacent
	pair across the cut, so a bridge always exists.

	Prefers bridges between two rewireable cells, and only touches a frozen cell
	as a last resort — keeping the party connected to an exit matters more than
	a room's cosmetic door count.

	@return number doorways opened
]]
function CaveLayout._reconnect(layout, changed)
	local opened = 0
	local guard = 0

	while true do
		guard += 1
		if guard > #layout.order + 8 then
			-- Defensive: never spin, even if an invariant is violated upstream.
			break
		end

		local componentOf, componentCount = CaveLayout.components(layout)
		if componentCount <= 1 then
			break
		end

		local homeComponent = componentOf[layout.entranceKey]
		local bridge = nil
		local fallback = nil

		for _, key in ipairs(layout.order) do
			local cell = layout.cells[key]
			if componentOf[key] == homeComponent then
				for _, dir in ipairs(DIRS) do
					local other = CaveLayout.neighbour(layout, cell, dir)
					if other and componentOf[other.key] ~= homeComponent then
						local candidate = { cell = cell, dir = dir, other = other }
						local frozen = RoomRules.isShiftProtected(cell.kind)
							or RoomRules.isShiftProtected(other.kind)
						if not frozen then
							bridge = candidate
							break
						elseif not fallback then
							fallback = candidate
						end
					end
				end
			end
			if bridge then
				break
			end
		end

		bridge = bridge or fallback
		if not bridge then
			break
		end

		setEdge(layout, bridge.cell, bridge.dir, true)
		opened += 1
		if changed then
			changed[bridge.cell.key] = true
			changed[bridge.other.key] = true
		end
	end

	return opened
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Validation
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	@return { ok = boolean, errors = { string }, warnings = { string } }

	Errors are invariant breaks that would produce broken or unfair geometry.
	Warnings are soft constraint misses (a room with more doorways than its kind
	normally has) which are cosmetic and allowed after a repair.
]]
function CaveLayout.validate(layout)
	local errors = {}
	local warnings = {}

	if not layout.entranceKey or not layout.cells[layout.entranceKey] then
		table.insert(errors, "layout has no entrance cell")
		return { ok = false, errors = errors, warnings = warnings }
	end

	-- 1 and 2: door symmetry, and no doors into nothing.
	for _, key in ipairs(layout.order) do
		local cell = layout.cells[key]
		for _, dir in ipairs(DIRS) do
			if cell.doors[dir] then
				local other = CaveLayout.neighbour(layout, cell, dir)
				if not other then
					table.insert(errors, ("cell %s has a door %s into empty space"):format(key, dir))
				elseif not other.doors[OPPOSITE[dir]] then
					table.insert(
						errors,
						("asymmetric door between %s (%s) and %s"):format(key, dir, other.key)
					)
				end
			end
		end

		if RoomRules.doorCount(cell.doors) == 0 then
			table.insert(errors, ("cell %s has no doorways"):format(key))
		end

		if cell.kind and not RoomRules.doorsSatisfy(cell.kind, cell.doors) then
			table.insert(
				warnings,
				("cell %s is kind %s with %d doorways, outside that kind's usual range"):format(
					key,
					tostring(cell.kind),
					RoomRules.doorCount(cell.doors)
				)
			)
		end
	end

	-- 3: everything reachable from the entrance.
	local reached = CaveLayout.computeDepths(layout, layout.entranceKey)
	if reached < #layout.order then
		table.insert(
			errors,
			("%d of %d cells are unreachable from the entrance"):format(
				#layout.order - reached,
				#layout.order
			)
		)
	end

	-- 4: at least one extraction, reachable from every cell.
	if #layout.extractionKeys == 0 then
		table.insert(errors, "layout has no extraction point")
	else
		for _, key in ipairs(layout.order) do
			if not CaveLayout.pathToExtraction(layout, key) then
				table.insert(errors, ("cell %s cannot reach any extraction point"):format(key))
				break -- one report is enough; they share a cause
			end
		end
	end

	-- 5: objectives still exist and are reachable.
	for _, objective in ipairs(layout.objectives) do
		local cell = layout.cells[objective.cellKey]
		if not cell then
			table.insert(
				errors,
				("objective %s points at missing cell %s"):format(objective.id, objective.cellKey)
			)
		elseif cell.depth < 0 then
			table.insert(
				errors,
				("objective %s is in unreachable cell %s"):format(objective.id, objective.cellKey)
			)
		end
	end

	return { ok = #errors == 0, errors = errors, warnings = warnings }
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Debug rendering
-- ─────────────────────────────────────────────────────────────────────────────

local KIND_GLYPH = {
	[K.Entrance] = "E",
	[K.CorridorStraight] = "─",
	[K.CorridorCurve] = "┐",
	[K.Junction] = "┼",
	[K.DeadEnd] = ".",
	[K.MiningChamber] = "M",
	[K.ResourceChamber] = "R",
	[K.MonsterNest] = "N",
	[K.PuzzleRoom] = "P",
	[K.AncientVault] = "V",
	[K.ExtractionChamber] = "X",
}

--[[
	ASCII plan of the layout, for eyeballing a seed in the output window.
	Each cell is drawn as a 3x3 block: the centre glyph is its kind and the edge
	characters are its doorways.
]]
function CaveLayout.render(layout)
	local rows = {}
	for row = 1, layout.gridHeight * 3 do
		local line = table.create(layout.gridWidth * 3, " ")
		rows[row] = line
	end

	for _, key in ipairs(layout.order) do
		local cell = layout.cells[key]
		local cx = cell.x * 3 + 2
		local cy = cell.y * 3 + 2
		rows[cy][cx] = KIND_GLYPH[cell.kind] or "?"
		if cell.doors.N then
			rows[cy - 1][cx] = "│"
		end
		if cell.doors.S then
			rows[cy + 1][cx] = "│"
		end
		if cell.doors.W then
			rows[cy][cx - 1] = "─"
		end
		if cell.doors.E then
			rows[cy][cx + 1] = "─"
		end
	end

	local lines = {}
	for _, row in ipairs(rows) do
		table.insert(lines, table.concat(row))
	end
	return table.concat(lines, "\n")
end

--[[ One-line summary, useful in logs. ]]
function CaveLayout.summarise(layout)
	local counts = {}
	for _, key in ipairs(layout.order) do
		local kind = layout.cells[key].kind or "nil"
		counts[kind] = (counts[kind] or 0) + 1
	end
	local parts = {}
	for kind, n in pairs(counts) do
		table.insert(parts, ("%s=%d"):format(kind, n))
	end
	table.sort(parts)
	return ("seed=%d rooms=%d shifts=%d exits=%d | %s"):format(
		layout.seed,
		#layout.order,
		layout.shiftsApplied,
		#layout.extractionKeys,
		table.concat(parts, " ")
	)
end

return CaveLayout
