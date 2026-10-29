--[[
	CaveLayout.spec.lua
	The maze generator and the night shift.

	This is the most important spec in the project. The shift is the game's
	defining mechanic and the easiest thing to break subtly: a rearrangement that
	seals a player in, strands an objective or produces asymmetric doorways would
	be very hard to notice by playing and trivial to catch here.

	The tests sweep many seeds rather than checking one, because a generator that
	works for seed 1 and fails for seed 847 is a generator that fails in
	production.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local CaveLayout = require(Shared.Lib.CaveLayout)
local DifficultyConfig = require(Shared.Config.DifficultyConfig)
local Enums = require(Shared.Enums)
local Rng = require(Shared.Lib.Rng)
local RoomRules = require(Shared.Lib.RoomRules)

local SWEEP = 120 -- seeds per sweeping test

local function generate(seed, overrides)
	local options = {
		seed = seed,
		roomCount = 13,
		loopConnections = 2,
		gridWidth = 7,
		gridHeight = 7,
		keysRequired = 1,
		puzzleRooms = 1,
	}
	for key, value in pairs(overrides or {}) do
		options[key] = value
	end
	return CaveLayout.generate(options)
end

local function doorCount(cell)
	return RoomRules.doorCount(cell.doors)
end

return function(suite)
	-- ── Determinism ──────────────────────────────────────────────────────────

	suite:test("the same seed produces an identical layout", function(expect)
		local a = generate(4242)
		local b = generate(4242)
		expect.equal(CaveLayout.render(a), CaveLayout.render(b), "renders differ for the same seed")
		expect.equal(a.entranceKey, b.entranceKey)
		expect.equal(a.vaultKey, b.vaultKey)
		expect.equal(#a.order, #b.order)
	end)

	suite:test("different seeds produce different layouts", function(expect)
		--[[ Not every pair has to differ (small grids can collide), but a run of
		     twenty seeds producing one layout would mean the seed is ignored. ]]
		local seen = {}
		local distinct = 0
		for seed = 1, 20 do
			local render = CaveLayout.render((generate(seed * 7919)))
			if not seen[render] then
				seen[render] = true
				distinct += 1
			end
		end
		expect.atLeast(distinct, 15, ("only %d distinct layouts from 20 seeds"):format(distinct))
	end)

	-- ── Shape ────────────────────────────────────────────────────────────────

	suite:test("generates the requested number of rooms", function(expect)
		for _, count in ipairs({ 10, 13, 15 }) do
			local layout = generate(99, { roomCount = count })
			expect.equal(#layout.order, count, ("asked for %d rooms"):format(count))
		end
	end)

	suite:test("every room has a kind, and the kind fits its doorways", function(expect)
		for seed = 1, 40 do
			local layout = generate(seed)
			for _, key in ipairs(layout.order) do
				local cell = layout.cells[key]
				expect.isType(cell.kind, "string", ("cell %s has no kind (seed %d)"):format(key, seed))
				--[[ Protected rooms may end up outside their usual door range
				     after a connectivity repair; that is a documented soft
				     constraint, so only filler rooms are checked strictly. ]]
				if not RoomRules.isShiftProtected(cell.kind) then
					expect.truthy(
						RoomRules.doorsSatisfy(cell.kind, cell.doors),
						("cell %s is %s with %d doors (seed %d)"):format(key, cell.kind, doorCount(cell), seed)
					)
				end
			end
		end
	end)

	suite:test("loop connections add alternative routes", function(expect)
		--[[ A pure spanning tree has exactly roomCount-1 edges. Each loop
		     connection adds one, which is what gives a trapped player somewhere
		     else to go after a shift. ]]
		local function edgeCount(layout)
			local total = 0
			for _, key in ipairs(layout.order) do
				total += doorCount(layout.cells[key])
			end
			return total / 2
		end

		local none = generate(321, { loopConnections = 0 })
		local some = generate(321, { loopConnections = 3 })
		expect.equal(edgeCount(none), #none.order - 1, "a tree should have n-1 edges")
		expect.equal(edgeCount(some), #some.order - 1 + 3, "three loops should add three edges")
	end)

	-- ── Invariants, swept across seeds and difficulties ──────────────────────

	suite:test("validates cleanly across many seeds and all difficulties", function(expect)
		for _, difficultyId in ipairs(DifficultyConfig.Order) do
			local difficulty = DifficultyConfig.resolve(difficultyId, 4)
			for seed = 1, SWEEP do
				local layout, validation = generate(seed * 13 + 1, {
					roomCount = difficulty.roomCount,
					loopConnections = difficulty.loopConnections,
					keysRequired = difficulty.keysRequired,
					puzzleRooms = difficulty.puzzleRooms,
				})
				if not validation.ok then
					expect.fail(
						("%s seed %d failed validation: %s"):format(
							difficultyId,
							seed,
							table.concat(validation.errors, " | ")
						)
					)
				end
				expect.truthy(layout.entranceKey, "no entrance")
			end
		end
	end)

	suite:test("doors are always symmetric and never point at nothing", function(expect)
		for seed = 1, SWEEP do
			local layout = generate(seed * 31)
			for _, key in ipairs(layout.order) do
				local cell = layout.cells[key]
				for _, dir in ipairs(Enums.DirectionList) do
					if cell.doors[dir] then
						local other = CaveLayout.neighbour(layout, cell, dir)
						expect.truthy(other, ("%s has a door %s into empty space"):format(key, dir))
						expect.truthy(
							other.doors[Enums.DirectionOpposite[dir]],
							("asymmetric door %s -> %s"):format(key, other.key)
						)
					end
				end
			end
		end
	end)

	suite:test("every room is reachable from the entrance", function(expect)
		for seed = 1, SWEEP do
			local layout = generate(seed * 17 + 5)
			local reached = CaveLayout.computeDepths(layout, layout.entranceKey)
			expect.equal(reached, #layout.order, ("seed %d left %d rooms unreachable"):format(seed, #layout.order - reached))
		end
	end)

	suite:test("every room can reach an extraction point", function(expect)
		for seed = 1, SWEEP do
			local layout = generate(seed * 23 + 7)
			expect.atLeast(#layout.extractionKeys, 1, "no extraction point")
			for _, key in ipairs(layout.order) do
				expect.truthy(
					CaveLayout.pathToExtraction(layout, key),
					("seed %d: %s cannot reach an exit"):format(seed, key)
				)
			end
		end
	end)

	suite:test("the entrance is always an extraction point", function(expect)
		for seed = 1, 40 do
			local layout = generate(seed * 101)
			expect.contains(layout.extractionKeys, layout.entranceKey, "the way in should be a way out")
		end
	end)

	-- ── Objectives ───────────────────────────────────────────────────────────

	suite:test("objectives sit in existing, reachable rooms", function(expect)
		for seed = 1, 60 do
			local layout = generate(seed * 37, { keysRequired = 2, puzzleRooms = 2 })
			expect.atLeast(#layout.objectives, 2, "expected at least the keys and the gate")
			for _, objective in ipairs(layout.objectives) do
				local cell = layout.cells[objective.cellKey]
				expect.truthy(cell, ("objective %s points at a missing cell"):format(objective.id))
				expect.atLeast(cell.depth, 0, ("objective %s is unreachable"):format(objective.id))
			end
		end
	end)

	suite:test("the vault is deep, and is not the entrance", function(expect)
		for seed = 1, 40 do
			local layout = generate(seed * 53)
			expect.truthy(layout.vaultKey, "no vault")
			expect.notEqual(layout.vaultKey, layout.entranceKey, "the vault should not be the tunnel mouth")
			--[[ The vault should be a genuine journey, not two rooms in. A third
			     of the room count is a conservative floor for a 13-room cave. ]]
			local vault = layout.cells[layout.vaultKey]
			expect.atLeast(vault.depth, 3, ("seed %d put the vault %d rooms in"):format(seed, vault.depth))
		end
	end)

	-- ── Pathfinding ──────────────────────────────────────────────────────────

	suite:test("findPath returns a genuinely connected route", function(expect)
		for seed = 1, 40 do
			local layout = generate(seed * 61)
			local path = CaveLayout.pathToExtraction(layout, layout.vaultKey)
			expect.truthy(path, "no route from the vault to an exit")

			for index = 1, #path - 1 do
				local from = layout.cells[path[index]]
				local to = layout.cells[path[index + 1]]
				local connected = false
				for _, dir in ipairs(Enums.DirectionList) do
					if from.doors[dir] then
						local other = CaveLayout.neighbour(layout, from, dir)
						if other and other.key == to.key then
							connected = true
							break
						end
					end
				end
				expect.truthy(connected, ("path step %s -> %s is not a doorway"):format(from.key, to.key))
			end
		end
	end)

	-- ── The maze shift ───────────────────────────────────────────────────────

	suite:test("a shift keeps the layout valid, over many shifts and seeds", function(expect)
		for seed = 1, 60 do
			local layout = generate(seed * 71)
			local rng = Rng.new(seed)
			for shiftIndex = 1, 6 do
				local result = CaveLayout.shift(layout, rng, { count = 5 })
				if not result.validation.ok then
					expect.fail(
						("seed %d shift %d broke validation: %s"):format(
							seed,
							shiftIndex,
							table.concat(result.validation.errors, " | ")
						)
					)
				end
			end
		end
	end)

	suite:test("a shift never adds or removes a room", function(expect)
		for seed = 1, 40 do
			local layout = generate(seed * 83)
			local before = #layout.order
			local keysBefore = {}
			for _, key in ipairs(layout.order) do
				keysBefore[key] = true
			end

			local rng = Rng.new(seed)
			CaveLayout.shift(layout, rng, { count = 5 })

			expect.equal(#layout.order, before, "the room count changed")
			for _, key in ipairs(layout.order) do
				expect.truthy(keysBefore[key], ("cell %s appeared from nowhere"):format(key))
			end
		end
	end)

	suite:test("objective and extraction rooms keep their kind through a shift", function(expect)
		for seed = 1, 40 do
			local layout = generate(seed * 89)
			local protectedKinds = {}
			for _, key in ipairs(layout.order) do
				local cell = layout.cells[key]
				if RoomRules.isShiftProtected(cell.kind) then
					protectedKinds[key] = cell.kind
				end
			end

			local rng = Rng.new(seed)
			for _ = 1, 4 do
				CaveLayout.shift(layout, rng, { count = 5 })
			end

			for key, kind in pairs(protectedKinds) do
				expect.equal(
					layout.cells[key].kind,
					kind,
					("protected cell %s changed from %s to %s"):format(key, kind, layout.cells[key].kind)
				)
			end
		end
	end)

	suite:test("a room with players in it is never left without a way out", function(expect)
		for seed = 1, 60 do
			local layout = generate(seed * 97)
			local rng = Rng.new(seed)

			--[[ Pick a few occupied rooms the way a real session would: wherever
			     the party happens to be standing. Deep rooms are the dangerous
			     case, so bias toward them. ]]
			local byDepth = {}
			for _, key in ipairs(layout.order) do
				table.insert(byDepth, key)
			end
			table.sort(byDepth, function(a, b)
				return layout.cells[a].depth > layout.cells[b].depth
			end)

			local occupied = {}
			for index = 1, math.min(4, #byDepth) do
				occupied[byDepth[index]] = true
			end

			for _ = 1, 5 do
				CaveLayout.shift(layout, rng, { count = 6, protectedKeys = occupied })

				for key in pairs(occupied) do
					local cell = layout.cells[key]
					expect.atLeast(
						RoomRules.doorCount(cell.doors),
						1,
						("seed %d: occupied cell %s was sealed"):format(seed, key)
					)
					expect.truthy(
						CaveLayout.pathToExtraction(layout, key),
						("seed %d: occupied cell %s lost its route to an exit"):format(seed, key)
					)
				end
			end
		end
	end)

	suite:test("an occupied room gets a second doorway where the grid allows one", function(expect)
		--[[ The brief asks that trapped players be given an alternative. A room
		     with two or more neighbours should never be left with a single
		     doorway after a shift. ]]
		local failures = 0
		local checked = 0

		for seed = 1, 60 do
			local layout = generate(seed * 103)
			local rng = Rng.new(seed)

			local occupied = {}
			local target = layout.vaultKey and layout.cells[layout.vaultKey]
			--[[ The vault is protected from rewiring, so pick a normal deep room
			     instead: that is the realistic "caught out far from home" case. ]]
			for _, key in ipairs(layout.order) do
				local cell = layout.cells[key]
				if not RoomRules.isShiftProtected(cell.kind) and cell.depth >= 2 then
					target = cell
					occupied[key] = true
					break
				end
			end

			if next(occupied) then
				CaveLayout.shift(layout, rng, { count = 6, protectedKeys = occupied })
				local cell = layout.cells[target.key]
				local potential = #CaveLayout.potentialDirections(layout, cell)
				if potential >= 2 then
					checked += 1
					if RoomRules.doorCount(cell.doors) < 2 then
						failures += 1
					end
				end
			end
		end

		expect.atLeast(checked, 20, "the test did not exercise enough rooms to be meaningful")
		expect.equal(failures, 0, ("%d of %d occupied rooms were left with one exit"):format(failures, checked))
	end)

	suite:test("a shift reports only cells that exist", function(expect)
		for seed = 1, 40 do
			local layout = generate(seed * 107)
			local rng = Rng.new(seed)
			local result = CaveLayout.shift(layout, rng, { count = 5 })
			for _, key in ipairs(result.changed) do
				expect.truthy(layout.cells[key], ("changed list names missing cell %s"):format(key))
			end
		end
	end)

	suite:test("a shift actually changes something", function(expect)
		--[[ A shift that quietly does nothing would be the worst failure mode:
		     the warning fires, the rumble plays, and the cave is identical. ]]
		local changedAtLeastOnce = 0
		for seed = 1, 40 do
			local layout = generate(seed * 109)
			local rng = Rng.new(seed)
			local result = CaveLayout.shift(layout, rng, { count = 4 })
			if #result.changed > 0 then
				changedAtLeastOnce += 1
			end
		end
		expect.atLeast(changedAtLeastOnce, 38, ("only %d of 40 shifts changed anything"):format(changedAtLeastOnce))
	end)

	suite:test("shiftsApplied counts up", function(expect)
		local layout = generate(555)
		local rng = Rng.new(555)
		expect.equal(layout.shiftsApplied, 0)
		CaveLayout.shift(layout, rng, { count = 3 })
		expect.equal(layout.shiftsApplied, 1)
		CaveLayout.shift(layout, rng, { count = 3 })
		expect.equal(layout.shiftsApplied, 2)
	end)

	-- ── Rendering ────────────────────────────────────────────────────────────

	suite:test("render produces a grid-shaped block of text", function(expect)
		local layout = generate(7)
		local render = CaveLayout.render(layout)
		local lines = string.split(render, "\n")
		expect.equal(#lines, layout.gridHeight * 3, "wrong number of rendered rows")
	end)

	suite:test("summarise mentions the seed and the room count", function(expect)
		local layout = generate(1234)
		local summary = CaveLayout.summarise(layout)
		expect.truthy(string.find(summary, "1234", 1, true), "the summary should name the seed")
		expect.truthy(string.find(summary, "rooms=", 1, true), "the summary should name the room count")
	end)
end
