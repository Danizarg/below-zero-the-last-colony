--[[
	ExpeditionPanel.lua
	The expedition lobby: difficulty, party, supplies, and the launch button.

	This is the screen where the risk is chosen, so it states the stakes plainly:
	each difficulty shows its clock, its threat level and — most importantly —
	how much of your haul you keep if it goes wrong. A player should never be
	surprised by a loss rule.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local DifficultyConfig = require(Shared.Config.DifficultyConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Util.Net)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local Routes = require(Shared.Routes)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local ExpeditionPanel = {}

local function clearChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function ExpeditionPanel.create(shell, store)
	local panel = UIKit.panel({
		name = "ExpeditionPanel",
		title = "Expeditions",
		subtitle = "Choose your risk, then go down",
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

	local state = { supplies = {} }

	store.changed:Connect(function(area)
		if area == "party" or area == "colony" or area == "inventory" or area == "role" then
			shell:refreshIfOpen("expedition")
		end
	end)

	return {
		root = panel.root,
		refresh = function()
			ExpeditionPanel.render(shell, store, content, state)
		end,
		onOpen = function()
			--[[ Make sure a party exists so the lobby has something to show even
			     for a solo player: solo is a party of one everywhere else in the
			     code, so it should be here too. ]]
			if not store.state.party then
				Net.request(Routes.Request.CreateParty, { visibility = "private" })
			end
		end,
	}
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Sections
-- ─────────────────────────────────────────────────────────────────────────────

local function renderDifficulty(store, container, party)
	local card = UIKit.frame({
		name = "Difficulty",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	card.LayoutOrder = 1
	UIKit.padding(card, Theme.Space.M)
	UIKit.list(card, { padding = Theme.Space.XS })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 18),
		text = "DIFFICULTY",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = card,
	}).LayoutOrder =
		1

	local isLeader = party and party.isLeader
	local selected = party and party.difficultyId or DifficultyConfig.Default

	for index, difficultyId in ipairs(DifficultyConfig.Order) do
		local mode = DifficultyConfig.get(difficultyId)
		local isSelected = difficultyId == selected

		local row = UIKit.button({
			name = "Diff_" .. difficultyId,
			size = UDim2.new(1, 0, 0, 86),
			text = "",
			color = isSelected and Theme.Color.Field or Theme.Color.Panel,
			strokeColor = isSelected and mode.accent or Theme.Color.Divider,
			parent = card,
			onClick = function()
				if not isLeader then
					store.notified:Fire({
						kind = "warning",
						title = "Only the leader can change this",
						body = "Ask your party leader, or leave to run solo.",
					})
					return
				end
				Net.request(Routes.Request.SetReady, { difficultyId = difficultyId, ready = true })
			end,
		})
		row.LayoutOrder = 1 + index

		UIKit.label({
			name = "Name",
			size = UDim2.new(1, -Theme.Space.XL, 0, 20),
			position = UDim2.fromOffset(Theme.Space.M, Theme.Space.S),
			text = ("%s%s"):format(mode.name, isSelected and "  ✔" or ""),
			textColor = mode.accent,
			textSize = Theme.Text.BodySize,
			font = Theme.Font.Heading,
			parent = row,
		})

		UIKit.label({
			name = "Blurb",
			size = UDim2.new(1, -Theme.Space.XL, 0, 16),
			position = UDim2.fromOffset(Theme.Space.M, 28),
			text = mode.blurb,
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.TinySize,
			parent = row,
		})

		--[[ The three numbers that actually matter when choosing: how long you
		     have, how hard the fights are, and what a failure costs. ]]
		local total = mode.phaseDurations.prep
			+ mode.phaseDurations.day
			+ mode.phaseDurations.dusk
			+ mode.phaseDurations.night
		UIKit.label({
			name = "Facts",
			size = UDim2.new(1, -Theme.Space.XL, 0, 32),
			position = UDim2.fromOffset(Theme.Space.M, 46),
			text = ("Run %s  ·  %d rooms  ·  %d-room shifts every %ds  ·  %ds to revive\nKeep %d%% of your haul if you die, %d%% if you run out of time"):format(
				UIKit.formatClock(total),
				mode.roomCount,
				mode.shiftCount,
				mode.shiftIntervalSeconds,
				mode.downedSeconds,
				math.floor(mode.lootKeptOnDeathFraction * 100),
				math.floor(mode.lootKeptOnTimeoutFraction * 100)
			),
			textColor = Theme.Color.TextFaint,
			textSize = Theme.Text.TinySize,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			parent = row,
		})
	end
end

local function renderParty(store, container, party)
	local card = UIKit.frame({
		name = "Party",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	card.LayoutOrder = 2
	UIKit.padding(card, Theme.Space.M)
	UIKit.list(card, { padding = Theme.Space.XS })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 18),
		text = party and ("PARTY  ·  CODE %s  ·  %d/%d"):format(party.code, party.size, party.maxSize)
			or "PARTY",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = card,
	}).LayoutOrder =
		1

	if not party then
		UIKit.label({
			name = "Solo",
			size = UDim2.new(1, 0, 0, 20),
			text = "Running solo.",
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.SmallSize,
			parent = card,
		}).LayoutOrder =
			2
	else
		for index, member in ipairs(party.members or {}) do
			UIKit.label({
				name = "Member_" .. member.userId,
				size = UDim2.new(1, 0, 0, 20),
				text = ("%s %s%s  ·  %s  %s"):format(
					member.isLeader and "★" or "·",
					member.name,
					member.isLeader and " (leader)" or "",
					member.roleIcon or "",
					member.ready and "ready" or "not ready"
				),
				textColor = member.ready and Theme.Color.Success or Theme.Color.TextMuted,
				textSize = Theme.Text.SmallSize,
				parent = card,
			}).LayoutOrder = 1
				+ index
		end

		local controls = UIKit.frame({
			name = "Controls",
			size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
			transparency = 1,
			parent = card,
		})
		controls.LayoutOrder = 50
		UIKit.list(controls, { horizontal = true, padding = Theme.Space.XS })

		UIKit.button({
			name = "Public",
			size = UDim2.new(0.33, -3, 1, 0),
			text = party.visibility == "public" and "Public ✔" or "Make public",
			textSize = Theme.Text.TinySize,
			parent = controls,
			onClick = function()
				Net.request(Routes.Request.CreateParty, {
					visibility = party.visibility == "public" and "private" or "public",
					difficultyId = party.difficultyId,
				})
			end,
		}).LayoutOrder =
			1

		UIKit.button({
			name = "Leave",
			size = UDim2.new(0.33, -3, 1, 0),
			text = "Leave party",
			textSize = Theme.Text.TinySize,
			parent = controls,
			onClick = function()
				Net.request(Routes.Request.LeaveParty)
			end,
		}).LayoutOrder =
			2

		UIKit.button({
			name = "Ready",
			size = UDim2.new(0.33, -3, 1, 0),
			text = "Toggle ready",
			textSize = Theme.Text.TinySize,
			parent = controls,
			onClick = function()
				local me
				for _, member in ipairs(party.members or {}) do
					if member.userId == Players.LocalPlayer.UserId then
						me = member
						break
					end
				end
				Net.request(Routes.Request.SetReady, { ready = not (me and me.ready) })
			end,
		}).LayoutOrder =
			3

		-- Public listing, so a solo player can find a group.
		local listing = party.publicParties or {}
		if #listing > 0 then
			UIKit.label({
				name = "OpenHeading",
				size = UDim2.new(1, 0, 0, 18),
				text = "OPEN PARTIES",
				textColor = Theme.Color.Accent,
				textSize = Theme.Text.TinySize,
				font = Theme.Font.Heading,
				parent = card,
			}).LayoutOrder =
				60

			for index, open in ipairs(listing) do
				if open.code ~= party.code then
					local join = UIKit.button({
						name = "Join_" .. open.code,
						size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
						text = ("%s  ·  %s  ·  %d/%d  ·  %s"):format(
							open.code,
							open.leader,
							open.size,
							open.maxSize,
							open.difficultyId
						),
						textSize = Theme.Text.TinySize,
						align = Enum.TextXAlignment.Left,
						parent = card,
						onClick = function()
							local response = Net.request(Routes.Request.JoinParty, { code = open.code })
							if not response.ok then
								store.notified:Fire({
									kind = "warning",
									title = "Could not join",
									body = response.detail == "party_full" and "That party is full."
										or "That party is no longer open.",
								})
							end
						end,
					})
					join.LayoutOrder = 60 + index
					UIKit.padding(join, Theme.Space.S)
				end
			end
		end
	end
end

local function renderSupplies(store, container, state)
	local card = UIKit.frame({
		name = "Supplies",
		size = UDim2.new(1, 0, 0, 0),
		color = Theme.Color.PanelRaised,
		radius = Theme.Radius.M,
		automaticSize = Enum.AutomaticSize.Y,
		parent = container,
	})
	card.LayoutOrder = 3
	UIKit.padding(card, Theme.Space.M)
	UIKit.list(card, { padding = Theme.Space.XS })

	UIKit.label({
		name = "Heading",
		size = UDim2.new(1, 0, 0, 18),
		text = "SUPPLIES TO CARRY",
		textColor = Theme.Color.Accent,
		textSize = Theme.Text.TinySize,
		font = Theme.Font.Heading,
		parent = card,
	}).LayoutOrder =
		1

	local any = false
	local index = 1
	for consumableId, def in pairs(ResourceConfig.Consumables) do
		local held = store.state.consumables[consumableId] or 0
		if held > 0 then
			any = true
			index += 1
			local want = state.supplies[consumableId] or 0

			local row = UIKit.frame({
				name = "Supply_" .. consumableId,
				size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
				transparency = 1,
				parent = card,
			})
			row.LayoutOrder = index

			local label = UIKit.label({
				name = "Name",
				size = UDim2.new(1, -140, 1, 0),
				text = ("%s %s   (%d in storage)"):format(def.icon, def.name, held),
				textColor = Theme.Color.Text,
				textSize = Theme.Text.SmallSize,
				parent = row,
			})

			local function setWant(value)
				state.supplies[consumableId] =
					math.clamp(value, 0, math.min(held, GameConfig.Inventory.MaxSuppliesPerType))
				label.Text = ("%s %s   (%d in storage)  →  taking %d"):format(
					def.icon,
					def.name,
					held,
					state.supplies[consumableId]
				)
			end

			UIKit.button({
				name = "Less",
				size = UDim2.fromOffset(44, Theme.MinTouchTarget),
				position = UDim2.new(1, -96, 0, 0),
				text = "−",
				parent = row,
				onClick = function()
					setWant((state.supplies[consumableId] or 0) - 1)
				end,
			})

			UIKit.button({
				name = "More",
				size = UDim2.fromOffset(44, Theme.MinTouchTarget),
				position = UDim2.new(1, -46, 0, 0),
				text = "+",
				parent = row,
				onClick = function()
					setWant((state.supplies[consumableId] or 0) + 1)
				end,
			})

			setWant(want)
		end
	end

	if not any then
		UIKit.label({
			name = "None",
			size = UDim2.new(1, 0, 0, 32),
			text = "No supplies in storage. Craft Cooked Mushrooms at the Farm and Glowroot Salves at the Infirmary.",
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.TinySize,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			parent = card,
		}).LayoutOrder =
			2
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Render
-- ─────────────────────────────────────────────────────────────────────────────

function ExpeditionPanel.render(shell, store, container, state)
	clearChildren(container)

	if store.inExpedition() then
		UIKit.emptyState({
			icon = "⛏",
			text = "You are already underground. Get out first.",
			parent = container,
		})
		return
	end

	local party = store.state.party

	renderDifficulty(store, container, party)
	renderParty(store, container, party)
	renderSupplies(store, container, state)

	-- Role reminder, because role is chosen elsewhere but matters here.
	local role = store.state.role
	UIKit.label({
		name = "RoleNote",
		size = UDim2.new(1, 0, 0, 20),
		text = role and ("Going down as %s. Change it in Roles."):format(
			(role.stats and role.roleId) and tostring(role.roleId):gsub("^%l", string.upper) or "?"
		) or "",
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.SmallSize,
		parent = container,
	}).LayoutOrder =
		10

	local launch = UIKit.primaryButton({
		name = "Launch",
		size = UDim2.new(1, 0, 0, 56),
		text = "ENTER THE CAVES",
		textSize = Theme.Text.SubheadingSize,
		parent = container,
		onClick = function()
			-- Load supplies first, then launch, so the bag is packed on arrival.
			local anySupplies = false
			for _, count in pairs(state.supplies) do
				if count > 0 then
					anySupplies = true
					break
				end
			end
			if anySupplies then
				Net.request(Routes.Request.LoadoutSupplies, { supplies = state.supplies })
			end

			local response = Net.request(Routes.Request.StartExpedition, {
				difficultyId = party and party.difficultyId or nil,
			})

			if response.ok then
				shell:close()
			else
				local body = "The server refused."
				if response.detail == "read_only" then
					body =
						"Your save is read-only this session, so an expedition could not be kept. Rejoin later."
				elseif response.detail == "not_all_ready" then
					body = "Everyone in the party has to be ready."
				elseif response.detail == "not_leader" then
					body = "Only the party leader can start."
				elseif response.detail == "server_full_of_expeditions" then
					body = "Too many expeditions are running on this server. Try again shortly."
				elseif response.detail == "teleport_place_unset" then
					body = response.message or "Transport is misconfigured."
				elseif response.reason == Enums.Reject.RateLimited then
					body = "Slow down a moment."
				end
				store.notified:Fire({ kind = "warning", title = "Cannot start", body = body })
			end
		end,
	})
	launch.LayoutOrder = 11

	if party and not party.allReady then
		UIKit.setEnabled(launch, false, "Waiting for the party to be ready")
	elseif party and not party.isLeader then
		UIKit.setEnabled(launch, false, "The leader starts the expedition")
	end

	UIKit.label({
		name = "Warning",
		size = UDim2.new(1, 0, 0, 32),
		text = "Anything you carry out of the caves becomes permanent. Anything you are still holding when "
			.. "the run ends is only partly recovered — except Ancient Keys, which you never lose.",
		textColor = Theme.Color.TextFaint,
		textSize = Theme.Text.TinySize,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		parent = container,
	}).LayoutOrder =
		12
end

return ExpeditionPanel
