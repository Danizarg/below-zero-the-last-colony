--[[
	PartFactory.lua

	Procedural geometry helpers. Every structure in this game — colony buildings,
	cave rooms, props, monster bodies — is assembled from Roblox primitives by
	these functions. There are no external asset dependencies anywhere, so the
	project runs from a fresh Rojo sync with nothing imported.

	Conventions:
	  * Everything is Anchored by default. Unanchored geometry in a procedurally
	    rebuilt cave is a physics explosion waiting to happen.
	  * Decorative parts get CanCollide = false and CanQuery = false so they cost
	    nothing in raycasts or the physics solver.
	  * Interaction uses ProximityPrompt, which gives keyboard, gamepad and touch
	    input for free and keeps prompts off the screen until they are relevant.
]]

local PartFactory = {}

--[[ Decorative geometry is anchored, non-colliding, invisible to raycasts and
     casts no shadow. Opt back in per call where it matters. ]]

-- ─────────────────────────────────────────────────────────────────────────────
-- Primitives
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	@param props {
		name, size (Vector3), cframe (CFrame) or position (Vector3),
		color (Color3), material (Enum.Material), transparency, reflectance,
		anchored, canCollide, canQuery, canTouch, castShadow, shape,
		parent (Instance)
	}
]]
function PartFactory.block(props)
	local part = Instance.new("Part")
	part.Name = props.name or "Block"
	part.Size = props.size or Vector3.new(4, 4, 4)
	part.Anchored = props.anchored ~= false
	part.CanCollide = props.canCollide ~= false
	part.CanQuery = props.canQuery ~= false
	part.CanTouch = props.canTouch == true
	part.CastShadow = props.castShadow ~= false
	part.Color = props.color or Color3.fromRGB(128, 128, 128)
	part.Material = props.material or Enum.Material.Slate
	part.Transparency = props.transparency or 0
	part.Reflectance = props.reflectance or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth

	if props.shape then
		part.Shape = props.shape
	end

	if props.cframe then
		part.CFrame = props.cframe
	elseif props.position then
		part.Position = props.position
	end

	if props.parent then
		part.Parent = props.parent
	end
	return part
end

function PartFactory.decor(props)
	local merged = table.clone(props)
	merged.anchored = props.anchored ~= false
	merged.canCollide = props.canCollide == true
	merged.canQuery = props.canQuery == true
	merged.canTouch = props.canTouch == true
	merged.castShadow = props.castShadow == true
	return PartFactory.block(merged)
end

function PartFactory.cylinder(props)
	local merged = table.clone(props)
	merged.shape = Enum.PartType.Cylinder
	return PartFactory.block(merged)
end

function PartFactory.sphere(props)
	local merged = table.clone(props)
	merged.shape = Enum.PartType.Ball
	return PartFactory.block(merged)
end

function PartFactory.wedge(props)
	local part = Instance.new("WedgePart")
	part.Name = props.name or "Wedge"
	part.Size = props.size or Vector3.new(4, 4, 4)
	part.Anchored = props.anchored ~= false
	part.CanCollide = props.canCollide ~= false
	part.CanQuery = props.canQuery ~= false
	part.CastShadow = props.castShadow ~= false
	part.Color = props.color or Color3.fromRGB(128, 128, 128)
	part.Material = props.material or Enum.Material.Slate
	part.Transparency = props.transparency or 0
	if props.cframe then
		part.CFrame = props.cframe
	elseif props.position then
		part.Position = props.position
	end
	if props.parent then
		part.Parent = props.parent
	end
	return part
end

function PartFactory.model(name, parent)
	local model = Instance.new("Model")
	model.Name = name
	if parent then
		model.Parent = parent
	end
	return model
end

function PartFactory.folder(name, parent)
	local existing = parent and parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	if parent then
		folder.Parent = parent
	end
	return folder
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lighting
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	A glowing part plus an optional PointLight.

	Lights are the single biggest performance lever in a dark game, so the
	default range is modest and shadows are off. Callers that want a hero light
	must opt in explicitly.
]]
function PartFactory.glow(props)
	local part = PartFactory.decor({
		name = props.name or "Glow",
		size = props.size or Vector3.new(2, 2, 2),
		cframe = props.cframe,
		position = props.position,
		color = props.color or Color3.fromRGB(200, 220, 255),
		material = Enum.Material.Neon,
		transparency = props.transparency or 0,
		shape = props.shape,
		parent = props.parent,
	})

	if props.light ~= false then
		local light = Instance.new("PointLight")
		light.Color = props.lightColor or props.color or Color3.fromRGB(200, 220, 255)
		light.Range = props.range or 18
		light.Brightness = props.brightness or 1.2
		light.Shadows = props.shadows == true
		light.Parent = part
	end

	return part
end

function PartFactory.spotLight(parent, props)
	local light = Instance.new("SpotLight")
	light.Color = props.color or Color3.fromRGB(255, 220, 180)
	light.Range = props.range or 40
	light.Brightness = props.brightness or 2
	light.Angle = props.angle or 90
	light.Face = props.face or Enum.NormalId.Bottom
	light.Shadows = props.shadows == true
	light.Parent = parent
	return light
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Walls with doorways
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Build a wall of `length` x `height` centred on `cframe`, with an optional
	doorway gap in the middle.

	The wall is emitted as up to three parts (left, right, lintel) rather than
	one part with a hole, because CSG at runtime is slow and unreliable. Three
	boxes are exact, cheap and trivially rebuilt during a maze shift.

	@param props {
		cframe, length, height, thickness, color, material, parent, name,
		doorway = { width = n, height = n } or nil
	}
	@return { Part, ... }
]]
function PartFactory.wall(props)
	local parts = {}
	local length = props.length or 72
	local height = props.height or 34
	local thickness = props.thickness or 4
	local cframe = props.cframe or CFrame.new()

	local shared = {
		color = props.color or Color3.fromRGB(80, 78, 72),
		material = props.material or Enum.Material.Slate,
		parent = props.parent,
		anchored = true,
		canCollide = true,
		castShadow = props.castShadow ~= false,
	}

	if not props.doorway then
		local part = PartFactory.block({
			name = props.name or "Wall",
			size = Vector3.new(length, height, thickness),
			cframe = cframe,
			color = shared.color,
			material = shared.material,
			parent = shared.parent,
			castShadow = shared.castShadow,
		})
		table.insert(parts, part)
		return parts
	end

	local doorWidth = math.min(props.doorway.width or 20, length - 2)
	local doorHeight = math.min(props.doorway.height or 18, height - 1)
	local sideWidth = (length - doorWidth) / 2

	if sideWidth > 0.05 then
		for _, sign in ipairs({ -1, 1 }) do
			local offsetX = sign * (doorWidth / 2 + sideWidth / 2)
			table.insert(
				parts,
				PartFactory.block({
					name = (props.name or "Wall") .. "Side",
					size = Vector3.new(sideWidth, height, thickness),
					cframe = cframe * CFrame.new(offsetX, 0, 0),
					color = shared.color,
					material = shared.material,
					parent = shared.parent,
					castShadow = shared.castShadow,
				})
			)
		end
	end

	local lintelHeight = height - doorHeight
	if lintelHeight > 0.05 then
		table.insert(
			parts,
			PartFactory.block({
				name = (props.name or "Wall") .. "Lintel",
				size = Vector3.new(doorWidth, lintelHeight, thickness),
				cframe = cframe * CFrame.new(0, (height - lintelHeight) / 2, 0),
				color = shared.color,
				material = shared.material,
				parent = shared.parent,
				castShadow = shared.castShadow,
			})
		)
	end

	return parts
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Interaction
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Attach a ProximityPrompt.

	ProximityPrompt is used rather than a custom click handler because it gives
	keyboard, gamepad and touch input with no extra code, respects line of sight,
	and only draws when the player is close enough to care.

	@param props {
		actionText, objectText, keyCode, holdDuration, maxDistance,
		requiresLineOfSight, exclusivity, enabled, name
	}
]]
function PartFactory.prompt(parent, props)
	props = props or {}
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = props.name or "Prompt"
	prompt.ActionText = props.actionText or "Interact"
	prompt.ObjectText = props.objectText or ""
	prompt.KeyboardKeyCode = props.keyCode or Enum.KeyCode.E
	prompt.GamepadKeyCode = props.gamepadKeyCode or Enum.KeyCode.ButtonX
	prompt.HoldDuration = props.holdDuration or 0
	prompt.MaxActivationDistance = props.maxDistance or 12
	prompt.RequiresLineOfSight = props.requiresLineOfSight ~= false
	prompt.Enabled = props.enabled ~= false
	prompt.Exclusivity = props.exclusivity or Enum.ProximityPromptExclusivity.OnePerButton
	prompt.Style = Enum.ProximityPromptStyle.Default
	prompt.Parent = parent
	return prompt
end

--[[ A floating label above a part. Used for node names, colonist names and
     objective markers. Capped in size so a crowded room stays readable. ]]
function PartFactory.label(parent, props)
	props = props or {}
	local billboard = Instance.new("BillboardGui")
	billboard.Name = props.name or "Label"
	billboard.Size = props.size or UDim2.fromOffset(190, 36)
	billboard.StudsOffsetWorldSpace = props.offset or Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = props.alwaysOnTop == true
	billboard.MaxDistance = props.maxDistance or 90
	billboard.LightInfluence = 0
	billboard.Parent = parent

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = props.font or Enum.Font.GothamBold
	label.Text = props.text or ""
	label.TextColor3 = props.color or Color3.fromRGB(236, 238, 244)
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextStrokeTransparency = 0.35
	label.TextScaled = false
	label.TextSize = props.textSize or 15
	label.Parent = billboard

	return billboard, label
end

--[[ Outline an object for the client. Used by the Runner's trap sense, the
     Pathfinder route and objective markers. ]]
function PartFactory.highlight(parent, props)
	props = props or {}
	local highlight = Instance.new("Highlight")
	highlight.Name = props.name or "Outline"
	highlight.FillColor = props.fillColor or Color3.fromRGB(232, 172, 84)
	highlight.OutlineColor = props.outlineColor or Color3.fromRGB(255, 220, 160)
	highlight.FillTransparency = props.fillTransparency or 0.75
	highlight.OutlineTransparency = props.outlineTransparency or 0
	highlight.DepthMode = props.alwaysOnTop and Enum.HighlightDepthMode.AlwaysOnTop
		or Enum.HighlightDepthMode.Occluded
	highlight.Adornee = parent
	highlight.Parent = parent
	return highlight
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Composite shapes
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Scatter small blocks in a disc. Used for rubble, bones and debris.
	Takes an Rng so a room's clutter is reproducible from the cave seed.
]]
function PartFactory.scatter(props)
	local parts = {}
	local rng = props.rng
	local count = props.count or 5
	local radius = props.radius or 14
	local origin = props.origin or Vector3.zero

	for index = 1, count do
		local angle = rng and rng:nextRange(0, math.pi * 2) or (index / count) * math.pi * 2
		local distance = rng and rng:nextRange(0, radius) or radius * 0.5
		local jitter = rng and rng:nextRange(0.7, 1.4) or 1
		local size = (props.size or Vector3.new(3, 2, 3)) * jitter

		table.insert(
			parts,
			PartFactory.decor({
				name = props.name or "Debris",
				size = size,
				cframe = CFrame.new(
					origin + Vector3.new(math.cos(angle) * distance, size.Y / 2, math.sin(angle) * distance)
				)
					* CFrame.Angles(
						rng and rng:nextRange(-0.3, 0.3) or 0,
						rng and rng:nextRange(0, math.pi * 2) or 0,
						rng and rng:nextRange(-0.3, 0.3) or 0
					),
				color = props.color or Color3.fromRGB(96, 94, 88),
				material = props.material or Enum.Material.Slate,
				parent = props.parent,
			})
		)
	end

	return parts
end

--[[ A cluster of glowing mushrooms: stalk plus cap, optional light on the
     largest one only so a field of mushrooms does not cost a field of lights. ]]
function PartFactory.mushrooms(props)
	local parts = {}
	local rng = props.rng
	local count = props.count or 6
	local radius = props.radius or 12
	local origin = props.origin or Vector3.zero
	local glowColor = props.glowColor or Color3.fromRGB(150, 220, 170)
	local litIndex = 1

	for index = 1, count do
		local angle = rng and rng:nextRange(0, math.pi * 2) or (index / count) * math.pi * 2
		local distance = rng and rng:nextRange(1, radius) or radius * 0.6
		local scale = rng and rng:nextRange(0.6, 1.6) or 1
		local base = origin + Vector3.new(math.cos(angle) * distance, 0, math.sin(angle) * distance)
		local stalkHeight = 2.4 * scale

		table.insert(
			parts,
			PartFactory.decor({
				name = "Stalk",
				size = Vector3.new(0.7 * scale, stalkHeight, 0.7 * scale),
				position = base + Vector3.new(0, stalkHeight / 2, 0),
				color = Color3.fromRGB(214, 210, 196),
				material = Enum.Material.Fabric,
				parent = props.parent,
			})
		)

		local cap = PartFactory.glow({
			name = "Cap",
			size = Vector3.new(2.2 * scale, 1.1 * scale, 2.2 * scale),
			position = base + Vector3.new(0, stalkHeight + 0.4 * scale, 0),
			shape = Enum.PartType.Ball,
			color = glowColor,
			lightColor = glowColor,
			range = 14 * scale,
			brightness = 0.6,
			light = index == litIndex,
			parent = props.parent,
		})
		table.insert(parts, cap)
	end

	return parts
end

--[[ A simple post lantern: pole, housing, light. The warm reference point that
     makes the dark readable. ]]
function PartFactory.lantern(props)
	local parts = {}
	local origin = props.origin or Vector3.zero
	local height = props.height or 11
	local lightColor = props.lightColor or Color3.fromRGB(255, 196, 128)

	table.insert(
		parts,
		PartFactory.block({
			name = "LanternPost",
			size = Vector3.new(0.6, height, 0.6),
			position = origin + Vector3.new(0, height / 2, 0),
			color = Color3.fromRGB(72, 62, 50),
			material = Enum.Material.Wood,
			canCollide = false,
			parent = props.parent,
		})
	)

	table.insert(
		parts,
		PartFactory.glow({
			name = "LanternFlame",
			size = Vector3.new(1.4, 1.8, 1.4),
			position = origin + Vector3.new(0, height, 0),
			color = lightColor,
			lightColor = lightColor,
			range = props.range or 34,
			brightness = props.brightness or 1.6,
			shadows = props.shadows == true,
			parent = props.parent,
		})
	)

	return parts
end

--[[ A rectangular arch: two legs and a span. Entrances and gates. ]]
function PartFactory.arch(props)
	local parts = {}
	local cframe = props.cframe or CFrame.new()
	local width = props.width or 24
	local height = props.height or 20
	local depth = props.depth or 4
	local legWidth = props.legWidth or 3
	local color = props.color or Color3.fromRGB(88, 82, 74)
	local material = props.material or Enum.Material.Rock

	for _, sign in ipairs({ -1, 1 }) do
		table.insert(
			parts,
			PartFactory.block({
				name = "ArchLeg",
				size = Vector3.new(legWidth, height, depth),
				cframe = cframe * CFrame.new(sign * (width / 2 - legWidth / 2), 0, 0),
				color = color,
				material = material,
				parent = props.parent,
			})
		)
	end

	table.insert(
		parts,
		PartFactory.block({
			name = "ArchSpan",
			size = Vector3.new(width, legWidth, depth),
			cframe = cframe * CFrame.new(0, height / 2 + legWidth / 2, 0),
			color = color,
			material = material,
			parent = props.parent,
		})
	)

	return parts
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cleanup
-- ─────────────────────────────────────────────────────────────────────────────

--[[ Destroy children matching a name prefix. Used by the maze shift to tear
     down only the walls of a changed room, never its floor, so a player
     standing in that room never loses the ground under them. ]]
function PartFactory.destroyByPrefix(container, prefix)
	if not container then
		return 0
	end
	local destroyed = 0
	for _, child in ipairs(container:GetChildren()) do
		if string.sub(child.Name, 1, #prefix) == prefix then
			child:Destroy()
			destroyed += 1
		end
	end
	return destroyed
end

return PartFactory
