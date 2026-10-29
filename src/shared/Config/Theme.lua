--[[
	Theme.lua
	Single source of truth for UI colour, type and spacing.

	Aesthetic: cold stone and lantern light. Near-black backgrounds, one warm
	amber accent for anything actionable, and a small set of status colours.
	Everything is built from Roblox primitives so there are no asset dependencies.
]]

local Theme = {}

Theme.Color = {
	-- Surfaces, darkest to lightest.
	Void = Color3.fromRGB(8, 9, 12),
	Backdrop = Color3.fromRGB(14, 15, 20),
	Panel = Color3.fromRGB(21, 23, 30),
	PanelRaised = Color3.fromRGB(28, 31, 40),
	Field = Color3.fromRGB(35, 38, 49),
	Divider = Color3.fromRGB(48, 52, 66),

	-- Text.
	Text = Color3.fromRGB(233, 236, 243),
	TextMuted = Color3.fromRGB(150, 157, 173),
	TextFaint = Color3.fromRGB(102, 108, 124),
	TextInverse = Color3.fromRGB(16, 14, 10),

	-- Brand accent: lantern amber.
	Accent = Color3.fromRGB(232, 172, 84),
	AccentDim = Color3.fromRGB(142, 103, 46),
	AccentGlow = Color3.fromRGB(255, 206, 134),

	-- Status.
	Health = Color3.fromRGB(216, 84, 84),
	Stamina = Color3.fromRGB(118, 196, 226),
	Hunger = Color3.fromRGB(198, 168, 96),
	Success = Color3.fromRGB(118, 206, 146),
	Warning = Color3.fromRGB(232, 172, 84),
	Danger = Color3.fromRGB(226, 78, 78),
	Info = Color3.fromRGB(122, 160, 236),

	-- Phase tints, used by the expedition HUD and the vignette.
	PhasePrep = Color3.fromRGB(126, 170, 206),
	PhaseDay = Color3.fromRGB(176, 196, 206),
	PhaseDusk = Color3.fromRGB(226, 142, 86),
	PhaseNight = Color3.fromRGB(92, 94, 160),
}

Theme.Font = {
	Display = Enum.Font.GothamBold,
	Heading = Enum.Font.GothamBold,
	Body = Enum.Font.Gotham,
	Mono = Enum.Font.Code,
}

Theme.Text = {
	TitleSize = 28,
	HeadingSize = 20,
	SubheadingSize = 16,
	BodySize = 14,
	SmallSize = 12,
	TinySize = 11,
}

Theme.Space = {
	XS = 4,
	S = 8,
	M = 12,
	L = 18,
	XL = 26,
	XXL = 38,
}

Theme.Radius = {
	S = 4,
	M = 8,
	L = 14,
	Pill = 999,
}

--[[ Minimum touch target. Every interactive element must meet this on at least
     one axis pair; UIKit asserts it in debug builds. ]]
Theme.MinTouchTarget = 44

Theme.Transparency = {
	Scrim = 0.35,
	Panel = 0.04,
	Glass = 0.22,
}

Theme.Tween = {
	Fast = 0.12,
	Normal = 0.2,
	Slow = 0.35,
	Easing = Enum.EasingStyle.Quint,
	Direction = Enum.EasingDirection.Out,
}

Theme.ZIndex = {
	Backdrop = 1,
	HUD = 10,
	Panel = 50,
	Modal = 100,
	Toast = 200,
	Critical = 500,
}

--[[ Named layouts so panels line up across screens without magic numbers. ]]
Theme.Layout = {
	PanelWidth = 0.62,
	PanelMaxWidth = 860,
	PanelHeight = 0.72,
	PanelMaxHeight = 620,
	SidebarWidth = 190,
	RowHeight = 46,
	HudBarWidth = 190,
	HudBarHeight = 12,
}

return Theme
