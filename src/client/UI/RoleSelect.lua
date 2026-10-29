--[[
	RoleSelect.lua
	Pick a specialisation, and see what mastery has unlocked.

	Roles that are designed but not implemented are shown greyed out with
	"Coming soon" rather than hidden. The player can see where the game is
	going, and nothing claims to work that does not.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local GameConfig = require(Shared.Config.GameConfig)
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local RoleSelect = {}

local function clearChildren(container)
	for _, child in ipairs(container:GetChildren()) do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
end

function RoleSelect.create(shell, store)
	local panel = UIKit.panel({
		name = "RoleSelect",
		title = "Roles",
		subtitle = "Change between expeditions, never during one",
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
		if area == "role" then
			shell:refreshIfOpen("roles")
		end
	end)

	return {
		root = panel.root,
		refresh = function()
			RoleSelect.render(shell, store, content)
		end,
	}
end

function RoleSelect.render(_shell, store, container)
	clearChildren(container)

	local roles = store.state.roles or {}
	local current = store.state.role and store.state.role.roleId

	if #roles == 0 then
		UIKit.emptyState({ icon = "◈", text = "Waiting for role data.", parent = container })
		return
	end

	if store.inExpedition() then
		UIKit.label({
			name = "Locked",
			size = UDim2.new(1, 0, 0, 34),
			text = "You cannot change role inside the caves. This is your loadout until you get out.",
			textColor = Theme.Color.Warning,
			textSize = Theme.Text.SmallSize,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			parent = container,
		}).LayoutOrder =
			0
	end

	for index, role in ipairs(roles) do
		local isCurrent = role.id == current

		local card = UIKit.frame({
			name = "Role_" .. role.id,
			size = UDim2.new(1, 0, 0, 0),
			color = isCurrent and Theme.Color.Field or Theme.Color.PanelRaised,
			radius = Theme.Radius.M,
			stroke = isCurrent,
			strokeColor = role.accent,
			automaticSize = Enum.AutomaticSize.Y,
			parent = container,
		})
		card.LayoutOrder = index
		UIKit.padding(card, Theme.Space.M)
		UIKit.list(card, { padding = Theme.Space.XS })

		UIKit.label({
			name = "Title",
			size = UDim2.new(1, 0, 0, 24),
			text = ("%s  %s%s"):format(role.icon or "◈", role.name, isCurrent and "   — SELECTED" or ""),
			textColor = role.accent or Theme.Color.Text,
			textSize = Theme.Text.SubheadingSize,
			font = Theme.Font.Display,
			parent = card,
		}).LayoutOrder =
			1

		UIKit.label({
			name = "Tagline",
			size = UDim2.new(1, 0, 0, 16),
			text = ("“%s”"):format(role.tagline or ""),
			textColor = Theme.Color.TextFaint,
			textSize = Theme.Text.TinySize,
			parent = card,
		}).LayoutOrder =
			2

		UIKit.label({
			name = "Description",
			size = UDim2.new(1, 0, 0, 0),
			text = role.description or "",
			textColor = Theme.Color.TextMuted,
			textSize = Theme.Text.SmallSize,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			automaticSize = Enum.AutomaticSize.Y,
			parent = card,
		}).LayoutOrder =
			3

		-- Ability.
		UIKit.label({
			name = "Ability",
			size = UDim2.new(1, 0, 0, 0),
			text = ("ABILITY  %s  (%ds cooldown)\n%s"):format(
				role.ability and role.ability.name or "—",
				math.floor(role.ability and role.ability.cooldown or 0),
				role.ability and role.ability.description or ""
			),
			textColor = Theme.Color.Text,
			textSize = Theme.Text.TinySize,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			automaticSize = Enum.AutomaticSize.Y,
			parent = card,
		}).LayoutOrder =
			4

		-- Passives.
		local passiveText = {}
		for _, passive in ipairs(role.passives or {}) do
			table.insert(passiveText, ("· %s — %s"):format(passive.name, passive.description))
		end
		if #passiveText > 0 then
			UIKit.label({
				name = "Passives",
				size = UDim2.new(1, 0, 0, 0),
				text = table.concat(passiveText, "\n"),
				textColor = Theme.Color.TextMuted,
				textSize = Theme.Text.TinySize,
				wrapped = true,
				alignY = Enum.TextYAlignment.Top,
				automaticSize = Enum.AutomaticSize.Y,
				parent = card,
			}).LayoutOrder =
				5
		end

		-- Mastery.
		local masteryBar = UIKit.bar({
			name = "Mastery",
			size = UDim2.new(1, 0, 0, 12),
			fillColor = role.accent or Theme.Color.Accent,
			textSize = Theme.Text.TinySize,
			parent = card,
		})
		masteryBar.root.LayoutOrder = 6
		masteryBar.set(
			role.mastery or 0,
			GameConfig.Rewards.MaxRoleMastery,
			("Mastery %d / %d"):format(role.mastery or 0, GameConfig.Rewards.MaxRoleMastery)
		)

		-- Upgrade ladder, with what is unlocked so far marked.
		local upgradeLines = {}
		for _, upgrade in ipairs(role.upgrades or {}) do
			local unlocked = (role.mastery or 0) >= upgrade.mastery
			table.insert(
				upgradeLines,
				("%s Lv%d  %s"):format(unlocked and "✔" or "·", upgrade.mastery, upgrade.name)
			)
		end
		if #upgradeLines > 0 then
			UIKit.label({
				name = "Upgrades",
				size = UDim2.new(1, 0, 0, 0),
				text = table.concat(upgradeLines, "\n"),
				textColor = Theme.Color.TextFaint,
				textSize = Theme.Text.TinySize,
				wrapped = true,
				alignY = Enum.TextYAlignment.Top,
				automaticSize = Enum.AutomaticSize.Y,
				parent = card,
			}).LayoutOrder =
				7
		end

		local button = UIKit.primaryButton({
			name = "Select",
			size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
			text = isCurrent and "Selected" or ("Play as " .. role.name),
			textSize = Theme.Text.SmallSize,
			parent = card,
			onClick = function()
				local response = Net.request(Routes.Request.SetRole, { roleId = role.id })
				if not response.ok then
					store.notified:Fire({
						kind = "warning",
						title = "Cannot change role",
						body = response.detail == "in_expedition" and "Not while you are underground."
							or "That role is not available yet.",
					})
				end
			end,
		})
		button.LayoutOrder = 8

		if not role.selectable then
			UIKit.setEnabled(button, false, "Coming soon")
		elseif isCurrent then
			UIKit.setEnabled(button, false, "Selected")
		elseif store.inExpedition() then
			UIKit.setEnabled(button, false, "Locked during an expedition")
		end
	end
end

return RoleSelect
