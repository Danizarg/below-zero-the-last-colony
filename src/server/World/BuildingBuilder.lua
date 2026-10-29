--[[
	BuildingBuilder.lua
	Turns a building placement into procedural geometry.

	One generic shell (platform, walls with a doorway, roof) plus a per-building
	detail pass. That split keeps every building recognisable at a glance while
	needing only a few dozen lines each, and it means a new building is a config
	entry plus an optional detail function.

	Buildings visibly change with level: more storeys, a brighter accent, extra
	fittings. The brief asks for architecture that evolves as the colony grows,
	and level is the lever that does it.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local BuildingConfig = require(Shared.Config.BuildingConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local PartFactory = require(Shared.Util.PartFactory)
local Rng = require(Shared.Lib.Rng)
local Theme = require(Shared.Config.Theme)

local BuildingBuilder = {}

local GRID = GameConfig.Colony.GridStep
local B = Enums.Building

-- ─────────────────────────────────────────────────────────────────────────────
-- Shell
-- ─────────────────────────────────────────────────────────────────────────────

local function buildShell(model, _def, level, size, height, palette)
	local wallThickness = 1.4
	local storeyHeight = height

	-- Platform.
	PartFactory.block({
		name = "Platform",
		size = Vector3.new(size.X, 1.6, size.Z),
		cframe = CFrame.new(0, 0.8, 0),
		color = Color3.fromRGB(62, 58, 52),
		material = Enum.Material.Slate,
		parent = model,
	})

	-- Walls, with a doorway on the +Z face.
	local doorWidth = math.min(8, size.X - 3)
	local doorHeight = math.min(10, storeyHeight - 1)

	PartFactory.wall({
		name = "WallFront",
		cframe = CFrame.new(0, 1.6 + storeyHeight / 2, size.Z / 2 - wallThickness / 2),
		length = size.X,
		height = storeyHeight,
		thickness = wallThickness,
		color = palette.primary,
		material = Enum.Material.WoodPlanks,
		doorway = { width = doorWidth, height = doorHeight },
		parent = model,
	})

	PartFactory.wall({
		name = "WallBack",
		cframe = CFrame.new(0, 1.6 + storeyHeight / 2, -size.Z / 2 + wallThickness / 2),
		length = size.X,
		height = storeyHeight,
		thickness = wallThickness,
		color = palette.primary,
		material = Enum.Material.WoodPlanks,
		parent = model,
	})

	for _, sign in ipairs({ -1, 1 }) do
		PartFactory.wall({
			name = "WallSide",
			cframe = CFrame.new(sign * (size.X / 2 - wallThickness / 2), 1.6 + storeyHeight / 2, 0)
				* CFrame.Angles(0, math.pi / 2, 0),
			length = size.Z,
			height = storeyHeight,
			thickness = wallThickness,
			color = palette.primary,
			material = Enum.Material.WoodPlanks,
			parent = model,
		})
	end

	-- Roof: a slab plus two wedges, which reads as pitched without the cost.
	local roofY = 1.6 + storeyHeight
	PartFactory.block({
		name = "RoofSlab",
		size = Vector3.new(size.X + 2, 1.2, size.Z + 2),
		cframe = CFrame.new(0, roofY + 0.6, 0),
		color = palette.accent,
		material = Enum.Material.Wood,
		parent = model,
	})

	local pitch = math.min(6, storeyHeight * 0.4)
	for _, sign in ipairs({ -1, 1 }) do
		PartFactory.wedge({
			name = "RoofPitch",
			size = Vector3.new(size.X + 2, pitch, (size.Z + 2) / 2),
			cframe = CFrame.new(0, roofY + 1.2 + pitch / 2, sign * (size.Z + 2) / 4)
				* CFrame.Angles(0, sign > 0 and 0 or math.pi, 0)
				* CFrame.Angles(0, math.pi / 2, 0),
			color = palette.accent,
			material = Enum.Material.Wood,
			parent = model,
		})
	end

	--[[ Upper storeys appear from level 2, so a visitor can read a colony's
	     development from the skyline alone. ]]
	if level >= 2 then
		PartFactory.block({
			name = "UpperStorey",
			size = Vector3.new(size.X * 0.7, storeyHeight * 0.5, size.Z * 0.7),
			cframe = CFrame.new(0, roofY + 1.2 + pitch + storeyHeight * 0.25, 0),
			color = palette.primary,
			material = Enum.Material.WoodPlanks,
			parent = model,
		})
	end
	if level >= 3 then
		PartFactory.glow({
			name = "LevelBeacon",
			size = Vector3.new(2, 2, 2),
			position = Vector3.new(0, roofY + 1.2 + pitch + storeyHeight * 0.5 + 3, 0),
			shape = Enum.PartType.Ball,
			color = palette.accent,
			lightColor = palette.accent,
			range = 40,
			brightness = 1.6,
			parent = model,
		})
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Per-building details
-- ─────────────────────────────────────────────────────────────────────────────

local details = {}

details[B.TownHall] = function(model, def, level, size, palette, _rng)
	-- A tower that grows with level: the colony's landmark.
	local towerHeight = 16 + level * 7
	PartFactory.block({
		name = "Tower",
		size = Vector3.new(7, towerHeight, 7),
		cframe = CFrame.new(size.X / 2 - 5, 1.6 + towerHeight / 2, -size.Z / 2 + 5),
		color = Color3.fromRGB(78, 72, 64),
		material = Enum.Material.Rock,
		parent = model,
	})
	PartFactory.glow({
		name = "TowerLight",
		size = Vector3.new(4, 4, 4),
		position = Vector3.new(size.X / 2 - 5, 1.6 + towerHeight + 2, -size.Z / 2 + 5),
		color = palette.accent,
		lightColor = Color3.fromRGB(255, 196, 120),
		range = 90,
		brightness = 2.4,
		parent = model,
	})

	-- Banner.
	PartFactory.decor({
		name = "Banner",
		size = Vector3.new(0.4, 12, 7),
		cframe = CFrame.new(-size.X / 2 + 1, 1.6 + 12, size.Z / 2 - 6),
		color = palette.accent,
		material = Enum.Material.Fabric,
		parent = model,
	})

	-- Noticeboard: the interaction anchor for colony management.
	local board = PartFactory.block({
		name = "Noticeboard",
		size = Vector3.new(8, 7, 1),
		cframe = CFrame.new(0, 5, size.Z / 2 + 2),
		color = Color3.fromRGB(96, 76, 54),
		material = Enum.Material.Wood,
		parent = model,
	})
	PartFactory.prompt(board, {
		name = "ColonyPrompt",
		actionText = "Manage Colony",
		objectText = def.name,
		maxDistance = 14,
		requiresLineOfSight = false,
	})
end

details[B.Housing] = function(model, _def, level, size, _palette, _rng)
	local chimneyHeight = 8 + level * 2
	PartFactory.block({
		name = "Chimney",
		size = Vector3.new(2.4, chimneyHeight, 2.4),
		cframe = CFrame.new(size.X / 2 - 3, 1.6 + size.Y + chimneyHeight / 2, -size.Z / 2 + 3),
		color = Color3.fromRGB(66, 62, 56),
		material = Enum.Material.Slate,
		parent = model,
	})
	PartFactory.glow({
		name = "WindowGlow",
		size = Vector3.new(3, 3, 0.4),
		position = Vector3.new(-size.X / 4, 7, size.Z / 2 - 0.4),
		color = Color3.fromRGB(255, 206, 140),
		lightColor = Color3.fromRGB(255, 196, 128),
		range = 24,
		brightness = 1,
		parent = model,
	})
end

details[B.Farm] = function(model, def, level, size, _palette, rng)
	--[[ The farm has no walls: it is planters and trellises, which makes it
	     instantly distinguishable from the housing silhouette. ]]
	for _, child in ipairs(model:GetChildren()) do
		if string.sub(child.Name, 1, 4) == "Wall" or string.sub(child.Name, 1, 4) == "Roof" then
			child:Destroy()
		end
	end

	local rows = 2 + level
	local spacing = size.Z / (rows + 1)
	for row = 1, rows do
		local z = -size.Z / 2 + spacing * row
		PartFactory.block({
			name = "Planter",
			size = Vector3.new(size.X - 4, 2, spacing * 0.55),
			cframe = CFrame.new(0, 2.6, z),
			color = Color3.fromRGB(64, 56, 46),
			material = Enum.Material.Ground,
			parent = model,
		})
		PartFactory.mushrooms({
			origin = Vector3.new(0, 3.6, z),
			count = 4 + level,
			radius = (size.X - 6) / 2,
			glowColor = Color3.fromRGB(168, 214, 150),
			rng = rng,
			parent = model,
		})
	end

	for _, sign in ipairs({ -1, 1 }) do
		PartFactory.block({
			name = "Trellis",
			size = Vector3.new(1, 10, size.Z),
			cframe = CFrame.new(sign * (size.X / 2 - 1), 6.6, 0),
			color = Color3.fromRGB(96, 80, 56),
			material = Enum.Material.Wood,
			canCollide = false,
			parent = model,
		})
	end

	local post = PartFactory.block({
		name = "FarmPost",
		size = Vector3.new(2, 6, 2),
		cframe = CFrame.new(size.X / 2 - 2, 4.6, size.Z / 2 - 2),
		color = Color3.fromRGB(92, 76, 54),
		material = Enum.Material.Wood,
		parent = model,
	})
	PartFactory.prompt(post, {
		name = "CraftPrompt",
		actionText = "Use Farm",
		objectText = def.name,
		maxDistance = 12,
		requiresLineOfSight = false,
	})
end

details[B.Workshop] = function(model, def, level, size, _palette, _rng)
	-- Forge: the warm orange light that marks the workshop from across the plot.
	PartFactory.block({
		name = "Forge",
		size = Vector3.new(6, 6, 5),
		cframe = CFrame.new(-size.X / 2 + 4, 4.6, -size.Z / 2 + 4),
		color = Color3.fromRGB(58, 54, 50),
		material = Enum.Material.Slate,
		parent = model,
	})
	PartFactory.glow({
		name = "ForgeFire",
		size = Vector3.new(3.4, 2.4, 3),
		position = Vector3.new(-size.X / 2 + 4, 6.4, -size.Z / 2 + 4),
		color = Color3.fromRGB(255, 136, 56),
		lightColor = Color3.fromRGB(255, 150, 72),
		range = 46,
		brightness = 2.2,
		parent = model,
	})

	local anvil = PartFactory.block({
		name = "Anvil",
		size = Vector3.new(4, 3.2, 2.4),
		cframe = CFrame.new(0, 3.2, size.Z / 2 - 4),
		color = Color3.fromRGB(70, 70, 76),
		material = Enum.Material.Metal,
		parent = model,
	})
	PartFactory.prompt(anvil, {
		name = "CraftPrompt",
		actionText = "Use Workshop",
		objectText = def.name,
		maxDistance = 12,
		requiresLineOfSight = false,
	})

	for index = 1, level do
		PartFactory.decor({
			name = "ToolRack",
			size = Vector3.new(0.6, 5, 3),
			cframe = CFrame.new(size.X / 2 - 1.2, 6, -size.Z / 2 + 4 + index * 4),
			color = Color3.fromRGB(104, 84, 60),
			material = Enum.Material.Wood,
			parent = model,
		})
	end
end

details[B.Infirmary] = function(model, def, level, size, _palette, _rng)
	-- A lit cross, readable from any angle without a texture.
	local crossColor = Color3.fromRGB(150, 236, 210)
	PartFactory.glow({
		name = "CrossVertical",
		size = Vector3.new(1.4, 6, 0.6),
		position = Vector3.new(0, 11, size.Z / 2 + 0.6),
		color = crossColor,
		lightColor = crossColor,
		range = 26,
		brightness = 1.4,
		parent = model,
	})
	PartFactory.glow({
		name = "CrossHorizontal",
		size = Vector3.new(6, 1.4, 0.6),
		position = Vector3.new(0, 11, size.Z / 2 + 0.6),
		color = crossColor,
		light = false,
		parent = model,
	})

	for index = 1, 1 + level do
		PartFactory.decor({
			name = "Cot",
			size = Vector3.new(3, 1.4, 6),
			cframe = CFrame.new(-size.X / 2 + 3 + (index - 1) * 4.5, 2.6, 0),
			color = Color3.fromRGB(176, 170, 158),
			material = Enum.Material.Fabric,
			parent = model,
		})
	end

	local counter = PartFactory.block({
		name = "Counter",
		size = Vector3.new(5, 3.4, 2),
		cframe = CFrame.new(size.X / 2 - 4, 3.3, size.Z / 2 - 3),
		color = Color3.fromRGB(88, 92, 92),
		material = Enum.Material.Slate,
		parent = model,
	})
	PartFactory.prompt(counter, {
		name = "CraftPrompt",
		actionText = "Use Infirmary",
		objectText = def.name,
		maxDistance = 12,
		requiresLineOfSight = false,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Entry points
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Footprint in world studs, accounting for rotation. ]]
function BuildingBuilder.footprintSize(buildingId, rotation)
	local def = BuildingConfig.get(buildingId)
	if not def then
		return Vector3.new(GRID, GRID, GRID)
	end
	local w, d = def.footprint.w, def.footprint.d
	if rotation == 90 or rotation == 270 then
		w, d = d, w
	end
	return Vector3.new(w * GRID, def.height, d * GRID)
end

--[[ Footprint in grid cells, accounting for rotation. ]]
function BuildingBuilder.footprintCells(buildingId, rotation)
	local def = BuildingConfig.get(buildingId)
	if not def then
		return 1, 1
	end
	local w, d = def.footprint.w, def.footprint.d
	if rotation == 90 or rotation == 270 then
		w, d = d, w
	end
	return w, d
end

--[[
	Build a building model.

	@param placement { uid, id, gx, gz, rot, level, health }
	@param origin    Vector3  world position of the footprint centre, on the ground
	@param parent    Instance
	@return Model
]]
function BuildingBuilder.build(placement, origin, parent)
	local def = BuildingConfig.get(placement.id)
	if not def then
		return nil
	end

	local level = math.clamp(placement.level or 1, 1, #def.levels)
	local rotation = placement.rot or 0
	local size = BuildingBuilder.footprintSize(placement.id, rotation)
	local palette = def.palette
		or { primary = Color3.fromRGB(96, 86, 72), accent = Color3.fromRGB(176, 140, 90) }

	local model = PartFactory.model(def.name, nil)
	model:SetAttribute("BuildingUid", placement.uid)
	model:SetAttribute("BuildingId", placement.id)
	model:SetAttribute("BuildingLevel", level)

	-- Height grows a little with level so upgrades are visible, not just numeric.
	local height = def.height * (1 + (level - 1) * 0.12)

	buildShell(model, def, level, size, height, palette)

	local rng = Rng.new(
		(tonumber(string.match(tostring(placement.uid), "%d+")) or 1) * 7919
			+ placement.gx * 31
			+ placement.gz
	)
	local detail = details[placement.id]
	if detail then
		detail(model, def, level, Vector3.new(size.X, height, size.Z), palette, rng)
	else
		--[[ Buildings without a detail pass still get a usable prompt, so a
		     newly configured building is interactable from the first sync. ]]
		local marker = PartFactory.block({
			name = "Marker",
			size = Vector3.new(3, 4, 3),
			cframe = CFrame.new(0, 3.6, size.Z / 2 + 2),
			color = palette.accent,
			material = Enum.Material.Slate,
			parent = model,
		})
		PartFactory.prompt(marker, {
			name = "BuildingPrompt",
			actionText = "Inspect",
			objectText = def.name,
			maxDistance = 12,
		})
	end

	-- A nameplate makes a crowded plot legible.
	local anchor = PartFactory.block({
		name = "LabelAnchor",
		size = Vector3.new(1, 1, 1),
		cframe = CFrame.new(0, height + 8, 0),
		transparency = 1,
		canCollide = false,
		canQuery = false,
		parent = model,
	})
	local _, label = PartFactory.label(anchor, {
		name = "BuildingLabel",
		text = ("%s  Lv%d"):format(def.name, level),
		color = Theme.Color.TextMuted,
		offset = Vector3.zero,
		textSize = 13,
		maxDistance = 120,
	})
	label.Font = Theme.Font.Body

	-- Position and parent last, so the model is assembled off-tree.
	local primary = model:FindFirstChild("Platform")
	if primary then
		model.PrimaryPart = primary
	end

	model:PivotTo(CFrame.new(origin) * CFrame.Angles(0, math.rad(rotation), 0))
	model.Parent = parent
	return model
end

--[[ A translucent preview of a footprint, for the client's placement ghost.
     Built server-side only for validation visuals; the client builds its own. ]]
function BuildingBuilder.footprintMarker(buildingId, rotation, origin, parent, valid)
	local size = BuildingBuilder.footprintSize(buildingId, rotation)
	return PartFactory.decor({
		name = "Footprint",
		size = Vector3.new(size.X, 0.4, size.Z),
		position = origin + Vector3.new(0, 0.2, 0),
		color = valid and Color3.fromRGB(118, 206, 146) or Color3.fromRGB(226, 78, 78),
		material = Enum.Material.Neon,
		transparency = 0.6,
		parent = parent,
	})
end

return BuildingBuilder
