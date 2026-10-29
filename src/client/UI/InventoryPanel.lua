--[[
	InventoryPanel.lua
	What you are carrying, and what is in the colony store.

	The panel shows whichever inventory is relevant: the expedition bag
	underground, colony storage at home. That is a deliberate choice — showing
	both at once invites the question "why can't I reach my storage from down
	here", and the answer is that you cannot.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Net = require(Shared.Util.Net)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local Routes = require(Shared.Routes)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local InventoryPanel = {}

local function clearChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function InventoryPanel.create(shell, store)
	local panel = UIKit.panel({
		name = "InventoryPanel",
		title = "Inventory",
		onClose = function()
			shell:close()
		end,
	})

	local content = UIKit.scroll({
		name = "Content",
		size = UDim2.new(1, -Theme.Space.XL, 1, -Theme.Space.XL),
		position = UDim2.fromOffset(Theme.Space.L, Theme.Space.M),
		parent = panel.body,
	})
	UIKit.list(content, { padding = Theme.Space.S })

	store.changed:Connect(function(area)
		if area == "inventory" or area == "zone" then
			shell:refreshIfOpen("inventory")
		end
	end)

	return {
		root = panel.root,
		refresh = function()
			InventoryPanel.render(shell, store, content)
		end,
	}
end

function InventoryPanel.render(shell, store, container)
	clearChildren(container)

	local inExpedition = store.inExpedition()
	local items, consumables, used, capacity = store.currentInventory()

	-- Header: which inventory, and how full.
	local header = UIKit.frame({
		name = "Header",
		size = UDim2.new(1, 0, 0, 56),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		parent = container,
	})
	header.LayoutOrder = 1
	UIKit.padding(header, Theme.Space.M)

	UIKit.label({
		name = "Title",
		size = UDim2.new(1, 0, 0, 18),
		text = inExpedition and "EXPEDITION BAG" or "COLONY STORAGE",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = header,
	})

	local bar = UIKit.bar({
		name = "Capacity",
		size = UDim2.new(1, 0, 0, 12),
		fillColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		parent = header,
	})
	bar.root.Position = UDim2.fromOffset(0, 22)
	bar.set(
		used or 0,
		math.max(1, capacity or 1),
		inExpedition and ("%d / %d weight"):format(math.floor(used or 0), math.floor(capacity or 0))
			or ("%d / %d units"):format(math.floor(used or 0), math.floor(capacity or 0))
	)

	-- Resources, in config order so the list never reshuffles.
	local anyItems = false
	for index, resourceId in ipairs(ResourceConfig.Order) do
		local count = items[resourceId] or 0
		if count > 0 then
			anyItems = true
			local def = ResourceConfig.get(resourceId)
			local row = UIKit.frame({
				name = "Item_" .. resourceId,
				size = UDim2.new(1, 0, 0, 44),
				color = Theme.Color.PanelRaised,
				radius = Theme.Radius.S,
				parent = container,
			})
			row.LayoutOrder = 10 + index
			UIKit.padding(row, Theme.Space.S)

			UIKit.label({
				name = "Icon",
				size = UDim2.fromOffset(28, 28),
				text = def.icon,
				textColor = def.color,
				textSize = Theme.Text.SubheadingSize,
				align = Enum.TextXAlignment.Center,
				parent = row,
			})

			UIKit.label({
				name = "Name",
				size = UDim2.new(1, -120, 0, 16),
				position = UDim2.fromOffset(34, 0),
				text = def.name,
				textColor = ResourceConfig.RarityColor[def.rarity] or Theme.Color.Text,
				textSize = Theme.Text.SmallSize,
				font = Theme.Font.Heading,
				parent = row,
			})

			UIKit.label({
				name = "Uses",
				size = UDim2.new(1, -120, 0, 14),
				position = UDim2.fromOffset(34, 15),
				text = table.concat(def.uses or {}, ", "),
				textColor = Theme.Color.TextFaint,
				textSize = Theme.Text.TinySize,
				truncate = true,
				parent = row,
			})

			UIKit.label({
				name = "Count",
				size = UDim2.fromOffset(80, 28),
				position = UDim2.new(1, -80, 0, 0),
				text = tostring(count),
				textColor = Theme.Color.Text,
				textSize = Theme.Text.SubheadingSize,
				font = Theme.Font.Mono,
				align = Enum.TextXAlignment.Right,
				parent = row,
			})
		end
	end

	if not anyItems then
		UIKit.emptyState({
			icon = "▤",
			text = inExpedition and "Your bag is empty. Find something worth carrying."
				or "Nothing in storage. Take an expedition.",
			parent = container,
		}).LayoutOrder = 20
	end

	-- Consumables, which are usable from here.
	for consumableId, count in pairs(consumables or {}) do
		local def = ResourceConfig.Consumables[consumableId]
		if def and count > 0 then
			local card = UIKit.frame({
				name = "Consumable_" .. consumableId,
				size = UDim2.new(1, 0, 0, 0),
				color = Theme.Color.PanelRaised,
				radius = Theme.Radius.M,
				automaticSize = Enum.AutomaticSize.Y,
				parent = container,
			})
			card.LayoutOrder = 100
			UIKit.padding(card, Theme.Space.M)
			UIKit.list(card, { padding = Theme.Space.XS })

			UIKit.label({
				name = "Name",
				size = UDim2.new(1, 0, 0, 18),
				text = ("%s %s  ×%d"):format(def.icon, def.name, count),
				textColor = Theme.Color.Text,
				textSize = Theme.Text.BodySize,
				font = Theme.Font.Heading,
				parent = card,
			}).LayoutOrder = 1

			UIKit.label({
				name = "Effect",
				size = UDim2.new(1, 0, 0, 16),
				text = def.description,
				textColor = Theme.Color.TextMuted,
				textSize = Theme.Text.TinySize,
				parent = card,
			}).LayoutOrder = 2

			local use = UIKit.primaryButton({
				name = "Use",
				size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
				text = "Use",
				textSize = Theme.Text.SmallSize,
				parent = card,
				onClick = function()
					local response = Net.request(Routes.Request.UseConsumable, { consumableId = consumableId })
					if not response.ok then
						store.notified:Fire({
							kind = "warning",
							title = "Cannot use that",
							body = "None left, or not right now.",
						})
					end
				end,
			})
			use.LayoutOrder = 3
		end
	end

	-- Tools.
	local toolsCard = UIKit.frame({
		name = "Tools",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	toolsCard.LayoutOrder = 200
	UIKit.padding(toolsCard, Theme.Space.M)
	UIKit.list(toolsCard, { padding = Theme.Space.XS })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 18),
		text = "TOOLS",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = toolsCard,
	}).LayoutOrder = 1

	for index, toolId in ipairs(ResourceConfig.ToolOrder) do
		local def = ResourceConfig.Tools[toolId]
		local owned = toolId == "bare_hands" or (store.state.tools and store.state.tools[toolId])
		if owned then
			local entry = store.state.tools and store.state.tools[toolId]
			local equipped = store.state.equippedTool == toolId
			local durabilityText = ""
			if def.maxDurability > 0 and entry then
				durabilityText = ("   %d/%d"):format(entry.durability or 0, def.maxDurability)
			end

			local button = UIKit.button({
				name = "Tool_" .. toolId,
				size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
				text = ("%s%s  ·  tier %d  ·  %d dmg%s"):format(
					equipped and "✔ " or "",
					def.name,
					def.tier,
					def.damage,
					durabilityText
				),
				textSize = Theme.Text.TinySize,
				align = Enum.TextXAlignment.Left,
				color = equipped and Theme.Color.Field or Theme.Color.Panel,
				parent = toolsCard,
				onClick = function()
					Net.request(Routes.Request.EquipTool, { toolId = toolId })
				end,
			})
			button.LayoutOrder = 1 + index
			UIKit.padding(button, Theme.Space.S)
		end
	end

	--[[ Depositing is only meaningful at home, and only when there is something
	     in the bag to deposit. ]]
	if not inExpedition and store.state.bagUsed and store.state.bagUsed > 0 then
		local deposit = UIKit.primaryButton({
			name = "Deposit",
			size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
			text = "Move everything from your bag into storage",
			textSize = Theme.Text.SmallSize,
			parent = container,
			onClick = function()
				Net.request(Routes.Request.DepositBag)
			end,
		})
		deposit.LayoutOrder = 300
	end
end

return InventoryPanel
