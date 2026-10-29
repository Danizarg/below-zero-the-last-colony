--[[
	SettingsPanel.lua
	Audio volumes, accessibility toggles and build information.

	Settings are stored on the profile, so they follow the player between
	sessions and devices. Each change is a single validated request; the server
	only accepts keys that already exist in the profile template, at the type
	they already hold.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local SettingsPanel = {}

local SLIDERS = {
	{ key = "musicVolume", label = "Music" },
	{ key = "sfxVolume", label = "Sound effects" },
	{ key = "ambienceVolume", label = "Cave ambience" },
	{ key = "hudScale", label = "HUD scale", min = 0.8, max = 1.4 },
}

local TOGGLES = {
	{ key = "screenShake", label = "Screen shake", note = "Camera shake on impacts and maze shifts." },
	{ key = "showDamageNumbers", label = "Damage numbers", note = "Floating numbers on hits." },
	{
		key = "colourblindMode",
		label = "High-contrast status colours",
		note = "Uses shape and brightness as well as hue for health, stamina and hunger.",
	},
}

local function clearChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function SettingsPanel.create(shell, store)
	local panel = UIKit.panel({
		name = "SettingsPanel",
		title = "Settings",
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

	return {
		root = panel.root,
		refresh = function()
			SettingsPanel.render(store, content)
		end,
	}
end

local function setSetting(store, key, value)
	local response = Net.request(Routes.Request.SetSetting, { key = key, value = value })
	if response.ok then
		store.state.settings[key] = response.value
		store.touch("settings")
	end
	return response.ok
end

function SettingsPanel.render(store, container)
	clearChildren(container)

	local settings = store.state.settings or {}

	--[[ Stepped buttons rather than a drag slider: a drag slider needs custom
	     input handling to work with both a mouse and a thumb, and five steps is
	     plenty for a volume control. ]]
	for index, slider in ipairs(SLIDERS) do
		local minValue = slider.min or 0
		local maxValue = slider.max or 1
		local current = settings[slider.key]
		if current == nil then
			current = maxValue
		end

		local row = UIKit.frame({
			name = "Slider_" .. slider.key,
			size = UDim2.new(1, 0, 0, 62),
			color = Theme.Color.PanelRaised,
			radius = Theme.Radius.M,
			parent = container,
		})
		row.LayoutOrder = index
		UIKit.padding(row, Theme.Space.M)

		local label = UIKit.label({
			name = "Label",
			size = UDim2.new(1, -100, 0, 18),
			text = ("%s  —  %d%%"):format(slider.label, math.floor((current / maxValue) * 100)),
			textColor = Theme.Color.Text,
			textSize = Theme.Text.SmallSize,
			parent = row,
		})

		local bar = UIKit.bar({
			name = "Level",
			size = UDim2.new(1, -100, 0, 8),
			fillColor = Theme.Color.Accent,
			showText = false,
			parent = row,
		})
		bar.root.Position = UDim2.fromOffset(0, 24)
		bar.set(current - minValue, maxValue - minValue)

		local function nudge(delta)
			local next_ = math.clamp(current + delta, minValue, maxValue)
			if setSetting(store, slider.key, next_) then
				current = next_
				label.Text = ("%s  —  %d%%"):format(slider.label, math.floor((current / maxValue) * 100))
				bar.set(current - minValue, maxValue - minValue)
			end
		end

		UIKit.button({
			name = "Down",
			size = UDim2.fromOffset(44, Theme.MinTouchTarget),
			position = UDim2.new(1, -96, 0, 0),
			text = "−",
			parent = row,
			onClick = function()
				nudge(-(maxValue - minValue) / 5)
			end,
		})

		UIKit.button({
			name = "Up",
			size = UDim2.fromOffset(44, Theme.MinTouchTarget),
			position = UDim2.new(1, -46, 0, 0),
			text = "+",
			parent = row,
			onClick = function()
				nudge((maxValue - minValue) / 5)
			end,
		})
	end

	for index, toggle in ipairs(TOGGLES) do
		local current = settings[toggle.key] == true

		local row = UIKit.frame({
			name = "Toggle_" .. toggle.key,
			size = UDim2.new(1, 0, 0, 64),
			color = Theme.Color.PanelRaised,
			radius = Theme.Radius.M,
			parent = container,
		})
		row.LayoutOrder = 20 + index
		UIKit.padding(row, Theme.Space.M)

		UIKit.label({
			name = "Label",
			size = UDim2.new(1, -110, 0, 18),
			text = toggle.label,
			textColor = Theme.Color.Text,
			textSize = Theme.Text.SmallSize,
			font = Theme.Font.Heading,
			parent = row,
		})

		UIKit.label({
			name = "Note",
			size = UDim2.new(1, -110, 0, 22),
			position = UDim2.fromOffset(0, 18),
			text = toggle.note,
			textColor = Theme.Color.TextFaint,
			textSize = Theme.Text.TinySize,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			parent = row,
		})

		local button
		button = UIKit.button({
			name = "Switch",
			size = UDim2.fromOffset(92, Theme.MinTouchTarget),
			position = UDim2.new(1, -92, 0.5, 0),
			anchor = Vector2.new(0, 0.5),
			text = current and "ON" or "OFF",
			textSize = Theme.Text.SmallSize,
			color = current and Theme.Color.Accent or Theme.Color.Field,
			textColor = current and Theme.Color.TextInverse or Theme.Color.TextMuted,
			parent = row,
			onClick = function()
				if setSetting(store, toggle.key, not current) then
					current = not current
					button.Text = current and "ON" or "OFF"
					button.BackgroundColor3 = current and Theme.Color.Accent or Theme.Color.Field
					button.TextColor3 = current and Theme.Color.TextInverse or Theme.Color.TextMuted
				end
			end,
		})
	end

	-- Build information, so a bug report can name a version.
	local info = UIKit.frame({
		name = "BuildInfo",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	info.LayoutOrder = 100
	UIKit.padding(info, Theme.Space.M)
	UIKit.list(info, { padding = 2 })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 18),
		text = "BUILD",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = info,
	}).LayoutOrder = 1

	local lines = {
		("Version %s"):format(store.state.version or GameConfig.Version),
		("Transport mode: %s"):format(GameConfig.TransportMode),
		("Data schema v%d"):format(GameConfig.DataVersion),
		("MVP content only: %s"):format(GameConfig.MvpContentOnly and "yes" or "no"),
		("Purchases: %s"):format(GameConfig.Monetization.Enabled and "enabled" or "disabled"),
	}
	if store.state.readOnly then
		table.insert(lines, "SAVE IS READ-ONLY THIS SESSION — progress will not persist.")
	end

	UIKit.label({
		name = "Lines",
		size = UDim2.new(1, 0, 0, 0),
		text = table.concat(lines, "\n"),
		textColor = store.state.readOnly and Theme.Color.Danger or Theme.Color.TextMuted,
		textSize = Theme.Text.TinySize,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		automaticSize = Enum.AutomaticSize.Y,
		parent = info,
	}).LayoutOrder = 2
end

return SettingsPanel
