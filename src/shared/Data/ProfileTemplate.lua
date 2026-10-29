--[[
	ProfileTemplate.lua
	The shape of a saved player profile.

	Rules for changing this file:
	  1. Adding a field is safe. TableUtil.reconcile fills it in on load.
	  2. Renaming or removing a field, or changing a field's type, needs a
	     migration step in Migrations.lua and a bump of GameConfig.DataVersion.
	  3. Never store anything derived. Colony effects, storage capacity and role
	     stats are all computed from config at runtime, so a balance change
	     applies to existing players instead of being frozen into their save.
	  4. Keep it small. DataStore values are capped and a profile is written on
	     every autosave.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Enums = require(script.Parent.Parent.Enums)

local ProfileTemplate = {}

ProfileTemplate.Template = {
	--[[ Schema version of this document, used by Migrations. ]]
	version = GameConfig.DataVersion,

	meta = {
		createdAt = 0,
		lastSeenAt = 0,
		playTimeSeconds = 0,
		sessionCount = 0,
		--[[ Set while a session owns this profile; see DataService session
		     locking. Prevents two servers writing the same profile. ]]
		lockJobId = "",
		lockTimestamp = 0,
	},

	progression = {
		level = 1,
		xp = 0,
		--[[ Role mastery is per role so switching specialisation does not throw
		     away progress. ]]
		roleMastery = {
			[Enums.Role.Runner] = 0,
			[Enums.Role.Medic] = 0,
			[Enums.Role.Guardian] = 0,
		},
		selectedRole = Enums.Role.Runner,
		expeditionsStarted = 0,
		expeditionsExtracted = 0,
		expeditionsFailed = 0,
		monstersDefeated = 0,
		roomsDiscovered = 0,
		deepestDepthReached = 0,
		highestDifficultyCleared = "",
	},

	colony = {
		name = "",
		level = 1,
		--[[ Buildings are stored as a flat array of placements. Grid coordinates
		     are integers in plot space, so a plot can be rebuilt exactly. ]]
		buildings = {
			-- { uid = "b1", id = "town_hall", gx = 0, gz = 0, rot = 0, level = 1, health = 400 }
		},
		nextBuildingUid = 1,

		--[[ Permanent colony storage. { [resourceId] = count } ]]
		storage = {},
		consumables = {},

		--[[ Tools the player owns, and which one is equipped. ]]
		tools = { bare_hands = { durability = 0 } },
		equippedTool = "bare_hands",

		colonists = {
			-- { uid = "c1", name = "Ash", job = "farmer", skill = 1, health = 100 }
		},
		nextColonistUid = 1,

		--[[ 0..100. Floors at GameConfig.NPC.ConditionFloor so a colony can
		     never be lost to absence. ]]
		condition = 100,
		food = 50,
		research = 0,

		--[[ Timestamp of the last production settlement, used to grant offline
		     production on the next join. ]]
		lastProductionAt = 0,

		--[[ Who may build in this colony. Visitors are read-only unless the
		     owner adds them here. Keyed by userId as a string, because
		     DataStore JSON turns integer keys into strings anyway. ]]
		builders = {},
	},

	escape = {
		--[[ Ancient keys held. Keys survive death by design. ]]
		keys = 0,
		gateStagesUnlocked = 0,
		--[[ Story beats the player has seen, so narration never repeats. ]]
		loreSeen = {},
		escaped = false,
	},

	cosmetics = {
		owned = {},
		equipped = {
			skin = "",
			lantern = "",
			buildingTheme = "",
		},
		loadoutSlots = 1,
		loadouts = {},
	},

	settings = {
		musicVolume = 0.5,
		sfxVolume = 0.8,
		ambienceVolume = 0.6,
		screenShake = true,
		showDamageNumbers = true,
		hudScale = 1,
		colourblindMode = false,
	},

	monetization = {
		--[[ Fulfilled Developer Product receipts, keyed by PurchaseId string.
		     This is what makes fulfilment idempotent: a receipt already present
		     is acknowledged and not granted twice. Trimmed to the most recent
		     entries by DataService to keep the profile small. ]]
		receipts = {},
		receiptOrder = {},
		rescuesPurchased = 0,
		rescuesUsed = 0,
	},

	--[[ Non-authoritative diagnostics, handy when a player reports a problem. ]]
	diagnostics = {
		lastExpeditionSeed = 0,
		lastExpeditionDifficulty = "",
		saveFailures = 0,
	},
}

--[[ A fresh profile with timestamps and a starting colony filled in.
     `now` is passed in rather than read from os.time() so callers can keep
     a consistent clock across a batch of operations. ]]
function ProfileTemplate.create(now, playerName)
	local TableUtil = require(script.Parent.Parent.Util.TableUtil)
	local profile = TableUtil.deepCopy(ProfileTemplate.Template)

	now = now or os.time()
	profile.meta.createdAt = now
	profile.meta.lastSeenAt = now
	profile.colony.lastProductionAt = now
	profile.colony.name = (playerName and playerName ~= "") and (playerName .. "'s Hollow") or "New Hollow"

	--[[ Starting resources: enough to place one shelter and one farm, so a new
	     player has something to do before their first expedition rather than
	     being sent straight into the dark. ]]
	profile.colony.storage = {
		[Enums.Resource.Stone] = 40,
		[Enums.Resource.Fiber] = 60,
		[Enums.Resource.Mushroom] = 10,
	}

	return profile
end

return ProfileTemplate
