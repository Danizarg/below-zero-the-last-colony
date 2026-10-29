--[[
	RoomConfig.lua

	Room module definitions and biome themes.

	Every room occupies one cell of the cave grid and has four standardised
	connection points, one per cardinal edge, centred on that edge. A doorway
	exists on an edge only when both neighbouring cells agree, which is what
	keeps the generated geometry non-overlapping and always traversable.

	This module owns the VISUAL side of a room: lighting, ceiling height, props
	and biome theming. The generation rules (`doorRule`, `weight`,
	`shiftProtected`, `isExtraction`) live in Lib/RoomRules.lua, which is free of
	Roblox datatypes so the generator can be tested in isolation. Those fields are
	merged in at the bottom of this file; RoomRules is authoritative.
]]

local Enums = require(script.Parent.Parent.Enums)
local RoomRules = require(script.Parent.Parent.Lib.RoomRules)
local K = Enums.RoomKind

local RoomConfig = {}

RoomConfig.Rooms = {
	[K.Entrance] = {
		id = K.Entrance,
		name = "Tunnel Mouth",
		doorRule = { min = 1, max = 3 },
		--[[ The entrance doubles as the primary extraction point. You leave the
		     way you came in; the separate ExtractionChamber is a secondary exit
		     that exists so a shift can never strand the party. ]]
		isExtraction = true,
		safeZone = true,
		lightLevel = 0.85,
		ceiling = 1.4, -- multiplier on Cave.RoomHeight
		weight = 0,
		props = { "entrance_arch", "supply_crate", "lantern_post" },
	},

	[K.CorridorStraight] = {
		id = K.CorridorStraight,
		name = "Tunnel",
		doorRule = { exact = 2, straight = true },
		lightLevel = 0.18,
		ceiling = 0.7,
		weight = 24,
		props = { "rubble", "support_beam" },
	},

	[K.CorridorCurve] = {
		id = K.CorridorCurve,
		name = "Bend",
		doorRule = { exact = 2, corner = true },
		lightLevel = 0.18,
		ceiling = 0.7,
		weight = 20,
		props = { "rubble", "mushroom_cluster" },
	},

	[K.Junction] = {
		id = K.Junction,
		name = "Junction",
		doorRule = { min = 3, max = 4 },
		lightLevel = 0.25,
		ceiling = 1,
		weight = 14,
		props = { "signpost", "support_beam", "lantern_post" },
	},

	[K.DeadEnd] = {
		id = K.DeadEnd,
		name = "Dead End",
		doorRule = { exact = 1 },
		lightLevel = 0.12,
		ceiling = 0.8,
		weight = 10,
		props = { "rubble", "bones", "mushroom_cluster" },
	},

	[K.MiningChamber] = {
		id = K.MiningChamber,
		name = "Mining Chamber",
		doorRule = { min = 1, max = 4 },
		lightLevel = 0.3,
		ceiling = 1.5,
		weight = 12,
		props = { "mine_cart", "support_beam", "lantern_post", "rubble" },
	},

	[K.ResourceChamber] = {
		id = K.ResourceChamber,
		name = "Fungal Hollow",
		doorRule = { min = 1, max = 4 },
		lightLevel = 0.4,
		ceiling = 1.6,
		weight = 12,
		props = { "mushroom_cluster", "mushroom_cluster", "glow_pool" },
	},

	[K.MonsterNest] = {
		id = K.MonsterNest,
		name = "Nest",
		doorRule = { min = 1, max = 3 },
		lightLevel = 0.08,
		ceiling = 1.3,
		weight = 8,
		props = { "bones", "bones", "egg_sac", "webbing" },
	},

	[K.PuzzleRoom] = {
		id = K.PuzzleRoom,
		name = "Sealed Antechamber",
		doorRule = { min = 1, max = 3 },
		lightLevel = 0.35,
		ceiling = 1.4,
		weight = 0, -- placed explicitly by the generator, never filled in randomly
		props = { "rune_pillar", "rune_pillar", "rune_pillar", "ancient_floor" },
	},

	[K.AncientVault] = {
		id = K.AncientVault,
		name = "Ancient Vault",
		doorRule = { min = 1, max = 2 },
		lightLevel = 0.45,
		ceiling = 1.9,
		weight = 0,
		--[[ Never rearranged by a maze shift; losing the objective room mid-run
		     would be unfair rather than tense. ]]
		shiftProtected = true,
		props = { "gate_frame", "ancient_floor", "rune_pillar", "relic_plinth" },
	},

	[K.ExtractionChamber] = {
		id = K.ExtractionChamber,
		name = "Collapse Shaft",
		doorRule = { min = 1, max = 2 },
		isExtraction = true,
		safeZone = true,
		lightLevel = 0.7,
		ceiling = 1.7,
		weight = 0,
		shiftProtected = true,
		props = { "rope_ladder", "lantern_post", "supply_crate" },
	},
}

--[[ Kinds the generator may use as filler, with their relative weights. ]]
RoomConfig.FillerOrder = {
	K.CorridorStraight,
	K.CorridorCurve,
	K.Junction,
	K.DeadEnd,
	K.MiningChamber,
	K.ResourceChamber,
	K.MonsterNest,
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Biomes
-- ─────────────────────────────────────────────────────────────────────────────

RoomConfig.Biomes = {
	[Enums.Biome.FungalHollow] = {
		id = Enums.Biome.FungalHollow,
		name = "Fungal Hollow",
		description = "Damp, warm and quietly alive. The shallowest reach of the caves.",
		rock = Color3.fromRGB(72, 68, 62),
		rockMaterial = Enum.Material.Slate,
		floor = Color3.fromRGB(62, 60, 54),
		floorMaterial = Enum.Material.Ground,
		ambientLight = Color3.fromRGB(44, 54, 46),
		fogColor = Color3.fromRGB(18, 24, 20),
		fogEnd = 260,
		glowColor = Color3.fromRGB(140, 210, 150),
		nodeBias = { fungal_cluster = 1.6, mushroom_patch = 1.5, stone_outcrop = 1.2 },
		difficultyFloor = Enums.Difficulty.Easy,
	},

	[Enums.Biome.IronDepths] = {
		id = Enums.Biome.IronDepths,
		name = "Iron Depths",
		description = "Rust in the air and a long way down. The rock here remembers tools.",
		rock = Color3.fromRGB(76, 62, 56),
		rockMaterial = Enum.Material.Rock,
		floor = Color3.fromRGB(58, 50, 46),
		floorMaterial = Enum.Material.Basalt,
		ambientLight = Color3.fromRGB(52, 42, 38),
		fogColor = Color3.fromRGB(24, 18, 16),
		fogEnd = 210,
		glowColor = Color3.fromRGB(230, 140, 90),
		nodeBias = { iron_seam = 1.8, coal_vein = 1.6, stone_outcrop = 1.3 },
		difficultyFloor = Enums.Difficulty.Medium,
	},

	[Enums.Biome.CrystalReach] = {
		id = Enums.Biome.CrystalReach,
		name = "Crystal Reach",
		description = "Everything hums. Nothing here grew by accident.",
		rock = Color3.fromRGB(62, 66, 84),
		rockMaterial = Enum.Material.Slate,
		floor = Color3.fromRGB(50, 54, 70),
		floorMaterial = Enum.Material.Pebble,
		ambientLight = Color3.fromRGB(42, 50, 72),
		fogColor = Color3.fromRGB(16, 20, 32),
		fogEnd = 180,
		glowColor = Color3.fromRGB(140, 190, 255),
		nodeBias = { crystal_formation = 2.2, iron_seam = 1.2 },
		difficultyFloor = Enums.Difficulty.Hard,
	},
}

--[[ Biomes an expedition may be generated in, by difficulty. ]]
RoomConfig.BiomesByDifficulty = {
	[Enums.Difficulty.Easy] = { Enums.Biome.FungalHollow },
	[Enums.Difficulty.Medium] = { Enums.Biome.FungalHollow, Enums.Biome.IronDepths },
	[Enums.Difficulty.Hard] = { Enums.Biome.IronDepths, Enums.Biome.CrystalReach },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Props (procedural geometry recipes consumed by server/World/RoomLibrary.lua)
-- ─────────────────────────────────────────────────────────────────────────────

RoomConfig.Props = {
	entrance_arch = { kind = "arch", size = Vector3.new(26, 20, 4), color = Color3.fromRGB(88, 82, 74) },
	supply_crate = { kind = "crate", size = Vector3.new(5, 4, 5), color = Color3.fromRGB(112, 88, 60) },
	lantern_post = { kind = "lantern", size = Vector3.new(1, 11, 1), light = Color3.fromRGB(255, 196, 128) },
	rubble = { kind = "scatter", count = 5, size = Vector3.new(3, 2, 3) },
	support_beam = { kind = "beam", size = Vector3.new(2, 1, 2), color = Color3.fromRGB(96, 76, 54) },
	mine_cart = { kind = "cart", size = Vector3.new(6, 5, 9), color = Color3.fromRGB(88, 82, 78) },
	mushroom_cluster = { kind = "mushrooms", count = 7, glow = true },
	glow_pool = { kind = "pool", size = Vector3.new(16, 1, 16), glow = Color3.fromRGB(120, 220, 190) },
	signpost = { kind = "sign", size = Vector3.new(4, 7, 1), color = Color3.fromRGB(104, 84, 60) },
	bones = {
		kind = "scatter",
		count = 6,
		size = Vector3.new(2.4, 0.6, 1),
		color = Color3.fromRGB(192, 186, 168),
	},
	egg_sac = { kind = "sac", size = Vector3.new(4, 5, 4), color = Color3.fromRGB(176, 168, 140) },
	webbing = { kind = "web", count = 4 },
	rune_pillar = { kind = "pillar", size = Vector3.new(4, 14, 4), glow = Color3.fromRGB(150, 180, 255) },
	ancient_floor = { kind = "tiles", size = Vector3.new(40, 1, 40), color = Color3.fromRGB(128, 118, 96) },
	gate_frame = { kind = "gate", size = Vector3.new(22, 26, 5), color = Color3.fromRGB(142, 128, 102) },
	relic_plinth = { kind = "plinth", size = Vector3.new(6, 5, 6), color = Color3.fromRGB(150, 138, 112) },
	rope_ladder = { kind = "ladder", size = Vector3.new(5, 30, 1), color = Color3.fromRGB(128, 104, 72) },
}

-- ─────────────────────────────────────────────────────────────────────────────
-- Merge generation rules from RoomRules (authoritative) into the visual defs.
-- Any value declared above is overwritten, so the two files can never drift.
-- ─────────────────────────────────────────────────────────────────────────────

for kind, room in pairs(RoomConfig.Rooms) do
	local rule = RoomRules.get(kind)
	if rule then
		room.doorRule = rule.doorRule
		room.weight = rule.weight
		room.shiftProtected = rule.shiftProtected == true
		room.isExtraction = rule.isExtraction == true
	else
		warn(("[RoomConfig] room kind %q has no entry in RoomRules"):format(tostring(kind)))
	end
end

RoomConfig.FillerOrder = RoomRules.FillerOrder

function RoomConfig.get(kind)
	return RoomConfig.Rooms[kind]
end

function RoomConfig.biome(id)
	return RoomConfig.Biomes[id] or RoomConfig.Biomes[Enums.Biome.FungalHollow]
end

return RoomConfig
