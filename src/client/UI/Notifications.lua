--[[
	Notifications.lua
	Three tiers of message, because they are not the same thing:

		toast   bottom-right, stacked, auto-dismissing. Routine feedback:
		        "crafted", "workers idle", "level up".
		alert   centre-screen banner. Something that changed the run: a key
		        found, the gate opening, night falling.
		warning full-screen, red, with a countdown. Reserved for the maze shift,
		        which is the one thing a player must not miss.

	The shift warning is the loudest element in the game on purpose. The brief
	asks for clear countdown warnings before the caves rearrange, and a toast in
	the corner would not do it.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local Notifications = {}
Notifications.__index = Notifications

local TOAST_LIFETIME = 5
local MAX_TOASTS = 4

local KIND_COLOR = {
	info = Theme.Color.Info,
	success = Theme.Color.Success,
	warning = Theme.Color.Warning,
	danger = Theme.Color.Danger,
	invite = Theme.Color.Accent,
	combat = Theme.Color.Danger,
}

function Notifications.new(shell, store)
	local self = setmetatable({}, Notifications)
	self.shell = shell
	self.store = store
	self._toasts = {}

	-- Toast stack, bottom-right.
	self.toastColumn = UIKit.frame({
		name = "Toasts",
		size = UDim2.new(0, 320, 0, 0),
		position = UDim2.new(1, -Theme.Space.M, 1, -Theme.Space.M),
		anchor = Vector2.new(1, 1),
		transparency = 1,
		automaticSize = Enum.AutomaticSize.Y,
		parent = shell.toastHost,
	})
	UIKit.list(self.toastColumn, {
		padding = Theme.Space.S,
		verticalAlign = Enum.VerticalAlignment.Bottom,
	})

	-- Centre alert banner.
	self.alertBanner = UIKit.frame({
		name = "Alert",
		size = UDim2.new(0, 520, 0, 92),
		position = UDim2.fromScale(0.5, 0.2),
		anchor = Vector2.new(0.5, 0.5),
		color = Theme.Color.Panel,
		radius = Theme.Radius.L,
		stroke = true,
		visible = false,
		parent = shell.criticalHost,
	})
	local alertConstraint = Instance.new("UISizeConstraint")
	alertConstraint.MaxSize = Vector2.new(520, 120)
	alertConstraint.Parent = self.alertBanner

	self.alertAccent = UIKit.frame({
		name = "Accent",
		size = UDim2.new(0, 4, 1, -Theme.Space.M),
		position = UDim2.fromOffset(0, Theme.Space.S),
		color = Theme.Color.Accent,
		radius = Theme.Radius.Pill,
		parent = self.alertBanner,
	})

	self.alertTitle = UIKit.label({
		name = "Title",
		size = UDim2.new(1, -Theme.Space.XL, 0, 28),
		position = UDim2.fromOffset(Theme.Space.L, Theme.Space.M),
		text = "",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.HeadingSize,
		font = Theme.Font.Display,
		truncate = true,
		parent = self.alertBanner,
	})

	self.alertBody = UIKit.label({
		name = "Body",
		size = UDim2.new(1, -Theme.Space.XL, 0, 36),
		position = UDim2.fromOffset(Theme.Space.L, 44),
		text = "",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.BodySize,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		parent = self.alertBanner,
	})

	-- Full-screen shift warning.
	self.warningOverlay = UIKit.frame({
		name = "ShiftWarning",
		size = UDim2.fromScale(1, 1),
		color = Theme.Color.Danger,
		transparency = 1,
		visible = false,
		parent = shell.criticalHost,
	})

	self.warningTitle = UIKit.label({
		name = "WarningTitle",
		size = UDim2.new(1, 0, 0, 56),
		position = UDim2.fromScale(0.5, 0.34),
		anchor = Vector2.new(0.5, 0.5),
		text = "",
		textColor = Theme.Color.Text,
		textSize = 40,
		font = Theme.Font.Display,
		align = Enum.TextXAlignment.Center,
		parent = self.warningOverlay,
	})

	self.warningBody = UIKit.label({
		name = "WarningBody",
		size = UDim2.new(1, 0, 0, 30),
		position = UDim2.fromScale(0.5, 0.42),
		anchor = Vector2.new(0.5, 0.5),
		text = "",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.HeadingSize,
		align = Enum.TextXAlignment.Center,
		parent = self.warningOverlay,
	})

	self:_wire()
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Toasts
-- ─────────────────────────────────────────────────────────────────────────────

function Notifications:toast(payload)
	--[[ Telegraph-only notifications (monster wind-ups) carry no text; they are
	     for the combat indicator, not the toast stack. ]]
	if payload.telegraph and (payload.title or "") == "" then
		return
	end

	local accent = KIND_COLOR[payload.kind] or Theme.Color.Info

	local card = UIKit.frame({
		name = "Toast",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		stroke = true,
		strokeTransparency = 0.4,
		automaticSize = Enum.AutomaticSize.Y,
		parent = self.toastColumn,
	})
	card.LayoutOrder = math.floor(os.clock() * 100)

	UIKit.frame({
		name = "Accent",
		size = UDim2.new(0, 3, 1, -12),
		position = UDim2.fromOffset(0, 6),
		color = accent,
		radius = Theme.Radius.Pill,
		parent = card,
	})

	local content = UIKit.frame({
		name = "Content",
		size = UDim2.new(1, -Theme.Space.L, 0, 0),
		position = UDim2.fromOffset(Theme.Space.M, 0),
		transparency = 1,
		automaticSize = Enum.AutomaticSize.Y,
		parent = card,
	})
	UIKit.padding(content, Theme.Space.S)
	UIKit.list(content, { padding = 2 })

	UIKit.label({
		name = "Title",
		size = UDim2.new(1, 0, 0, 18),
		text = payload.title or "",
		textColor = accent,
		textSize = Theme.Text.BodySize,
		font = Theme.Font.Heading,
		truncate = true,
		parent = content,
	}).LayoutOrder =
		1

	if payload.body and payload.body ~= "" then
		local body = UIKit.label({
			name = "Body",
			size = UDim2.new(1, 0, 0, 0),
			text = payload.body,
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.SmallSize,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			automaticSize = Enum.AutomaticSize.Y,
			parent = content,
		})
		body.LayoutOrder = 2
	end

	if payload.detail then
		UIKit.label({
			name = "Detail",
			size = UDim2.new(1, 0, 0, 14),
			text = payload.detail,
			textColor = Theme.Color.TextFaint,
			textSize = Theme.Text.TinySize,
			parent = content,
		}).LayoutOrder =
			3
	end

	--[[ An invite toast gets a join button, because an invite you cannot accept
	     from where you read it is just noise. ]]
	if payload.kind == "invite" and payload.code then
		local accept = UIKit.primaryButton({
			name = "Accept",
			size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
			text = "Join party " .. payload.code,
			textSize = Theme.Text.SmallSize,
			parent = content,
			onClick = function()
				if self.onJoinParty then
					self.onJoinParty(payload.code)
				end
			end,
		})
		accept.LayoutOrder = 4
	end

	table.insert(self._toasts, card)
	while #self._toasts > MAX_TOASTS do
		local oldest = table.remove(self._toasts, 1)
		if oldest then
			oldest:Destroy()
		end
	end

	card.BackgroundTransparency = 1
	UIKit.tween(card, { BackgroundTransparency = 0 }, Theme.Tween.Normal)

	task.delay(payload.lifetime or TOAST_LIFETIME, function()
		if not card.Parent then
			return
		end
		UIKit.tween(card, { BackgroundTransparency = 1 }, Theme.Tween.Slow)
		for _, descendant in ipairs(card:GetDescendants()) do
			if descendant:IsA("TextLabel") then
				UIKit.tween(descendant, { TextTransparency = 1 }, Theme.Tween.Slow)
			end
		end
		task.delay(Theme.Tween.Slow + 0.1, function()
			local index = table.find(self._toasts, card)
			if index then
				table.remove(self._toasts, index)
			end
			card:Destroy()
		end)
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Alerts
-- ─────────────────────────────────────────────────────────────────────────────

function Notifications:alert(payload)
	local accent = KIND_COLOR[payload.kind] or Theme.Color.Accent

	self.alertAccent.BackgroundColor3 = accent
	self.alertTitle.Text = payload.title or ""
	self.alertTitle.TextColor3 = accent
	self.alertBody.Text = payload.body or ""
	self.alertBanner.Visible = true
	self.alertBanner.BackgroundTransparency = 1

	UIKit.tween(self.alertBanner, { BackgroundTransparency = 0.05 }, Theme.Tween.Normal)

	self._alertToken = (self._alertToken or 0) + 1
	local token = self._alertToken

	task.delay(payload.duration or 4, function()
		if token ~= self._alertToken then
			return
		end
		UIKit.tween(self.alertBanner, { BackgroundTransparency = 1 }, Theme.Tween.Slow)
		task.delay(Theme.Tween.Slow + 0.05, function()
			if token == self._alertToken then
				self.alertBanner.Visible = false
			end
		end)
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Shift warning
-- ─────────────────────────────────────────────────────────────────────────────

function Notifications:shiftWarning(payload)
	self.warningTitle.Text = payload.title or "WARNING: THE CAVES ARE SHIFTING"
	self.warningBody.Text = payload.body or "RETURN TO THE COLONY."
	self.warningOverlay.Visible = true

	--[[ A hard pulse of red at the screen edges rather than a flat wash, so the
	     player can still see where they are going while being told to run. ]]
	local peak = payload.secondsRemaining and payload.secondsRemaining <= 10 and 0.78 or 0.88
	self.warningOverlay.BackgroundTransparency = 1
	UIKit.tween(self.warningOverlay, { BackgroundTransparency = peak }, 0.18)

	self._warnToken = (self._warnToken or 0) + 1
	local token = self._warnToken

	task.delay(0.22, function()
		if token ~= self._warnToken then
			return
		end
		UIKit.tween(self.warningOverlay, { BackgroundTransparency = 1 }, 0.9)
	end)

	task.delay(payload.secondsRemaining and 2.6 or 4, function()
		if token ~= self._warnToken then
			return
		end
		self.warningOverlay.Visible = false
	end)
end

function Notifications:shiftApplied(payload)
	self:alert({
		kind = "danger",
		title = "THE CAVES HAVE SHIFTED",
		body = ("%d passages changed. Your map is out of date."):format(
			(payload.opened or 0) + (payload.closed or 0)
		),
		duration = 4,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Wiring
-- ─────────────────────────────────────────────────────────────────────────────

function Notifications:_wire()
	self.store.notified:Connect(function(payload)
		self:toast(payload)
	end)
	self.store.alerted:Connect(function(payload)
		self:alert(payload)
	end)
	self.store.shiftWarned:Connect(function(payload)
		self:shiftWarning(payload)
	end)
	self.store.shiftApplied:Connect(function(payload)
		self:shiftApplied(payload)
	end)
	self.store.discovery:Connect(function(payload)
		self:toast({
			kind = "success",
			title = payload.title or "Discovery",
			body = payload.cellKey and "Marked on your map." or nil,
		})
	end)
	self.store.teammateDowned:Connect(function(payload)
		self:alert({
			kind = "danger",
			title = ("%s IS DOWN"):format(string.upper(payload.name or "A teammate")),
			body = ("%d seconds to reach them."):format(math.floor(payload.seconds or 0)),
			duration = 4,
		})
	end)
	self.store.teammateRevived:Connect(function(payload)
		self:toast({
			kind = "success",
			title = ("%s is back up"):format(payload.name or "Teammate"),
			body = payload.byName and ("Revived by " .. payload.byName) or nil,
		})
	end)
end

return Notifications
