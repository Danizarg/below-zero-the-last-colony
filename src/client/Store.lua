--[[
	Store.lua
	The client's view of server state.

	Every Routes.Push route lands here and nowhere else. UI reads from
	`Store.state` and subscribes to `Store.changed`, so no panel talks to the
	network directly and no two panels can disagree about what the server said.

	This is a read model, not a source of truth. Nothing in it is authoritative:
	it is the last thing the server told us, kept so the interface can draw
	without asking again.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local Net = require(Shared.Util.Net)
local Routes = require(Shared.Routes)
local Signal = require(Shared.Util.Signal)

local Store = {}

Store.state = {
	-- Colony
	colony = nil,
	storage = {},
	consumables = {},
	storageCapacity = 0,
	storageUsed = 0,
	tools = {},
	equippedTool = "bare_hands",
	recipes = {},
	directory = {},

	-- Expedition bag
	bag = {},
	bagConsumables = {},
	bagCapacity = 0,
	bagUsed = 0,

	-- Player stats
	stats = {
		health = 100,
		maxHealth = 100,
		stamina = 100,
		staminaMax = 100,
		hunger = 100,
		hungerMax = 100,
		state = Enums.MemberState.Alive,
		downedRemaining = nil,
		sprinting = false,
	},

	-- Roles
	role = nil,
	roles = {},

	-- Party
	party = nil,

	-- Expedition
	zone = Enums.Zone.Colony,
	expedition = nil,
	objectives = nil,
	results = nil,
	spectating = false,
	spectateInfo = nil,

	-- Shop
	shop = nil,

	-- Meta
	settings = {},
	readOnly = false,
	version = "?",
}

Store.changed = Signal.new("storeChanged")
Store.notified = Signal.new("notified")
Store.alerted = Signal.new("alerted")
Store.shiftWarned = Signal.new("shiftWarned")
Store.shiftApplied = Signal.new("shiftApplied")
Store.routeRevealed = Signal.new("routeRevealed")
Store.soundRequested = Signal.new("soundRequested")
Store.resultsReady = Signal.new("resultsReady")
Store.discovery = Signal.new("discovery")
Store.phaseChanged = Signal.new("phaseChanged")
Store.teammateDowned = Signal.new("teammateDowned")
Store.teammateRevived = Signal.new("teammateRevived")
Store.nodeDepleted = Signal.new("nodeDepleted")

--[[ Fire a change for one logical area. UI subscribes to the areas it cares
     about rather than redrawing everything on every packet. ]]
local function touch(area)
	Store.changed:Fire(area, Store.state)
end

Store.touch = touch

local function mergeInto(target, source, keys)
	for _, key in ipairs(keys) do
		if source[key] ~= nil then
			target[key] = source[key]
		end
	end
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Convenience queries used across the UI
-- ─────────────────────────────────────────────────────────────────────────────

function Store.inExpedition()
	return Store.state.zone == Enums.Zone.Expedition
end

function Store.resourceCount(resourceId)
	if Store.inExpedition() then
		return Store.state.bag[resourceId] or 0
	end
	return Store.state.storage[resourceId] or 0
end

function Store.currentInventory()
	if Store.inExpedition() then
		return Store.state.bag, Store.state.bagConsumables, Store.state.bagUsed, Store.state.bagCapacity
	end
	return Store.state.storage, Store.state.consumables, Store.state.storageUsed, Store.state.storageCapacity
end

function Store.phase()
	return Store.state.expedition and Store.state.expedition.phase or nil
end

function Store.isDowned()
	return Store.state.stats.state == Enums.MemberState.Downed
end

function Store.isDead()
	return Store.state.stats.state == Enums.MemberState.Dead
end

--[[ Teammates other than the local player, for the team panel. ]]
function Store.teammates(localUserId)
	local out = {}
	local expedition = Store.state.expedition
	if not expedition then
		return out
	end
	for _, member in ipairs(expedition.team or {}) do
		if member.userId ~= localUserId then
			table.insert(out, member)
		end
	end
	return out
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Wiring
-- ─────────────────────────────────────────────────────────────────────────────

function Store.start()
	Net.on(Routes.Push.ColonySync, function(payload)
		if type(payload) ~= "table" then
			return
		end
		Store.state.colony = payload
		touch("colony")
	end)

	Net.on(Routes.Push.InventorySync, function(payload)
		if type(payload) ~= "table" then
			return
		end
		--[[ Storage and bag arrive in separate packets so a harvest does not
		     have to resend the whole colony. Merge rather than replace. ]]
		if payload.storage then
			Store.state.storage = payload.storage
			Store.state.consumables = payload.consumables or {}
			Store.state.storageCapacity = payload.capacity or Store.state.storageCapacity
			Store.state.storageUsed = payload.used or Store.state.storageUsed
			Store.state.tools = payload.tools or Store.state.tools
			Store.state.equippedTool = payload.equippedTool or Store.state.equippedTool
			Store.state.recipes = payload.recipes or Store.state.recipes
		end
		if payload.bag then
			Store.state.bag = payload.bag
			Store.state.bagConsumables = payload.bagConsumables or {}
			Store.state.bagCapacity = payload.bagCapacity or Store.state.bagCapacity
			Store.state.bagUsed = payload.bagUsed or 0
		end
		touch("inventory")
	end)

	Net.on(Routes.Push.StatsSync, function(payload)
		if type(payload) ~= "table" then
			return
		end
		mergeInto(Store.state.stats, payload, {
			"health",
			"maxHealth",
			"stamina",
			"staminaMax",
			"hunger",
			"hungerMax",
			"state",
			"sprinting",
			"downedWindow",
		})
		--[[ downedRemaining is deliberately assigned rather than merged: nil
		     means "not downed" and must be able to clear. ]]
		Store.state.stats.downedRemaining = payload.downedRemaining

		--[[ Belt and braces on the spectate overlay: if the server says we are
		     alive again, we are not spectating, whatever route brought us back. ]]
		if Store.state.spectating and payload.state == Enums.MemberState.Alive then
			Store.state.spectating = false
			Store.state.spectateInfo = nil
			touch("spectate")
		end

		touch("stats")
	end)

	Net.on(Routes.Push.AbilityState, function(payload)
		if type(payload) ~= "table" then
			return
		end
		--[[ Stamped so the HUD can drain the cooldown locally; this route only
		     fires on use or refresh, so its cooldownRemaining is a snapshot. ]]
		payload.syncedAt = os.clock()
		Store.state.role = payload
		if payload.roles then
			Store.state.roles = payload.roles
		end
		touch("role")
	end)

	Net.on(Routes.Push.PartySync, function(payload)
		if type(payload) ~= "table" then
			return
		end
		if Store.state.party and payload.marks and not payload.members then
			Store.state.party.marks = payload.marks
		else
			Store.state.party = payload
		end
		touch("party")
	end)

	Net.on(Routes.Push.ExpeditionSync, function(payload)
		if type(payload) ~= "table" then
			return
		end
		--[[ Stamp the arrival against the CLIENT's own clock. The server sends
		     remaining durations rather than timestamps, because os.clock() is
		     process-relative and a server value means nothing here. The HUD
		     interpolates from this stamp between syncs. ]]
		payload.syncedAt = os.clock()
		Store.state.expedition = payload
		touch("expedition")
	end)

	Net.on(Routes.Push.ObjectiveSync, function(payload)
		if type(payload) ~= "table" then
			return
		end
		Store.state.objectives = payload
		touch("objectives")
	end)

	Net.on(Routes.Push.ZoneChanged, function(payload)
		if type(payload) ~= "table" then
			return
		end
		Store.state.zone = payload.zone or Enums.Zone.Colony
		--[[ Both are kept: the id drives the lighting palette, the name is what
		     the HUD prints. ]]
		Store.state.biomeId = payload.biome
		Store.state.biomeName = payload.biomeName
		if Store.state.zone == Enums.Zone.Colony then
			--[[ Leaving the caves clears per-run state so a stale objective
			     tracker or spectate overlay cannot survive into the colony. ]]
			Store.state.expedition = nil
			Store.state.objectives = nil
			Store.state.spectating = false
			Store.state.spectateInfo = nil
		end
		touch("zone")
	end)

	Net.on(Routes.Push.ShopSync, function(payload)
		if type(payload) ~= "table" then
			return
		end
		Store.state.shop = payload
		touch("shop")
	end)

	Net.on(Routes.Push.PhaseChanged, function(payload)
		if type(payload) ~= "table" then
			return
		end
		if Store.state.expedition then
			Store.state.expedition.phase = payload.phase
			Store.state.expedition.phaseRemaining = payload.remaining or payload.duration
			Store.state.expedition.phaseDuration = payload.duration
			Store.state.expedition.syncedAt = os.clock()
		end
		Store.phaseChanged:Fire(payload)
		touch("expedition")
	end)

	Net.on(Routes.Push.Notify, function(payload)
		if type(payload) == "table" then
			Store.notified:Fire(payload)
		end
	end)

	Net.on(Routes.Push.Alert, function(payload)
		if type(payload) == "table" then
			Store.alerted:Fire(payload)
		end
	end)

	Net.on(Routes.Push.ShiftWarning, function(payload)
		if type(payload) == "table" then
			Store.shiftWarned:Fire(payload)
		end
	end)

	Net.on(Routes.Push.ShiftApplied, function(payload)
		if type(payload) == "table" then
			if Store.state.objectives and payload.map then
				Store.state.objectives.map = payload.map
				touch("objectives")
			end
			Store.shiftApplied:Fire(payload)
		end
	end)

	Net.on(Routes.Push.RouteRevealed, function(payload)
		if type(payload) == "table" then
			Store.routeRevealed:Fire(payload)
		end
	end)

	Net.on(Routes.Push.PlaySound, function(payload)
		if type(payload) == "table" then
			Store.soundRequested:Fire(payload)
		end
	end)

	Net.on(Routes.Push.Results, function(payload)
		if type(payload) == "table" then
			Store.state.results = payload
			Store.resultsReady:Fire(payload)
		end
	end)

	Net.on(Routes.Push.ExpeditionEnded, function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.spectating then
			Store.state.spectating = true
			Store.state.spectateInfo = payload
			touch("spectate")
		end
	end)

	Net.on(Routes.Push.Downed, function(payload)
		if type(payload) == "table" then
			Store.teammateDowned:Fire(payload)
		end
	end)

	Net.on(Routes.Push.Revived, function(payload)
		if type(payload) == "table" then
			--[[ A rescue or revive of the LOCAL player clears the spectate
			     overlay. Without this it only cleared on a zone change back to
			     the colony, so a rescued player kept a full-screen "YOU DIED"
			     sheet over their HUD for the rest of the run. ]]
			if payload.userId == Players.LocalPlayer.UserId then
				Store.state.spectating = false
				Store.state.spectateInfo = nil
				touch("spectate")
			end
			Store.teammateRevived:Fire(payload)
		end
	end)

	Net.on(Routes.Push.NodeDepleted, function(payload)
		if type(payload) == "table" then
			Store.nodeDepleted:Fire(payload)
		end
	end)

	Net.on(Routes.Push.Discovery, function(payload)
		if type(payload) == "table" then
			Store.discovery:Fire(payload)
		end
	end)

	--[[ One request for everything the UI needs at startup. Retried a few times
	     because the profile may still be loading when the client is ready. ]]
	task.spawn(function()
		for attempt = 1, 6 do
			local response = Net.request(Routes.Request.GetProfile)
			if response.ok then
				Store.state.colony = response.colony or Store.state.colony
				Store.state.settings = response.settings or {}
				Store.state.cosmetics = response.cosmetics
				Store.state.readOnly = response.readOnly == true
				Store.state.degraded = response.degraded == true
				Store.state.directory = response.directory or {}
				Store.state.version = response.version or "?"
				touch("colony")
				touch("meta")
				return
			end
			task.wait(attempt * 0.5)
		end
		warn("[BZ/Store] profile never arrived; the UI will show empty state")
	end)

	return Store
end

return Store
