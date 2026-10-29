--[[
	PlotGrid.spec.lua

	Plot geometry is shared between the server's real placement and the client's
	ghost. A mismatch there shows up as a preview that lands somewhere else,
	which feels like a bug in the game rather than in the maths, so it is worth
	pinning down.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local BuildingConfig = require(Shared.Config.BuildingConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local PlotGrid = require(Shared.Lib.PlotGrid)

local COLONY = GameConfig.Colony

return function(suite)
	suite:test("plots are spaced evenly and centred on the origin", function(expect)
		local centres = {}
		for index = 1, COLONY.MaxPlots do
			centres[index] = PlotGrid.plotCentre(index)
		end

		--[[ With an odd grid width, the middle plot sits on the origin, which is
		     what keeps the cavern symmetrical around its centre. ]]
		local middle = math.ceil(COLONY.MaxPlots / 2)
		expect.near(centres[middle].X, 0, 0.001, "the middle plot should be at x = 0")
		expect.near(centres[middle].Z, 0, 0.001, "the middle plot should be at z = 0")

		-- Horizontal neighbours are exactly one spacing apart.
		expect.near(
			(centres[2] - centres[1]).Magnitude,
			COLONY.PlotSpacing,
			0.001,
			"adjacent plots are not one spacing apart"
		)
	end)

	suite:test("no two plots share a centre", function(expect)
		local seen = {}
		for index = 1, COLONY.MaxPlots do
			local centre = PlotGrid.plotCentre(index)
			local key = ("%0.1f,%0.1f"):format(centre.X, centre.Z)
			expect.falsy(seen[key], ("plots %s and %d overlap"):format(tostring(seen[key]), index))
			seen[key] = index
		end
	end)

	suite:test("plots do not overlap each other", function(expect)
		--[[ Spacing must exceed the plot size, or a building at the edge of one
		     plot would stand inside its neighbour. ]]
		expect.greaterThan(COLONY.PlotSpacing, COLONY.PlotSize, "plot spacing must be larger than plot size")
	end)

	suite:test("a grid cell maps to a world position and back", function(expect)
		for index = 1, COLONY.MaxPlots do
			for gx = -8, 8, 4 do
				for gz = -8, 8, 4 do
					local world = PlotGrid.gridToWorld(index, gx, gz)
					local backX, backZ = PlotGrid.worldToGrid(index, world, 3, 3)
					expect.near(backX, gx, 0.001, ("x round-trip failed at %d,%d"):format(gx, gz))
					expect.near(backZ, gz, 0.001, ("z round-trip failed at %d,%d"):format(gx, gz))
				end
			end
		end
	end)

	suite:test("even footprints snap to half cells so their edges land on grid lines", function(expect)
		--[[ A 4-wide building centred on a whole cell would straddle a grid line
		     and look half a cell off. Snapping to halves fixes that, and the
		     server uses the same rule, so the ghost matches the result. ]]
		local centre = PlotGrid.plotCentre(1)
		local nudged = centre + Vector3.new(COLONY.GridStep * 2.3, 0, 0)

		local evenX = PlotGrid.worldToGrid(1, nudged, 4, 4)
		expect.near(evenX % 1, 0.5, 0.001, "an even footprint should snap to a half cell")

		local oddX = PlotGrid.worldToGrid(1, nudged, 5, 5)
		expect.near(oddX % 1, 0, 0.001, "an odd footprint should snap to a whole cell")
	end)

	suite:test("the build area is inside the plot with a margin", function(expect)
		local limit = PlotGrid.gridHalfExtent()
		local reach = limit * COLONY.GridStep
		expect.lessThan(reach * 2, COLONY.PlotSize, "the build area should not reach the plot edge")
		expect.greaterThan(limit, 4, "the build area is too small to be usable")
	end)

	suite:test("footprint bounds reject anything hanging over the edge", function(expect)
		local limit = PlotGrid.gridHalfExtent()

		expect.truthy(PlotGrid.footprintInBounds(0, 0, 5, 5), "the plot centre should be buildable")
		expect.truthy(
			PlotGrid.footprintInBounds(limit - 2, limit - 2, 4, 4),
			"a 4x4 two cells inside the limit should fit"
		)
		expect.falsy(
			PlotGrid.footprintInBounds(limit, limit, 4, 4),
			"a 4x4 centred on the limit hangs over the edge"
		)
		expect.falsy(PlotGrid.footprintInBounds(limit + 10, 0, 1, 1), "well outside should be rejected")
		expect.falsy(PlotGrid.footprintInBounds(0, -(limit + 10), 1, 1), "well outside should be rejected")
	end)

	suite:test("rotation swaps a footprint's axes at 90 and 270 only", function(expect)
		local footprint = { w = 5, d = 3 }

		local w0, d0 = PlotGrid.rotatedFootprint(footprint, 0)
		expect.equal(w0, 5)
		expect.equal(d0, 3)

		local w90, d90 = PlotGrid.rotatedFootprint(footprint, 90)
		expect.equal(w90, 3)
		expect.equal(d90, 5)

		local w180, d180 = PlotGrid.rotatedFootprint(footprint, 180)
		expect.equal(w180, 5)
		expect.equal(d180, 3)

		local w270, d270 = PlotGrid.rotatedFootprint(footprint, 270)
		expect.equal(w270, 3)
		expect.equal(d270, 5)
	end)

	suite:test("overlap detection treats a shared edge as free", function(expect)
		--[[ Flush rows are a normal thing to want to build, so touching edges
		     must not count as an overlap. ]]
		local a = PlotGrid.rect(0, 0, 4, 4)
		local b = PlotGrid.rect(4, 0, 4, 4)
		expect.falsy(PlotGrid.overlaps(a, b), "flush neighbours should not overlap")

		local c = PlotGrid.rect(3, 0, 4, 4)
		expect.truthy(PlotGrid.overlaps(a, c), "one cell of intrusion should count as an overlap")

		expect.truthy(PlotGrid.overlaps(a, a), "a rectangle overlaps itself")
	end)

	suite:test("overlap detection works on both axes", function(expect)
		local a = PlotGrid.rect(0, 0, 4, 4)
		expect.falsy(PlotGrid.overlaps(a, PlotGrid.rect(0, 4, 4, 4)), "flush on z should be free")
		expect.truthy(PlotGrid.overlaps(a, PlotGrid.rect(0, 3, 4, 4)), "overlapping on z should be caught")
		expect.falsy(PlotGrid.overlaps(a, PlotGrid.rect(9, 9, 4, 4)), "far apart should be free")
	end)

	suite:test("the pre-placed Town Hall fits at the plot centre", function(expect)
		--[[ BuildingService grants a free Town Hall at (0,0) on a new colony, so
		     that placement has to be legal by definition. ]]
		local townHall = BuildingConfig.get(Enums.Building.TownHall)
		local w, d = PlotGrid.rotatedFootprint(townHall.footprint, 0)
		expect.truthy(
			PlotGrid.footprintInBounds(0, 0, w, d),
			"the starting Town Hall does not fit where the server places it"
		)
	end)

	suite:test("the spawn point and cave entrance are inside the plot", function(expect)
		for index = 1, COLONY.MaxPlots do
			local centre = PlotGrid.plotCentre(index)
			local half = COLONY.PlotSize / 2

			local spawn = PlotGrid.plotSpawnPosition(index)
			expect.atMost(
				math.abs(spawn.X - centre.X),
				half,
				("plot %d spawn is outside the plot"):format(index)
			)
			expect.atMost(
				math.abs(spawn.Z - centre.Z),
				half,
				("plot %d spawn is outside the plot"):format(index)
			)

			local entrance = PlotGrid.caveEntrancePosition(index)
			expect.atMost(
				math.abs(entrance.X - centre.X),
				half,
				("plot %d cave entrance is outside the plot"):format(index)
			)
			expect.atMost(
				math.abs(entrance.Z - centre.Z),
				half,
				("plot %d cave entrance is outside the plot"):format(index)
			)
		end
	end)

	suite:test("the spawn point and the cave entrance are not on top of each other", function(expect)
		local spawn = PlotGrid.plotSpawnPosition(1)
		local entrance = PlotGrid.caveEntrancePosition(1)
		expect.greaterThan(
			(spawn - entrance).Magnitude,
			60,
			"a player should not spawn standing in the cave entrance prompt"
		)
	end)

	suite:test("there are at least as many plots as the server can hold players", function(expect)
		--[[ A player with no plot is a player with no colony, so this has to hold
		     for the configured party and server sizes. ]]
		expect.atLeast(
			COLONY.MaxPlots,
			GameConfig.Party.DesignMaxSize,
			"fewer plots than the long-term party cap"
		)
		expect.atMost(
			COLONY.MaxPlots,
			COLONY.PlotGridWidth * COLONY.PlotGridWidth,
			"MaxPlots exceeds what the grid can lay out"
		)
	end)
end
