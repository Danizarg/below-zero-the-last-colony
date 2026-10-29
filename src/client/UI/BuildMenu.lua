--[[
	BuildMenu.lua
	Choose a building to place, and manage the ones already standing.

	Two tabs: "Build" lists what can be placed, with costs and lock reasons;
	"Manage" lists what is placed, with upgrade, repair and demolish.

	Picking a building here hands off to BuildController, which owns the
	placement ghost and the world-space controls. This panel never places
	anything itself — it only chooses, which keeps the placement preview in one
	place and the catalogue in another.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local BuildingConfig = require(Shared.Config.BuildingConfig)
local Net = require(Shared.Util.Net)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local Routes = require(Shared.Routes)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local BuildMenu = {}

local TABS = {
	{ id = "build", label = "Build" },
	{ id = "manage", label = "Manage" },
}

local function clearChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function BuildMenu.create(shell, store, buildController)
	local panel = UIKit.panel({
		name = "BuildMenu",
		title = "Construction",
		subtitle = "Place, upgrade and repair",
		onClose = function()
			shell:close()
		end,
	})

	local activeTab = "build"
	local content

	local tabs = UIKit.tabs({
		tabs = TABS,
		parent = panel.body,
		onChange = function(id)
			activeTab = id
			BuildMenu.render(shell, store, buildController, content, activeTab)
		end,
	})
	tabs.root.Position = UDim2.fromOffset(Theme.Space.L, Theme.Space.S)
	tabs.root.Size = UDim2.new(1, -Theme.Space.XL, 0, Theme.MinTouchTarget)

	content = UIKit.scroll({
		name = "Content",
		size = UDim2.new(1, -Theme.Space.XL, 1, -(Theme.MinTouchTarget + Theme.Space.XL)),
		position = UDim2.fromOffset(Theme.Space.L, Theme.MinTouchTarget + Theme.Space.M),
		parent = panel.body,
	})
	UIKit.list(content, { padding = Theme.Space.S })

	store.changed:Connect(function(area)
		if area == "colony" or area == "inventory" then
			shell:refreshIfOpen("build")
		end
	end)

	return {
		root = panel.root,
		refresh = function()
			BuildMenu.render(shell, store, buildController, content, activeTab)
		end,
		onClose = function()
			--[[ Closing the menu does NOT cancel an in-progress placement: the
			     player needs the world visible to choose a spot. ]]
		end,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Build tab
-- ─────────────────────────────────────────────────────────────────────────────

local function renderBuild(shell, store, buildController, container)
	local colony = store.state.colony
	local unlocked = colony and colony.unlocked or {}

	if #unlocked == 0 then
		UIKit.emptyState({ icon = "⚒", text = "Waiting for colony data.", parent = container })
		return
	end

	UIKit.label({
		name = "Hint",
		size = UDim2.new(1, 0, 0, 32),
		text = "Pick a building, then click or tap the ground inside your plot. R rotates, Escape cancels.",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.SmallSize,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		parent = container,
	}).LayoutOrder = 0

	for index, entry in ipairs(unlocked) do
		local def = BuildingConfig.get(entry.id)
		local card = UIKit.frame({
			name = "Building_" .. entry.id,
			size = UDim2.new(1, 0, 0, 0),
			color = Theme.Color.PanelRaised,
			radius = Theme.Radius.M,
			automaticSize = Enum.AutomaticSize.Y,
			parent = container,
		})
		card.LayoutOrder = index
		UIKit.padding(card, Theme.Space.M)
		UIKit.list(card, { padding = Theme.Space.XS })

		UIKit.label({
			name = "Name",
			size = UDim2.new(1, 0, 0, 20),
			text = ("%s  %s%s"):format(
				entry.icon or "⌂",
				entry.name,
				entry.maxCount and ("   %d/%d"):format(entry.count, entry.maxCount) or ""
			),
			textColor = (def and def.palette and def.palette.accent) or Theme.Color.Text,
			textSize = Theme.Text.BodySize,
			font = Theme.Font.Heading,
			parent = card,
		}).LayoutOrder = 1

		UIKit.label({
			name = "Description",
			size = UDim2.new(1, 0, 0, 0),
			text = entry.description or "",
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.TinySize,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			automaticSize = Enum.AutomaticSize.Y,
			parent = card,
		}).LayoutOrder = 2

		UIKit.label({
			name = "Cost",
			size = UDim2.new(1, 0, 0, 18),
			text = ("%d×%d cells   ·   %s"):format(
				entry.footprint and entry.footprint.w or 1,
				entry.footprint and entry.footprint.d or 1,
				UIKit.formatCost(entry.cost, ResourceConfig.Resources, store.state.storage)
			),
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.SmallSize,
			richText = true,
			parent = card,
		}).LayoutOrder = 3

		local button = UIKit.primaryButton({
			name = "Place",
			size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
			text = "Place",
			textSize = Theme.Text.SmallSize,
			parent = card,
			onClick = function()
				buildController:beginPlacement(entry.id)
				shell:close()
			end,
		})
		button.LayoutOrder = 4

		if entry.locked then
			local reason = "Locked"
			if entry.lockReason == "coming_soon" then
				reason = "Not implemented yet"
			elseif entry.lockReason == "requires" then
				reason = "Requires " .. (entry.requiresText or "more progress")
			end
			UIKit.setEnabled(button, false, reason)
		elseif entry.atLimit then
			UIKit.setEnabled(button, false, "You have the maximum of these")
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Manage tab
-- ─────────────────────────────────────────────────────────────────────────────

local function renderManage(shell, store, container)
	local colony = store.state.colony
	local placements = colony and colony.buildings or {}

	if #placements == 0 then
		UIKit.emptyState({ icon = "⌂", text = "Nothing built yet.", parent = container })
		return
	end

	for index, placement in ipairs(placements) do
		local def = BuildingConfig.get(placement.id)
		if not def then
			continue
		end

		local card = UIKit.frame({
			name = "Placed_" .. placement.uid,
			size = UDim2.new(1, 0, 0, 0),
			color = Theme.Color.PanelRaised,
			radius = Theme.Radius.M,
			automaticSize = Enum.AutomaticSize.Y,
			parent = container,
		})
		card.LayoutOrder = index
		UIKit.padding(card, Theme.Space.M)
		UIKit.list(card, { padding = Theme.Space.XS })

		UIKit.label({
			name = "Name",
			size = UDim2.new(1, 0, 0, 20),
			text = ("%s  %s   Lv%d / %d"):format(
				def.icon,
				def.name,
				placement.level or 1,
				placement.maxLevel or #def.levels
			),
			textColor = (def.palette and def.palette.accent) or Theme.Color.Text,
			textSize = Theme.Text.BodySize,
			font = Theme.Font.Heading,
			parent = card,
		}).LayoutOrder = 1

		local healthBar = UIKit.bar({
			name = "Condition",
			size = UDim2.new(1, 0, 0, 10),
			fillColor = Theme.Color.Success,
			textSize = Theme.Text.TinySize,
			parent = card,
		})
		healthBar.root.LayoutOrder = 2
		healthBar.set(placement.health or 0, placement.maxHealth or 1)
		local fraction = (placement.health or 0) / math.max(1, placement.maxHealth or 1)
		healthBar.setColor(fraction > 0.8 and Theme.Color.Success or (fraction > 0.5 and Theme.Color.Warning or Theme.Color.Danger))

		local actions = UIKit.frame({
			name = "Actions",
			size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
			transparency = 1,
			parent = card,
		})
		actions.LayoutOrder = 3
		UIKit.list(actions, { horizontal = true, padding = Theme.Space.XS })

		-- Upgrade.
		local upgradeCost, nextLevel = BuildingConfig.upgradeCost(placement.id, placement.level or 1)
		local upgrade = UIKit.primaryButton({
			name = "Upgrade",
			size = UDim2.new(0.38, 0, 1, 0),
			text = nextLevel and ("Upgrade to Lv%d"):format(nextLevel) or "Max level",
			textSize = Theme.Text.TinySize,
			parent = actions,
			onClick = function()
				local response = Net.request(Routes.Request.UpgradeBuilding, { uid = placement.uid })
				if not response.ok then
					store.notified:Fire({
						kind = "warning",
						title = "Cannot upgrade",
						body = "Not enough resources.",
					})
				end
			end,
		})
		upgrade.LayoutOrder = 1
		if not upgradeCost then
			UIKit.setEnabled(upgrade, false, "Max level")
		end

		-- Repair.
		local repair = UIKit.button({
			name = "Repair",
			size = UDim2.new(0.3, 0, 1, 0),
			text = "Repair",
			textSize = Theme.Text.TinySize,
			parent = actions,
			onClick = function()
				local response = Net.request(Routes.Request.RepairBuilding, { uid = placement.uid })
				if not response.ok and response.detail ~= "not_damaged" then
					store.notified:Fire({
						kind = "warning",
						title = "Cannot repair",
						body = "Not enough resources.",
					})
				end
			end,
		})
		repair.LayoutOrder = 2
		UIKit.setEnabled(repair, fraction < 0.999, "Undamaged")

		-- Demolish. The Town Hall is intentionally not demolishable.
		local demolish = UIKit.button({
			name = "Demolish",
			size = UDim2.new(0.3, -4, 1, 0),
			text = "Demolish",
			textSize = Theme.Text.TinySize,
			color = Theme.Color.Field,
			strokeColor = Theme.Color.Danger,
			parent = actions,
			onClick = function()
				local response = Net.request(Routes.Request.RemoveBuilding, { uid = placement.uid })
				if response.ok then
					store.notified:Fire({
						kind = "info",
						title = "Demolished",
						body = "Half the materials were recovered.",
					})
				else
					store.notified:Fire({
						kind = "warning",
						title = "Cannot demolish",
						body = response.detail == "cannot_demolish" and "The Town Hall holds the colony together."
							or "Refused by the server.",
					})
				end
			end,
		})
		demolish.LayoutOrder = 3
		if def.unique and placement.id == "town_hall" then
			UIKit.setEnabled(demolish, false, "Permanent")
		end

		if upgradeCost then
			UIKit.label({
				name = "UpgradeCost",
				size = UDim2.new(1, 0, 0, 16),
				text = "Upgrade: " .. UIKit.formatCost(upgradeCost, ResourceConfig.Resources, store.state.storage),
				textColor = Theme.Color.TextFaint,
				textSize = Theme.Text.TinySize,
				richText = true,
				parent = card,
			}).LayoutOrder = 4
		end
	end
end

function BuildMenu.render(shell, store, buildController, container, tab)
	clearChildren(container)
	if tab == "build" then
		renderBuild(shell, store, buildController, container)
	else
		renderManage(shell, store, container)
	end
end

return BuildMenu
