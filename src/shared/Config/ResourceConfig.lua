--[[
	ResourceConfig.lua
	Resource definitions, harvest node definitions and crafting recipes.
]]

local Enums = require(script.Parent.Parent.Enums)
local R = Enums.Resource

local ResourceConfig = {}

-- ─────────────────────────────────────────────────────────────────────────────
-- Resources
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	stackLimit  per-slot cap in an inventory
	weight      expedition bag capacity cost per unit
	rarity      "common" | "uncommon" | "rare" | "epic" | "unique"
	tier        minimum tool tier required to harvest (0 = bare hands)
	icon        single glyph used by the UI; no external asset IDs anywhere
]]
ResourceConfig.Resources = {
	[R.Stone] = {
		id = R.Stone,
		name = "Stone",
		description = "Cold, dense rock. The bones of every wall you will ever build.",
		stackLimit = 200,
		weight = 1,
		rarity = "common",
		tier = 0,
		icon = "■",
		color = Color3.fromRGB(135, 138, 148),
		uses = { "Construction", "Repairs", "Tool heads" },
	},
	[R.Fiber] = {
		id = R.Fiber,
		name = "Fungal Fiber",
		description = "Tough strands pulled from cave fungus. Stands in for wood down here.",
		stackLimit = 200,
		weight = 1,
		rarity = "common",
		tier = 0,
		icon = "≈",
		color = Color3.fromRGB(150, 176, 126),
		uses = { "Construction", "Rope", "Bandages" },
	},
	[R.Iron] = {
		id = R.Iron,
		name = "Iron Ore",
		description = "Rust-red seams running through the deep rock.",
		stackLimit = 120,
		weight = 2,
		rarity = "uncommon",
		tier = 1,
		icon = "◆",
		color = Color3.fromRGB(176, 122, 96),
		biomes = { Enums.Biome.IronDepths, Enums.Biome.FungalHollow },
		uses = { "Tools", "Workshop upgrades", "Structural frames" },
	},
	[R.Coal] = {
		id = R.Coal,
		name = "Coal",
		description = "Burns long and hot. The colony runs on it.",
		stackLimit = 150,
		weight = 1,
		rarity = "common",
		tier = 1,
		icon = "●",
		color = Color3.fromRGB(58, 58, 64),
		uses = { "Fuel", "Smelting", "Lanterns" },
	},
	[R.Mushroom] = {
		id = R.Mushroom,
		name = "Cave Mushroom",
		description = "Edible, barely. Better once a cook has had a go at it.",
		stackLimit = 100,
		weight = 1,
		rarity = "common",
		tier = 0,
		icon = "✿",
		color = Color3.fromRGB(196, 158, 206),
		uses = { "Food", "Farm seed stock" },
	},
	[R.Herb] = {
		id = R.Herb,
		name = "Glowroot",
		description = "A faintly luminous root. Chewed raw it dulls pain; brewed it does more.",
		stackLimit = 80,
		weight = 1,
		rarity = "uncommon",
		tier = 0,
		icon = "✚",
		color = Color3.fromRGB(126, 216, 196),
		uses = { "Medicine", "Infirmary stock" },
	},
	[R.Crystal] = {
		id = R.Crystal,
		name = "Resonant Crystal",
		description = "Hums when you hold it. Nobody has worked out why.",
		stackLimit = 50,
		weight = 3,
		rarity = "rare",
		tier = 2,
		icon = "◇",
		color = Color3.fromRGB(128, 180, 255),
		biomes = { Enums.Biome.CrystalReach, Enums.Biome.IronDepths },
		uses = { "Research", "Power", "Advanced construction" },
	},
	[R.Relic] = {
		id = R.Relic,
		name = "Ancient Fragment",
		description = "Worked stone from something that was down here long before you.",
		stackLimit = 25,
		weight = 2,
		rarity = "epic",
		tier = 0,
		icon = "⌘",
		color = Color3.fromRGB(226, 198, 124),
		uses = { "Research", "Gate study" },
	},
	[R.AncientKey] = {
		id = R.AncientKey,
		name = "Ancient Key",
		description = "One of several. The First Gate will not open for fewer.",
		stackLimit = 9,
		weight = 0,
		rarity = "unique",
		tier = 0,
		icon = "★",
		color = Color3.fromRGB(255, 228, 150),
		--[[ Keys survive death. Losing a key to a bad run would make the escape
		     objective feel punishing rather than suspenseful. ]]
		protectedOnDeath = true,
		uses = { "Unlocking the First Gate" },
	},
}

ResourceConfig.Order = {
	R.Stone,
	R.Fiber,
	R.Iron,
	R.Coal,
	R.Mushroom,
	R.Herb,
	R.Crystal,
	R.Relic,
	R.AncientKey,
}

ResourceConfig.RarityColor = {
	common = Color3.fromRGB(176, 182, 194),
	uncommon = Color3.fromRGB(126, 206, 150),
	rare = Color3.fromRGB(118, 170, 248),
	epic = Color3.fromRGB(196, 140, 236),
	unique = Color3.fromRGB(255, 212, 122),
}

function ResourceConfig.get(id)
	return ResourceConfig.Resources[id]
end

function ResourceConfig.isValid(id)
	return ResourceConfig.Resources[id] ~= nil
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Harvest nodes
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	A node is a world object that yields a resource over a number of hits.
	`hits` is how many successful swings empty it. The server owns the hit count;
	the client only asks to swing.

	weight  relative spawn chance inside a room that accepts this node
	rooms   room kinds this node may spawn in
]]
ResourceConfig.Nodes = {
	stone_outcrop = {
		id = "stone_outcrop",
		name = "Stone Outcrop",
		resource = R.Stone,
		yieldPerHit = 3,
		hits = 4,
		tier = 0,
		respawnSeconds = 75,
		weight = 10,
		size = Vector3.new(6, 5, 6),
		color = Color3.fromRGB(122, 126, 136),
		material = Enum.Material.Slate,
		rooms = {
			Enums.RoomKind.MiningChamber,
			Enums.RoomKind.CorridorStraight,
			Enums.RoomKind.CorridorCurve,
			Enums.RoomKind.Junction,
			Enums.RoomKind.DeadEnd,
			Enums.RoomKind.ResourceChamber,
		},
	},
	fungal_cluster = {
		id = "fungal_cluster",
		name = "Fungal Cluster",
		resource = R.Fiber,
		yieldPerHit = 3,
		hits = 3,
		tier = 0,
		respawnSeconds = 60,
		weight = 9,
		size = Vector3.new(5, 4, 5),
		color = Color3.fromRGB(128, 158, 110),
		material = Enum.Material.Grass,
		glow = Color3.fromRGB(150, 210, 140),
		rooms = {
			Enums.RoomKind.ResourceChamber,
			Enums.RoomKind.CorridorStraight,
			Enums.RoomKind.CorridorCurve,
			Enums.RoomKind.DeadEnd,
			Enums.RoomKind.Entrance,
			--[[ Fungus thrives in a nest: damp, warm and undisturbed. This also
			     gives a nest something to harvest, so it is a room worth risking
			     rather than pure hazard. ]]
			Enums.RoomKind.MonsterNest,
		},
	},
	iron_seam = {
		id = "iron_seam",
		name = "Iron Seam",
		resource = R.Iron,
		yieldPerHit = 2,
		hits = 5,
		tier = 1,
		respawnSeconds = 130,
		weight = 6,
		size = Vector3.new(6, 6, 5),
		color = Color3.fromRGB(150, 104, 82),
		material = Enum.Material.Rock,
		rooms = { Enums.RoomKind.MiningChamber, Enums.RoomKind.ResourceChamber, Enums.RoomKind.Junction },
	},
	coal_vein = {
		id = "coal_vein",
		name = "Coal Vein",
		resource = R.Coal,
		yieldPerHit = 3,
		hits = 4,
		tier = 1,
		respawnSeconds = 100,
		weight = 7,
		size = Vector3.new(6, 5, 5),
		color = Color3.fromRGB(44, 44, 50),
		material = Enum.Material.Basalt,
		rooms = { Enums.RoomKind.MiningChamber, Enums.RoomKind.ResourceChamber, Enums.RoomKind.DeadEnd },
	},
	mushroom_patch = {
		id = "mushroom_patch",
		name = "Mushroom Patch",
		resource = R.Mushroom,
		yieldPerHit = 2,
		hits = 3,
		tier = 0,
		respawnSeconds = 55,
		weight = 7,
		size = Vector3.new(5, 3, 5),
		color = Color3.fromRGB(178, 142, 190),
		material = Enum.Material.Fabric,
		glow = Color3.fromRGB(206, 160, 226),
		rooms = {
			Enums.RoomKind.ResourceChamber,
			Enums.RoomKind.Entrance,
			Enums.RoomKind.CorridorCurve,
			Enums.RoomKind.DeadEnd,
		},
	},
	glowroot_bed = {
		id = "glowroot_bed",
		name = "Glowroot Bed",
		resource = R.Herb,
		yieldPerHit = 2,
		hits = 2,
		tier = 0,
		respawnSeconds = 90,
		weight = 5,
		size = Vector3.new(5, 2, 5),
		color = Color3.fromRGB(96, 186, 168),
		material = Enum.Material.Fabric,
		glow = Color3.fromRGB(126, 226, 206),
		rooms = { Enums.RoomKind.ResourceChamber, Enums.RoomKind.PuzzleRoom, Enums.RoomKind.DeadEnd },
	},
	crystal_formation = {
		id = "crystal_formation",
		name = "Crystal Formation",
		resource = R.Crystal,
		yieldPerHit = 1,
		hits = 4,
		tier = 2,
		respawnSeconds = 200,
		weight = 3,
		size = Vector3.new(5, 8, 5),
		color = Color3.fromRGB(110, 160, 230),
		material = Enum.Material.Glass,
		glow = Color3.fromRGB(140, 196, 255),
		rooms = { Enums.RoomKind.MiningChamber, Enums.RoomKind.AncientVault, Enums.RoomKind.PuzzleRoom },
	},
	relic_pile = {
		id = "relic_pile",
		name = "Collapsed Masonry",
		resource = R.Relic,
		yieldPerHit = 1,
		hits = 3,
		tier = 0,
		respawnSeconds = 0, -- one-shot; does not respawn within a run
		weight = 4,
		size = Vector3.new(6, 4, 6),
		color = Color3.fromRGB(176, 158, 120),
		material = Enum.Material.Sandstone,
		rooms = {
			Enums.RoomKind.AncientVault,
			Enums.RoomKind.PuzzleRoom,
			Enums.RoomKind.ExtractionChamber,
			--[[ What is left of whoever came through here before you. A nest
			     holding relics is the risk/reward case the room needs: with
			     fungal_cluster weighted 9 against this at 4, roughly a third of
			     nests are worth the fight. ]]
			Enums.RoomKind.MonsterNest,
		},
	},
}

--[[ How many nodes a room kind wants before difficulty scaling. ]]
ResourceConfig.NodesPerRoom = {
	[Enums.RoomKind.Entrance] = 1,
	[Enums.RoomKind.CorridorStraight] = 1,
	[Enums.RoomKind.CorridorCurve] = 1,
	[Enums.RoomKind.Junction] = 1,
	[Enums.RoomKind.DeadEnd] = 2,
	[Enums.RoomKind.MiningChamber] = 5,
	[Enums.RoomKind.ResourceChamber] = 5,
	[Enums.RoomKind.MonsterNest] = 1,
	[Enums.RoomKind.PuzzleRoom] = 2,
	[Enums.RoomKind.AncientVault] = 3,
	[Enums.RoomKind.ExtractionChamber] = 1,
}

function ResourceConfig.nodesForRoom(roomKind)
	local out = {}
	for _, node in pairs(ResourceConfig.Nodes) do
		for _, kind in ipairs(node.rooms) do
			if kind == roomKind then
				table.insert(out, node)
				break
			end
		end
	end
	--[[ Deterministic order matters: the generator picks from this list with a
	     seeded RNG, so an unstable order would break reproducible seeds. ]]
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

-- ─────────────────────────────────────────────────────────────────────────────
-- Tools
-- ─────────────────────────────────────────────────────────────────────────────

ResourceConfig.Tools = {
	bare_hands = {
		id = "bare_hands",
		name = "Bare Hands",
		tier = 0,
		damage = 6,
		swingCooldown = 0.75,
		harvestMultiplier = 0.6,
		maxDurability = 0, -- 0 = indestructible
		cost = {},
	},
	stone_pick = {
		id = "stone_pick",
		name = "Stone Pick",
		tier = 1,
		damage = 10,
		swingCooldown = 0.65,
		harvestMultiplier = 1,
		maxDurability = 120,
		cost = { [R.Stone] = 12, [R.Fiber] = 6 },
	},
	iron_pick = {
		id = "iron_pick",
		name = "Iron Pick",
		tier = 2,
		damage = 15,
		swingCooldown = 0.55,
		harvestMultiplier = 1.5,
		maxDurability = 300,
		cost = { [R.Iron] = 14, [R.Fiber] = 8, [R.Coal] = 6 },
	},
	iron_blade = {
		id = "iron_blade",
		name = "Iron Blade",
		tier = 1,
		damage = 26,
		swingCooldown = 0.6,
		harvestMultiplier = 0.5,
		maxDurability = 240,
		cost = { [R.Iron] = 18, [R.Fiber] = 6 },
	},
}

ResourceConfig.ToolOrder = { "bare_hands", "stone_pick", "iron_pick", "iron_blade" }

-- ─────────────────────────────────────────────────────────────────────────────
-- Consumables and crafting
-- ─────────────────────────────────────────────────────────────────────────────

ResourceConfig.Consumables = {
	cooked_mushroom = {
		id = "cooked_mushroom",
		name = "Cooked Mushroom",
		description = "Restores hunger and a little stamina.",
		icon = "✿",
		hunger = 45,
		stamina = 25,
		health = 0,
		stackLimit = 20,
		weight = 1,
	},
	glowroot_salve = {
		id = "glowroot_salve",
		name = "Glowroot Salve",
		description = "Restores health. A medic gets more out of it.",
		icon = "✚",
		hunger = 0,
		stamina = 0,
		health = 40,
		stackLimit = 10,
		weight = 1,
	},
}

--[[ Recipes are evaluated server-side only. `station` must match a built
     building id in the player's colony, or nil for anywhere. ]]
ResourceConfig.Recipes = {
	{
		id = "craft_stone_pick",
		name = "Stone Pick",
		station = Enums.Building.Workshop,
		cost = { [R.Stone] = 12, [R.Fiber] = 6 },
		grantsTool = "stone_pick",
	},
	{
		id = "craft_iron_pick",
		name = "Iron Pick",
		station = Enums.Building.Workshop,
		stationLevel = 2,
		cost = { [R.Iron] = 14, [R.Fiber] = 8, [R.Coal] = 6 },
		grantsTool = "iron_pick",
	},
	{
		id = "craft_iron_blade",
		name = "Iron Blade",
		station = Enums.Building.Workshop,
		cost = { [R.Iron] = 18, [R.Fiber] = 6 },
		grantsTool = "iron_blade",
	},
	{
		id = "cook_mushroom",
		name = "Cooked Mushroom x3",
		station = Enums.Building.Farm,
		cost = { [R.Mushroom] = 4, [R.Coal] = 1 },
		grantsConsumable = { id = "cooked_mushroom", count = 3 },
	},
	{
		id = "brew_salve",
		name = "Glowroot Salve x2",
		station = Enums.Building.Infirmary,
		cost = { [R.Herb] = 3, [R.Fiber] = 2 },
		grantsConsumable = { id = "glowroot_salve", count = 2 },
	},
}

return ResourceConfig
