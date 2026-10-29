--[[
	InteractionController.lua
	Routes every world interaction to the right server request.

	All world interaction goes through ProximityPrompt, which means keyboard,
	gamepad and touch all work with no per-input-type code, and the prompt only
	appears when the player is close enough and has line of sight. The prompt's
	Name is the contract: the server-side builders set it, and this file maps it
	to a request.

	The gate is the one interaction with a two-step flow — examine, then
	decide — because spending ancient keys should never happen on a single
	keypress.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)
local Theme = require(Shared.Config.Theme)

local InteractionController = {}
InteractionController.__index = InteractionController

function InteractionController.new(store, shell, uiKit)
	local self = setmetatable({}, InteractionController)
	self.store = store
	self.shell = shell
	self.UIKit = uiKit
	self._dialog = nil
	return self
end

--[[ Find the id attribute a prompt's owning model carries. Prompts live on a
     part, so this walks up to the Model that was tagged. ]]
local function findAttribute(instance, attribute)
	local cursor = instance
	while cursor and cursor ~= workspace do
		if cursor:GetAttribute(attribute) ~= nil then
			return cursor:GetAttribute(attribute)
		end
		cursor = cursor.Parent
	end
	return nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Gate dialog
-- ─────────────────────────────────────────────────────────────────────────────

function InteractionController:_closeDialog()
	if self._dialog then
		self._dialog:Destroy()
		self._dialog = nil
	end
end

function InteractionController:_showGateDialog(info)
	self:_closeDialog()
	local UIKit = self.UIKit

	local scrim = UIKit.frame({
		name = "GateDialog",
		size = UDim2.fromScale(1, 1),
		color = Theme.Color.Void,
		transparency = 0.45,
		zIndex = Theme.ZIndex.Modal,
		parent = self.shell.modalHost,
	})
	self._dialog = scrim

	local card = UIKit.frame({
		name = "Card",
		size = UDim2.new(0, 460, 0, 0),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = Theme.Color.Panel,
		radius = Theme.Radius.L,
		stroke = true,
		strokeColor = Theme.Color.Accent,
		automaticSize = Enum.AutomaticSize.Y,
		parent = scrim,
	})
	UIKit.padding(card, Theme.Space.L)
	UIKit.list(card, { padding = Theme.Space.S })

	UIKit.label({
		name = "Title",
		size = UDim2.new(1, 0, 0, 32),
		text = info.complete and "THE FIRST GATE" or string.upper(info.stageName or "THE FIRST GATE"),
		textColor = Theme.Color.AccentGlow,
		textSize = Theme.Text.TitleSize,
		font = Theme.Font.Display,
		align = Enum.TextXAlignment.Center,
		parent = card,
	}).LayoutOrder =
		1

	UIKit.label({
		name = "Lore",
		size = UDim2.new(1, 0, 0, 0),
		text = info.complete and (info.message or "") or (info.lore or ""),
		textColor = Theme.Color.TextMuted,
		textSize = Theme.Text.SmallSize,
		align = Enum.TextXAlignment.Center,
		wrapped = true,
		alignY = Enum.TextYAlignment.Top,
		automaticSize = Enum.AutomaticSize.Y,
		parent = card,
	}).LayoutOrder =
		2

	if not info.complete then
		UIKit.label({
			name = "Requirement",
			size = UDim2.new(1, 0, 0, 0),
			text = ("Needs %d ancient key%s.  You have %d (%d in your bag, %d banked)."):format(
				info.keysRequired or 1,
				(info.keysRequired or 1) == 1 and "" or "s",
				info.keysHeld or 0,
				info.keysInBag or 0,
				info.keysBanked or 0
			),
			textColor = (info.canUnlock and Theme.Color.Success) or Theme.Color.Warning,
			textSize = Theme.Text.SmallSize,
			align = Enum.TextXAlignment.Center,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			automaticSize = Enum.AutomaticSize.Y,
			parent = card,
		}).LayoutOrder =
			3

		UIKit.label({
			name = "Unlocks",
			size = UDim2.new(1, 0, 0, 0),
			text = ("Opening it unlocks: %s\nYour colony is not reset. Nothing is lost."):format(
				info.unlocks or "the next chapter"
			),
			textColor = Theme.Color.TextFaint,
			textSize = Theme.Text.TinySize,
			align = Enum.TextXAlignment.Center,
			wrapped = true,
			alignY = Enum.TextYAlignment.Top,
			automaticSize = Enum.AutomaticSize.Y,
			parent = card,
		}).LayoutOrder =
			4

		local unlock = UIKit.primaryButton({
			name = "Unlock",
			size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
			text = ("Open the gate (spends %d key%s)"):format(
				info.keysRequired or 1,
				(info.keysRequired or 1) == 1 and "" or "s"
			),
			textSize = Theme.Text.SmallSize,
			parent = card,
			onClick = function()
				local response = Net.request(Routes.Request.UnlockGate)
				self:_closeDialog()
				if not response.ok then
					local body = "The gate does not move."
					if response.detail == "keys" then
						body = ("You need %d keys and have %d."):format(
							response.need or 0,
							response.have or 0
						)
					elseif response.detail == "future_chapter" then
						body = ("%s is designed but not built yet. Later chapter."):format(
							response.stageName or "That seal"
						)
					elseif response.reason == Enums.Reject.TooFar then
						body = "Stand closer to the gate."
					end
					self.store.notified:Fire({ kind = "warning", title = "The gate holds", body = body })
				end
			end,
		})
		unlock.LayoutOrder = 5

		if not info.canUnlock then
			local reason = "Not enough keys"
			if not info.implemented then
				reason = "A later chapter"
			end
			UIKit.setEnabled(unlock, false, reason)
		end
	end

	local close = UIKit.button({
		name = "Close",
		size = UDim2.new(1, 0, 0, Theme.MinTouchTarget),
		text = "Step back",
		textSize = Theme.Text.SmallSize,
		parent = card,
		onClick = function()
			self:_closeDialog()
		end,
	})
	close.LayoutOrder = 6
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Prompt routing
-- ─────────────────────────────────────────────────────────────────────────────

local function reasonText(response)
	if response.reason == Enums.Reject.TooFar then
		return "You are too far away."
	elseif response.reason == Enums.Reject.OnCooldown then
		return "Too soon."
	elseif response.reason == Enums.Reject.InventoryFull then
		return "Your bag is full."
	elseif response.reason == Enums.Reject.RateLimited then
		return "Slow down."
	elseif response.detail == "needs_tool" then
		return response.tool and ("You need a %s for this."):format(response.tool)
			or "You need a better tool."
	elseif response.detail == "no_stamina" then
		return "Out of stamina."
	elseif response.detail == "depleted" then
		return "Nothing left here."
	elseif response.detail == "not_at_extraction" then
		return "You have to be at an extraction point."
	end
	return nil
end

function InteractionController:_handlePrompt(prompt)
	local name = prompt.Name

	--[[ Colony prompts just open a panel. The noticeboard and the crafting
	     stations both land on the colony panel: crafting is a tab inside it, so
	     a separate destination would only add a click. ]]
	local PANEL_FOR_PROMPT = {
		ExpeditionPrompt = "expedition",
		ColonyPrompt = "colony",
		CraftPrompt = "colony",
		BuildingPrompt = "build",
	}

	local panel = PANEL_FOR_PROMPT[name]
	if panel then
		self.shell:open(panel)
		return
	end

	-- Expedition prompts: server requests.
	if name == "HarvestPrompt" then
		local nodeId = findAttribute(prompt, "NodeId")
		if not nodeId then
			return
		end
		local response = Net.request(Routes.Request.HarvestNode, { nodeId = nodeId })
		if not response.ok then
			local text = reasonText(response)
			if text then
				self.store.notified:Fire({
					kind = "warning",
					title = "Cannot harvest",
					body = text,
					lifetime = 3,
				})
			end
		elseif response.gained and response.gained > 0 then
			--[[ A short-lived toast rather than a persistent one: harvesting is
			     the most repeated action in the game and should not bury the
			     notification stack. ]]
			self.store.notified:Fire({
				kind = "success",
				title = ("+%d"):format(response.gained),
				body = nil,
				lifetime = 1.5,
			})
		end
		return
	end

	if name == "ExtractPrompt" then
		local response = Net.request(Routes.Request.RequestExtraction)
		if not response.ok then
			local text = reasonText(response) or "Cannot extract from here."
			self.store.notified:Fire({ kind = "warning", title = "Extraction failed", body = text })
		end
		return
	end

	if name == "KeyPrompt" or name == "PillarPrompt" then
		local id = findAttribute(prompt, "InteractableId")
		if not id then
			return
		end
		local response = Net.request(Routes.Request.Interact, { id = id })
		if not response.ok then
			local text = reasonText(response)
			if text then
				self.store.notified:Fire({
					kind = "warning",
					title = "Nothing happens",
					body = text,
					lifetime = 3,
				})
			end
		elseif response.kind == "pillar" and response.progress then
			--[[ A reset and a solve both already produce their own server-side
			     message (a notification and a party-wide alert respectively), so
			     echoing them here would double the toast. Only the in-progress
			     step needs local feedback. ]]
			if not response.reset and not response.solved then
				self.store.notified:Fire({
					kind = "info",
					title = ("Rune %d of %d"):format(response.progress, response.total),
					body = nil,
					lifetime = 2,
				})
			end
		end
		return
	end

	if name == "GatePrompt" then
		local id = findAttribute(prompt, "InteractableId")
		if not id then
			return
		end
		local response = Net.request(Routes.Request.Interact, { id = id })
		if response.ok and response.kind == "gate" then
			self:_showGateDialog(response)
		else
			local text = reasonText(response) or "You cannot reach the gate."
			self.store.notified:Fire({ kind = "warning", title = "The gate", body = text })
		end
		return
	end
end

function InteractionController:start()
	ProximityPromptService.PromptTriggered:Connect(function(prompt)
		local ok, err = pcall(function()
			self:_handlePrompt(prompt)
		end)
		if not ok then
			warn(("[BZ/Interaction] prompt %q failed: %s"):format(prompt.Name, tostring(err)))
		end
	end)

	--[[ Leaving the caves closes any world dialog, so a gate dialog cannot
	     follow the player home. ]]
	self.store.changed:Connect(function(area)
		if area == "zone" then
			self:_closeDialog()
		end
	end)

	return self
end

return InteractionController
