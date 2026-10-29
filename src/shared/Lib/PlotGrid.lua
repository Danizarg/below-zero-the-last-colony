--[[
	PlotGrid.lua
	Colony plot geometry, shared by the server and the client.

	The server places buildings from saved grid coordinates; the client draws a
	placement ghost at those same coordinates. If the two used separate copies of
	this arithmetic they would drift, and a ghost that lies about where a
	building will land is worse than no ghost at all. So the maths lives here and
	both sides call it.

	Grid coordinates are integers in plot space, with (0,0) at the plot centre.
	They are what gets persisted, so a colony rebuilds identically regardless of
	where its plot happens to be in the cavern.
]]

local Shared = script.Parent.Parent
local GameConfig = require(Shared.Config.GameConfig)

local PlotGrid = {}

local COLONY = GameConfig.Colony

--[[ World-space centre of a plot, 1-indexed, at floor level. ]]
function PlotGrid.plotCentre(index)
	local width = COLONY.PlotGridWidth
	local gx = (index - 1) % width
	local gz = math.floor((index - 1) / width)
	local offset = (width - 1) / 2
	return Vector3.new((gx - offset) * COLONY.PlotSpacing, COLONY.FloorY, (gz - offset) * COLONY.PlotSpacing)
end

function PlotGrid.plotSpawnPosition(index)
	return PlotGrid.plotCentre(index) + COLONY.SpawnOffset
end

function PlotGrid.caveEntrancePosition(index)
	return PlotGrid.plotCentre(index) + COLONY.CaveEntranceOffset
end

--[[ Grid cell -> world position, on the plot's ground surface. ]]
function PlotGrid.gridToWorld(index, gx, gz)
	local centre = PlotGrid.plotCentre(index)
	return Vector3.new(centre.X + gx * COLONY.GridStep, COLONY.FloorY + 2, centre.Z + gz * COLONY.GridStep)
end

--[[
	World position -> nearest grid cell.

	Footprints with an even cell count sit between cells, so the snap offset
	depends on the footprint: a 4-wide building snaps to half-cell boundaries so
	its edges land on grid lines, while a 5-wide one snaps to cell centres.
	Without this, even-width buildings always look half a cell off.
]]
function PlotGrid.worldToGrid(index, position, footprintW, footprintD)
	local centre = PlotGrid.plotCentre(index)
	local localX = (position.X - centre.X) / COLONY.GridStep
	local localZ = (position.Z - centre.Z) / COLONY.GridStep

	local function snap(value, cells)
		if cells and cells % 2 == 0 then
			--[[ Even footprint: snap to half-cell, which keeps the footprint's
			     edges aligned to grid lines. ]]
			return math.floor(value * 2 + 0.5) / 2
		end
		return math.floor(value + 0.5)
	end

	return snap(localX, footprintW), snap(localZ, footprintD)
end

--[[ Half-extent of the build area, in grid cells. Leaves a margin inside the
     plot so a large building can never overhang a neighbour. ]]
function PlotGrid.gridHalfExtent()
	local usable = COLONY.PlotSize - 24
	return math.floor((usable / 2) / COLONY.GridStep)
end

--[[ Is a footprint fully inside the plot's build area? ]]
function PlotGrid.footprintInBounds(gx, gz, w, d)
	local limit = PlotGrid.gridHalfExtent()
	local halfW = w / 2
	local halfD = d / 2
	return (gx - halfW) >= -limit
		and (gx + halfW) <= limit
		and (gz - halfD) >= -limit
		and (gz + halfD) <= limit
end

--[[ Footprint cells for a building, accounting for rotation. Takes the
     footprint table so this module stays independent of BuildingConfig. ]]
function PlotGrid.rotatedFootprint(footprint, rotation)
	local w = footprint and footprint.w or 1
	local d = footprint and footprint.d or 1
	if rotation == 90 or rotation == 270 then
		w, d = d, w
	end
	return w, d
end

--[[ Axis-aligned rectangle in grid space, for overlap tests. ]]
function PlotGrid.rect(gx, gz, w, d)
	return {
		minX = gx - w / 2,
		maxX = gx + w / 2,
		minZ = gz - d / 2,
		maxZ = gz + d / 2,
	}
end

--[[ Shared edges do not count as overlapping, so flush rows are buildable. ]]
function PlotGrid.overlaps(a, b)
	return a.minX < b.maxX and b.minX < a.maxX and a.minZ < b.maxZ and b.minZ < a.maxZ
end

function PlotGrid.gridStep()
	return COLONY.GridStep
end

return PlotGrid
