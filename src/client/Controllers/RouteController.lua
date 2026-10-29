--[[
	RouteController.lua
	Draws the Runner's Pathfinder route, and marks discovered objectives.

	The server computes the route (so a modified client cannot ask for a path it
	has not earned) and sends a list of world positions. This controller turns
	that into a trail of glowing markers with beams between them, which fades
	when the ability expires.

	Objective markers work the same way: the server only sends a position once
	the room has been discovered, so the marker is a record of exploration rather
	than a solution.
]]


local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local PartFactory = require(Shared.Util.PartFactory)
local Theme = require(Shared.Config.Theme)

local RouteController = {}
RouteController.__index = RouteController

function RouteController.new(store)
	local self = setmetatable({}, RouteController)
	self.store = store
	self._routeFolder = nil
	self._markerFolder = nil
	self._routeToken = 0
	return self
end

function RouteController:_container(name)
	local existing = workspace:FindFirstChild(name)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = workspace
	return folder
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Route trail
-- ─────────────────────────────────────────────────────────────────────────────

function RouteController:clearRoute()
	if self._routeFolder then
		self._routeFolder:Destroy()
		self._routeFolder = nil
	end
end

--[[
	@param positions { Vector3, ... }  room centres from entrance-ward
	@param duration  number            seconds before it fades
]]
function RouteController:showRoute(positions, duration, sharedBy)
	self:clearRoute()

	if not positions or #positions == 0 then
		return
	end

	self._routeToken += 1
	local token = self._routeToken

	local folder = Instance.new("Folder")
	folder.Name = "PathfinderRoute"
	folder.Parent = self:_container("BelowZeroClientFX")
	self._routeFolder = folder

	local previous
	for index, position in ipairs(positions) do
		--[[ The colour runs from the player's position (amber) to the exit
		     (green), so the direction of travel is readable at a glance without
		     reading numbers. ]]
		local alpha = (index - 1) / math.max(1, #positions - 1)
		local color = Theme.Color.Accent:Lerp(Theme.Color.Success, alpha)

		local marker = PartFactory.glow({
			name = "RouteNode",
			size = Vector3.new(2.4, 2.4, 2.4),
			position = position,
			shape = Enum.PartType.Ball,
			color = color,
			lightColor = color,
			range = 24,
			brightness = 1.6,
			light = index % 2 == 1,
			parent = folder,
		})

		local attachment = Instance.new("Attachment")
		attachment.Name = "Node"
		attachment.Parent = marker

		if previous then
			local beam = Instance.new("Beam")
			beam.Attachment0 = previous
			beam.Attachment1 = attachment
			beam.Color = ColorSequence.new(color)
			beam.Width0 = 0.8
			beam.Width1 = 0.8
			beam.LightEmission = 1
			beam.Transparency = NumberSequence.new(0.25)
			beam.FaceCamera = true
			beam.Parent = marker
		end

		previous = attachment
	end

	-- The exit marker gets a label so the end of the trail is unambiguous.
	local last = positions[#positions]
	local exitAnchor = PartFactory.decor({
		name = "RouteExit",
		size = Vector3.new(1, 1, 1),
		position = last + Vector3.new(0, 6, 0),
		transparency = 1,
		parent = folder,
	})
	local _, label = PartFactory.label(exitAnchor, {
		name = "ExitLabel",
		text = "◆ THIS WAY OUT",
		color = Theme.Color.Success,
		offset = Vector3.zero,
		textSize = 16,
		maxDistance = 400,
		alwaysOnTop = true,
	})
	label.Font = Theme.Font.Display

	if sharedBy then
		self.store.notified:Fire({
			kind = "info",
			title = ("%s found the way out"):format(sharedBy),
			body = "Follow the lights.",
			lifetime = 4,
		})
	end

	task.delay(duration or 12, function()
		if token == self._routeToken then
			self:clearRoute()
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Objective markers
-- ─────────────────────────────────────────────────────────────────────────────

function RouteController:markDiscovery(payload)
	if not payload.position then
		return
	end

	local folder = self:_container("BelowZeroClientFX")

	local anchor = PartFactory.glow({
		name = "DiscoveryMarker",
		size = Vector3.new(2, 2, 2),
		position = payload.position + Vector3.new(0, 12, 0),
		shape = Enum.PartType.Ball,
		color = Theme.Color.Accent,
		lightColor = Theme.Color.Accent,
		range = 40,
		brightness = 2,
		parent = folder,
	})

	local _, label = PartFactory.label(anchor, {
		name = "DiscoveryLabel",
		text = payload.title or "Objective",
		color = Theme.Color.Accent,
		offset = Vector3.new(0, 3, 0),
		textSize = 15,
		maxDistance = 500,
		alwaysOnTop = true,
	})
	label.Font = Theme.Font.Heading

	--[[ A revealed objective stays marked for a long while — it is the reward
	     for solving a puzzle — but not forever, or the cave fills with pins. ]]
	task.delay(180, function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function RouteController:start()
	self.store.routeRevealed:Connect(function(payload)
		local positions = {}
		for _, entry in ipairs(payload.positions or {}) do
			if typeof(entry) == "Vector3" then
				table.insert(positions, entry)
			end
		end
		self:showRoute(positions, payload.duration, payload.sharedBy)
	end)

	self.store.discovery:Connect(function(payload)
		self:markDiscovery(payload)
	end)

	--[[ Leaving the caves clears every world marker, so nothing follows the
	     player into the colony. ]]
	self.store.changed:Connect(function(area)
		if area == "zone" and not self.store.inExpedition() then
			self:clearRoute()
			local folder = workspace:FindFirstChild("BelowZeroClientFX")
			if folder then
				folder:ClearAllChildren()
			end
		end
	end)

	return self
end

return RouteController
