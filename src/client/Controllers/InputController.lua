--[[
	InputController.lua
	Turns input into intent and sends it to the server.

	The client never resolves an outcome. A click produces "I swung, possibly at
	monster X"; the server decides whether that connected, for how much, and
	whether the player had the stamina. Target resolution here is a hint, and
	the server re-measures range itself.

	Bindings
	────────
		Left click / touch ⚔   attack
		E                      handled by ProximityPrompt (interact)
		Q                      role ability
		Shift (hold)           sprint
		Space                  jump (engine default)
		Escape                 close panel, or reopen the main menu
		Tab                    inventory

	ContextActionService is used for the gameplay actions so they do not fire
	while a text box has focus or a panel is capturing input.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)

local InputController = {}
InputController.__index = InputController

local ATTACK_ACTION = "BZ_Attack"
local ABILITY_ACTION = "BZ_Ability"
local SPRINT_ACTION = "BZ_Sprint"

--[[ Client-side throttle so a held mouse button does not spend the player's
     whole rate-limit budget on swings the server will refuse anyway. ]]
local ATTACK_MIN_INTERVAL = 0.3
local ABILITY_MIN_INTERVAL = 0.5

function InputController.new(store, shell, hud)
	local self = setmetatable({}, InputController)
	self.store = store
	self.shell = shell
	self.hud = hud
	self.player = Players.LocalPlayer
	self.camera = workspace.CurrentCamera
	self._lastAttack = 0
	self._lastAbility = 0
	self._sprinting = false

	--[[ Let the HUD's touch buttons route through the same code path as the
	     keyboard, so there is one implementation of each action. ]]
	hud.onAttack = function()
		self:attack()
	end
	hud.onAbility = function()
		self:useAbility()
	end
	hud.onSprint = function(enabled)
		self:setSprinting(enabled)
	end
	hud.onRescue = function(paid)
		self:requestRescue(paid)
	end
	hud.onRevive = function(userId)
		self:revive(userId)
	end

	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Target resolution
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	What is the player aiming at?

	Casts from the camera through the cursor (or screen centre on touch) and
	walks up to a Model carrying a MonsterId attribute. Returns nil when the cast
	hits scenery, which the server treats as a miss.
]]
function InputController:_monsterUnderCursor()
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end

	local position
	if UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		position = camera.ViewportSize / 2
	else
		position = UserInputService:GetMouseLocation()
	end

	local ray = camera:ViewportPointToRay(position.X, position.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { self.player.Character }
	params.IgnoreWater = true

	local result = workspace:Raycast(ray.Origin, ray.Direction * 60, params)
	if not result then
		return nil
	end

	local instance = result.Instance
	while instance and instance ~= workspace do
		if instance:IsA("Model") and instance:GetAttribute("MonsterId") then
			return instance:GetAttribute("MonsterId")
		end
		instance = instance.Parent
	end

	--[[ Fallback: the nearest monster within melee reach. Clicking a tunnel wall
	     while a crawler is chewing on you should still hit the crawler. ]]
	local root = self.player.Character and self.player.Character.PrimaryPart
	if not root then
		return nil
	end

	local expeditions = workspace:FindFirstChild("Expeditions")
	if not expeditions then
		return nil
	end

	local bestId, bestDistance
	for _, descendant in ipairs(expeditions:GetDescendants()) do
		if descendant:IsA("Model") and descendant:GetAttribute("MonsterId") and descendant.PrimaryPart then
			local distance = (descendant.PrimaryPart.Position - root.Position).Magnitude
			if distance <= 12 and (not bestDistance or distance < bestDistance) then
				bestId, bestDistance = descendant:GetAttribute("MonsterId"), distance
			end
		end
	end
	return bestId
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Actions
-- ─────────────────────────────────────────────────────────────────────────────

function InputController:attack()
	if not self.store.inExpedition() then
		return
	end
	if self.store.isDowned() or self.store.isDead() then
		return
	end

	local now = os.clock()
	if now - self._lastAttack < ATTACK_MIN_INTERVAL then
		return
	end
	self._lastAttack = now

	local monsterId = self:_monsterUnderCursor()
	local response = Net.request(Routes.Request.Attack, { monsterId = monsterId })

	if response.ok and response.hit then
		if response.deflected then
			--[[ The Stalker shrugs off weapons. Saying so once, clearly, is how
			     the player learns that running is the answer. ]]
			self.store.notified:Fire({
				kind = "danger",
				title = "Your blade does nothing",
				body = "This one cannot be killed with what you are carrying. Run.",
			})
		elseif response.killed then
			self.store.notified:Fire({ kind = "success", title = "Killed", body = nil, lifetime = 2 })
		end
	end
end

function InputController:useAbility()
	if not self.store.inExpedition() then
		return
	end

	local now = os.clock()
	if now - self._lastAbility < ABILITY_MIN_INTERVAL then
		return
	end
	self._lastAbility = now

	local response = Net.request(Routes.Request.UseAbility)
	if not response.ok then
		local body = "Not right now."
		if response.reason == Enums.Reject.OnCooldown then
			body = ("Ready in %ds."):format(math.ceil(response.remaining or 0))
		elseif response.detail == "no_stamina" then
			body = "Not enough stamina."
		elseif response.reason == Enums.Reject.NotImplemented then
			body = "This role's ability is not implemented yet."
		elseif response.detail == "no_route" then
			body = "No route to an exit from here."
		end
		self.store.notified:Fire({ kind = "warning", title = "Ability unavailable", body = body, lifetime = 3 })
	end
end

function InputController:setSprinting(enabled)
	if self._sprinting == enabled then
		return
	end
	self._sprinting = enabled
	--[[ Fire-and-forget: sprinting is a continuous state, and a request/response
	     round trip per keypress would be wasteful. The server owns WalkSpeed. ]]
	Net.send(Routes.Event.SetSprinting, { sprinting = enabled })
end

function InputController:requestRescue(paid)
	local response = Net.request(Routes.Request.RequestRescue, { paid = paid == true })
	if not response.ok then
		local body = "No rescue available."
		if response.detail == "no_free_rescue" then
			body = "Your free rescue is spent. You will return home when the run ends."
		elseif response.detail == "expedition_over" then
			body = "The expedition is already over."
		end
		self.store.notified:Fire({ kind = "warning", title = "Cannot rescue", body = body })
	end
end

function InputController:revive(userId)
	local response = Net.request(Routes.Request.Revive, { userId = userId })
	if not response.ok then
		local body = "Cannot reach them."
		if response.reason == Enums.Reject.TooFar then
			body = "Get closer."
		elseif response.detail == "no_stamina" then
			body = "Not enough stamina."
		elseif response.detail == "not_downed" then
			body = "They are not down."
		end
		self.store.notified:Fire({ kind = "warning", title = "Cannot revive", body = body, lifetime = 3 })
	else
		self.store.notified:Fire({
			kind = "info",
			title = "Reviving",
			body = ("Hold still for %.1fs."):format(response.duration or 0),
			lifetime = response.duration or 4,
		})
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Binding
-- ─────────────────────────────────────────────────────────────────────────────

function InputController:start(mainMenu)
	ContextActionService:BindAction(ATTACK_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			self:attack()
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.UserInputType.MouseButton1)

	ContextActionService:BindAction(ABILITY_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			self:useAbility()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.Q)

	ContextActionService:BindAction(SPRINT_ACTION, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			self:setSprinting(true)
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			self:setSprinting(false)
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift)

	--[[ Escape reopens the main menu when no panel is open, which is the only
	     way back to it without a dedicated button eating HUD space. ]]
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and not self.shell.openPanel then
			if mainMenu and not mainMenu.isVisible() then
				mainMenu.show()
			end
		end
	end)

	--[[ Sprinting must not survive a death or a zone change, or the player
	     arrives home draining stamina for no reason. ]]
	self.store.changed:Connect(function(area)
		if area == "zone" or area == "stats" then
			if self._sprinting and (self.store.isDowned() or self.store.isDead() or not self.store.inExpedition()) then
				self:setSprinting(false)
			end
		end
	end)

	return self
end

return InputController
