--[[
	ColonyPanel.lua
	Colony management: overview, colonist jobs and crafting.

	Three tabs rather than three panels, because they are all answers to "what
	is my colony doing" and splitting them would mean opening three windows to
	make one decision.

	Every row here is a request to the server. Nothing in this file computes a
	cost, a slot count or an outcome; it renders what the server sent and asks
	for changes by id.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local JobConfig = require(Shared.Config.JobConfig)
local Net = require(Shared.Util.Net)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local Routes = require(Shared.Routes)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local ColonyPanel = {}

local TABS = {
	{ id = "overview", label = "Overview" },
	{ id = "colonists", label = "Colonists" },
	{ id = "crafting", label = "Crafting" },
}

local function clearChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function ColonyPanel.create(shell, store)
	local panel = UIKit.panel({
		name = "ColonyPanel",
		title = "Colony",
		subtitle = "Manage your survivors and your stockpile",
		onClose = function()
			shell:close()
		end,
	})

	local activeTab = "overview"
	--[[ Declared up front so the tab handler closes over the local rather than
	     leaking a global. ]]
	local content

	local tabs = UIKit.tabs({
		tabs = TABS,
		parent = panel.body,
		onChange = function(id)
			activeTab = id
			ColonyPanel.render(shell, store, content, activeTab)
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

	local instance = {
		root = panel.root,
		refresh = function()
			ColonyPanel.render(shell, store, content, activeTab)
		end,
	}

	store.changed:Connect(function(area)
		if area == "colony" or area == "inventory" then
			shell:refreshIfOpen("colony")
		end
	end)

	return instance
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Overview
-- ─────────────────────────────────────────────────────────────────────────────

local function renderOverview(shell, store, container)
	local colony = store.state.colony
	if not colony then
		UIKit.emptyState({ icon = "⌂", text = "Your colony has not loaded yet.", parent = container })
		return
	end

	local stats = UIKit.frame({
		name = "Stats",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	stats.LayoutOrder = 1
	UIKit.padding(stats, Theme.Space.M)
	UIKit.list(stats, { padding = 2 })

	local rows = {
		{ label = "Colony level", value = tostring(colony.colonyLevel or 1) },
		{
			label = "Population",
			value = ("%d / %d"):format(colony.population or 0, colony.populationCap or 0),
		},
		{ label = "Food stored", value = tostring(math.floor(colony.food or 0)) },
		--[[ `foodPerTick` is the snapshot's buildings-only figure — the sum of
		     every building's `foodPerTick` scaled by its health, and nothing
		     else (ColonyService:snapshot, BuildingService:effectsFor). The
		     colony's actual food rate is that plus what working Cooks add and
		     minus what every colonist eats, idlers included, so the two can
		     disagree in SIGN: a Farm at level 1 under a Farmer, a Guard and an
		     idler grows 3 a tick and loses 3.1. Labelled "Food per tick" with
		     a signed format it read as a net rate, and a colony quietly
		     running its larder down looked as if it fed itself. The label now
		     says which number this is; the net rate is not computed anywhere
		     outside the production tick, so there is nothing honest to print
		     in its place. ]]
		{ label = "Food grown / tick", value = ("%.1f"):format(colony.foodPerTick or 0) },
		{
			label = "Condition",
			value = ("%d%%"):format(math.floor(colony.condition or 100)),
			valueColor = (colony.condition or 100) >= 80 and Theme.Color.Success or Theme.Color.Warning,
		},
		{ label = "Production bonus", value = ("x%.2f"):format(colony.productionMultiplier or 1) },
		{ label = "Research", value = tostring(math.floor(colony.research or 0)) },
		{ label = "Buildings", value = tostring(#(colony.buildings or {})) },
		{ label = "Ancient keys banked", value = tostring(colony.keys or 0) },
		{ label = "Gate stages opened", value = tostring(colony.gateStages or 0) },
		{ label = "Explorer level", value = tostring(colony.level or 1) },
	}

	for index, row in ipairs(rows) do
		local statRow = UIKit.statRow({
			key = row.label,
			label = row.label,
			value = row.value,
			valueColor = row.valueColor,
			parent = stats,
		})
		statRow.root.LayoutOrder = index
	end

	-- Visiting other colonies.
	local directory = store.state.directory or {}
	if #directory > 0 then
		local visitCard = UIKit.frame({
			name = "Visit",
			size = UDim2.new(1, 0, 0, 0),
			color = Theme.Color.PanelRaised,
			radius = Theme.Radius.M,
			automaticSize = Enum.AutomaticSize.Y,
			parent = container,
		})
		visitCard.LayoutOrder = 2
		UIKit.padding(visitCard, Theme.Space.M)
		UIKit.list(visitCard, { padding = Theme.Space.XS })

		UIKit.label({
			name = "Heading",
			size = UDim2.new(1, 0, 0, 18),
			text = "OTHER COLONIES IN THIS CAVERN",
			textColor = Theme.Color.Accent,
			textSize = Theme.Text.TinySize,
			font = Theme.Font.Heading,
			parent = visitCard,
		}).LayoutOrder =
			1

		UIKit.label({
			name = "Note",
			size = UDim2.new(1, 0, 0, 30),
			text = "You can walk to any of these, or jump there. Visitors can look but not build, "
				.. "and never touch another colony's storage.",
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.TinySize,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			parent = visitCard,
		}).LayoutOrder =
			2

		for index, entry in ipairs(directory) do
			local button = UIKit.button({
				name = "Visit_" .. entry.userId,
				size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
				text = ("%s  ·  plot %d%s"):format(
					entry.displayName or entry.name,
					entry.plotIndex,
					entry.canManage and "  (you can build here)" or ""
				),
				textSize = Theme.Text.SmallSize,
				align = Enum.TextXAlignment.Left,
				parent = visitCard,
				onClick = function()
					Net.request(Routes.Request.VisitColony, { userId = entry.userId })
					shell:close()
				end,
			})
			button.LayoutOrder = 2 + index
			UIKit.padding(button, Theme.Space.M)
		end
	end

	local goHome = UIKit.button({
		name = "GoHome",
		size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
		text = "Return to my colony",
		textSize = Theme.Text.SmallSize,
		parent = container,
		onClick = function()
			Net.request(Routes.Request.GoHome)
			shell:close()
		end,
	})
	goHome.LayoutOrder = 3
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Colonists
-- ─────────────────────────────────────────────────────────────────────────────

local function renderColonists(_shell, store, container)
	local colony = store.state.colony
	if not colony then
		return
	end

	local roster = colony.colonists or {}
	local slots = colony.jobSlots or {}
	local usage = colony.jobUsage or {}

	-- Recruitment.
	local recruitCard = UIKit.frame({
		name = "Recruit",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	recruitCard.LayoutOrder = 1
	UIKit.padding(recruitCard, Theme.Space.M)
	UIKit.list(recruitCard, { padding = Theme.Space.XS })

	local atCap = #roster >= (colony.populationCap or 0)
	UIKit.label({
		name = "Status",
		size = UDim2.new(1, 0, 0, 18),
		text = ("%d of %d colonists"):format(#roster, colony.populationCap or 0),
		textColor = Theme.Color.Text,
		textSize = Theme.Text.BodySize,
		font = Theme.Font.Heading,
		parent = recruitCard,
	}).LayoutOrder =
		1

	local recruit = UIKit.primaryButton({
		name = "RecruitButton",
		size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
		text = atCap and "Build more Shelters for room" or "Recruit a colonist (25 food)",
		textSize = Theme.Text.SmallSize,
		parent = recruitCard,
		onClick = function()
			local response = Net.request(Routes.Request.RecruitColonist)
			if not response.ok then
				store.notified:Fire({
					kind = "warning",
					title = "Cannot recruit",
					body = response.detail == "needs_housing" and "You need more Shelters first."
						or (response.detail == "food" and "Not enough food." or "Refused by the server."),
				})
			end
		end,
	})
	recruit.LayoutOrder = 2
	UIKit.setEnabled(recruit, not atCap and (colony.food or 0) >= 25)

	if #roster == 0 then
		UIKit.emptyState({
			icon = "·",
			text = "No colonists yet. Recruit someone once you have food and a shelter.",
			parent = container,
		}).LayoutOrder =
			2
		return
	end

	-- One card per colonist, with job buttons.
	for index, colonist in ipairs(roster) do
		local card = UIKit.frame({
			name = "Colonist_" .. colonist.uid,
			size = UDim2.new(1, 0, 0, 0),
			color = Theme.Color.PanelRaised,
			radius = Theme.Radius.M,
			automaticSize = Enum.AutomaticSize.Y,
			parent = container,
		})
		card.LayoutOrder = 10 + index
		UIKit.padding(card, Theme.Space.M)
		UIKit.list(card, { padding = Theme.Space.XS })

		local job = JobConfig.get(colonist.job)
		UIKit.label({
			name = "Name",
			size = UDim2.new(1, 0, 0, 20),
			text = ("%s  %s  ·  %s  ·  skill %.1f"):format(
				job.icon,
				colonist.name,
				job.name,
				colonist.skill or 1
			),
			textColor = job.accent,
			textSize = Theme.Text.BodySize,
			font = Theme.Font.Heading,
			parent = card,
		}).LayoutOrder =
			1

		UIKit.label({
			name = "JobBlurb",
			size = UDim2.new(1, 0, 0, 16),
			text = job.description,
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.TinySize,
			parent = card,
		}).LayoutOrder =
			2

		local jobRow = UIKit.frame({
			name = "Jobs",
			size = UDim2.new(1, 0, 0, 0),
			transparency = 1,
			automaticSize = Enum.AutomaticSize.Y,
			parent = card,
		})
		jobRow.LayoutOrder = 3
		UIKit.grid(jobRow, { cellSize = UDim2.new(0.25, -6, 0, Theme.MinTouchTarget) })

		for jobIndex, jobId in ipairs(JobConfig.Order) do
			local candidate = JobConfig.get(jobId)
			local total = slots[jobId]
			local used = usage[jobId] or 0
			local available = jobId == Enums.Job.Idle or (total and used < total)
			local isCurrent = colonist.job == jobId

			--[[ Jobs with no workplace are hidden rather than shown disabled:
			     a Researcher button with no laboratory is just confusing
			     until the laboratory exists. ]]
			if jobId == Enums.Job.Idle or total then
				local button = UIKit.button({
					name = "Job_" .. jobId,
					--[[ The NAME, not the icon. This read `icon .. " " .. count`, which
					     for Idle is the single character "·" and for every other job is a
					     bare glyph — nothing on the button said what you were assigning,
					     and several of those glyphs have no outline in Gotham anyway. The
					     grid cell is a quarter of the card, so the word fits. ]]
					text = total and ("%s %d/%d"):format(candidate.name, used, total) or candidate.name,
					textSize = Theme.Text.TinySize,
					color = isCurrent and Theme.Color.Accent or Theme.Color.Field,
					textColor = isCurrent and Theme.Color.TextInverse or Theme.Color.Text,
					parent = jobRow,
					onClick = function()
						local response = Net.request(Routes.Request.AssignJob, {
							uid = colonist.uid,
							job = jobId,
						})
						if not response.ok then
							store.notified:Fire({
								kind = "warning",
								title = "Cannot assign",
								body = response.detail == "no_slots" and ("No free %s positions."):format(
									candidate.name
								) or ("%s needs its building first."):format(candidate.name),
							})
						end
					end,
				})
				button.LayoutOrder = jobIndex
				UIKit.setEnabled(button, isCurrent or available)
			end
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Crafting
-- ─────────────────────────────────────────────────────────────────────────────

local function renderCrafting(_shell, store, container)
	local recipes = store.state.recipes or {}
	if #recipes == 0 then
		UIKit.emptyState({
			icon = "⚒",
			text = "No recipes yet. Build a Workshop, a Farm or an Infirmary to unlock crafting.",
			parent = container,
		})
		return
	end

	for index, recipe in ipairs(recipes) do
		local card = UIKit.frame({
			name = "Recipe_" .. recipe.id,
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
			text = recipe.name,
			textColor = Theme.Color.Text,
			textSize = Theme.Text.BodySize,
			font = Theme.Font.Heading,
			parent = card,
		}).LayoutOrder =
			1

		UIKit.label({
			name = "Cost",
			size = UDim2.new(1, 0, 0, 18),
			text = UIKit.formatCost(recipe.cost, ResourceConfig.Resources, store.state.storage),
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.SmallSize,
			richText = true,
			parent = card,
		}).LayoutOrder =
			2

		local button = UIKit.primaryButton({
			name = "Craft",
			size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
			text = "Craft",
			textSize = Theme.Text.SmallSize,
			parent = card,
			onClick = function()
				local response = Net.request(Routes.Request.Craft, { recipeId = recipe.id })
				if response.ok then
					store.notified:Fire({ kind = "success", title = "Crafted", body = recipe.name })
				else
					store.notified:Fire({
						kind = "warning",
						title = "Cannot craft",
						body = response.detail == "read_only"
								and "Your save is read-only this session, so nothing can be crafted."
							or response.reason == Enums.Reject.NotEnoughResources and "Not enough resources."
							or "You need the right building, at the right level.",
					})
				end
			end,
		})
		button.LayoutOrder = 3

		if not recipe.available then
			local reason = "Not available"
			if recipe.blockedBy == "station" then
				reason = "Needs a " .. tostring(recipe.station):gsub("_", " ")
			elseif recipe.blockedBy == "station_level" then
				reason = ("Needs that building at level %d"):format(recipe.stationLevel or 1)
			elseif recipe.blockedBy == "resources" then
				reason = "Not enough resources"
			end
			UIKit.setEnabled(button, false, reason)
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Dispatch
-- ─────────────────────────────────────────────────────────────────────────────

function ColonyPanel.render(shell, store, container, tab)
	clearChildren(container)
	if tab == "overview" then
		renderOverview(shell, store, container)
	elseif tab == "colonists" then
		renderColonists(shell, store, container)
	elseif tab == "crafting" then
		renderCrafting(shell, store, container)
	end
end

return ColonyPanel
