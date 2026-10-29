--[[
	ColonyBuilder.lua
	Builds the persistent colony cavern and the player plots inside it.

	Why plots: the brief asks for a persistent colony per player that friends can
	visit, with permissions that stop a visitor stealing or demolishing. The
	simplest reliable implementation of that is a shared cavern divided into
	owned plots — visiting is a walk, there is no instance handover, and
	ownership is a single integer comparison on the server. Documented as a
	deliberate choice in GAME_DESIGN.md.

	All geometry is procedural. Nothing here references an external asset.

	Hierarchy produced:

		Workspace/Colony
			Cavern/            static shell: floor, walls, ceiling, features
			Plots/
				Plot_1/
					Ground
					Border/
					Spawn          (SpawnLocation, disabled until claimed)
					Campfire/
					CaveEntrance/  (prompt lives here)
					Buildings/     (BuildingService fills this)
					Colonists/     (NPCService fills this)
					Nameplate
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local GameConfig = require(Shared.Config.GameConfig)
local PartFactory = require(Shared.Util.PartFactory)
local PlotGrid = require(Shared.Lib.PlotGrid)
local Rng = require(Shared.Lib.Rng)
local Theme = require(Shared.Config.Theme)

local ColonyBuilder = {}

local COLONY = GameConfig.Colony

-- Cavern palette: cold damp stone, warm lantern light.
local ROCK = Color3.fromRGB(66, 63, 58)
local ROCK_DARK = Color3.fromRGB(44, 42, 39)
local GROUND = Color3.fromRGB(74, 68, 60)
local GROUND_OWNED = Color3.fromRGB(86, 78, 66)

-- ─────────────────────────────────────────────────────────────────────────────
-- Plot geometry
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Plot geometry lives in Shared/Lib/PlotGrid, so the client's placement ghost
     and the server's real placement cannot drift apart. These are thin
     re-exports, kept so the call sites below read naturally. ]]
ColonyBuilder.plotCentre = PlotGrid.plotCentre
ColonyBuilder.plotSpawnPosition = PlotGrid.plotSpawnPosition
ColonyBuilder.caveEntrancePosition = PlotGrid.caveEntrancePosition
ColonyBuilder.gridToWorld = PlotGrid.gridToWorld
ColonyBuilder.gridHalfExtent = PlotGrid.gridHalfExtent
ColonyBuilder.footprintInBounds = PlotGrid.footprintInBounds

-- ─────────────────────────────────────────────────────────────────────────────
-- Cavern shell
-- ─────────────────────────────────────────────────────────────────────────────

local function buildCavern(parent, rng)
	local cavern = PartFactory.folder("Cavern", parent)

	local span = COLONY.PlotSpacing * COLONY.PlotGridWidth + 320
	local height = COLONY.CavernHeight

	-- Floor. One slab: cheap, flat, and never the thing a player falls through.
	PartFactory.block({
		name = "CavernFloor",
		size = Vector3.new(span, 8, span),
		position = Vector3.new(0, COLONY.FloorY - 4, 0),
		color = GROUND,
		material = Enum.Material.Ground,
		parent = cavern,
	})

	-- Ceiling.
	PartFactory.block({
		name = "CavernCeiling",
		size = Vector3.new(span, 8, span),
		position = Vector3.new(0, COLONY.FloorY + height, 0),
		color = ROCK_DARK,
		material = Enum.Material.Rock,
		parent = cavern,
	})

	-- Perimeter walls. Thick enough that no camera clips outside.
	local half = span / 2
	local wallSpecs = {
		{ size = Vector3.new(span, height, 12), position = Vector3.new(0, height / 2, -half) },
		{ size = Vector3.new(span, height, 12), position = Vector3.new(0, height / 2, half) },
		{ size = Vector3.new(12, height, span), position = Vector3.new(-half, height / 2, 0) },
		{ size = Vector3.new(12, height, span), position = Vector3.new(half, height / 2, 0) },
	}
	for index, spec in ipairs(wallSpecs) do
		PartFactory.block({
			name = "CavernWall" .. index,
			size = spec.size,
			position = spec.position,
			color = ROCK,
			material = Enum.Material.Rock,
			parent = cavern,
		})
	end

	--[[ Stalactites and columns. These are the whole reason the colony reads as
	     "underground" rather than "a field at night", so they are worth the
	     part budget. Decorative, so they are non-colliding and unqueryable. ]]
	local features = PartFactory.folder("Features", cavern)

	for _ = 1, 34 do
		local x = rng:nextRange(-half + 60, half - 60)
		local z = rng:nextRange(-half + 60, half - 60)
		local length = rng:nextRange(18, 54)
		local radius = rng:nextRange(3, 9)
		PartFactory.decor({
			name = "Stalactite",
			size = Vector3.new(radius, length, radius),
			cframe = CFrame.new(x, COLONY.FloorY + height - length / 2 - 4, z)
				* CFrame.Angles(rng:nextRange(-0.08, 0.08), 0, rng:nextRange(-0.08, 0.08)),
			color = ROCK,
			material = Enum.Material.Rock,
			parent = features,
		})
	end

	--[[ Columns sit on the plot boundaries so they frame the plots instead of
	     landing in the middle of someone's build area. ]]
	local boundary = COLONY.PlotSpacing * (COLONY.PlotGridWidth / 2)
	for _, x in ipairs({ -boundary, 0, boundary }) do
		for _, z in ipairs({ -boundary, boundary }) do
			local radius = rng:nextRange(10, 16)
			PartFactory.block({
				name = "Column",
				size = Vector3.new(radius, height, radius),
				position = Vector3.new(x, COLONY.FloorY + height / 2, z),
				color = ROCK,
				material = Enum.Material.Rock,
				parent = features,
			})
		end
	end

	-- Ambient glow: mushroom fields along the cavern edges.
	local flora = PartFactory.folder("Flora", cavern)
	for _ = 1, 16 do
		local edge = rng:nextInteger(1, 4)
		local along = rng:nextRange(-half + 80, half - 80)
		local inset = rng:nextRange(40, 90)
		local origin
		if edge == 1 then
			origin = Vector3.new(along, COLONY.FloorY, -half + inset)
		elseif edge == 2 then
			origin = Vector3.new(along, COLONY.FloorY, half - inset)
		elseif edge == 3 then
			origin = Vector3.new(-half + inset, COLONY.FloorY, along)
		else
			origin = Vector3.new(half - inset, COLONY.FloorY, along)
		end
		PartFactory.mushrooms({
			origin = origin,
			count = rng:nextInteger(4, 9),
			radius = rng:nextRange(8, 18),
			glowColor = Color3.fromRGB(132, 206, 158),
			rng = rng,
			parent = flora,
		})
	end

	return cavern
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Plot contents
-- ─────────────────────────────────────────────────────────────────────────────

local function buildCampfire(parent, origin, rng)
	local fire = PartFactory.folder("Campfire", parent)

	PartFactory.block({
		name = "FirePit",
		size = Vector3.new(9, 1.2, 9),
		position = origin + Vector3.new(0, 0.6, 0),
		color = Color3.fromRGB(58, 54, 50),
		material = Enum.Material.Slate,
		parent = fire,
	})

	for index = 1, 8 do
		local angle = (index / 8) * math.pi * 2
		PartFactory.decor({
			name = "FireStone",
			size = Vector3.new(2, 1.6, 2),
			cframe = CFrame.new(origin + Vector3.new(math.cos(angle) * 4.2, 1.4, math.sin(angle) * 4.2))
				* CFrame.Angles(0, angle, 0),
			color = Color3.fromRGB(88, 84, 78),
			material = Enum.Material.Slate,
			parent = fire,
		})
	end

	for index = 1, 5 do
		local angle = (index / 5) * math.pi * 2
		PartFactory.decor({
			name = "Log",
			size = Vector3.new(1.4, 5, 1.4),
			cframe = CFrame.new(origin + Vector3.new(math.cos(angle) * 1.4, 2.6, math.sin(angle) * 1.4))
				* CFrame.Angles(math.rad(rng:nextRange(55, 70)), angle, 0),
			color = Color3.fromRGB(72, 54, 38),
			material = Enum.Material.Wood,
			parent = fire,
		})
	end

	--[[ The flame is a single neon part plus one light. A ParticleEmitter is
	     added by the client's atmosphere controller only for nearby fires, so a
	     full server does not pay for nine particle systems at once. ]]
	local flame = PartFactory.glow({
		name = "Flame",
		size = Vector3.new(3.6, 4.4, 3.6),
		position = origin + Vector3.new(0, 3.6, 0),
		shape = Enum.PartType.Ball,
		color = Color3.fromRGB(255, 164, 72),
		lightColor = Color3.fromRGB(255, 176, 96),
		range = 58,
		brightness = 2.4,
		shadows = false,
		parent = fire,
	})
	flame:SetAttribute("IsCampfire", true)

	return fire
end

local function buildCaveEntrance(parent, origin)
	local entrance = PartFactory.folder("CaveEntrance", parent)

	-- Mouth: a dark recess framed by an arch, so it reads as "that way is out".
	PartFactory.arch({
		cframe = CFrame.new(origin + Vector3.new(0, 11, 0)),
		width = 30,
		height = 22,
		depth = 8,
		legWidth = 5,
		color = Color3.fromRGB(78, 72, 64),
		material = Enum.Material.Rock,
		parent = entrance,
	})

	PartFactory.block({
		name = "Darkness",
		size = Vector3.new(24, 20, 2),
		position = origin + Vector3.new(0, 10, -3),
		color = Color3.fromRGB(4, 4, 6),
		material = Enum.Material.SmoothPlastic,
		canCollide = true,
		parent = entrance,
	})

	-- Interaction anchor.
	local anchor = PartFactory.block({
		name = "Anchor",
		size = Vector3.new(10, 8, 6),
		position = origin + Vector3.new(0, 4, 8),
		color = Color3.fromRGB(86, 78, 66),
		material = Enum.Material.Slate,
		transparency = 1,
		canCollide = false,
		parent = entrance,
	})

	PartFactory.prompt(anchor, {
		name = "ExpeditionPrompt",
		actionText = "Prepare Expedition",
		objectText = "Cave Entrance",
		keyCode = Enum.KeyCode.E,
		maxDistance = 16,
		requiresLineOfSight = false,
	})

	PartFactory.lantern({
		origin = origin + Vector3.new(-18, 0, 10),
		height = 12,
		lightColor = Color3.fromRGB(255, 190, 120),
		range = 40,
		parent = entrance,
	})
	PartFactory.lantern({
		origin = origin + Vector3.new(18, 0, 10),
		height = 12,
		lightColor = Color3.fromRGB(255, 190, 120),
		range = 40,
		parent = entrance,
	})

	local _, label = PartFactory.label(anchor, {
		name = "EntranceLabel",
		text = "THE DEEP",
		color = Theme.Color.Accent,
		offset = Vector3.new(0, 7, 0),
		textSize = 18,
		maxDistance = 140,
	})
	label.Font = Theme.Font.Display

	return entrance, anchor
end

local function buildPlot(parent, index)
	local centre = ColonyBuilder.plotCentre(index)
	local plot = PartFactory.folder("Plot_" .. index, parent)
	plot:SetAttribute("PlotIndex", index)

	PartFactory.block({
		name = "Ground",
		size = Vector3.new(COLONY.PlotSize, 2, COLONY.PlotSize),
		position = centre + Vector3.new(0, 1, 0),
		color = GROUND,
		material = Enum.Material.Ground,
		parent = plot,
	})

	-- Low border so the plot boundary is legible without a wall in the way.
	local border = PartFactory.folder("Border", plot)
	local half = COLONY.PlotSize / 2
	local borderSpecs = {
		{ size = Vector3.new(COLONY.PlotSize, 2.4, 3), offset = Vector3.new(0, 1.2, -half) },
		{ size = Vector3.new(COLONY.PlotSize, 2.4, 3), offset = Vector3.new(0, 1.2, half) },
		{ size = Vector3.new(3, 2.4, COLONY.PlotSize), offset = Vector3.new(-half, 1.2, 0) },
		{ size = Vector3.new(3, 2.4, COLONY.PlotSize), offset = Vector3.new(half, 1.2, 0) },
	}
	for _, spec in ipairs(borderSpecs) do
		PartFactory.block({
			name = "BorderEdge",
			size = spec.size,
			position = centre + spec.offset,
			color = Color3.fromRGB(58, 54, 48),
			material = Enum.Material.Slate,
			canCollide = false,
			parent = border,
		})
	end

	--[[ One SpawnLocation per plot, Neutral and disabled. ColonyService enables
	     exactly the claimed owner's spawn, which is how a player lands in their
	     own colony rather than a random one. ]]
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.Position = centre + COLONY.SpawnOffset - Vector3.new(0, 3, 0)
	spawn.Anchored = true
	spawn.CanCollide = true
	spawn.Enabled = false
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Transparency = 0.6
	spawn.Color = Color3.fromRGB(96, 86, 70)
	spawn.Material = Enum.Material.Slate
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = plot

	local rng = Rng.new(1000 + index)
	buildCampfire(plot, centre + Vector3.new(0, 2, 44), rng)
	buildCaveEntrance(plot, centre + COLONY.CaveEntranceOffset + Vector3.new(0, 2, 0))

	PartFactory.folder("Buildings", plot)
	PartFactory.folder("Colonists", plot)

	-- Nameplate, set by ColonyService when the plot is claimed.
	local nameplateAnchor = PartFactory.block({
		name = "Nameplate",
		size = Vector3.new(6, 1, 1),
		position = centre + Vector3.new(0, 10, half - 8),
		transparency = 1,
		canCollide = false,
		canQuery = false,
		parent = plot,
	})
	local _, nameLabel = PartFactory.label(nameplateAnchor, {
		name = "OwnerLabel",
		text = "UNCLAIMED",
		color = Theme.Color.TextMuted,
		offset = Vector3.new(0, 0, 0),
		textSize = 16,
		maxDistance = 260,
	})
	nameLabel.Font = Theme.Font.Heading

	-- Plot lighting so an empty plot is not pitch black.
	for _, offset in ipairs({
		Vector3.new(-half + 30, 0, -half + 30),
		Vector3.new(half - 30, 0, -half + 30),
		Vector3.new(-half + 30, 0, half - 30),
		Vector3.new(half - 30, 0, half - 30),
	}) do
		PartFactory.lantern({
			origin = centre + offset + Vector3.new(0, 2, 0),
			height = 14,
			lightColor = Color3.fromRGB(255, 196, 132),
			range = 62,
			brightness = 1.4,
			parent = plot,
		})
	end

	return plot
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Entry point
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Build the colony once, at server start. Idempotent: if Workspace/Colony
	already exists it is returned untouched, so a hot-reload during development
	does not duplicate the world.

	@return Folder colonyRoot
]]
function ColonyBuilder.build()
	local existing = workspace:FindFirstChild("Colony")
	if existing then
		return existing
	end

	local root = Instance.new("Folder")
	root.Name = "Colony"

	local rng = Rng.new(20240129)
	buildCavern(root, rng)

	local plots = PartFactory.folder("Plots", root)
	for index = 1, COLONY.MaxPlots do
		buildPlot(plots, index)
	end

	root.Parent = workspace
	return root
end

--[[ A claimed plot's ground is warmer than an empty one, so "mine" and
     "nobody's" are distinguishable from across the cavern. ]]
function ColonyBuilder.setPlotClaimed(plot, claimed)
	if not plot then
		return
	end
	local ground = plot:FindFirstChild("Ground")
	if ground then
		ground.Color = claimed and GROUND_OWNED or GROUND
	end
end

function ColonyBuilder.getPlot(index)
	local root = workspace:FindFirstChild("Colony")
	if not root then
		return nil
	end
	local plots = root:FindFirstChild("Plots")
	return plots and plots:FindFirstChild("Plot_" .. index) or nil
end

return ColonyBuilder
