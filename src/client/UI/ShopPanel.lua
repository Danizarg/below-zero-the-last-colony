--[[
	ShopPanel.lua
	The cosmetic shop.

	With monetization switched off (the current state of the build), this panel
	shows the catalogue with a plain notice that nothing can be purchased and
	nothing is required to play. That is more honest than hiding the shop, and
	it means the flow is already built and reviewable when products do exist.

	Every entry states whether it is cosmetic. The one product with a gameplay
	effect — the optional extra rescue — says so, states its cap, and sits next
	to the fact that a free rescue always comes first.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)
local ShopConfig = require(Shared.Config.ShopConfig)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local ShopPanel = {}

local function clearChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function ShopPanel.create(shell, store)
	local panel = UIKit.panel({
		name = "ShopPanel",
		title = "Shop",
		subtitle = "Cosmetics only, no randomised rewards",
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
		if area == "shop" then
			shell:refreshIfOpen("shop")
		end
	end)

	return {
		root = panel.root,
		refresh = function()
			ShopPanel.render(store, content)
		end,
		onOpen = function()
			Net.request(Routes.Request.GetShop)
		end,
	}
end

function ShopPanel.render(store, container)
	clearChildren(container)

	local shop = store.state.shop
	if not shop then
		UIKit.emptyState({ icon = "★", text = "Loading the catalogue.", parent = container })
		return
	end

	-- The honest notice, first thing on the panel.
	if shop.notice then
		local notice = UIKit.frame({
			name = "Notice",
			size = UDim2.new(1, 0, 0, 0),
			color = Theme.Color.Field,
			radius = Theme.Radius.M,
			stroke = true,
			strokeColor = Theme.Color.Warning,
			automaticSize = Enum.AutomaticSize.Y,
			parent = container,
		})
		notice.LayoutOrder = 0
		UIKit.padding(notice, Theme.Space.M)

		UIKit.label({
			name = "Text",
			size = UDim2.new(1, 0, 0, 0),
			text = shop.notice,
			textColor = Theme.Color.Warning,
			textSize = Theme.Text.SmallSize,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			automaticSize = Enum.AutomaticSize.Y,
			parent = notice,
		})
	end

	-- Rescue policy, stated up front because it is the only non-cosmetic thing.
	local policy = UIKit.frame({
		name = "Policy",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	policy.LayoutOrder = 1
	UIKit.padding(policy, Theme.Space.M)
	UIKit.list(policy, { padding = 2 })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 18),
		text = "HOW THIS SHOP WORKS",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = policy,
	}).LayoutOrder = 1

	UIKit.label({
		name = "Rules",
		size = UDim2.new(1, 0, 0, 0),
		text = ("· Everything here is cosmetic, except one optional rescue.\n"
			.. "· You always get %d free rescue per expedition, before any purchase.\n"
			.. "· No crates, no rolls, no randomised rewards.\n"
			.. "· Nothing here makes you stronger underground."):format(shop.freeRescuesPerExpedition or 1),
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.TinySize,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		automaticSize = Enum.AutomaticSize.Y,
		parent = policy,
	}).LayoutOrder = 2

	-- Products, grouped by category.
	local byCategory = {}
	for _, product in ipairs(shop.products or {}) do
		byCategory[product.category] = byCategory[product.category] or {}
		table.insert(byCategory[product.category], product)
	end

	local order = 10
	for _, category in ipairs(shop.categories or ShopConfig.CategoryOrder) do
		local products = byCategory[category]
		if products and #products > 0 then
			local meta = (shop.categoryMeta or ShopConfig.CategoryMeta)[category] or { name = category, icon = "·" }
			order += 1

			UIKit.label({
				name = "Cat_" .. category,
				size = UDim2.new(1, 0, 0, 24),
				text = ("%s  %s"):format(meta.icon, string.upper(meta.name)),
				textColor = Theme.Color.Accent,
				textSize = Theme.Text.SmallSize,
				font = Theme.Font.Heading,
				parent = container,
			}).LayoutOrder = order

			for _, product in ipairs(products) do
				order += 1
				local card = UIKit.frame({
					name = "Product_" .. product.id,
					size = UDim2.new(1, 0, 0, 0),
					color = Theme.Color.PanelRaised,
					radius = Theme.Radius.M,
					automaticSize = Enum.AutomaticSize.Y,
					parent = container,
				})
				card.LayoutOrder = order
				UIKit.padding(card, Theme.Space.M)
				UIKit.list(card, { padding = Theme.Space.XS })

				UIKit.label({
					name = "Name",
					size = UDim2.new(1, 0, 0, 20),
					text = ("%s%s"):format(product.name, product.owned and "   ✔ OWNED" or ""),
					textColor = product.owned and Theme.Color.Success or Theme.Color.Text,
					textSize = Theme.Text.BodySize,
					font = Theme.Font.Heading,
					parent = card,
				}).LayoutOrder = 1

				UIKit.label({
					name = "Description",
					size = UDim2.new(1, 0, 0, 0),
					text = product.description or "",
					textColor = Theme.Color.TextMuted,
					textSize = Theme.Text.TinySize,
					wrapped = true,
					alignY = Enum.TextYAlignment.Top,
					automaticSize = Enum.AutomaticSize.Y,
					parent = card,
				}).LayoutOrder = 2

				UIKit.label({
					name = "Tag",
					size = UDim2.new(1, 0, 0, 16),
					text = product.isCosmetic and "Cosmetic only" or "Affects gameplay — capped per expedition",
					textColor = product.isCosmetic and Theme.Color.Info or Theme.Color.Warning,
					textSize = Theme.Text.TinySize,
					parent = card,
				}).LayoutOrder = 3

				local button = UIKit.primaryButton({
					name = "Buy",
					size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
					text = product.priceHint and ("R$ %d"):format(product.priceHint) or "Purchase",
					textSize = Theme.Text.SmallSize,
					parent = card,
					onClick = function()
						local response = Net.request(Routes.Request.PromptPurchase, { productId = product.id })
						if not response.ok then
							store.notified:Fire({
								kind = "info",
								title = "Not available",
								body = response.message or "This product does not exist yet.",
							})
						end
					end,
				})
				button.LayoutOrder = 4

				if product.owned then
					UIKit.setEnabled(button, false, "Owned")
				elseif not product.purchasable then
					local reason = "Not available yet"
					if product.unavailableReason == "monetization_disabled" then
						reason = "Purchases are off in this build"
					elseif product.unavailableReason == "product_not_configured" then
						reason = "Not created yet"
					end
					UIKit.setEnabled(button, false, reason)
				end
			end
		end
	end

	if (shop.rescueBalance or 0) > 0 then
		UIKit.label({
			name = "RescueBalance",
			size = UDim2.new(1, 0, 0, 20),
			text = ("You hold %d purchased rescue(s)."):format(shop.rescueBalance),
			textColor = Theme.Color.Info,
			textSize = Theme.Text.SmallSize,
			parent = container,
		}).LayoutOrder = 999
	end
end

return ShopPanel
