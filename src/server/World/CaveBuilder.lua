--[[
	CaveBuilder.lua
	Turns a CaveLayout into world geometry, and rearranges it on a night shift.

	The split between CaveLayout and CaveBuilder is the central architectural
	choice of the cave system: the layout is pure data with provable invariants,
	and this module is a dumb projection of it. A shift mutates the layout first,
	validates it, and only then asks this module to rebuild the cells that
	changed.

	What a shift rebuild touches, and what it must not:
		rebuilt    walls, ceiling, props
		preserved  floor (nobody falls), resource nodes (no duplication),
		           monsters, players, dropped objectives

	Rebuilding only changed cells is also the performance story: a Hard shift
	touches five of fifteen rooms, so it costs a third of a rebuild rather than a
	whole one.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local CaveLayout = require(Shared.Lib.CaveLayout)
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local PartFactory = require(Shared.Util.PartFactory)
local Rng = require(Shared.Lib.Rng)
local RoomConfig = require(Shared.Config.RoomConfig)
local RoomLibrary = require(script.Parent.RoomLibrary)

local log = Logger.new("CaveBuilder")

local CaveBuilder = {}

local CAVE = GameConfig.Cave

--[[ World origin for a concurrent session slot. Sessions are spaced far enough
     apart that no light, sound or stray part from one reaches another. ]]
function CaveBuilder.originForSlot(slot)
	return CAVE.WorldOrigin + Vector3.new((slot - 1) * CAVE.SessionStrideX, 0, 0)
end

--[[
	Build the whole cave.

	@param layout  table from CaveLayout.generate
	@param origin  Vector3 session world origin
	@param biomeId string
	@param parent  Instance to put the cave under
	@return built  { root, rooms = { [cellKey] = Model }, origin, biome }
]]
function CaveBuilder.build(layout, origin, biomeId, parent)
	local biome = RoomConfig.biome(biomeId)
	local root = Instance.new("Folder")
	root.Name = "Cave"
	root:SetAttribute("Seed", layout.seed)
	root:SetAttribute("Biome", biome.id)

	local rooms = {}

	for _, key in ipairs(layout.order) do
		local cell = layout.cells[key]
		local cellOrigin = RoomLibrary.cellOrigin(origin, cell)

		local roomModel = PartFactory.model("Room_" .. key, nil)
		roomModel:SetAttribute("CellKey", key)
		roomModel:SetAttribute("Kind", cell.kind)
		roomModel:SetAttribute("GridX", cell.x)
		roomModel:SetAttribute("GridY", cell.y)

		local floor = RoomLibrary.buildFloor(roomModel, cellOrigin, biome)
		roomModel.PrimaryPart = floor

		--[[ Each cell gets its own deterministic generator derived from the
		     layout seed and its coordinates, so a cell's clutter is identical
		     every time that seed is played, and a rebuild after a shift does not
		     depend on how many random numbers the rest of the cave consumed. ]]
		local cellRng = Rng.new(layout.seed * 7919 + cell.x * 131 + cell.y * 17)
		RoomLibrary.buildShell(roomModel, cell, cellOrigin, biome, cellRng)
		RoomLibrary.decorateSpecial(roomModel, cell, cellOrigin, layout)

		PartFactory.folder("Nodes", roomModel)
		PartFactory.folder("Monsters", roomModel)

		roomModel.Parent = root
		rooms[key] = roomModel
	end

	--[[ A sealing shell around the whole grid. Without it a player who clips a
	     doorway falls out of the world; with it they land in the dark and walk
	     back. Cheap insurance. ]]
	local gridWidth = layout.gridWidth * CAVE.CellSize
	local gridHeight = layout.gridHeight * CAVE.CellSize
	local centre = origin
		+ Vector3.new((layout.gridWidth - 1) * CAVE.CellSize / 2, 0, (layout.gridHeight - 1) * CAVE.CellSize / 2)

	PartFactory.block({
		name = "Bedrock",
		size = Vector3.new(gridWidth + 160, 8, gridHeight + 160),
		position = centre + Vector3.new(0, -14, 0),
		color = biome.rock,
		material = biome.rockMaterial,
		parent = root,
	})

	root.Parent = parent

	log:info("built cave: %s", CaveLayout.summarise(layout))
	if GameConfig.Debug then
		print(("[BZ/CaveBuilder] layout seed %d\n%s"):format(layout.seed, CaveLayout.render(layout)))
	end

	return { root = root, rooms = rooms, origin = origin, biome = biome }
end

--[[
	Rebuild the cells a shift changed.

	@param built        value returned by build()
	@param layout       the already-shifted layout
	@param changedKeys  array of cell keys
	@return number rebuilt
]]
function CaveBuilder.rebuildCells(built, layout, changedKeys)
	local rebuilt = 0
	for _, key in ipairs(changedKeys) do
		local cell = layout.cells[key]
		local roomModel = built.rooms[key]
		if cell and roomModel and roomModel.Parent then
			local cellOrigin = RoomLibrary.cellOrigin(built.origin, cell)
			local cellRng = Rng.new(layout.seed * 7919 + cell.x * 131 + cell.y * 17 + layout.shiftsApplied * 104729)

			RoomLibrary.buildShell(roomModel, cell, cellOrigin, built.biome, cellRng)
			roomModel:SetAttribute("Kind", cell.kind)
			rebuilt += 1
		end
	end
	return rebuilt
end

--[[ Which cell contains a world position, or nil if it is outside the grid.
     Used to work out which room each player is standing in, which is what the
     shift uses to decide what it may not rearrange. ]]
function CaveBuilder.cellKeyAt(layout, origin, position)
	local local_ = position - origin
	local gx = math.floor(local_.X / CAVE.CellSize + 0.5)
	local gy = math.floor(local_.Z / CAVE.CellSize + 0.5)
	local key = CaveLayout.key(gx, gy)
	return layout.cells[key] and key or nil
end

function CaveBuilder.cellCentre(origin, cell)
	return RoomLibrary.cellOrigin(origin, cell)
end

--[[ A safe spawn point inside a cell: the centre, lifted clear of the floor. ]]
function CaveBuilder.spawnPointIn(origin, cell)
	return RoomLibrary.cellOrigin(origin, cell) + Vector3.new(0, 4, 0)
end

function CaveBuilder.destroy(built)
	if built and built.root then
		built.root:Destroy()
	end
end

return CaveBuilder
