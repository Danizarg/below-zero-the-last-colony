--[[
	BuildController.lua
	The placement ghost.

	Picking a building in the BuildMenu starts a placement. A translucent
	footprint follows the cursor, snapped to the colony build grid, green where
	the server will accept it and red where it will not. Clicking sends the grid
	coordinates; R rotates; Escape cancels.

	The client's validity check is a courtesy, not a decision. It uses the same
	PlotGrid maths and the same placement list the server has, so the ghost is
	accurate — but BuildingService re-validates everything, and a client that
	lies about a position simply gets refused.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local BuildingConfig = require(Shared.Config.BuildingConfig)
local Enums = require(Shared.Enums)
local Net = require(Shared.Util.Net)
local PlotGrid = require(Shared.Lib.PlotGrid)
local Routes = require(Shared.Routes)
local Theme = require(Shared.Config.Theme)

local BuildController = {}
BuildController.__index = BuildController

local VALID_COLOR = Color3.fromRGB(118, 206, 146)
local INVALID_COLOR = Color3.fromRGB(226, 78, 78)
local GRID_STEP = PlotGrid.gridStep()

function BuildController.new(store, shell, uiKit)
	local self = setmetatable({}, BuildController)
	self.store = store
	self.shell = shell
	self.UIKit = uiKit
	self.player = Players.LocalPlayer

	self.active = nil -- { buildingId, rotation, gx, gz, valid }
	self._ghost = nil
	self._gridLines = nil
	self._banner = nil
	self._connection = nil

	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Ghost geometry
-- ─────────────────────────────────────────────────────────────────────────────

function BuildController:_buildGhost(buildingId, rotation)
	self:_destroyGhost()

	local def = BuildingConfig.get(buildingId)
	if not def then
		return
	end

	local w, d = PlotGrid.rotatedFootprint(def.footprint, rotation)

	local model = Instance.new("Model")
	model.Name = "PlacementGhost"

	--[[ A flat footprint plus a low volume: the footprint shows exactly which
	     cells are claimed, and the volume gives a sense of the building's bulk
	     without pretending to be the finished model. ]]
	local pad = Instance.new("Part")
	pad.Name = "Footprint"
	pad.Size = Vector3.new(w * GRID_STEP, 0.4, d * GRID_STEP)
	pad.Anchored = true
	pad.CanCollide = false
	pad.CanQuery = false
	pad.CastShadow = false
	pad.Material = Enum.Material.Neon
	pad.Color = VALID_COLOR
	pad.Transparency = 0.5
	pad.Parent = model

	local volume = Instance.new("Part")
	volume.Name = "Volume"
	volume.Size = Vector3.new(w * GRID_STEP, def.height, d * GRID_STEP)
	volume.Anchored = true
	volume.CanCollide = false
	volume.CanQuery = false
	volume.CastShadow = false
	volume.Material = Enum.Material.ForceField
	volume.Color = VALID_COLOR
	volume.Transparency = 0.75
	volume.Parent = model

	--[[ A facing marker, because rotation is invisible on a symmetrical
	     footprint and the doorway is on the +Z face. ]]
	local facing = Instance.new("Part")
	facing.Name = "Facing"
	facing.Size = Vector3.new(math.min(6, w * GRID_STEP * 0.5), 0.6, 2)
	facing.Anchored = true
	facing.CanCollide = false
	facing.CanQuery = false
	facing.CastShadow = false
	facing.Material = Enum.Material.Neon
	facing.Color = Theme.Color.Accent
	facing.Transparency = 0.2
	facing.Parent = model

	model.PrimaryPart = pad
	model.Parent = workspace

	self._ghost = { model = model, pad = pad, volume = volume, facing = facing, w = w, d = d, height = def.height }
end

function BuildController:_destroyGhost()
	if self._ghost then
		self._ghost.model:Destroy()
		self._ghost = nil
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Validity
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Would the server accept this placement? Mirrors BuildingService's geometry
	checks against the colony snapshot the client already holds.
]]
function BuildController:_validate(gx, gz)
	local active = self.active
	local colony = self.store.state.colony
	if not active or not colony then
		return false, "no_colony"
	end

	local def = BuildingConfig.get(active.buildingId)
	if not def then
		return false, "unknown"
	end

	local w, d = PlotGrid.rotatedFootprint(def.footprint, active.rotation)
	if not PlotGrid.footprintInBounds(gx, gz, w, d) then
		return false, "outside your plot"
	end

	local candidate = PlotGrid.rect(gx, gz, w, d)
	for _, placement in ipairs(colony.buildings or {}) do
		local otherDef = BuildingConfig.get(placement.id)
		if otherDef then
			local ow, od = PlotGrid.rotatedFootprint(otherDef.footprint, placement.rot or 0)
			if PlotGrid.overlaps(candidate, PlotGrid.rect(placement.gx, placement.gz, ow, od)) then
				return false, "overlaps " .. otherDef.name
			end
		end
	end

	-- Affordability, from the storage snapshot.
	local levelData = def.levels[1]
	for resourceId, amount in pairs(levelData.cost or {}) do
		if (self.store.state.storage[resourceId] or 0) < amount then
			return false, "not enough resources"
		end
	end

	return true
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Cursor to grid
-- ─────────────────────────────────────────────────────────────────────────────

function BuildController:_cursorGrid()
	local camera = workspace.CurrentCamera
	local colony = self.store.state.colony
	if not camera or not colony or not colony.plotIndex then
		return nil
	end

	local screenPosition
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		screenPosition = camera.ViewportSize / 2
	else
		screenPosition = UserInputService:GetMouseLocation()
	end

	local ray = camera:ViewportPointToRay(screenPosition.X, screenPosition.Y)

	--[[ Intersect the ray with the plot's ground plane analytically rather than
	     raycasting: a raycast would hit the ghost, existing buildings or a
	     colonist and make the preview jump. ]]
	local planeY = PlotGrid.plotCentre(colony.plotIndex).Y + 2
	if math.abs(ray.Direction.Y) < 1e-4 then
		return nil
	end
	local distance = (planeY - ray.Origin.Y) / ray.Direction.Y
	if distance < 0 or distance > 2000 then
		return nil
	end
	local hit = ray.Origin + ray.Direction * distance

	local def = BuildingConfig.get(self.active.buildingId)
	local w, d = PlotGrid.rotatedFootprint(def and def.footprint, self.active.rotation)
	local gx, gz = PlotGrid.worldToGrid(colony.plotIndex, hit, w, d)
	return gx, gz
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Banner
-- ─────────────────────────────────────────────────────────────────────────────

function BuildController:_showBanner(buildingId)
	local UIKit = self.UIKit
	self:_hideBanner()

	local def = BuildingConfig.get(buildingId)

	local banner = UIKit.frame({
		name = "PlacementBanner",
		size = UDim2.new(0, 480, 0, 76),
		position = UDim2.new(0.5, 0, 0, 90),
		anchor = Vector2.new(0.5, 0),
		color = Theme.Color.Backdrop,
		transparency = 0.1,
		radius = Theme.Radius.M,
		stroke = true,
		strokeColor = Theme.Color.Accent,
		zIndex = Theme.ZIndex.Toast,
		parent = self.shell.criticalHost,
	})
	UIKit.padding(banner, Theme.Space.S)

	UIKit.label({
		name = "Title",
		size = UDim2.new(1, 0, 0, 20),
		text = ("PLACING %s"):format(string.upper(def and def.name or buildingId)),
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.BodySize,
		font = Theme.Font.Heading,
		align = Enum.TextXAlignment.Center,
		parent = banner,
	})

	local status = UIKit.label({
		name = "Status",
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 20),
		text = "",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.SmallSize,
		align = Enum.TextXAlignment.Center,
		parent = banner,
	})

	local controls = UIKit.frame({
		name = "Controls",
		size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
		position = UDim2.fromOffset(0, 36),
		transparency = 1,
		parent = banner,
	})
	UIKit.list(controls, { horizontal = true, padding = Theme.Space.XS, horizontalAlign = Enum.HorizontalAlignment.Center })

	UIKit.button({
		name = "Rotate",
		size = UDim2.fromOffset(120, 36),
		text = "Rotate  [R]",
		textSize = Theme.Text.TinySize,
		parent = controls,
		onClick = function()
			self:rotate()
		end,
	}).LayoutOrder = 1

	UIKit.primaryButton({
		name = "Confirm",
		size = UDim2.fromOffset(120, 36),
		text = "Place",
		textSize = Theme.Text.TinySize,
		parent = controls,
		onClick = function()
			self:confirm()
		end,
	}).LayoutOrder = 2

	UIKit.button({
		name = "Cancel",
		size = UDim2.fromOffset(120, 36),
		text = "Cancel  [Esc]",
		textSize = Theme.Text.TinySize,
		parent = controls,
		onClick = function()
			self:cancel()
		end,
	}).LayoutOrder = 3

	self._banner = banner
	self._bannerStatus = status
end

function BuildController:_hideBanner()
	if self._banner then
		self._banner:Destroy()
		self._banner = nil
		self._bannerStatus = nil
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Placement lifecycle
-- ─────────────────────────────────────────────────────────────────────────────

function BuildController:beginPlacement(buildingId)
	if self.store.inExpedition() then
		self.store.notified:Fire({
			kind = "warning",
			title = "Not down here",
			body = "You can only build in your colony.",
		})
		return
	end

	self.active = { buildingId = buildingId, rotation = 0, gx = 0, gz = 0, valid = false }
	self:_buildGhost(buildingId, 0)
	self:_showBanner(buildingId)

	if not self._connection then
		self._connection = RunService.RenderStepped:Connect(function()
			self:_update()
		end)
	end
end

function BuildController:rotate()
	if not self.active then
		return
	end
	self.active.rotation = (self.active.rotation + 90) % 360
	self:_buildGhost(self.active.buildingId, self.active.rotation)
end

function BuildController:cancel()
	self.active = nil
	self:_destroyGhost()
	self:_hideBanner()
	if self._connection then
		self._connection:Disconnect()
		self._connection = nil
	end
end

function BuildController:confirm()
	local active = self.active
	if not active then
		return
	end
	if not active.valid then
		self.store.notified:Fire({
			kind = "warning",
			title = "Cannot place here",
			body = active.reason and ("That spot " .. active.reason .. ".") or "Pick another spot.",
			lifetime = 3,
		})
		return
	end

	local response = Net.request(Routes.Request.PlaceBuilding, {
		buildingId = active.buildingId,
		gx = active.gx,
		gz = active.gz,
		rot = active.rotation,
	})

	if response.ok then
		local def = BuildingConfig.get(active.buildingId)
		self.store.notified:Fire({
			kind = "success",
			title = "Built",
			body = def and def.name or active.buildingId,
		})
		self:cancel()
	else
		local body = "The server refused that placement."
		if response.reason == Enums.Reject.NotEnoughResources then
			body = "Not enough resources."
		elseif response.reason == Enums.Reject.Occupied then
			body = "Something is already there."
		elseif response.reason == Enums.Reject.TooFar then
			body = "That is outside your plot."
		elseif response.reason == Enums.Reject.LimitReached then
			body = response.detail == "building_limit" and "You have the maximum of these."
				or "Your plot is full."
		elseif response.reason == Enums.Reject.NoPermission then
			body = "You do not have the prerequisites, or this is not your colony."
		elseif response.reason == Enums.Reject.NotImplemented then
			body = "That building is not implemented yet."
		end
		self.store.notified:Fire({ kind = "warning", title = "Cannot build", body = body })
	end
end

function BuildController:_update()
	local active = self.active
	if not active or not self._ghost then
		return
	end

	local gx, gz = self:_cursorGrid()
	if not gx then
		return
	end

	active.gx, active.gz = gx, gz
	local valid, reason = self:_validate(gx, gz)
	active.valid = valid
	active.reason = reason

	local colony = self.store.state.colony
	local world = PlotGrid.gridToWorld(colony.plotIndex, gx, gz)
	local pivot = CFrame.new(world) * CFrame.Angles(0, math.rad(active.rotation), 0)

	local ghost = self._ghost
	ghost.pad.CFrame = pivot * CFrame.new(0, 0.2, 0)
	ghost.volume.CFrame = pivot * CFrame.new(0, ghost.height / 2, 0)
	ghost.facing.CFrame = pivot * CFrame.new(0, 0.5, ghost.d * GRID_STEP / 2 - 1)

	local color = valid and VALID_COLOR or INVALID_COLOR
	ghost.pad.Color = color
	ghost.volume.Color = color

	if self._bannerStatus then
		self._bannerStatus.Text = valid and "Looks good. Place it."
			or ("Cannot place: " .. tostring(reason or "blocked"))
		self._bannerStatus.TextColor3 = valid and Theme.Color.Success or Theme.Color.Danger
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Input
-- ─────────────────────────────────────────────────────────────────────────────

function BuildController:start()
	UserInputService.InputBegan:Connect(function(input, processed)
		if not self.active then
			return
		end

		if input.KeyCode == Enum.KeyCode.Escape then
			self:cancel()
			return
		end
		if input.KeyCode == Enum.KeyCode.R then
			self:rotate()
			return
		end

		--[[ `processed` is true when the click landed on the UI, which is how the
		     banner's own buttons avoid also placing a building. ]]
		if processed then
			return
		end
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			self:confirm()
		end
	end)

	--[[ Leaving the colony cancels any placement in progress. ]]
	self.store.changed:Connect(function(area)
		if area == "zone" and self.store.inExpedition() and self.active then
			self:cancel()
		end
	end)

	return self
end

return BuildController
