--[[
	ColonyHUD.lua
	The always-on readout while the player is in their colony.

	Shows: colony name and level, stored resources, population, food production,
	and the current objective. Hidden entirely during an expedition, where the
	ExpeditionHUD takes over.

	Resource chips are created once and updated in place rather than rebuilt on
	every ColonySync, because the colony syncs every production tick and
	rebuilding a dozen frames every ten seconds is wasteful and makes the UI
	flicker.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local ColonyHUD = {}
ColonyHUD.__index = ColonyHUD

--[[ Resources worth a permanent slot on screen. The rest live in the inventory
     panel; eight chips is already the limit of what reads at a glance. ]]
local PINNED = {
	Enums.Resource.Stone,
	Enums.Resource.Fiber,
	Enums.Resource.Iron,
	Enums.Resource.Coal,
	Enums.Resource.Mushroom,
	Enums.Resource.Herb,
	Enums.Resource.Crystal,
	Enums.Resource.Relic,
}

function ColonyHUD.new(shell, store)
	local self = setmetatable({}, ColonyHUD)
	self.shell = shell
	self.store = store
	self._chips = {}

	self.root = UIKit.frame({
		name = "ColonyHUD",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
		parent = shell.hudHost,
	})

	-- ── Colony identity, top-left ───────────────────────────────────────────
	local header = UIKit.frame({
		name = "Header",
		size = UDim2.new(0, 280, 0, 62),
		position = UDim2.fromOffset(Theme.Space.M, Theme.Space.M + 36),
		color = Theme.Color.Backdrop,
		transparency = 0.15,
		radius = Theme.Radius.M,
		stroke = true,
		strokeTransparency = 0.5,
		parent = self.root,
	})
	UIKit.padding(header, Theme.Space.S)

	self.colonyName = UIKit.label({
		name = "Name",
		size = UDim2.new(1, 0, 0, 22),
		text = "—",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.SubheadingSize,
		font = Theme.Font.Display,
		truncate = true,
		parent = header,
	})

	self.colonySub = UIKit.label({
		name = "Sub",
		size = UDim2.new(1, 0, 0, 16),
		position = UDim2.fromOffset(0, 24),
		text = "",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.SmallSize,
		parent = header,
	})

	self.conditionBar = UIKit.bar({
		name = "Condition",
		size = UDim2.new(1, 0, 0, 6),
		position = UDim2.fromOffset(0, 44),
		fillColor = Theme.Color.Success,
		showText = false,
		parent = header,
	})
	self.conditionBar.root.Position = UDim2.fromOffset(0, 44)

	-- ── Resource strip, top-centre ──────────────────────────────────────────
	local strip = UIKit.frame({
		name = "Resources",
		size = UDim2.new(0, 0, 0, 38),
		position = UDim2.new(0.5, 0, 0, Theme.Space.M + 36),
		anchor = Vector2.new(0.5, 0),
		color = Theme.Color.Backdrop,
		transparency = 0.15,
		radius = Theme.Radius.M,
		stroke = true,
		strokeTransparency = 0.5,
		automaticSize = Enum.AutomaticSize.X,
		parent = self.root,
	})
	UIKit.padding(strip, Theme.Space.XS)
	UIKit.list(
		strip,
		{ horizontal = true, padding = Theme.Space.XS, verticalAlign = Enum.VerticalAlignment.Center }
	)
	self.strip = strip

	for index, resourceId in ipairs(PINNED) do
		local def = ResourceConfig.get(resourceId)
		local chip = UIKit.resourceChip({
			id = resourceId,
			icon = def and def.icon or "•",
			iconColor = def and def.color or Theme.Color.Accent,
			count = 0,
			size = UDim2.fromOffset(84, 28),
			parent = strip,
		})
		chip.root.LayoutOrder = index
		self._chips[resourceId] = chip
	end

	self.capacityLabel = UIKit.label({
		name = "Capacity",
		size = UDim2.new(0, 220, 0, 16),
		position = UDim2.new(0.5, 0, 0, Theme.Space.M + 78),
		anchor = Vector2.new(0.5, 0),
		text = "",
		textColor = Theme.Color.TextFaint,
		textSize = Theme.Text.TinySize,
		align = Enum.TextXAlignment.Center,
		parent = self.root,
	})

	-- ── Objective card, top-right ───────────────────────────────────────────
	local objective = UIKit.frame({
		name = "Objective",
		size = UDim2.new(0, 260, 0, 0),
		position = UDim2.new(1, -Theme.Space.M, 0, Theme.Space.M + 36),
		anchor = Vector2.new(1, 0),
		color = Theme.Color.Backdrop,
		transparency = 0.15,
		radius = Theme.Radius.M,
		stroke = true,
		strokeTransparency = 0.5,
		automaticSize = Enum.AutomaticSize.Y,
		parent = self.root,
	})
	UIKit.padding(objective, Theme.Space.S)
	UIKit.list(objective, { padding = 2 })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 16),
		text = "NEXT",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = objective,
	}).LayoutOrder =
		1

	self.objectiveText = UIKit.label({
		name = "Text",
		size = UDim2.new(1, 0, 0, 0),
		text = "Getting your bearings.",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.SmallSize,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		automaticSize = Enum.AutomaticSize.Y,
		parent = objective,
	})
	self.objectiveText.LayoutOrder = 2

	self.readOnlyWarning = UIKit.label({
		name = "ReadOnly",
		size = UDim2.new(1, 0, 0, 0),
		text = "",
		textColor = Theme.Color.Danger,
		textSize = Theme.Text.TinySize,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		automaticSize = Enum.AutomaticSize.Y,
		visible = false,
		parent = objective,
	})
	self.readOnlyWarning.LayoutOrder = 3

	self:_wire()
	self:refresh()
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Objective text
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	A single "what should I do next" line, derived from colony state.

	This is the onboarding. A new player who reads nothing else should still
	know where to go, which is why the order below runs from the most basic
	action to the most advanced.
]]
function ColonyHUD:_nextObjective(colony)
	if not colony then
		return "Waiting for your colony to load."
	end

	local buildings = {}
	for _, placement in ipairs(colony.buildings or {}) do
		buildings[placement.id] = math.max(buildings[placement.id] or 0, placement.level)
	end

	if not buildings[Enums.Building.Housing] then
		return "Build a Shelter so more colonists can join you. Press B."
	end

	local unassigned = (colony.jobUsage and colony.jobUsage[Enums.Job.Idle]) or 0
	if not buildings[Enums.Building.Farm] then
		return "Build a Fungal Farm to feed the colony. Press B."
	end
	if unassigned > 0 then
		return ("%d colonist%s have no work. Assign them in the Colony panel."):format(
			unassigned,
			unassigned == 1 and "" or "s"
		)
	end
	if (colony.colonyLevel or 1) < 2 then
		return "Upgrade the Town Hall to unlock the Workshop. Press B."
	end
	if not buildings[Enums.Building.Workshop] then
		return "Build a Workshop, then craft a Stone Pick before heading down."
	end
	if (colony.keys or 0) < 1 then
		return "Take an expedition and bring back an Ancient Key. Press X."
	end
	if (colony.gateStages or 0) < 1 then
		return "Find the Ancient Vault and open the First Gate."
	end
	return "Expand the colony and push deeper. Press X for expeditions."
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Refresh
-- ─────────────────────────────────────────────────────────────────────────────

function ColonyHUD:refresh()
	local state = self.store.state
	local colony = state.colony

	self.root.Visible = state.zone == Enums.Zone.Colony

	if colony then
		self.colonyName.Text = colony.colonyName or "New Hollow"
		self.colonySub.Text = ("Colony Lv%d  ·  %d/%d colonists  ·  %d food"):format(
			colony.colonyLevel or 1,
			colony.population or 0,
			colony.populationCap or 0,
			math.floor(colony.food or 0)
		)
		self.conditionBar.set(colony.condition or 100, 100)
		self.conditionBar.setColor(
			(colony.condition or 100) >= 80 and Theme.Color.Success
				or ((colony.condition or 100) >= 60 and Theme.Color.Warning or Theme.Color.Danger)
		)
	end

	for resourceId, chip in pairs(self._chips) do
		local amount = state.storage[resourceId] or 0
		chip.count.Text = amount >= 1000 and ("%.1fk"):format(amount / 1000) or tostring(amount)
		--[[ Dim a resource the player has none of, so the strip reads as "what I
		     have" rather than a list of everything that exists. ]]
		chip.root.BackgroundTransparency = amount > 0 and 0.25 or 0.6
		chip.count.TextTransparency = amount > 0 and 0 or 0.5
	end

	if state.storageCapacity > 0 then
		local fraction = state.storageUsed / state.storageCapacity
		self.capacityLabel.Text = ("Storage %d / %d"):format(state.storageUsed, state.storageCapacity)
		self.capacityLabel.TextColor3 = fraction > 0.92 and Theme.Color.Danger
			or (fraction > 0.75 and Theme.Color.Warning or Theme.Color.TextFaint)
	else
		self.capacityLabel.Text = ""
	end

	self.objectiveText.Text = self:_nextObjective(colony)

	if state.readOnly then
		self.readOnlyWarning.Visible = true
		self.readOnlyWarning.Text = "Your save is read-only this session: another server still holds it. "
			.. "Progress will not be kept. Try rejoining in a minute."
	elseif state.degraded then
		--[[ Different cause, same consequence, and the player should hear about
		     it before they invest an hour in the session. ]]
		self.readOnlyWarning.Visible = true
		self.readOnlyWarning.Text = "Saving is currently unavailable, so progress may not be kept. "
			.. "The server is retrying; rejoining later is safest."
	else
		self.readOnlyWarning.Visible = false
	end
end

function ColonyHUD:_wire()
	self.store.changed:Connect(function(area)
		if area == "colony" or area == "inventory" or area == "zone" or area == "meta" then
			self:refresh()
		end
	end)
end

return ColonyHUD
