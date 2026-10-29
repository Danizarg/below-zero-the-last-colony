--[[
	ExpeditionHUD.lua
	Everything the player needs underground, and nothing else.

	Layout
	──────
		top centre     phase, clock, and the shift countdown
		top right      team roster with health and downed timers
		right          objective tracker and a compact room map
		bottom left    health, stamina, hunger
		bottom right   bag weight, equipped tool, extraction state
		bottom centre  ability button (and action buttons on touch)
		overlays       downed countdown, spectate-and-rescue

	The shift countdown is the most prominent number on screen once dusk starts,
	because it is the only one that can kill you by surprise.

	Touch support is a real control cluster, not a scaled-down desktop HUD:
	attack, interact and ability are 56px buttons in the thumb zone, and sprint
	is a toggle rather than a hold.
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local ExpeditionHUD = {}
ExpeditionHUD.__index = ExpeditionHUD

local PHASE_LABEL = {
	prep = "PREPARATION",
	day = "DAY",
	dusk = "DUSK",
	night = "NIGHT",
	ended = "OVER",
}

local PHASE_COLOR = {
	prep = Theme.Color.PhasePrep,
	day = Theme.Color.PhaseDay,
	dusk = Theme.Color.PhaseDusk,
	night = Theme.Color.PhaseNight,
	ended = Theme.Color.TextMuted,
}

local PHASE_BLURB = {
	prep = "The caves are quiet. Gather while you can.",
	day = "Monsters are sluggish. Push deeper.",
	dusk = "The caves are about to shift. Start heading back.",
	night = "Everything down here is awake.",
}

function ExpeditionHUD.new(shell, store)
	local self = setmetatable({}, ExpeditionHUD)
	self.shell = shell
	self.store = store
	self._teamRows = {}
	self._objectiveRows = {}

	--[[ Callbacks the controllers assign. The HUD never sends network requests
	     itself; it reports intent and lets the controllers validate and send. ]]
	self.onAttack = nil
	self.onInteract = nil
	self.onAbility = nil
	self.onSprint = nil
	self.onExtract = nil
	self.onRescue = nil
	self.onLeave = nil

	local isTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	self.isTouch = isTouch

	self.root = UIKit.frame({
		name = "ExpeditionHUD",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
		visible = false,
		parent = shell.hudHost,
	})

	self:_buildClock()
	self:_buildVitals()
	self:_buildTeam()
	self:_buildObjectives()
	self:_buildBag()
	self:_buildActions()
	self:_buildOverlays()

	self:_wire()
	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Clock
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionHUD:_buildClock()
	local card = UIKit.frame({
		name = "Clock",
		size = UDim2.new(0, 300, 0, 86),
		position = UDim2.new(0.5, 0, 0, Theme.Space.M + 36),
		anchor = Vector2.new(0.5, 0),
		color = Theme.Color.Backdrop,
		transparency = 0.12,
		radius = Theme.Radius.M,
		stroke = true,
		strokeTransparency = 0.45,
		parent = self.root,
	})
	UIKit.padding(card, Theme.Space.S)

	self.phaseLabel = UIKit.label({
		name = "Phase",
		size = UDim2.new(0.55, 0, 0, 22),
		text = "—",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.SubheadingSize,
		font = Theme.Font.Display,
		parent = card,
	})

	self.clockLabel = UIKit.label({
		name = "Remaining",
		size = UDim2.new(0.45, 0, 0, 22),
		position = UDim2.fromScale(0.55, 0),
		text = "0:00",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.SubheadingSize,
		font = Theme.Font.Mono,
		align = Enum.TextXAlignment.Right,
		parent = card,
	})

	self.phaseBar = UIKit.bar({
		name = "PhaseBar",
		size = UDim2.new(1, 0, 0, 6),
		fillColor = Theme.Color.PhaseDay,
		showText = false,
		parent = card,
	})
	self.phaseBar.root.Position = UDim2.fromOffset(0, 26)

	self.phaseBlurb = UIKit.label({
		name = "Blurb",
		size = UDim2.new(1, 0, 0, 16),
		position = UDim2.fromOffset(0, 36),
		text = "",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.TinySize,
		truncate = true,
		parent = card,
	})

	--[[ The shift countdown. Hidden until dusk, then the loudest thing in the
	     top half of the screen. ]]
	self.shiftLabel = UIKit.label({
		name = "ShiftCountdown",
		size = UDim2.new(1, 0, 0, 22),
		position = UDim2.fromOffset(0, 52),
		text = "",
		textColor = Theme.Color.Danger,
		textSize = Theme.Text.SubheadingSize,
		font = Theme.Font.Display,
		align = Enum.TextXAlignment.Center,
		visible = false,
		parent = card,
	})

	self.locationLabel = UIKit.label({
		name = "Location",
		size = UDim2.new(0, 300, 0, 16),
		position = UDim2.new(0.5, 0, 0, Theme.Space.M + 126),
		anchor = Vector2.new(0.5, 0),
		text = "",
		textColor = Theme.Color.TextFaint,
		textSize = Theme.Text.SmallSize,
		align = Enum.TextXAlignment.Center,
		parent = self.root,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Vitals
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionHUD:_buildVitals()
	local card = UIKit.frame({
		name = "Vitals",
		size = UDim2.new(0, 230, 0, 92),
		position = UDim2.new(0, Theme.Space.M, 1, -(self.isTouch and 120 or Theme.Space.M)),
		anchor = Vector2.new(0, 1),
		color = Theme.Color.Backdrop,
		transparency = 0.12,
		radius = Theme.Radius.M,
		stroke = true,
		strokeTransparency = 0.45,
		parent = self.root,
	})
	UIKit.padding(card, Theme.Space.S)
	UIKit.list(card, { padding = Theme.Space.XS })

	local function makeBar(label, color, order)
		local row = UIKit.frame({
			name = label,
			size = UDim2.new(1, 0, 0, 22),
			transparency = 1,
			parent = card,
		})
		row.LayoutOrder = order

		UIKit.label({
			name = "Key",
			size = UDim2.new(0, 22, 1, 0),
			text = label,
			textColor = color,
			textSize = Theme.Text.TinySize,
			font = Theme.Font.Heading,
			parent = row,
		})

		local bar = UIKit.bar({
			name = "Bar",
			size = UDim2.new(1, -26, 0, 14),
			position = UDim2.fromOffset(26, 4),
			fillColor = color,
			textSize = Theme.Text.TinySize,
			parent = row,
		})
		bar.root.Position = UDim2.fromOffset(26, 4)
		return bar
	end

	self.healthBar = makeBar("HP", Theme.Color.Health, 1)
	self.staminaBar = makeBar("ST", Theme.Color.Stamina, 2)
	self.hungerBar = makeBar("FD", Theme.Color.Hunger, 3)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Team
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionHUD:_buildTeam()
	self.teamCard = UIKit.frame({
		name = "Team",
		size = UDim2.new(0, 240, 0, 0),
		position = UDim2.new(1, -Theme.Space.M, 0, Theme.Space.M + 36),
		anchor = Vector2.new(1, 0),
		color = Theme.Color.Backdrop,
		transparency = 0.12,
		radius = Theme.Radius.M,
		stroke = true,
		strokeTransparency = 0.45,
		automaticSize = Enum.AutomaticSize.Y,
		visible = false,
		parent = self.root,
	})
	UIKit.padding(self.teamCard, Theme.Space.S)
	UIKit.list(self.teamCard, { padding = Theme.Space.XS })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 14),
		text = "TEAM",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = self.teamCard,
	}).LayoutOrder =
		0
end

function ExpeditionHUD:_teamRow(member)
	local row = self._teamRows[member.userId]
	if row then
		return row
	end

	local container = UIKit.frame({
		name = "Member_" .. member.userId,
		size = UDim2.new(1, 0, 0, 34),
		color = Theme.Color.Field,
		transparency = 0.4,
		radius = Theme.Radius.S,
		parent = self.teamCard,
	})

	local icon = UIKit.label({
		name = "Icon",
		size = UDim2.fromOffset(24, 34),
		position = UDim2.fromOffset(4, 0),
		text = "◈",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.BodySize,
		align = Enum.TextXAlignment.Center,
		parent = container,
	})

	local name = UIKit.label({
		name = "Name",
		size = UDim2.new(1, -92, 0, 16),
		position = UDim2.fromOffset(30, 2),
		text = member.name or "?",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.SmallSize,
		font = Theme.Font.Heading,
		truncate = true,
		parent = container,
	})

	local bar = UIKit.bar({
		name = "Health",
		size = UDim2.new(1, -96, 0, 6),
		fillColor = Theme.Color.Health,
		showText = false,
		parent = container,
	})
	bar.root.Position = UDim2.fromOffset(30, 22)

	local status = UIKit.label({
		name = "Status",
		size = UDim2.fromOffset(58, 34),
		position = UDim2.new(1, -60, 0, 0),
		text = "",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Mono,
		align = Enum.TextXAlignment.Right,
		parent = container,
	})

	--[[ Tapping a downed teammate's row is the touch path to reviving them. On
	     desktop the proximity prompt covers it, but a thumb needs a target. ]]
	local hit = UIKit.button({
		name = "Revive",
		size = UDim2.fromScale(1, 1),
		text = "",
		color = Theme.Color.Field,
		transparency = 1,
		stroke = false,
		radius = Theme.Radius.S,
		parent = container,
		onClick = function()
			if self.onRevive then
				self.onRevive(member.userId)
			end
		end,
	})
	hit.Visible = false

	row = { container = container, icon = icon, name = name, bar = bar, status = status, reviveButton = hit }
	self._teamRows[member.userId] = row
	return row
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Objectives
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionHUD:_buildObjectives()
	self.objectiveCard = UIKit.frame({
		name = "Objectives",
		size = UDim2.new(0, 240, 0, 0),
		position = UDim2.new(1, -Theme.Space.M, 0, Theme.Space.M + 220),
		anchor = Vector2.new(1, 0),
		color = Theme.Color.Backdrop,
		transparency = 0.12,
		radius = Theme.Radius.M,
		stroke = true,
		strokeTransparency = 0.45,
		automaticSize = Enum.AutomaticSize.Y,
		parent = self.root,
	})
	UIKit.padding(self.objectiveCard, Theme.Space.S)
	UIKit.list(self.objectiveCard, { padding = 2 })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 14),
		text = "OBJECTIVES",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = self.objectiveCard,
	}).LayoutOrder =
		0

	self.explorationLabel = UIKit.label({
		name = "Exploration",
		size = UDim2.new(1, 0, 0, 16),
		text = "",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.TinySize,
		parent = self.objectiveCard,
	})
	self.explorationLabel.LayoutOrder = 99
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Bag and tool
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionHUD:_buildBag()
	local card = UIKit.frame({
		name = "Bag",
		size = UDim2.new(0, 220, 0, 72),
		position = UDim2.new(1, -Theme.Space.M, 1, -(self.isTouch and 200 or Theme.Space.M)),
		anchor = Vector2.new(1, 1),
		color = Theme.Color.Backdrop,
		transparency = 0.12,
		radius = Theme.Radius.M,
		stroke = true,
		strokeTransparency = 0.45,
		parent = self.root,
	})
	UIKit.padding(card, Theme.Space.S)

	self.toolLabel = UIKit.label({
		name = "Tool",
		size = UDim2.new(1, 0, 0, 18),
		text = "Bare Hands",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.SmallSize,
		font = Theme.Font.Heading,
		parent = card,
	})

	self.bagBar = UIKit.bar({
		name = "Capacity",
		size = UDim2.new(1, 0, 0, 12),
		fillColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		parent = card,
	})
	self.bagBar.root.Position = UDim2.fromOffset(0, 22)

	self.extractionLabel = UIKit.label({
		name = "Extraction",
		size = UDim2.new(1, 0, 0, 18),
		position = UDim2.fromOffset(0, 38),
		text = "",
		textColor = Theme.Color.Success,
		textSize = Theme.Text.SmallSize,
		font = Theme.Font.Heading,
		parent = card,
	})
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Actions
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionHUD:_buildActions()
	-- Ability button, bottom centre, always present.
	self.abilityButton = UIKit.button({
		name = "Ability",
		size = UDim2.fromOffset(self.isTouch and 72 or 180, self.isTouch and 72 or 52),
		position = UDim2.new(0.5, 0, 1, -(self.isTouch and 120 or Theme.Space.M)),
		anchor = Vector2.new(0.5, 1),
		text = "ABILITY",
		textSize = Theme.Text.SmallSize,
		color = Theme.Color.PanelRaised,
		radius = self.isTouch and Theme.Radius.Pill or Theme.Radius.M,
		parent = self.root,
		onClick = function()
			if self.onAbility then
				self.onAbility()
			end
		end,
	})

	self.abilityCooldown = UIKit.frame({
		name = "Cooldown",
		size = UDim2.fromScale(0, 1),
		color = Theme.Color.Void,
		transparency = 0.45,
		radius = self.isTouch and Theme.Radius.Pill or Theme.Radius.M,
		parent = self.abilityButton,
	})
	self.abilityCooldown.ZIndex = 3

	if not self.isTouch then
		return
	end

	--[[ Touch control cluster, bottom-right, inside the natural thumb arc.
	     These are the only way to attack or interact without a keyboard. ]]
	local cluster = UIKit.frame({
		name = "TouchActions",
		size = UDim2.fromOffset(140, 140),
		position = UDim2.new(1, -Theme.Space.M, 1, -Theme.Space.M),
		anchor = Vector2.new(1, 1),
		transparency = 1,
		parent = self.root,
	})

	local function actionButton(name, text, position, callbackName)
		return UIKit.button({
			name = name,
			size = UDim2.fromOffset(62, 62),
			position = position,
			text = text,
			textSize = Theme.Text.SubheadingSize,
			color = Theme.Color.PanelRaised,
			radius = Theme.Radius.Pill,
			parent = cluster,
			onClick = function()
				local callback = self[callbackName]
				if callback then
					callback()
				end
			end,
		})
	end

	actionButton("Attack", "⚔", UDim2.fromOffset(74, 0), "onAttack")
	actionButton("Interact", "✋", UDim2.fromOffset(0, 74), "onInteract")

	self.sprintButton = actionButton("Sprint", "»", UDim2.fromOffset(74, 74), "onSprintToggle")
	self.onSprintToggle = function()
		self._sprinting = not self._sprinting
		self.sprintButton.BackgroundColor3 = self._sprinting and Theme.Color.Accent or Theme.Color.PanelRaised
		if self.onSprint then
			self.onSprint(self._sprinting)
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Overlays
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionHUD:_buildOverlays()
	-- Downed.
	self.downedOverlay = UIKit.frame({
		name = "Downed",
		size = UDim2.fromScale(1, 1),
		color = Theme.Color.Health,
		transparency = 0.82,
		visible = false,
		zIndex = Theme.ZIndex.Critical,
		parent = self.shell.criticalHost,
	})

	self.downedTitle = UIKit.label({
		name = "Title",
		size = UDim2.new(1, 0, 0, 48),
		position = UDim2.fromScale(0.5, 0.42),
		anchor = Vector2.new(0.5, 0.5),
		text = "YOU ARE DOWN",
		textColor = Theme.Color.Text,
		textSize = 38,
		font = Theme.Font.Display,
		align = Enum.TextXAlignment.Center,
		parent = self.downedOverlay,
	})

	self.downedTimer = UIKit.label({
		name = "Timer",
		size = UDim2.new(1, 0, 0, 60),
		position = UDim2.fromScale(0.5, 0.52),
		anchor = Vector2.new(0.5, 0.5),
		text = "",
		textColor = Theme.Color.Text,
		textSize = 54,
		font = Theme.Font.Mono,
		align = Enum.TextXAlignment.Center,
		parent = self.downedOverlay,
	})

	self.downedHint = UIKit.label({
		name = "Hint",
		size = UDim2.new(1, 0, 0, 24),
		position = UDim2.fromScale(0.5, 0.6),
		anchor = Vector2.new(0.5, 0.5),
		text = "Hold on. Someone can still reach you.",
		textColor = Theme.Color.Text,
		textSize = Theme.Text.SubheadingSize,
		align = Enum.TextXAlignment.Center,
		parent = self.downedOverlay,
	})

	-- Spectating after death.
	self.spectateOverlay = UIKit.frame({
		name = "Spectate",
		size = UDim2.fromScale(1, 1),
		color = Theme.Color.Void,
		transparency = 0.45,
		visible = false,
		zIndex = Theme.ZIndex.Critical,
		parent = self.shell.criticalHost,
	})

	local panel = UIKit.frame({
		name = "Panel",
		size = UDim2.fromOffset(420, 280),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = Theme.Color.Panel,
		radius = Theme.Radius.L,
		stroke = true,
		parent = self.spectateOverlay,
	})
	UIKit.padding(panel, Theme.Space.L)
	UIKit.list(panel, { padding = Theme.Space.S })

	UIKit.label({
		name = "Title",
		size = UDim2.new(1, 0, 0, 32),
		text = "YOU DIED",
		textColor = Theme.Color.Danger,
		textSize = Theme.Text.TitleSize,
		font = Theme.Font.Display,
		align = Enum.TextXAlignment.Center,
		parent = panel,
	}).LayoutOrder =
		1

	--[[ Why you died, in plain words. The brief asks that players always
	     understand their death, and the server sends the damage breakdown for
	     exactly this. ]]
	self.deathCause = UIKit.label({
		name = "Cause",
		size = UDim2.new(1, 0, 0, 0),
		text = "",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.BodySize,
		align = Enum.TextXAlignment.Center,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		automaticSize = Enum.AutomaticSize.Y,
		parent = panel,
	})
	self.deathCause.LayoutOrder = 2

	UIKit.spacer(panel, Theme.Space.S, 3)

	self.rescueButton = UIKit.primaryButton({
		name = "Rescue",
		size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
		text = "Use free rescue",
		parent = panel,
		onClick = function()
			if self.onRescue then
				self.onRescue(false)
			end
		end,
	})
	self.rescueButton.LayoutOrder = 4

	self.rescueNote = UIKit.label({
		name = "RescueNote",
		size = UDim2.new(1, 0, 0, 32),
		text = "",
		textColor = Theme.Color.TextFaint,
		textSize = Theme.Text.TinySize,
		align = Enum.TextXAlignment.Center,
		wrapped = true,
		parent = panel,
	})
	self.rescueNote.LayoutOrder = 5

	self.spectateButton = UIKit.button({
		name = "Spectate",
		size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
		text = "Watch the rest of the run",
		textSize = Theme.Text.SmallSize,
		parent = panel,
		onClick = function()
			self.spectateOverlay.Visible = false
		end,
	})
	self.spectateButton.LayoutOrder = 6
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Refresh
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionHUD:refreshVitals()
	local stats = self.store.state.stats
	self.healthBar.set(stats.health, stats.maxHealth)
	self.staminaBar.set(stats.stamina, stats.staminaMax)
	self.hungerBar.set(stats.hunger, stats.hungerMax)

	--[[ Colour shifts as a bar gets dangerous, so peripheral vision is enough
	     to notice. ]]
	local healthFraction = stats.health / math.max(1, stats.maxHealth)
	self.healthBar.setColor(healthFraction < 0.3 and Theme.Color.Danger or Theme.Color.Health)
	self.hungerBar.setColor(stats.hunger < 20 and Theme.Color.Danger or Theme.Color.Hunger)

	-- Downed overlay.
	local downed = stats.state == Enums.MemberState.Downed and stats.downedRemaining
	if downed then
		self.downedOverlay.Visible = true
		self.downedTimer.Text = ("%.1f"):format(math.max(0, downed))
		--[[ A frozen timer means a Medic is holding it. Saying so turns a
		     confusing number into a readable rescue in progress. ]]
		if self._lastDownedRemaining and math.abs(self._lastDownedRemaining - downed) < 0.01 then
			self.downedHint.Text = "Someone is stabilising you. The timer has stopped."
			self.downedTimer.TextColor3 = Theme.Color.Success
		else
			self.downedHint.Text = "Hold on. Someone can still reach you."
			self.downedTimer.TextColor3 = Theme.Color.Text
		end
		self._lastDownedRemaining = downed
	else
		self.downedOverlay.Visible = false
		self._lastDownedRemaining = nil
	end
end

function ExpeditionHUD:refreshClock()
	local expedition = self.store.state.expedition
	if not expedition then
		return
	end

	local phase = expedition.phase or "day"
	self.phaseLabel.Text = PHASE_LABEL[phase] or string.upper(phase)
	self.phaseLabel.TextColor3 = PHASE_COLOR[phase] or Theme.Color.Text
	self.phaseBlurb.Text = PHASE_BLURB[phase] or ""
	self.phaseBar.setColor(PHASE_COLOR[phase] or Theme.Color.Accent)

	--[[ The server sends remaining DURATIONS plus the client's own receipt
	     stamp, never a server timestamp: os.clock() is process-relative, so
	     subtracting the client's clock from a server clock value yields
	     nonsense. Everything below counts down from the last sync using this
	     client's clock, which is the only one it can trust. ]]
	local sinceSync = math.max(0, os.clock() - (expedition.syncedAt or os.clock()))

	local remaining = math.max(0, (expedition.phaseRemaining or 0) - sinceSync)
	local duration = math.max(1, expedition.phaseDuration or 1)
	self.clockLabel.Text = UIKit.formatClock(remaining)
	self.phaseBar.set(duration - remaining, duration)

	if expedition.nextShiftIn then
		self.shiftLabel.Visible = true
		local seconds = math.max(0, expedition.nextShiftIn - sinceSync)
		self.shiftLabel.Text = ("SHIFT IN %s"):format(UIKit.formatClock(seconds))
		self.shiftLabel.TextColor3 = seconds <= 30 and Theme.Color.Danger or Theme.Color.Warning
	else
		self.shiftLabel.Visible = false
	end

	local parts = {}
	if expedition.biomeName then
		table.insert(parts, expedition.biomeName)
	end
	if expedition.roomName then
		table.insert(parts, expedition.roomName)
	end
	table.insert(
		parts,
		("%s · shift %d"):format(expedition.difficultyName or "?", expedition.shiftsApplied or 0)
	)
	self.locationLabel.Text = table.concat(parts, "  ·  ")

	self.extractionLabel.Text = expedition.atExtraction and "◆ EXTRACTION READY — hold E" or ""
end

function ExpeditionHUD:refreshTeam()
	local expedition = self.store.state.expedition
	if not expedition then
		self.teamCard.Visible = false
		return
	end

	local team = expedition.team or {}
	--[[ Solo runs hide the team card entirely rather than showing a list of
	     one, which would just be a duplicate of the vitals panel. ]]
	self.teamCard.Visible = #team > 1

	local seen = {}
	for index, member in ipairs(team) do
		seen[member.userId] = true
		local row = self:_teamRow(member)
		row.container.LayoutOrder = index
		row.name.Text = member.name or "?"
		row.bar.set(member.health or 0, member.maxHealth or 100)

		if member.state == Enums.MemberState.Downed then
			row.status.Text = member.downedRemaining and ("%.0fs"):format(member.downedRemaining) or "DOWN"
			row.status.TextColor3 = Theme.Color.Danger
			row.icon.Text = "✚"
			row.icon.TextColor3 = Theme.Color.Danger
			row.reviveButton.Visible = self.isTouch
			row.bar.setColor(Theme.Color.Danger)
		elseif member.state == Enums.MemberState.Dead then
			row.status.Text = "DEAD"
			row.status.TextColor3 = Theme.Color.TextFaint
			row.icon.Text = "✖"
			row.icon.TextColor3 = Theme.Color.TextFaint
			row.reviveButton.Visible = false
			row.container.BackgroundTransparency = 0.7
		elseif member.state == Enums.MemberState.Extracted then
			row.status.Text = "OUT"
			row.status.TextColor3 = Theme.Color.Success
			row.icon.Text = "◆"
			row.icon.TextColor3 = Theme.Color.Success
			row.reviveButton.Visible = false
		else
			row.status.Text = ("%d"):format(member.health or 0)
			row.status.TextColor3 = Theme.Color.TextMuted
			row.icon.Text = member.isLeader and "★" or "◈"
			row.icon.TextColor3 = Theme.Color.Accent
			row.reviveButton.Visible = false
			row.bar.setColor(Theme.Color.Health)
			row.container.BackgroundTransparency = 0.4
		end
	end

	for userId, row in pairs(self._teamRows) do
		if not seen[userId] then
			row.container:Destroy()
			self._teamRows[userId] = nil
		end
	end
end

function ExpeditionHUD:refreshObjectives()
	local objectives = self.store.state.objectives
	if not objectives then
		return
	end

	local seen = {}
	for index, objective in ipairs(objectives.objectives or {}) do
		seen[objective.id] = true
		local row = self._objectiveRows[objective.id]
		if not row then
			row = UIKit.label({
				name = "Obj_" .. objective.id,
				size = UDim2.new(1, 0, 0, 18),
				text = "",
				textColor = Theme.Color.Text,
				textSize = Theme.Text.SmallSize,
				truncate = true,
				parent = self.objectiveCard,
			})
			self._objectiveRows[objective.id] = row
		end
		row.LayoutOrder = index

		local marker = objective.done and "✔" or (objective.discovered and "◆" or "·")
		local label = objective.label or objective.kind
		if not objective.discovered and not objective.done then
			label = ("%s (undiscovered)"):format(label)
		end
		row.Text = ("%s  %s"):format(marker, label)
		row.TextColor3 = objective.done and Theme.Color.Success
			or (objective.discovered and Theme.Color.Text or Theme.Color.TextFaint)
	end

	for id, row in pairs(self._objectiveRows) do
		if not seen[id] then
			row:Destroy()
			self._objectiveRows[id] = nil
		end
	end

	self.explorationLabel.Text = ("Explored %d / %d rooms  ·  Keys %d / %d"):format(
		objectives.roomsDiscovered or 0,
		objectives.totalRooms or 0,
		objectives.keysCollected or 0,
		objectives.keysRequired or 1
	)
end

function ExpeditionHUD:refreshBag()
	local state = self.store.state
	self.bagBar.set(
		state.bagUsed or 0,
		math.max(1, state.bagCapacity or 1),
		("%d / %d kg"):format(math.floor(state.bagUsed or 0), math.floor(state.bagCapacity or 0))
	)

	local fraction = (state.bagUsed or 0) / math.max(1, state.bagCapacity or 1)
	self.bagBar.setColor(
		fraction > 0.95 and Theme.Color.Danger
			or (fraction > 0.8 and Theme.Color.Warning or Theme.Color.Accent)
	)

	local tool = ResourceConfig.Tools[state.equippedTool]
	if tool then
		local entry = state.tools and state.tools[state.equippedTool]
		if tool.maxDurability > 0 and entry then
			self.toolLabel.Text = ("%s  (%d%%)"):format(
				tool.name,
				math.floor(((entry.durability or 0) / tool.maxDurability) * 100)
			)
		else
			self.toolLabel.Text = tool.name
		end
	end
end

function ExpeditionHUD:refreshAbility()
	local role = self.store.state.role
	if not role or not role.ability then
		return
	end

	local label = role.ability.name or "Ability"
	self.abilityButton.Text = self.isTouch
			and (role.ability.name and string.sub(role.ability.name, 1, 1) or "★")
		or ("%s  [Q]"):format(label)

	--[[ AbilityState arrives only when the ability is used or the role refreshes,
	     so `cooldownRemaining` is a snapshot that never decreases. Counting down
	     locally from the stamp is what makes the shade actually drain instead of
	     sitting at full width until the next push. ]]
	local sinceSync = math.max(0, os.clock() - (role.syncedAt or os.clock()))
	local remaining = math.max(0, (role.cooldownRemaining or 0) - sinceSync)
	local total = math.max(1, role.ability.cooldown or 1)

	if remaining > 0.05 then
		self.abilityCooldown.Size = UDim2.fromScale(math.clamp(remaining / total, 0, 1), 1)
		self.abilityButton.TextTransparency = 0.4
	else
		self.abilityCooldown.Size = UDim2.fromScale(0, 1)
		self.abilityButton.TextTransparency = 0
	end
end

function ExpeditionHUD:refreshSpectate()
	local info = self.store.state.spectateInfo
	if not self.store.state.spectating or not info then
		self.spectateOverlay.Visible = false
		return
	end

	self.spectateOverlay.Visible = true

	local causeParts = info.damageSummary or {}
	if #causeParts > 0 then
		self.deathCause.Text = ("Killed by %s."):format(table.concat(causeParts, ", "))
	else
		self.deathCause.Text = ("Cause: %s."):format(tostring(info.cause or "unknown"))
	end

	local free = info.freeRescuesRemaining or 0
	if free > 0 then
		UIKit.setEnabled(self.rescueButton, true)
		self.rescueButton.Text = ("Use free rescue (%d left)"):format(free)
		--[[ The window matters: if this death wiped the party the run is only
		     held open briefly, and a button that quietly stops working is worse
		     than one that told you it would. ]]
		if info.rescueWindowSeconds then
			self.rescueNote.Text = (
				"A free rescue puts you back at the tunnel mouth with your bag. "
				.. "Decide within about %d seconds."
			):format(math.floor(info.rescueWindowSeconds))
		else
			self.rescueNote.Text = "A free rescue puts you back at the tunnel mouth with your bag."
		end
	else
		UIKit.setEnabled(self.rescueButton, false, "No free rescue left")
		self.rescueNote.Text = "Your free rescue is spent. You will return to the colony when the expedition ends, "
			.. "keeping part of your haul and all of your keys."
	end
end

function ExpeditionHUD:refresh()
	local inExpedition = self.store.state.zone == Enums.Zone.Expedition
	self.root.Visible = inExpedition
	if not inExpedition then
		self.downedOverlay.Visible = false
		self.spectateOverlay.Visible = false
		return
	end

	self:refreshVitals()
	self:refreshClock()
	self:refreshTeam()
	self:refreshObjectives()
	self:refreshBag()
	self:refreshAbility()
	self:refreshSpectate()
end

function ExpeditionHUD:_wire()
	self.store.changed:Connect(function(area)
		if area == "stats" then
			self:refreshVitals()
		elseif area == "expedition" then
			self:refreshClock()
			self:refreshTeam()
		elseif area == "objectives" then
			self:refreshObjectives()
		elseif area == "inventory" then
			self:refreshBag()
		elseif area == "role" then
			self:refreshAbility()
		elseif area == "spectate" then
			self:refreshSpectate()
		elseif area == "zone" then
			self:refresh()
		end
	end)

	--[[ The clock has to tick between server packets or it would jump in
	     half-second steps. Driven from RenderStepped only while visible. ]]
	RunService.RenderStepped:Connect(function()
		if not self.root.Visible then
			return
		end
		self:refreshClock()
		self:refreshAbility()
		if self.downedOverlay.Visible then
			local remaining = self.store.state.stats.downedRemaining
			if remaining then
				self.downedTimer.Text = ("%.1f"):format(math.max(0, remaining))
			end
		end
	end)
end

return ExpeditionHUD
