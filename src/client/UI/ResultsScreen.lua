--[[
	ResultsScreen.lua
	The post-expedition report.

	Shown as a modal with no scrim click-through, because it is the moment the
	run's consequences land and dismissing it by accident loses the only summary
	the player gets.

	It reports what was lost as plainly as what was gained. A failure screen that
	only shows the rewards teaches nothing.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local ResultsScreen = {}

local OUTCOME = {
	extracted = {
		title = "EXTRACTED",
		color = Theme.Color.Success,
		blurb = "You got out. Everything you carried is permanent now.",
	},
	timeout = {
		title = "CAUGHT BY THE SHIFT",
		color = Theme.Color.Warning,
		blurb = "Night ended with you still underground. You lost most of what you were carrying.",
	},
	died = {
		title = "LOST IN THE DARK",
		color = Theme.Color.Danger,
		blurb = "You did not make it back. What survived was recovered by the colony.",
	},
	wiped = {
		title = "THE PARTY WAS LOST",
		color = Theme.Color.Danger,
		blurb = "Nobody made it out. The colony recovered what it could.",
	},
	abandoned = {
		title = "EXPEDITION ABANDONED",
		color = Theme.Color.TextMuted,
		blurb = "You pulled out early. The usual recovery rules applied.",
	},
}

local function clearChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

local function resourceList(container, title, list, color, order)
	if not list or #list == 0 then
		return
	end

	local card = UIKit.frame({
		name = title,
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	card.LayoutOrder = order
	UIKit.padding(card, Theme.Space.M)
	UIKit.list(card, { padding = 2 })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 18),
		text = string.upper(title),
		textColor = color,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = card,
	}).LayoutOrder =
		1

	for index, entry in ipairs(list) do
		UIKit.label({
			name = "Entry_" .. entry.id,
			size = UDim2.new(1, 0, 0, 18),
			text = ("%s  %s  ×%d"):format(entry.icon or "•", entry.name, entry.count),
			textColor = Theme.Color.Text,
			textSize = Theme.Text.SmallSize,
			parent = card,
		}).LayoutOrder = 1
			+ index
	end
end

function ResultsScreen.create(shell, store)
	local panel = UIKit.panel({
		name = "ResultsScreen",
		title = "Expedition Report",
		onClose = function()
			shell:close()
		end,
	})

	local content = UIKit.scroll({
		name = "Content",
		size = UDim2.new(1, -Theme.Space.XL, 1, -(Theme.Space.XL + 56)),
		position = UDim2.fromOffset(Theme.Space.L, Theme.Space.M),
		parent = panel.body,
	})
	UIKit.list(content, { padding = Theme.Space.S })

	local dismiss = UIKit.primaryButton({
		name = "Dismiss",
		size = UDim2.new(1, -Theme.Space.XL, 0, Theme.MinTouchTarget),
		position = UDim2.new(0, Theme.Space.L, 1, -(Theme.MinTouchTarget + Theme.Space.M)),
		text = "Back to the colony",
		parent = panel.body,
		onClick = function()
			shell:close()
		end,
	})
	_ = dismiss

	store.resultsReady:Connect(function()
		--[[ Opening the results is a push, not a pull: the run ended, so the
		     player should be looking at the report whether or not they asked. ]]
		shell:open("results")
	end)

	return {
		root = panel.root,
		refresh = function()
			ResultsScreen.render(store, content)
		end,
	}
end

function ResultsScreen.render(store, container)
	clearChildren(container)

	local results = store.state.results
	if not results then
		UIKit.emptyState({ icon = "⛏", text = "No expedition to report on yet.", parent = container })
		return
	end

	local outcome = OUTCOME[results.outcome] or OUTCOME.timeout

	-- Headline.
	local headline = UIKit.frame({
		name = "Headline",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		stroke = true,
		strokeColor = outcome.color,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	headline.LayoutOrder = 1
	UIKit.padding(headline, Theme.Space.M)
	UIKit.list(headline, { padding = Theme.Space.XS })

	UIKit.label({
		name = "Outcome",
		size = UDim2.new(1, 0, 0, 30),
		text = outcome.title,
		textColor = outcome.color,
		textSize = Theme.Text.TitleSize,
		font = Theme.Font.Display,
		parent = headline,
	}).LayoutOrder =
		1

	UIKit.label({
		name = "Blurb",
		size = UDim2.new(1, 0, 0, 0),
		text = outcome.blurb,
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.SmallSize,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		automaticSize = Enum.AutomaticSize.Y,
		parent = headline,
	}).LayoutOrder =
		2

	if results.keptFraction then
		UIKit.label({
			name = "KeptRule",
			size = UDim2.new(1, 0, 0, 16),
			text = ("Recovery rate on this difficulty: %d%%"):format(math.floor(results.keptFraction * 100)),
			textColor = Theme.Color.TextFaint,
			textSize = Theme.Text.TinySize,
			parent = headline,
		}).LayoutOrder =
			3
	end

	if results.rescued then
		UIKit.label({
			name = "Rescued",
			size = UDim2.new(1, 0, 0, 16),
			text = "You used a rescue on this run.",
			textColor = Theme.Color.Info,
			textSize = Theme.Text.TinySize,
			parent = headline,
		}).LayoutOrder =
			4
	end

	-- Run summary.
	local summary = UIKit.frame({
		name = "Summary",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	summary.LayoutOrder = 2
	UIKit.padding(summary, Theme.Space.M)
	UIKit.list(summary, { padding = 2 })

	local rows = {
		{ label = "Difficulty", value = results.difficultyName or "?" },
		{ label = "Time underground", value = UIKit.formatClock(results.durationSeconds) },
		{
			label = "Rooms explored",
			value = ("%d / %d"):format(results.roomsDiscovered or 0, results.totalRooms or 0),
		},
		{ label = "Maze shifts survived", value = tostring(results.shiftsSurvived or 0) },
		{ label = "Enemies defeated", value = tostring(results.monstersDefeated or 0) },
		{ label = "Objectives completed", value = tostring(results.objectivesCompleted or 0) },
		{ label = "Times revived", value = tostring(results.revivesReceived or 0) },
		{ label = "Seed", value = tostring(results.seed or 0) },
	}
	for index, row in ipairs(rows) do
		UIKit.statRow({
			key = row.label,
			label = row.label,
			value = row.value,
			parent = summary,
		}).root.LayoutOrder =
			index
	end

	resourceList(container, "Brought home", results.extractedResources, Theme.Color.Success, 3)
	resourceList(container, "Lost", results.lostResources, Theme.Color.Danger, 4)
	resourceList(
		container,
		"Storage was full, left behind",
		results.overflowResources,
		Theme.Color.Warning,
		5
	)

	-- Progression.
	local progression = UIKit.frame({
		name = "Progression",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	progression.LayoutOrder = 6
	UIKit.padding(progression, Theme.Space.M)
	UIKit.list(progression, { padding = Theme.Space.XS })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 18),
		text = "PROGRESSION",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = progression,
	}).LayoutOrder =
		1

	UIKit.label({
		name = "Xp",
		size = UDim2.new(1, 0, 0, 20),
		text = ("+%d XP%s"):format(
			results.xpGained or 0,
			(results.levelsGained or 0) > 0 and ("   ·   LEVEL %d"):format(results.level) or ""
		),
		textColor = (results.levelsGained or 0) > 0 and Theme.Color.Accent or Theme.Color.Text,
		textSize = Theme.Text.BodySize,
		font = Theme.Font.Heading,
		parent = progression,
	}).LayoutOrder =
		2

	local breakdown = {}
	for bucket, amount in pairs(results.xpBreakdown or {}) do
		table.insert(breakdown, ("%s %d"):format(bucket, amount))
	end
	table.sort(breakdown)
	if #breakdown > 0 then
		UIKit.label({
			name = "Breakdown",
			size = UDim2.new(1, 0, 0, 16),
			text = table.concat(breakdown, "  ·  "),
			textColor = Theme.Color.TextFaint,
			textSize = Theme.Text.TinySize,
			parent = progression,
		}).LayoutOrder =
			3
	end

	local xpBar = UIKit.bar({
		name = "LevelBar",
		size = UDim2.new(1, 0, 0, 12),
		fillColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		parent = progression,
	})
	xpBar.root.LayoutOrder = 4
	xpBar.set(
		results.xpIntoLevel or 0,
		results.xpForNextLevel or 1,
		("Level %d  ·  %d / %d to next"):format(
			results.level or 1,
			results.xpIntoLevel or 0,
			results.xpForNextLevel or 0
		)
	)

	UIKit.label({
		name = "Mastery",
		size = UDim2.new(1, 0, 0, 18),
		text = ("%s mastery %d%s"):format(
			results.roleName or "Role",
			results.masteryLevel or 0,
			(results.masteryGained or 0) > 0 and (" (+%d)"):format(results.masteryGained) or ""
		),
		textColor = Theme.Color.Text,
		textSize = Theme.Text.SmallSize,
		parent = progression,
	}).LayoutOrder =
		5

	for index, unlock in ipairs(results.masteryUnlocks or {}) do
		UIKit.label({
			name = "Unlock_" .. unlock.id,
			size = UDim2.new(1, 0, 0, 16),
			text = ("✔ Unlocked: %s"):format(unlock.name),
			textColor = Theme.Color.Success,
			textSize = Theme.Text.TinySize,
			parent = progression,
		}).LayoutOrder = 5
			+ index
	end

	-- Colony rewards.
	UIKit.label({
		name = "ColonyNote",
		size = UDim2.new(1, 0, 0, 32),
		text = ("Colony level %d  ·  Ancient keys banked %d  ·  Gate stages opened %d"):format(
			results.colonyLevel or 1,
			results.keysBanked or 0,
			results.gateStages or 0
		),
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.SmallSize,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		parent = container,
	}).LayoutOrder =
		7
end

return ResultsScreen
