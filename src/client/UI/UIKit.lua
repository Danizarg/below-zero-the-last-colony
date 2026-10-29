--[[
	UIKit.lua
	Reusable interface components, built from Roblox primitives and Theme tokens.

	Every panel and HUD in the game is assembled from these, which is how the
	interface stays visually consistent without a design system living in nine
	different files. No component reads a raw colour or size: everything comes
	from Theme.

	Touch and keyboard both work because every interactive component is a real
	TextButton with a minimum 44px hit target, not a frame with a click
	detector — so Roblox's own input handling covers mouse, touch and gamepad.
]]

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Theme = require(Shared.Config.Theme)

local UIKit = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Primitives
-- ─────────────────────────────────────────────────────────────────────────────

local function applyCorner(instance, radius)
	if radius and radius > 0 then
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, radius)
		corner.Parent = instance
	end
end

local function applyStroke(instance, color, thickness, transparency)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or Theme.Color.Divider
	stroke.Thickness = thickness or 1
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = instance
	return stroke
end

UIKit.applyCorner = applyCorner
UIKit.applyStroke = applyStroke

function UIKit.frame(props)
	local frame = Instance.new("Frame")
	frame.Name = props.name or "Frame"
	frame.Size = props.size or UDim2.fromScale(1, 1)
	frame.Position = props.position or UDim2.new()
	frame.AnchorPoint = props.anchor or Vector2.new()
	frame.BackgroundColor3 = props.color or Theme.Color.Panel
	frame.BackgroundTransparency = props.transparency or 0
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = props.clips == true
	frame.Visible = props.visible ~= false
	frame.ZIndex = props.zIndex or 1
	frame.AutomaticSize = props.automaticSize or Enum.AutomaticSize.None

	applyCorner(frame, props.radius)
	if props.stroke then
		applyStroke(frame, props.strokeColor, props.strokeThickness, props.strokeTransparency)
	end
	if props.parent then
		frame.Parent = props.parent
	end
	return frame
end

function UIKit.label(props)
	local label = Instance.new("TextLabel")
	label.Name = props.name or "Label"
	label.Size = props.size or UDim2.new(1, 0, 0, 20)
	label.Position = props.position or UDim2.new()
	label.AnchorPoint = props.anchor or Vector2.new()
	label.BackgroundTransparency = props.backgroundTransparency or 1
	label.BackgroundColor3 = props.color or Theme.Color.Panel
	label.BorderSizePixel = 0
	label.Font = props.font or Theme.Font.Body
	label.Text = props.text or ""
	label.TextColor3 = props.textColor or Theme.Color.Text
	label.TextSize = props.textSize or Theme.Text.BodySize
	label.TextXAlignment = props.align or Enum.TextXAlignment.Left
	label.TextYAlignment = props.alignY or Enum.TextYAlignment.Center
	label.TextWrapped = props.wrapped == true
	label.TextTruncate = props.truncate and Enum.TextTruncate.AtEnd or Enum.TextTruncate.None
	label.RichText = props.richText == true
	label.ZIndex = props.zIndex or 1
	label.AutomaticSize = props.automaticSize or Enum.AutomaticSize.None
	label.Visible = props.visible ~= false

	if props.radius then
		applyCorner(label, props.radius)
	end
	if props.parent then
		label.Parent = props.parent
	end
	return label
end

--[[
	A button.

	Always at least Theme.MinTouchTarget tall, because the UI has to work on a
	phone and a 20px row is unusable with a thumb.
]]
function UIKit.button(props)
	local button = Instance.new("TextButton")
	button.Name = props.name or "Button"

	local height = props.height or Theme.MinTouchTarget
	button.Size = props.size or UDim2.new(1, 0, 0, math.max(height, Theme.MinTouchTarget))
	button.Position = props.position or UDim2.new()
	button.AnchorPoint = props.anchor or Vector2.new()
	button.BackgroundColor3 = props.color or Theme.Color.Field
	button.BackgroundTransparency = props.transparency or 0
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = props.font or Theme.Font.Heading
	button.Text = props.text or ""
	button.TextColor3 = props.textColor or Theme.Color.Text
	button.TextSize = props.textSize or Theme.Text.BodySize
	button.TextXAlignment = props.align or Enum.TextXAlignment.Center
	button.ZIndex = props.zIndex or 2
	button.Visible = props.visible ~= false
	button.Active = true

	applyCorner(button, props.radius or Theme.Radius.M)
	local stroke
	if props.stroke ~= false then
		stroke = applyStroke(button, props.strokeColor or Theme.Color.Divider, 1, 0.3)
	end

	local baseColor = button.BackgroundColor3
	local hoverColor = props.hoverColor
		or Color3.new(
			math.min(1, baseColor.R + 0.06),
			math.min(1, baseColor.G + 0.06),
			math.min(1, baseColor.B + 0.07)
		)

	--[[ Hover and press feedback. Cheap, and its absence is the single biggest
	     thing that makes a Roblox UI feel unfinished. ]]
	button.MouseEnter:Connect(function()
		if button:GetAttribute("Disabled") then
			return
		end
		UIKit.tween(button, { BackgroundColor3 = hoverColor }, Theme.Tween.Fast)
		if stroke then
			UIKit.tween(stroke, { Transparency = 0 }, Theme.Tween.Fast)
		end
	end)
	button.MouseLeave:Connect(function()
		UIKit.tween(button, { BackgroundColor3 = baseColor }, Theme.Tween.Fast)
		if stroke then
			UIKit.tween(stroke, { Transparency = 0.3 }, Theme.Tween.Fast)
		end
	end)
	button.MouseButton1Down:Connect(function()
		if button:GetAttribute("Disabled") then
			return
		end
		UIKit.tween(button, { BackgroundTransparency = 0.25 }, Theme.Tween.Fast)
	end)
	button.MouseButton1Up:Connect(function()
		UIKit.tween(button, { BackgroundTransparency = props.transparency or 0 }, Theme.Tween.Fast)
	end)

	if props.onClick then
		button.Activated:Connect(function()
			if button:GetAttribute("Disabled") then
				return
			end
			props.onClick(button)
		end)
	end

	if props.parent then
		button.Parent = props.parent
	end
	return button
end

function UIKit.primaryButton(props)
	local merged = table.clone(props)
	merged.color = props.color or Theme.Color.Accent
	merged.textColor = props.textColor or Theme.Color.TextInverse
	merged.strokeColor = props.strokeColor or Theme.Color.AccentGlow
	return UIKit.button(merged)
end

--[[ Grey a button out and say why, rather than hiding it. A player who can see
     the locked option understands the progression. ]]
function UIKit.setEnabled(button, enabled, disabledText)
	button:SetAttribute("Disabled", not enabled)
	button.AutoLocalize = false
	if enabled then
		button.TextTransparency = 0
		button.BackgroundTransparency = 0
	else
		button.TextTransparency = 0.45
		button.BackgroundTransparency = 0.55
		if disabledText then
			button.Text = disabledText
		end
	end
end

function UIKit.tween(instance, goal, duration, style)
	local info = TweenInfo.new(duration or Theme.Tween.Normal, style or Theme.Tween.Easing, Theme.Tween.Direction)
	local tween = TweenService:Create(instance, info, goal)
	tween:Play()
	return tween
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Layout helpers
-- ─────────────────────────────────────────────────────────────────────────────

function UIKit.list(parent, props)
	props = props or {}
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = props.horizontal and Enum.FillDirection.Horizontal or Enum.FillDirection.Vertical
	layout.Padding = UDim.new(0, props.padding or Theme.Space.S)
	layout.SortOrder = props.sortOrder or Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = props.horizontalAlign or Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = props.verticalAlign or Enum.VerticalAlignment.Top
	layout.Parent = parent
	return layout
end

function UIKit.grid(parent, props)
	props = props or {}
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = props.cellSize or UDim2.new(0.5, -6, 0, 72)
	layout.CellPadding = props.cellPadding or UDim2.fromOffset(Theme.Space.S, Theme.Space.S)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = parent
	return layout
end

function UIKit.padding(parent, amount)
	local padding = Instance.new("UIPadding")
	local value = UDim.new(0, amount or Theme.Space.M)
	padding.PaddingTop = value
	padding.PaddingBottom = value
	padding.PaddingLeft = value
	padding.PaddingRight = value
	padding.Parent = parent
	return padding
end

function UIKit.scroll(props)
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = props.name or "Scroll"
	scroll.Size = props.size or UDim2.fromScale(1, 1)
	scroll.Position = props.position or UDim2.new()
	scroll.BackgroundTransparency = props.transparency or 1
	scroll.BackgroundColor3 = props.color or Theme.Color.Backdrop
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = Theme.Color.Divider
	scroll.ScrollBarImageTransparency = 0.2
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ElasticBehavior = Enum.ElasticBehavior.Never
	scroll.ZIndex = props.zIndex or 1

	if props.parent then
		scroll.Parent = props.parent
	end
	return scroll
end

function UIKit.divider(parent, order)
	local line = UIKit.frame({
		name = "Divider",
		size = UDim2.new(1, 0, 0, 1),
		color = Theme.Color.Divider,
		transparency = 0.4,
		parent = parent,
	})
	line.LayoutOrder = order or 0
	return line
end

function UIKit.spacer(parent, height, order)
	local space = UIKit.frame({
		name = "Spacer",
		size = UDim2.new(1, 0, 0, height or Theme.Space.M),
		transparency = 1,
		parent = parent,
	})
	space.LayoutOrder = order or 0
	return space
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Composite components
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	A labelled progress bar. Returns { root, fill, text, set(value, max) }.

	Used for health, stamina, hunger, XP, the phase clock and build progress, so
	it carries its own formatting rather than each caller inventing one.
]]
function UIKit.bar(props)
	local root = UIKit.frame({
		name = props.name or "Bar",
		size = props.size or UDim2.new(1, 0, 0, Theme.Layout.HudBarHeight),
		color = Theme.Color.Field,
		radius = Theme.Radius.Pill,
		parent = props.parent,
	})
	root.ClipsDescendants = true

	local fill = UIKit.frame({
		name = "Fill",
		size = UDim2.fromScale(0, 1),
		color = props.fillColor or Theme.Color.Accent,
		radius = Theme.Radius.Pill,
		parent = root,
	})

	local text
	if props.showText ~= false then
		text = UIKit.label({
			name = "Value",
			size = UDim2.fromScale(1, 1),
			text = "",
			textColor = props.textColor or Theme.Color.Text,
			textSize = props.textSize or Theme.Text.TinySize,
			font = Theme.Font.Heading,
			align = Enum.TextXAlignment.Center,
			parent = root,
		})
		text.ZIndex = 3
	end

	local component = { root = root, fill = fill, text = text }

	function component.set(value, max, labelOverride)
		max = math.max(1, max or 1)
		local fraction = math.clamp((value or 0) / max, 0, 1)
		UIKit.tween(fill, { Size = UDim2.fromScale(fraction, 1) }, Theme.Tween.Fast)
		if text then
			text.Text = labelOverride or ("%d / %d"):format(math.floor(value or 0), math.floor(max))
		end
	end

	function component.setColor(color)
		UIKit.tween(fill, { BackgroundColor3 = color }, Theme.Tween.Normal)
	end

	return component
end

--[[ A resource chip: glyph, count, name on hover. The icon is a text glyph, so
     there are no image assets to miss. ]]
function UIKit.resourceChip(props)
	local root = UIKit.frame({
		name = "Chip_" .. (props.id or "res"),
		size = props.size or UDim2.new(0, 96, 0, 30),
		color = Theme.Color.Field,
		radius = Theme.Radius.S,
		transparency = 0.25,
		parent = props.parent,
	})

	UIKit.label({
		name = "Icon",
		size = UDim2.new(0, 22, 1, 0),
		position = UDim2.fromOffset(6, 0),
		text = props.icon or "•",
		textColor = props.iconColor or Theme.Color.Accent,
		textSize = Theme.Text.SubheadingSize,
		font = Theme.Font.Heading,
		align = Enum.TextXAlignment.Center,
		parent = root,
	})

	local count = UIKit.label({
		name = "Count",
		size = UDim2.new(1, -32, 1, 0),
		position = UDim2.fromOffset(30, 0),
		text = tostring(props.count or 0),
		textColor = Theme.Color.Text,
		textSize = Theme.Text.BodySize,
		font = Theme.Font.Heading,
		parent = root,
	})

	return { root = root, count = count }
end

--[[ A panel: titled container with a close button, sized for both desktop and
     phone. Returns { root, header, body, close }. ]]
function UIKit.panel(props)
	local root = UIKit.frame({
		name = props.name or "Panel",
		size = props.size
			or UDim2.new(
				Theme.Layout.PanelWidth,
				0,
				Theme.Layout.PanelHeight,
				0
			),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = Theme.Color.Panel,
		radius = Theme.Radius.L,
		stroke = true,
		strokeColor = Theme.Color.Divider,
		zIndex = Theme.ZIndex.Panel,
		parent = props.parent,
	})

	--[[ Constrain so the panel never grows past a readable width on a monitor
	     or shrink below usability on a phone. ]]
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(Theme.Layout.PanelMaxWidth, Theme.Layout.PanelMaxHeight)
	constraint.MinSize = Vector2.new(260, 240)
	constraint.Parent = root

	local header = UIKit.frame({
		name = "Header",
		size = UDim2.new(1, 0, 0, 56),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.L,
		parent = root,
	})

	--[[ Square off the bottom corners of the header so it joins the body
	     cleanly instead of showing a rounded seam. ]]
	UIKit.frame({
		name = "HeaderJoin",
		size = UDim2.new(1, 0, 0, Theme.Radius.L),
		position = UDim2.new(0, 0, 1, -Theme.Radius.L),
		color = Theme.Color.PanelRaised,
		parent = header,
	})

	UIKit.label({
		name = "Title",
		size = UDim2.new(1, -110, 1, 0),
		position = UDim2.fromOffset(Theme.Space.L, 0),
		text = props.title or "",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.HeadingSize,
		font = Theme.Font.Display,
		parent = header,
	})

	if props.subtitle then
		UIKit.label({
			name = "Subtitle",
			size = UDim2.new(1, -110, 0, 16),
			position = UDim2.new(0, Theme.Space.L, 1, -20),
			text = props.subtitle,
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.SmallSize,
			parent = header,
		})
	end

	local close = UIKit.button({
		name = "Close",
		size = UDim2.fromOffset(Theme.MinTouchTarget, Theme.MinTouchTarget),
		position = UDim2.new(1, -Theme.Space.S, 0.5, 0),
		anchor = Vector2.new(1, 0.5),
		text = "✕",
		textSize = Theme.Text.SubheadingSize,
		color = Theme.Color.Field,
		radius = Theme.Radius.M,
		parent = header,
		onClick = props.onClose,
	})

	local body = UIKit.frame({
		name = "Body",
		size = UDim2.new(1, 0, 1, -56),
		position = UDim2.fromOffset(0, 56),
		transparency = 1,
		parent = root,
	})

	return { root = root, header = header, body = body, close = close }
end

--[[ A tab strip. Returns { root, setActive(id) } and calls onChange(id). ]]
function UIKit.tabs(props)
	local root = UIKit.frame({
		name = "Tabs",
		size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
		transparency = 1,
		parent = props.parent,
	})
	UIKit.list(root, { horizontal = true, padding = Theme.Space.XS })

	local buttons = {}
	local active

	local function setActive(id)
		active = id
		for tabId, button in pairs(buttons) do
			local isActive = tabId == id
			UIKit.tween(button, {
				BackgroundColor3 = isActive and Theme.Color.Accent or Theme.Color.Field,
			}, Theme.Tween.Fast)
			button.TextColor3 = isActive and Theme.Color.TextInverse or Theme.Color.TextMuted
		end
	end

	for index, tab in ipairs(props.tabs) do
		local button = UIKit.button({
			name = "Tab_" .. tab.id,
			size = UDim2.new(0, tab.width or 112, 1, 0),
			text = tab.label,
			textSize = Theme.Text.SmallSize,
			color = Theme.Color.Field,
			radius = Theme.Radius.M,
			parent = root,
			onClick = function()
				if active ~= tab.id then
					setActive(tab.id)
					if props.onChange then
						props.onChange(tab.id)
					end
				end
			end,
		})
		button.LayoutOrder = index
		buttons[tab.id] = button
	end

	if props.tabs[1] then
		setActive(props.default or props.tabs[1].id)
	end

	return { root = root, setActive = setActive, buttons = buttons }
end

--[[ A full-screen scrim, used behind modal panels so the world does not compete
     with the interface. ]]
function UIKit.scrim(props)
	local scrim = UIKit.frame({
		name = "Scrim",
		size = UDim2.fromScale(1, 1),
		color = Theme.Color.Void,
		transparency = 1,
		zIndex = Theme.ZIndex.Panel - 1,
		parent = props.parent,
	})
	UIKit.tween(scrim, { BackgroundTransparency = Theme.Transparency.Scrim }, Theme.Tween.Normal)

	if props.onClick then
		local catcher = UIKit.button({
			name = "ScrimCatcher",
			size = UDim2.fromScale(1, 1),
			text = "",
			color = Theme.Color.Void,
			transparency = 1,
			radius = 0,
			stroke = false,
			parent = scrim,
			onClick = props.onClick,
		})
		catcher.ZIndex = 1
	end

	return scrim
end

--[[ A labelled stat line: "Population   7 / 12". The single most repeated
     pattern in the colony UI. ]]
function UIKit.statRow(props)
	local root = UIKit.frame({
		name = "Stat_" .. (props.key or "row"),
		size = UDim2.new(1, 0, 0, 26),
		transparency = 1,
		parent = props.parent,
	})

	UIKit.label({
		name = "Key",
		size = UDim2.fromScale(0.58, 1),
		text = props.label or "",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.SmallSize,
		parent = root,
	})

	local value = UIKit.label({
		name = "Value",
		size = UDim2.fromScale(0.42, 1),
		position = UDim2.fromScale(0.58, 0),
		text = props.value or "",
		textColor = props.valueColor or Theme.Color.Text,
		textSize = Theme.Text.BodySize,
		font = Theme.Font.Heading,
		align = Enum.TextXAlignment.Right,
		parent = root,
	})

	return { root = root, value = value }
end

--[[ An empty-state message, so a panel with nothing in it explains itself
     rather than looking broken. ]]
function UIKit.emptyState(props)
	local root = UIKit.frame({
		name = "Empty",
		size = UDim2.new(1, 0, 0, 90),
		transparency = 1,
		parent = props.parent,
	})

	UIKit.label({
		name = "Glyph",
		size = UDim2.new(1, 0, 0, 30),
		text = props.icon or "·",
		textColor = Theme.Color.TextFaint,
		textSize = 26,
		font = Theme.Font.Display,
		align = Enum.TextXAlignment.Center,
		parent = root,
	})

	UIKit.label({
		name = "Message",
		size = UDim2.new(1, 0, 0, 50),
		position = UDim2.fromOffset(0, 34),
		text = props.text or "Nothing here yet.",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.SmallSize,
		align = Enum.TextXAlignment.Center,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		parent = root,
	})

	return root
end

--[[ Format a cost table as "12 Stone · 6 Fiber", with missing amounts in red.
     Returns a rich-text string. ]]
function UIKit.formatCost(cost, resourceDefs, held)
	local parts = {}
	local ids = {}
	for id in pairs(cost or {}) do
		table.insert(ids, id)
	end
	table.sort(ids)

	for _, id in ipairs(ids) do
		local amount = cost[id]
		local def = resourceDefs and resourceDefs[id]
		local name = def and def.name or id
		local have = held and (held[id] or 0) or nil
		if have ~= nil and have < amount then
			local colour = Theme.Color.Danger
			table.insert(
				parts,
				('<font color="rgb(%d,%d,%d)">%d %s</font>'):format(
					math.floor(colour.R * 255),
					math.floor(colour.G * 255),
					math.floor(colour.B * 255),
					amount,
					name
				)
			)
		else
			table.insert(parts, ("%d %s"):format(amount, name))
		end
	end

	return #parts > 0 and table.concat(parts, "  ·  ") or "Free"
end

function UIKit.formatClock(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	return ("%d:%02d"):format(math.floor(seconds / 60), seconds % 60)
end

return UIKit
