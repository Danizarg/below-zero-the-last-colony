--[[
	Routes.lua
	Every network route name in one place, so client and server cannot disagree
	about a string literal.

	Naming: "<area>/<verb>". Requests expect a reply; Events do not.
]]

local Routes = {}

--[[ Client -> server, expects a reply. ]]
Routes.Request = {
	-- Profile and colony
	GetProfile = "profile/get",
	SetSetting = "profile/setSetting",

	-- Navigation
	GoHome = "colony/goHome",
	VisitColony = "colony/visit",

	-- Construction
	PlaceBuilding = "colony/place",
	RemoveBuilding = "colony/remove",
	UpgradeBuilding = "colony/upgrade",
	RepairBuilding = "colony/repair",

	-- Colonists
	AssignJob = "colony/assignJob",
	RecruitColonist = "colony/recruit",

	-- Crafting and storage
	Craft = "craft/make",
	EquipTool = "inventory/equipTool",
	DepositBag = "inventory/deposit",
	UseConsumable = "inventory/use",
	LoadoutSupplies = "expedition/loadSupplies",

	-- Expedition lifecycle
	SetRole = "role/set",
	CreateParty = "party/create",
	JoinParty = "party/join",
	LeaveParty = "party/leave",
	SetReady = "party/ready",
	InviteToParty = "party/invite",
	StartExpedition = "expedition/start",
	LeaveExpedition = "expedition/leave",
	RequestExtraction = "expedition/extract",
	RequestRescue = "expedition/rescue",

	-- In-expedition actions
	HarvestNode = "world/harvest",
	Attack = "combat/attack",
	UseAbility = "role/ability",
	Revive = "survival/revive",
	Interact = "world/interact",
	UnlockGate = "objective/unlockGate",
	SolvePuzzle = "objective/solvePuzzle",

	-- Shop
	GetShop = "shop/get",
	PromptPurchase = "shop/prompt",

	-- Diagnostics (debug builds only; the handler refuses when Debug is off)
	DebugCommand = "debug/command",
}

--[[ Client -> server, fire and forget. ]]
Routes.Event = {
	SetSprinting = "survival/sprint",
	ReportPosition = "world/position",
	MarkLocation = "party/mark",
	Emote = "cosmetic/emote",
}

--[[ Server -> client. ]]
Routes.Push = {
	-- Snapshots
	ProfileSync = "sync/profile",
	ColonySync = "sync/colony",
	InventorySync = "sync/inventory",
	StatsSync = "sync/stats",
	PartySync = "sync/party",
	ExpeditionSync = "sync/expedition",
	ObjectiveSync = "sync/objectives",
	ShopSync = "sync/shop",

	-- Discrete events
	Notify = "ui/notify",
	Alert = "ui/alert",
	PhaseChanged = "expedition/phase",
	ShiftWarning = "expedition/shiftWarning",
	ShiftApplied = "expedition/shiftApplied",
	ExpeditionEnded = "expedition/ended",
	Results = "expedition/results",
	Downed = "survival/downed",
	Revived = "survival/revived",
	NodeDepleted = "world/nodeDepleted",
	RouteRevealed = "role/routeRevealed",
	AbilityState = "role/abilityState",
	PlaySound = "audio/play",
	ZoneChanged = "world/zone",
	Discovery = "world/discovery",
}

--[[ Per-route rate limits, in { burst, window } form. Anything not listed uses
     GameConfig.Net defaults. Tight budgets on the hot gameplay routes are the
     main defence against a scripted client spamming harvests or attacks. ]]
Routes.Limits = {
	[Routes.Request.HarvestNode] = { burst = 6, window = 1 },
	[Routes.Request.Attack] = { burst = 6, window = 1 },
	[Routes.Request.Revive] = { burst = 4, window = 1 },
	[Routes.Request.Interact] = { burst = 8, window = 1 },
	[Routes.Request.UseAbility] = { burst = 3, window = 2 },
	[Routes.Request.UseConsumable] = { burst = 4, window = 1 },
	[Routes.Request.PlaceBuilding] = { burst = 6, window = 2 },
	[Routes.Request.UpgradeBuilding] = { burst = 4, window = 2 },
	[Routes.Request.RepairBuilding] = { burst = 4, window = 2 },
	[Routes.Request.RemoveBuilding] = { burst = 4, window = 2 },
	[Routes.Request.Craft] = { burst = 5, window = 2 },
	[Routes.Request.AssignJob] = { burst = 8, window = 2 },
	[Routes.Request.StartExpedition] = { burst = 2, window = 10 },
	[Routes.Request.RequestExtraction] = { burst = 3, window = 5 },
	[Routes.Request.RequestRescue] = { burst = 2, window = 10 },
	[Routes.Request.GetProfile] = { burst = 3, window = 5 },
	[Routes.Request.PromptPurchase] = { burst = 3, window = 10 },
	[Routes.Event.SetSprinting] = { burst = 10, window = 1 },
	[Routes.Event.ReportPosition] = { burst = 12, window = 1 },
	[Routes.Event.MarkLocation] = { burst = 4, window = 2 },
	[Routes.Event.Emote] = { burst = 3, window = 3 },
}

function Routes.limitsFor(route)
	return Routes.Limits[route]
end

return Routes
