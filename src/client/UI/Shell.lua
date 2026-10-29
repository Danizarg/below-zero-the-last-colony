--[[
	Shell.lua
	The root interface: one ScreenGui, a layered host for everything else, and
	the navigation that opens panels.

	Layering (Theme.ZIndex)
	───────────────────────
		HUD       always-on gameplay readouts
		Panel     one modal panel at a time, over a scrim
		Modal     results screen, which must not be dismissed accidentally
		Toast     transient notifications
		Critical  shift warnings and death, which outrank everything

	Only one panel is open at a time, on purpose. A survival HUD with four
	floating windows is unreadable, and the brief asks explicitly for an
	uncluttered screen.

	Navigation hides itself during an expedition: down there the only interface
	that matters is the HUD, and a colony menu would be a liability.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local Theme = require(Shared.Config.Theme)
local UIKit = require(script.Parent.UIKit)

local Shell = {}
Shell.__index = Shell

local NAV_ITEMS = {
	{ id = "colony", label = "Colony", icon = "⌂", key = Enum.KeyCode.C },
	{ id = "build", label = "Build", icon = "⚒", key = Enum.KeyCode.B },
	{ id = "expedition", label = "Expeditions", icon = "⛏", key = Enum.KeyCode.X },
	{ id = "roles", label = "Roles", icon = "◈", key = Enum.KeyCode.R },
	{ id = "inventory", label = "Inventory", icon = "▤", key = Enum.KeyCode.Tab },
	{ id = "shop", label = "Shop", icon = "★", key = nil },
	{ id = "settings", label = "Settings", icon = "⚙", key = nil },
}

function Shell.new(store)
	local self = setmetatable({}, Shell)
	self.store = store
	self.panels = {}
	self.openPanel = nil
	self._scrim = nil
	self._navButtons = {}

	local player = Players.LocalPlayer

	local gui = Instance.new("ScreenGui")
	gui.Name = "BelowZeroUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
	gui.DisplayOrder = 10
	gui.Parent = player:WaitForChild("PlayerGui")
	self.gui = gui

	--[[ Hosts are plain transparent frames so a panel can be parented without
	     each one having to know about layering. ]]
	self.hudHost = UIKit.frame({
		name = "HudHost",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
		zIndex = Theme.ZIndex.HUD,
		parent = gui,
	})
	self.panelHost = UIKit.frame({
		name = "PanelHost",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
		zIndex = Theme.ZIndex.Panel,
		parent = gui,
	})
	self.modalHost = UIKit.frame({
		name = "ModalHost",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
		zIndex = Theme.ZIndex.Modal,
		parent = gui,
	})
	self.toastHost = UIKit.frame({
		name = "ToastHost",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
		zIndex = Theme.ZIndex.Toast,
		parent = gui,
	})
	self.criticalHost = UIKit.frame({
		name = "CriticalHost",
		size = UDim2.fromScale(1, 1),
		transparency = 1,
		zIndex = Theme.ZIndex.Critical,
		parent = gui,
	})

	self:_buildNav()
	self:_wireInput()

	store.changed:Connect(function(area)
		if area == "zone" then
			self:_updateNavVisibility()
		end
	end)
	self:_updateNavVisibility()

	return self
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Navigation
-- ─────────────────────────────────────────────────────────────────────────────

function Shell:_buildNav()
	--[[ Bottom-left on desktop, and raised clear of the thumb zone on touch so
	     it does not sit under the movement stick or the jump button. The
	     ScreenGui uses IgnoreGuiInset, so the top-bar offset is applied
	     explicitly where it matters instead of being inherited. ]]
	local isTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

	local bar = UIKit.frame({
		name = "NavBar",
		size = UDim2.new(0, 0, 0, Theme.MinTouchTarget + Theme.Space.S * 2),
		position = UDim2.new(0, Theme.Space.M, 1, -(isTouch and 110 or Theme.Space.M)),
		anchor = Vector2.new(0, 1),
		color = Theme.Color.Backdrop,
		transparency = 0.12,
		radius = Theme.Radius.L,
		stroke = true,
		automaticSize = Enum.AutomaticSize.X,
		parent = self.hudHost,
	})
	UIKit.padding(bar, Theme.Space.S)
	UIKit.list(
		bar,
		{ horizontal = true, padding = Theme.Space.XS, verticalAlign = Enum.VerticalAlignment.Center }
	)
	self.navBar = bar

	for index, item in ipairs(NAV_ITEMS) do
		local button = UIKit.button({
			name = "Nav_" .. item.id,
			size = UDim2.fromOffset(isTouch and Theme.MinTouchTarget or 94, Theme.MinTouchTarget),
			text = isTouch and item.icon or (item.icon .. "  " .. item.label),
			textSize = isTouch and Theme.Text.SubheadingSize or Theme.Text.SmallSize,
			color = Theme.Color.Field,
			radius = Theme.Radius.M,
			parent = bar,
			onClick = function()
				self:toggle(item.id)
			end,
		})
		button.LayoutOrder = index
		self._navButtons[item.id] = button
	end

	--[[ A hint line, because a new player has no idea that E opens things. It
	     fades out after the first interaction. ]]
	self.hint = UIKit.label({
		name = "Hint",
		size = UDim2.new(0, 420, 0, 18),
		position = UDim2.new(0, Theme.Space.M, 1, -(isTouch and 160 or Theme.Space.M + 62)),
		anchor = Vector2.new(0, 1),
		text = isTouch and "Tap the icons to manage your colony. Walk to the tunnel mouth to begin."
			or "C colony · B build · X expeditions · R roles · Tab inventory · E to interact",
		textColor = Theme.Color.TextFaint,
		textSize = Theme.Text.SmallSize,
		parent = self.hudHost,
	})
end

function Shell:_updateNavVisibility()
	local inExpedition = self.store.state.zone == Enums.Zone.Expedition
	if self.navBar then
		self.navBar.Visible = not inExpedition
	end
	if self.hint then
		self.hint.Visible = not inExpedition
	end
	if inExpedition and self.openPanel and self.openPanel ~= "results" then
		self:close()
	end
end

function Shell:_wireInput()
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end

		if input.KeyCode == Enum.KeyCode.Escape then
			if self.openPanel then
				self:close()
			end
			return
		end

		--[[ Panel hotkeys are colony-only. Opening a build menu mid-expedition
		     would be both useless and dangerous. ]]
		if self.store.state.zone == Enums.Zone.Expedition then
			if input.KeyCode == Enum.KeyCode.Tab then
				self:toggle("inventory")
			end
			return
		end

		for _, item in ipairs(NAV_ITEMS) do
			if item.key and input.KeyCode == item.key then
				self:toggle(item.id)
				return
			end
		end
	end)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Panel management
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Register a panel.

	@param id     string
	@param factory function(shell) -> { root = GuiObject, refresh = function? ,
	                                    onOpen = function?, onClose = function? }

	Panels are built lazily on first open, so a session that never opens the
	shop never pays for building it.
]]
function Shell:register(id, factory)
	self.panels[id] = { factory = factory, instance = nil }
end

function Shell:_ensure(id)
	local entry = self.panels[id]
	if not entry then
		return nil
	end
	if not entry.instance then
		local ok, built = pcall(entry.factory, self)
		if not ok then
			warn(("[BZ/Shell] panel %q failed to build: %s"):format(id, tostring(built)))
			return nil
		end
		entry.instance = built
		if built.root then
			built.root.Visible = false
			built.root.Parent = (id == "results") and self.modalHost or self.panelHost
		end
	end
	return entry.instance
end

function Shell:open(id)
	local panel = self:_ensure(id)
	if not panel then
		return
	end

	if self.openPanel and self.openPanel ~= id then
		self:close()
	end

	self.openPanel = id

	if id ~= "results" then
		self._scrim = UIKit.scrim({
			parent = self.panelHost,
			onClick = function()
				self:close()
			end,
		})
	end

	panel.root.Visible = true
	--[[ A small rise-and-fade on open. It costs nothing and is the difference
	     between a window appearing and a window arriving. ]]
	panel.root.Position = UDim2.fromScale(0.5, 0.53)
	UIKit.tween(panel.root, { Position = UDim2.fromScale(0.5, 0.5) }, Theme.Tween.Normal)

	if panel.onOpen then
		local ok, err = pcall(panel.onOpen)
		if not ok then
			warn(("[BZ/Shell] panel %q onOpen failed: %s"):format(id, tostring(err)))
		end
	end
	if panel.refresh then
		pcall(panel.refresh)
	end

	for navId, button in pairs(self._navButtons) do
		button.BackgroundColor3 = (navId == id) and Theme.Color.AccentDim or Theme.Color.Field
	end

	if self.hint then
		UIKit.tween(self.hint, { TextTransparency = 1 }, Theme.Tween.Slow)
	end
end

function Shell:close()
	local id = self.openPanel
	if not id then
		return
	end
	self.openPanel = nil

	local entry = self.panels[id]
	local panel = entry and entry.instance
	if panel then
		if panel.onClose then
			pcall(panel.onClose)
		end
		if panel.root then
			panel.root.Visible = false
		end
	end

	if self._scrim then
		local scrim = self._scrim
		self._scrim = nil
		UIKit.tween(scrim, { BackgroundTransparency = 1 }, Theme.Tween.Fast)
		task.delay(Theme.Tween.Fast + 0.05, function()
			if scrim then
				scrim:Destroy()
			end
		end)
	end

	for _, button in pairs(self._navButtons) do
		button.BackgroundColor3 = Theme.Color.Field
	end
end

function Shell:toggle(id)
	if self.openPanel == id then
		self:close()
	else
		self:open(id)
	end
end

function Shell:isOpen(id)
	return self.openPanel == id
end

--[[ Refresh a panel if it exists and is open. Called by panels' own store
     subscriptions so a closed panel does no work. ]]
function Shell:refreshIfOpen(id)
	if self.openPanel ~= id then
		return
	end
	local entry = self.panels[id]
	if entry and entry.instance and entry.instance.refresh then
		pcall(entry.instance.refresh)
	end
end

return Shell
