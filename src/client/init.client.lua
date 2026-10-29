--[[
	BELOW ZERO: THE LAST COLONY — client bootstrap

	Order matters here:
	  1. Net.start() waits for the server's remotes to exist.
	  2. Store.start() subscribes to every push route and requests the profile,
	     so no UI can be built against an empty state by accident.
	  3. The Shell creates the single ScreenGui and its layers.
	  4. HUDs are built eagerly (they are always needed); panels are registered
	     as factories and built on first open.
	  5. Controllers are wired last, because they hand callbacks to the HUD.

	Everything in this file is wiring. There is no gameplay logic on the client:
	it renders what the server sent and sends back intent.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local GameConfig = require(Shared.Config.GameConfig)
local Logger = require(Shared.Util.Logger)
local Net = require(Shared.Util.Net)

local log = Logger.new("Client")

-- ── Transport and state ──────────────────────────────────────────────────────

Net.start()

local Store = require(script.Store)
Store.start()

-- ── UI ───────────────────────────────────────────────────────────────────────

local UIKit = require(script.UI.UIKit)
local Shell = require(script.UI.Shell)
local Notifications = require(script.UI.Notifications)
local ColonyHUD = require(script.UI.ColonyHUD)
local ExpeditionHUD = require(script.UI.ExpeditionHUD)
local MainMenu = require(script.UI.MainMenu)

local shell = Shell.new(Store)
local notifications = Notifications.new(shell, Store)
local colonyHUD = ColonyHUD.new(shell, Store)
local expeditionHUD = ExpeditionHUD.new(shell, Store)
local mainMenu = MainMenu.create(shell, Store)

-- ── Controllers ──────────────────────────────────────────────────────────────

local AudioController = require(script.Controllers.AudioController)
local AtmosphereController = require(script.Controllers.AtmosphereController)
local BuildController = require(script.Controllers.BuildController)
local InputController = require(script.Controllers.InputController)
local InteractionController = require(script.Controllers.InteractionController)
local RouteController = require(script.Controllers.RouteController)

local audio = AudioController.new(Store):start()
local atmosphere = AtmosphereController.new(Store, shell):start()
local build = BuildController.new(Store, shell, UIKit):start()
local input = InputController.new(Store, shell, expeditionHUD)
local interaction = InteractionController.new(Store, shell, UIKit):start()
local route = RouteController.new(Store):start()

input:start(mainMenu)

-- ── Panels ───────────────────────────────────────────────────────────────────

local ColonyPanel = require(script.UI.ColonyPanel)
local BuildMenu = require(script.UI.BuildMenu)
local RoleSelect = require(script.UI.RoleSelect)
local ExpeditionPanel = require(script.UI.ExpeditionPanel)
local InventoryPanel = require(script.UI.InventoryPanel)
local ShopPanel = require(script.UI.ShopPanel)
local ResultsScreen = require(script.UI.ResultsScreen)
local SettingsPanel = require(script.UI.SettingsPanel)

shell:register("colony", function(host)
	return ColonyPanel.create(host, Store)
end)
shell:register("build", function(host)
	return BuildMenu.create(host, Store, build)
end)
shell:register("roles", function(host)
	return RoleSelect.create(host, Store)
end)
shell:register("expedition", function(host)
	return ExpeditionPanel.create(host, Store)
end)
shell:register("inventory", function(host)
	return InventoryPanel.create(host, Store)
end)
shell:register("shop", function(host)
	return ShopPanel.create(host, Store)
end)
shell:register("results", function(host)
	return ResultsScreen.create(host, Store)
end)
shell:register("settings", function(host)
	return SettingsPanel.create(host, Store)
end)

--[[ The results screen subscribes to Store.resultsReady in its factory, so it
     has to exist before the first expedition ends rather than being built
     lazily on first open. ]]
shell:_ensure("results")

-- ── Cross-wiring that does not belong in any one module ──────────────────────

--[[ The invite toast's join button needs the party route, which Notifications
     should not know about. ]]
notifications.onJoinParty = function(code)
	local Routes = require(Shared.Routes)
	local response = Net.request(Routes.Request.JoinParty, { code = code })
	if response.ok then
		shell:open("expedition")
	else
		Store.notified:Fire({
			kind = "warning",
			title = "Could not join",
			body = "That party is full or already underground.",
		})
	end
end

--[[ A first-time player sees the menu; a returning one does not, because the
     menu is a welcome rather than a gate. ]]
task.delay(1, function()
	if not Store.state.colony or (Store.state.colony.level or 1) <= 1 then
		mainMenu.show()
	end
end)

-- Keep references alive, and in debug builds make them reachable from the console.
local client = {
	store = Store,
	shell = shell,
	notifications = notifications,
	colonyHUD = colonyHUD,
	expeditionHUD = expeditionHUD,
	mainMenu = mainMenu,
	audio = audio,
	atmosphere = atmosphere,
	build = build,
	input = input,
	interaction = interaction,
	route = route,
}

--[[ A console handle, debug builds only. Being able to type
     `_G.BelowZeroClient.store.state` in the Studio command bar is worth a lot
     while testing, but a published client should not hand its internals to
     anyone who opens the developer console. ]]
if GameConfig.Debug then
	-- selene: allow(global_usage)
	_G.BelowZeroClient = client
end

log:info("client ready (v%s) for %s", GameConfig.Version, Players.LocalPlayer.Name)
