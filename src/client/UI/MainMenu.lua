--[[
	MainMenu.lua
	The landing screen, shown once on arrival and reachable afterwards.

	It exists for two reasons: the brief asks for a main menu with these seven
	entries, and a first-time player who spawns straight into a dark cavern with
	no explanation does not know what the game is. "Play" simply dismisses it and
	leaves the player standing in their colony with the HUD's objective line
	telling them what to do next.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local GameConfig = require(Shared.Config.GameConfig)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local MainMenu = {}

local ENTRIES = {
	{ id = "play", label = "Play", icon = "▶", blurb = "Step into your colony." },
	{ id = "colony", label = "My Colony", icon = "⌂", blurb = "Survivors, stockpile, production." },
	{ id = "expedition", label = "Expeditions", icon = "⛏", blurb = "Pick a difficulty and go down." },
	{ id = "roles", label = "Roles", icon = "◈", blurb = "Runner, Medic, Guardian." },
	{ id = "inventory", label = "Inventory", icon = "▤", blurb = "What you carry and what you store." },
	{ id = "shop", label = "Shop", icon = "★", blurb = "Cosmetics. Nothing you need." },
	{ id = "settings", label = "Settings", icon = "⚙", blurb = "Audio and accessibility." },
}

function MainMenu.create(shell, _store)
	local root = UIKit.frame({
		name = "MainMenu",
		size = UDim2.fromScale(1, 1),
		color = Theme.Color.Void,
		transparency = 0.08,
		zIndex = Theme.ZIndex.Modal,
		visible = false,
		parent = shell.modalHost,
	})

	--[[ A vertical gradient keeps the flat backdrop from looking like an error
	     screen, at no asset cost. ]]
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(Theme.Color.Void, Theme.Color.Backdrop)
	gradient.Rotation = 90
	gradient.Parent = root

	local card = UIKit.frame({
		name = "Card",
		size = UDim2.new(0, 520, 0, 0),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		transparency = 1,
		automaticSize = Enum.AutomaticSize.Y,
		parent = root,
	})
	local constraint = Instance.new("UISizeConstraint")
	constraint.MaxSize = Vector2.new(520, 10000)
	constraint.MinSize = Vector2.new(280, 0)
	constraint.Parent = card
	UIKit.list(card, { padding = Theme.Space.S })

	-- Title.
	UIKit.label({
		name = "Title",
		size = UDim2.new(1, 0, 0, 44),
		text = "BELOW ZERO",
		textColor = Theme.Color.Text,
		textSize = 40,
		font = Theme.Font.Display,
		align = Enum.TextXAlignment.Center,
		parent = card,
	}).LayoutOrder =
		1

	UIKit.label({
		name = "Subtitle",
		size = UDim2.new(1, 0, 0, 22),
		text = "THE LAST COLONY",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.SubheadingSize,
		font = Theme.Font.Heading,
		align = Enum.TextXAlignment.Center,
		parent = card,
	}).LayoutOrder =
		2

	UIKit.label({
		name = "Pitch",
		size = UDim2.new(1, 0, 0, 54),
		text = "Build a civilisation in the dark. Take what the caves will give you, "
			.. "and be home before they rearrange themselves.",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.SmallSize,
		align = Enum.TextXAlignment.Center,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		parent = card,
	}).LayoutOrder =
		3

	UIKit.spacer(card, Theme.Space.M, 4)

	for index, entry in ipairs(ENTRIES) do
		local isPlay = entry.id == "play"
		local button = (isPlay and UIKit.primaryButton or UIKit.button)({
			name = "Menu_" .. entry.id,
			size = UDim2.new(1, 0, 0, isPlay and 58 or 50),
			text = "",
			parent = card,
			onClick = function()
				if isPlay then
					MainMenu.hide(root)
				else
					MainMenu.hide(root)
					shell:open(entry.id)
				end
			end,
		})
		button.LayoutOrder = 10 + index

		UIKit.label({
			name = "Icon",
			size = UDim2.fromOffset(40, isPlay and 58 or 50),
			position = UDim2.fromOffset(Theme.Space.M, 0),
			text = entry.icon,
			textColor = isPlay and Theme.Color.TextInverse or Theme.Color.Accent,
			textSize = Theme.Text.SubheadingSize,
			align = Enum.TextXAlignment.Center,
			parent = button,
		})

		UIKit.label({
			name = "Label",
			size = UDim2.new(1, -70, 0, 20),
			position = UDim2.fromOffset(58, isPlay and 10 or 6),
			text = entry.label,
			textColor = isPlay and Theme.Color.TextInverse or Theme.Color.Text,
			textSize = Theme.Text.BodySize,
			font = Theme.Font.Heading,
			parent = button,
		})

		UIKit.label({
			name = "Blurb",
			size = UDim2.new(1, -70, 0, 16),
			position = UDim2.fromOffset(58, isPlay and 30 or 24),
			text = entry.blurb,
			textColor = isPlay and Theme.Color.TextInverse or Theme.Color.TextFaint,
			textSize = Theme.Text.TinySize,
			parent = button,
		})
	end

	UIKit.spacer(card, Theme.Space.S, 90)

	local footer = UIKit.label({
		name = "Footer",
		size = UDim2.new(1, 0, 0, 28),
		text = ("v%s  ·  %s  ·  Press Escape to reopen this menu"):format(
			GameConfig.Version,
			Players.LocalPlayer.DisplayName
		),
		textColor = Theme.Color.TextFaint,
		textSize = Theme.Text.TinySize,
		align = Enum.TextXAlignment.Center,
		parent = card,
	})
	footer.LayoutOrder = 91

	return {
		root = root,
		show = function()
			MainMenu.show(root)
		end,
		hide = function()
			MainMenu.hide(root)
		end,
		isVisible = function()
			return root.Visible
		end,
	}
end

function MainMenu.show(root)
	root.Visible = true
	root.BackgroundTransparency = 1
	UIKit.tween(root, { BackgroundTransparency = 0.08 }, Theme.Tween.Normal)
end

function MainMenu.hide(root)
	UIKit.tween(root, { BackgroundTransparency = 1 }, Theme.Tween.Fast)
	task.delay(Theme.Tween.Fast + 0.05, function()
		root.Visible = false
	end)
end

return MainMenu
