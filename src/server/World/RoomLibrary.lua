--[[
	RoomLibrary.lua
	Builds the geometry for a single cave cell.

	Part naming is load-bearing. A night shift rebuilds a room's walls, ceiling
	and props while leaving its floor alone, so the names are the contract:

		Floor      never destroyed — a player standing in a shifting room must
		           never lose the ground under them
		Wall_N/E/S/W  rebuilt on every shift that touches this cell
		Ceiling    rebuilt (it is above the player, so it is safe to swap)
		Props      a folder, rebuilt with the room's kind
		Nodes      a folder owned by NodeService, never touched by a shift, so a
		           rearrangement can never re-roll resources into existence

	Rooms are axis-aligned cells of a fixed size, which is what guarantees
	non-overlapping geometry: two rooms cannot intersect because they occupy
	different integer grid cells, and doorways only exist where two cells agree.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local PartFactory = require(Shared.Util.PartFactory)
local RoomConfig = require(Shared.Config.RoomConfig)
local Theme = require(Shared.Config.Theme)

local RoomLibrary = {}

local CAVE = GameConfig.Cave
local K = Enums.RoomKind

local DIRECTION_ANGLE = { N = 0, E = math.pi / 2, S = math.pi, W = -math.pi / 2 }
local DIRECTION_OFFSET = {
	N = Vector3.new(0, 0, -1),
	E = Vector3.new(1, 0, 0),
	S = Vector3.new(0, 0, 1),
	W = Vector3.new(-1, 0, 0),
}

--[[ World position of a cell's centre, at floor level. ]]
function RoomLibrary.cellOrigin(sessionOrigin, cell)
	return sessionOrigin + Vector3.new(cell.x * CAVE.CellSize, 0, cell.y * CAVE.CellSize)
end

function RoomLibrary.roomHeight(cell)
	local def = RoomConfig.get(cell.kind) or RoomConfig.get(K.CorridorStraight)
	return CAVE.RoomHeight * (def.ceiling or 1)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Props
-- ─────────────────────────────────────────────────────────────────────────────

local propBuilders = {}

propBuilders.arch = function(folder, origin, spec, biome, _rng)
	PartFactory.arch({
		cframe = CFrame.new(origin + Vector3.new(0, spec.size.Y / 2, 0)),
		width = spec.size.X,
		height = spec.size.Y,
		depth = spec.size.Z,
		color = spec.color or biome.rock,
		material = biome.rockMaterial,
		parent = folder,
	})
end

propBuilders.crate = function(folder, origin, spec, _biome, rng)
	PartFactory.block({
		name = "Crate",
		size = spec.size,
		cframe = CFrame.new(origin + Vector3.new(0, spec.size.Y / 2, 0))
			* CFrame.Angles(0, rng:nextRange(0, 6.28), 0),
		color = spec.color or Color3.fromRGB(112, 88, 60),
		material = Enum.Material.Wood,
		parent = folder,
	})
end

propBuilders.lantern = function(folder, origin, spec, _biome, _rng)
	PartFactory.lantern({
		origin = origin,
		height = spec.size.Y,
		lightColor = spec.light or Color3.fromRGB(255, 196, 128),
		range = 46,
		brightness = 1.5,
		parent = folder,
	})
end

propBuilders.scatter = function(folder, origin, spec, biome, rng)
	PartFactory.scatter({
		origin = origin,
		count = spec.count or 5,
		radius = CAVE.CellSize * 0.3,
		size = spec.size,
		color = spec.color or biome.rock,
		material = biome.rockMaterial,
		rng = rng,
		parent = folder,
	})
end

propBuilders.beam = function(folder, origin, _spec, _biome, _rng)
	--[[ Mine supports: two posts and a lintel. Cheap, and they do a lot of work
	     selling "someone dug this". ]]
	local height = CAVE.RoomHeight * 0.6
	for _, sign in ipairs({ -1, 1 }) do
		PartFactory.decor({
			name = "SupportPost",
			size = Vector3.new(2, height, 2),
			position = origin + Vector3.new(sign * CAVE.DoorWidth / 2, height / 2, 0),
			color = Color3.fromRGB(94, 74, 52),
			material = Enum.Material.Wood,
			parent = folder,
		})
	end
	PartFactory.decor({
		name = "SupportLintel",
		size = Vector3.new(CAVE.DoorWidth + 4, 2, 2),
		position = origin + Vector3.new(0, height, 0),
		color = Color3.fromRGB(94, 74, 52),
		material = Enum.Material.Wood,
		parent = folder,
	})
end

propBuilders.cart = function(folder, origin, spec, _biome, rng)
	--[[ A mine cart: body, two wheels and a short run of rail. It is the single
	     most effective prop for selling "people worked here", which is what
	     makes a mining chamber feel different from a natural cavern. ]]
	local angle = rng:nextRange(0, math.pi * 2)
	local base = CFrame.new(origin + Vector3.new(0, spec.size.Y / 2, 0)) * CFrame.Angles(0, angle, 0)

	PartFactory.decor({
		name = "CartBody",
		size = spec.size,
		cframe = base,
		color = spec.color or Color3.fromRGB(88, 82, 78),
		material = Enum.Material.CorrodedMetal,
		parent = folder,
	})

	-- Hollow it out with a darker inset so it does not read as a solid block.
	PartFactory.decor({
		name = "CartInterior",
		size = Vector3.new(spec.size.X - 1.2, spec.size.Y * 0.5, spec.size.Z - 1.2),
		cframe = base * CFrame.new(0, spec.size.Y * 0.35, 0),
		color = Color3.fromRGB(40, 38, 36),
		material = Enum.Material.Slate,
		parent = folder,
	})

	for _, offset in ipairs({ -spec.size.Z * 0.3, spec.size.Z * 0.3 }) do
		PartFactory.decor({
			name = "CartWheel",
			size = Vector3.new(spec.size.X + 0.6, 2, 2),
			cframe = base * CFrame.new(0, -spec.size.Y / 2 + 0.6, offset),
			color = Color3.fromRGB(54, 52, 50),
			material = Enum.Material.Metal,
			parent = folder,
		})
	end

	for _, side in ipairs({ -1, 1 }) do
		PartFactory.decor({
			name = "Rail",
			size = Vector3.new(0.5, 0.4, spec.size.Z * 2.4),
			cframe = base * CFrame.new(side * spec.size.X * 0.42, -spec.size.Y / 2, 0),
			color = Color3.fromRGB(92, 78, 64),
			material = Enum.Material.CorrodedMetal,
			parent = folder,
		})
	end
end

propBuilders.mushrooms = function(folder, origin, spec, biome, rng)
	PartFactory.mushrooms({
		origin = origin,
		count = spec.count or 6,
		radius = CAVE.CellSize * 0.22,
		glowColor = biome.glowColor,
		rng = rng,
		parent = folder,
	})
end

propBuilders.pool = function(folder, origin, spec, biome, _rng)
	PartFactory.glow({
		name = "GlowPool",
		size = spec.size,
		position = origin + Vector3.new(0, 0.3, 0),
		color = spec.glow or biome.glowColor,
		lightColor = spec.glow or biome.glowColor,
		range = 42,
		brightness = 1.1,
		transparency = 0.25,
		parent = folder,
	})
end

propBuilders.sign = function(folder, origin, spec, _biome, _rng)
	local post = PartFactory.decor({
		name = "Signpost",
		size = Vector3.new(0.6, spec.size.Y, 0.6),
		position = origin + Vector3.new(0, spec.size.Y / 2, 0),
		color = spec.color or Color3.fromRGB(104, 84, 60),
		material = Enum.Material.Wood,
		parent = folder,
	})
	PartFactory.decor({
		name = "SignBoard",
		size = Vector3.new(spec.size.X, 2.4, 0.4),
		position = origin + Vector3.new(0, spec.size.Y - 1.5, 0),
		color = spec.color or Color3.fromRGB(104, 84, 60),
		material = Enum.Material.Wood,
		parent = folder,
	})
	return post
end

propBuilders.sac = function(folder, origin, spec, _biome, _rng)
	PartFactory.decor({
		name = "EggSac",
		size = spec.size,
		position = origin + Vector3.new(0, spec.size.Y / 2, 0),
		shape = Enum.PartType.Ball,
		color = spec.color or Color3.fromRGB(176, 168, 140),
		material = Enum.Material.Fabric,
		transparency = 0.15,
		parent = folder,
	})
end

propBuilders.web = function(folder, origin, spec, _biome, rng)
	for index = 1, spec.count or 3 do
		local angle = rng:nextRange(0, math.pi * 2)
		PartFactory.decor({
			name = "Web",
			size = Vector3.new(rng:nextRange(8, 16), 0.3, rng:nextRange(8, 16)),
			cframe = CFrame.new(origin + Vector3.new(0, CAVE.RoomHeight * 0.55, 0))
				* CFrame.Angles(0, angle, 0)
				* CFrame.new(index * 3, 0, 0),
			color = Color3.fromRGB(198, 196, 188),
			material = Enum.Material.Fabric,
			transparency = 0.5,
			parent = folder,
		})
	end
end

propBuilders.pillar = function(folder, origin, spec, _biome, _rng)
	PartFactory.decor({
		name = "RunePillar",
		size = spec.size,
		position = origin + Vector3.new(0, spec.size.Y / 2, 0),
		color = Color3.fromRGB(132, 122, 100),
		material = Enum.Material.Sandstone,
		parent = folder,
	})
	PartFactory.glow({
		name = "Rune",
		size = Vector3.new(spec.size.X * 0.4, spec.size.Y * 0.5, 0.3),
		position = origin + Vector3.new(0, spec.size.Y * 0.6, spec.size.Z / 2),
		color = spec.glow or Color3.fromRGB(150, 180, 255),
		lightColor = spec.glow or Color3.fromRGB(150, 180, 255),
		range = 24,
		brightness = 1.2,
		parent = folder,
	})
end

propBuilders.tiles = function(folder, origin, spec, _biome, _rng)
	PartFactory.decor({
		name = "AncientFloor",
		size = spec.size,
		position = origin + Vector3.new(0, 0.3, 0),
		color = spec.color or Color3.fromRGB(128, 118, 96),
		material = Enum.Material.Sandstone,
		parent = folder,
	})
end

propBuilders.gate = function(folder, origin, spec, _biome, _rng)
	--[[ The First Gate. ObjectiveService attaches the prompt and drives its
	     visual state, so this is purely the frame and the sealed slab. ]]
	local gate = PartFactory.folder("FirstGate", folder)
	PartFactory.arch({
		cframe = CFrame.new(origin + Vector3.new(0, spec.size.Y / 2, 0)),
		width = spec.size.X,
		height = spec.size.Y,
		depth = spec.size.Z,
		legWidth = 4,
		color = Color3.fromRGB(142, 128, 102),
		material = Enum.Material.Sandstone,
		parent = gate,
	})
	local slab = PartFactory.block({
		name = "GateSlab",
		size = Vector3.new(spec.size.X - 8, spec.size.Y - 2, 2.4),
		position = origin + Vector3.new(0, spec.size.Y / 2, 0),
		color = Color3.fromRGB(58, 54, 50),
		material = Enum.Material.Slate,
		parent = gate,
	})
	slab:SetAttribute("IsGateSlab", true)
	return gate
end

propBuilders.plinth = function(folder, origin, spec, _biome, _rng)
	PartFactory.block({
		name = "Plinth",
		size = spec.size,
		position = origin + Vector3.new(0, spec.size.Y / 2, 0),
		color = spec.color or Color3.fromRGB(150, 138, 112),
		material = Enum.Material.Sandstone,
		parent = folder,
	})
end

propBuilders.ladder = function(folder, origin, spec, _biome, _rng)
	--[[ The secondary extraction point: a shaft of rope ladder reaching up into
	     the dark. ObjectiveService / ExpeditionService attach the prompt. ]]
	for rung = 0, math.floor(spec.size.Y / 3) do
		PartFactory.decor({
			name = "Rung",
			size = Vector3.new(spec.size.X, 0.4, 0.6),
			position = origin + Vector3.new(0, rung * 3 + 1, 0),
			color = spec.color or Color3.fromRGB(128, 104, 72),
			material = Enum.Material.Wood,
			parent = folder,
		})
	end
	for _, sign in ipairs({ -1, 1 }) do
		PartFactory.decor({
			name = "LadderRope",
			size = Vector3.new(0.3, spec.size.Y, 0.3),
			position = origin + Vector3.new(sign * spec.size.X / 2, spec.size.Y / 2, 0),
			color = Color3.fromRGB(150, 128, 92),
			material = Enum.Material.Fabric,
			parent = folder,
		})
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Room assembly
-- ─────────────────────────────────────────────────────────────────────────────

--[[ The floor is built once per cell and never rebuilt. ]]
function RoomLibrary.buildFloor(roomModel, origin, biome)
	return PartFactory.block({
		name = "Floor",
		size = Vector3.new(CAVE.CellSize, 4, CAVE.CellSize),
		position = origin + Vector3.new(0, -2, 0),
		color = biome.floor,
		material = biome.floorMaterial,
		parent = roomModel,
	})
end

--[[
	Build (or rebuild) the walls, ceiling and props of a cell.

	Called on first build and again for every cell a shift touches. Destroys only
	what it owns, so the floor and any resource nodes survive untouched.
]]
function RoomLibrary.buildShell(roomModel, cell, origin, biome, rng)
	PartFactory.destroyByPrefix(roomModel, "Wall_")
	local oldCeiling = roomModel:FindFirstChild("Ceiling")
	if oldCeiling then
		oldCeiling:Destroy()
	end
	local oldProps = roomModel:FindFirstChild("Props")
	if oldProps then
		oldProps:Destroy()
	end

	local def = RoomConfig.get(cell.kind) or RoomConfig.get(K.CorridorStraight)
	local height = RoomLibrary.roomHeight(cell)
	local half = CAVE.CellSize / 2

	-- Walls. A doorway gap exists only where the layout says there is a door.
	for _, dir in ipairs(Enums.DirectionList) do
		local offset = DIRECTION_OFFSET[dir] * (half - CAVE.WallThickness / 2)
		local cframe = CFrame.new(origin + Vector3.new(offset.X, height / 2, offset.Z))
			* CFrame.Angles(0, DIRECTION_ANGLE[dir], 0)

		--[[ PartFactory.wall prefixes every part it emits with the name given
		     here, so all of them start with "Wall_" and destroyByPrefix above
		     clears exactly this set and nothing else. ]]
		PartFactory.wall({
			name = "Wall_" .. dir,
			cframe = cframe,
			length = CAVE.CellSize,
			height = height,
			thickness = CAVE.WallThickness,
			color = biome.rock,
			material = biome.rockMaterial,
			doorway = cell.doors[dir] and { width = CAVE.DoorWidth, height = CAVE.DoorHeight } or nil,
			parent = roomModel,
		})
	end

	-- Ceiling.
	PartFactory.block({
		name = "Ceiling",
		size = Vector3.new(CAVE.CellSize, 4, CAVE.CellSize),
		position = origin + Vector3.new(0, height + 2, 0),
		color = biome.rock,
		material = biome.rockMaterial,
		parent = roomModel,
	})

	-- Props.
	local props = PartFactory.folder("Props", roomModel)
	local propList = def.props or {}
	local count = #propList
	for index, propId in ipairs(propList) do
		local spec = RoomConfig.Props[propId]
		if spec then
			local builder = propBuilders[spec.kind]
			if builder then
				--[[ Props are spread around the cell rather than stacked at the
				     centre, with a seeded offset so the same cave seed always
				     looks the same. ]]
				local angle = (index / math.max(1, count)) * math.pi * 2 + rng:nextRange(-0.4, 0.4)
				local distance = count > 1 and rng:nextRange(half * 0.25, half * 0.6) or 0
				local propOrigin = origin
					+ Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
				local ok, err = pcall(builder, props, propOrigin, spec, biome, rng)
				if not ok then
					warn(("[BZ/RoomLibrary] prop %q failed: %s"):format(propId, tostring(err)))
				end
			end
		end
	end

	-- Ambient fill light, so a room is navigable without a lantern in hand.
	local lightLevel = def.lightLevel or 0.2
	if lightLevel > 0.05 then
		PartFactory.glow({
			name = "AmbientFill",
			size = Vector3.new(2, 2, 2),
			position = origin + Vector3.new(0, height * 0.75, 0),
			color = biome.glowColor,
			lightColor = biome.ambientLight,
			range = CAVE.CellSize * (0.5 + lightLevel),
			brightness = 0.4 + lightLevel * 1.2,
			transparency = 1,
			parent = props,
		})
	end

	return roomModel
end

--[[ Name label shown in the HUD when a player enters a room, and above safe
     rooms so an exit is visible from the doorway. ]]
function RoomLibrary.decorateSpecial(roomModel, cell, origin, _layout)
	local def = RoomConfig.get(cell.kind)
	if not def then
		return
	end

	if def.isExtraction then
		local anchor = PartFactory.block({
			name = "ExtractionAnchor",
			size = Vector3.new(14, 8, 14),
			position = origin + Vector3.new(0, 4, 0),
			transparency = 1,
			canCollide = false,
			canQuery = false,
			parent = roomModel,
		})
		anchor:SetAttribute("IsExtraction", true)

		PartFactory.prompt(anchor, {
			name = "ExtractPrompt",
			actionText = "Extract",
			objectText = "Surface Route",
			holdDuration = 1.5,
			maxDistance = 18,
			requiresLineOfSight = false,
		})

		local _, label = PartFactory.label(anchor, {
			name = "ExtractionLabel",
			text = "◆ EXTRACTION",
			color = Theme.Color.Success,
			offset = Vector3.new(0, 10, 0),
			textSize = 18,
			maxDistance = 200,
			alwaysOnTop = true,
		})
		label.Font = Theme.Font.Display

		-- A bright beacon so an exit is findable from a corridor away.
		PartFactory.glow({
			name = "ExtractionBeacon",
			size = Vector3.new(3, 3, 3),
			position = origin + Vector3.new(0, RoomLibrary.roomHeight(cell) * 0.7, 0),
			shape = Enum.PartType.Ball,
			color = Theme.Color.Success,
			lightColor = Theme.Color.Success,
			range = 90,
			brightness = 2.2,
			parent = roomModel,
		})
	end

	if cell.kind == K.AncientVault then
		local _, label = PartFactory.label(roomModel:FindFirstChild("Floor") or roomModel, {
			name = "VaultLabel",
			text = "ANCIENT VAULT",
			color = Theme.Color.Accent,
			offset = Vector3.new(0, 18, 0),
			textSize = 16,
			maxDistance = 160,
		})
		label.Font = Theme.Font.Display
	end
end

RoomLibrary.propBuilders = propBuilders

return RoomLibrary
