--[[
	BuildingConfig.lua

	Buildings are placed on the plot's 8-stud build grid. `footprint` is measured
	in grid cells, so a {w=4,d=3} building occupies 32x24 studs.

	Effects are declarative. BuildingService sums them into a colony "effects"
	table; no system reads building ids directly.

	Effect keys:
	  population        housing capacity added
	  foodPerTick       food produced per NPC production tick
	  storageBonus      added colony storage capacity
	  craftStation      recipe station this building satisfies
	  healRate          colony passive healing per second while inside
	  researchPerTick   research points per tick
	  productionMult    multiplier on all NPC production
	  jobSlots          { [job] = count } work slots this building opens
]]

local Enums = require(script.Parent.Parent.Enums)
local B = Enums.Building
local R = Enums.Resource
local J = Enums.Job

local BuildingConfig = {}

BuildingConfig.Buildings = {
	[B.TownHall] = {
		id = B.TownHall,
		name = "Town Hall",
		implemented = true,
		description = "The heart of the colony. Sets your colony level and unlocks everything else.",
		icon = "⌂",
		footprint = { w = 5, d = 5 },
		height = 26,
		maxLevel = 4,
		unique = true, -- exactly one per colony
		--[[ Pre-placed free on a new colony so a fresh player always has a
		     functioning centre. Cost applies only to rebuilds. ]]
		grantedFree = true,
		palette = { primary = Color3.fromRGB(104, 86, 66), accent = Color3.fromRGB(196, 150, 86) },

		levels = {
			{
				cost = { [R.Stone] = 40, [R.Fiber] = 30 },
				maxHealth = 400,
				effects = { storageBonus = 400, population = 2, jobSlots = { [J.Guard] = 1 } },
				unlocks = { B.Housing, B.Farm },
			},
			{
				cost = { [R.Stone] = 120, [R.Fiber] = 80, [R.Iron] = 20 },
				maxHealth = 650,
				effects = { storageBonus = 900, population = 3, jobSlots = { [J.Guard] = 2 } },
				unlocks = { B.Workshop },
			},
			{
				cost = { [R.Stone] = 260, [R.Iron] = 70, [R.Coal] = 40 },
				maxHealth = 900,
				effects = {
					storageBonus = 1600,
					population = 4,
					productionMult = 1.1,
					jobSlots = { [J.Guard] = 3 },
				},
				unlocks = { B.Infirmary },
			},
			{
				cost = { [R.Stone] = 450, [R.Iron] = 150, [R.Crystal] = 25 },
				maxHealth = 1300,
				effects = {
					storageBonus = 2600,
					population = 5,
					productionMult = 1.25,
					jobSlots = { [J.Guard] = 4 },
				},
				unlocks = {},
			},
		},
	},

	[B.Housing] = {
		id = B.Housing,
		name = "Shelter",
		implemented = true,
		description = "Somewhere for colonists to sleep. More shelters, more colonists.",
		icon = "⌃",
		footprint = { w = 3, d = 3 },
		height = 14,
		maxLevel = 3,
		maxCount = 8,
		palette = { primary = Color3.fromRGB(96, 76, 58), accent = Color3.fromRGB(154, 122, 88) },

		levels = {
			{ cost = { [R.Stone] = 15, [R.Fiber] = 25 }, maxHealth = 160, effects = { population = 2 } },
			{
				cost = { [R.Stone] = 45, [R.Fiber] = 55, [R.Iron] = 8 },
				maxHealth = 260,
				effects = { population = 4 },
			},
			{
				cost = { [R.Stone] = 110, [R.Iron] = 25, [R.Coal] = 15 },
				maxHealth = 400,
				effects = { population = 6, productionMult = 1.03 },
			},
		},
	},

	[B.Farm] = {
		id = B.Farm,
		name = "Fungal Farm",
		implemented = true,
		description = "Rows of cultivated cave mushrooms. Feeds colonists and stocks expeditions.",
		icon = "✿",
		footprint = { w = 4, d = 4 },
		height = 10,
		maxLevel = 3,
		maxCount = 6,
		palette = { primary = Color3.fromRGB(78, 88, 66), accent = Color3.fromRGB(150, 196, 122) },

		levels = {
			{
				cost = { [R.Stone] = 20, [R.Fiber] = 35 },
				maxHealth = 180,
				effects = {
					foodPerTick = 3,
					craftStation = B.Farm,
					jobSlots = { [J.Farmer] = 2 },
				},
			},
			{
				cost = { [R.Stone] = 60, [R.Fiber] = 90, [R.Herb] = 10 },
				maxHealth = 280,
				effects = {
					foodPerTick = 7,
					craftStation = B.Farm,
					jobSlots = { [J.Farmer] = 4, [J.Cook] = 1 },
				},
			},
			{
				cost = { [R.Stone] = 140, [R.Fiber] = 180, [R.Crystal] = 10 },
				maxHealth = 420,
				effects = {
					foodPerTick = 13,
					craftStation = B.Farm,
					jobSlots = { [J.Farmer] = 6, [J.Cook] = 2 },
				},
			},
		},
	},

	[B.Workshop] = {
		id = B.Workshop,
		name = "Workshop",
		implemented = true,
		description = "Benches, a forge and somewhere to put a broken pick. Crafts tools.",
		icon = "⚒",
		footprint = { w = 4, d = 3 },
		height = 16,
		maxLevel = 3,
		maxCount = 3,
		requires = { [B.TownHall] = 2 },
		palette = { primary = Color3.fromRGB(88, 80, 76), accent = Color3.fromRGB(198, 132, 78) },

		levels = {
			{
				cost = { [R.Stone] = 50, [R.Fiber] = 30, [R.Iron] = 10 },
				maxHealth = 240,
				effects = {
					craftStation = B.Workshop,
					storageBonus = 150,
					jobSlots = { [J.Builder] = 2, [J.Miner] = 1 },
				},
			},
			{
				cost = { [R.Stone] = 130, [R.Iron] = 45, [R.Coal] = 30 },
				maxHealth = 380,
				effects = {
					craftStation = B.Workshop,
					storageBonus = 350,
					productionMult = 1.08,
					jobSlots = { [J.Builder] = 3, [J.Miner] = 3 },
				},
			},
			{
				cost = { [R.Stone] = 280, [R.Iron] = 110, [R.Crystal] = 18 },
				maxHealth = 560,
				effects = {
					craftStation = B.Workshop,
					storageBonus = 700,
					productionMult = 1.15,
					jobSlots = { [J.Builder] = 4, [J.Miner] = 5 },
				},
			},
		},
	},

	[B.Infirmary] = {
		id = B.Infirmary,
		name = "Infirmary",
		implemented = true,
		description = "Cots, boiled water and glowroot. Heals you between expeditions.",
		icon = "✚",
		footprint = { w = 4, d = 3 },
		height = 14,
		maxLevel = 3,
		maxCount = 2,
		requires = { [B.TownHall] = 3 },
		palette = { primary = Color3.fromRGB(80, 92, 92), accent = Color3.fromRGB(126, 216, 196) },

		levels = {
			{
				cost = { [R.Stone] = 60, [R.Fiber] = 40, [R.Herb] = 15 },
				maxHealth = 220,
				effects = {
					craftStation = B.Infirmary,
					healRate = 4,
					jobSlots = { [J.Medic] = 2 },
					--[[ Shortens the downed window penalty carried between runs. ]]
					reviveWindowBonus = 5,
				},
			},
			{
				cost = { [R.Stone] = 150, [R.Herb] = 40, [R.Iron] = 30 },
				maxHealth = 340,
				effects = {
					craftStation = B.Infirmary,
					healRate = 9,
					jobSlots = { [J.Medic] = 3 },
					reviveWindowBonus = 10,
				},
			},
			{
				cost = { [R.Stone] = 300, [R.Herb] = 90, [R.Crystal] = 15 },
				maxHealth = 500,
				effects = {
					craftStation = B.Infirmary,
					healRate = 16,
					jobSlots = { [J.Medic] = 5 },
					reviveWindowBonus = 15,
				},
			},
		},
	},

	-- ───────────────────────────────────────────────────────────────────────────
	-- Defined, not yet buildable. Blocked while GameConfig.MvpContentOnly.
	-- ───────────────────────────────────────────────────────────────────────────

	[B.Kitchen] = {
		id = B.Kitchen,
		name = "Kitchen",
		implemented = false,
		description = "Turns raw harvest into expedition rations with far less waste.",
		icon = "♨",
		footprint = { w = 3, d = 3 },
		height = 13,
		maxLevel = 3,
		maxCount = 2,
		requires = { [B.Farm] = 2 },
		palette = { primary = Color3.fromRGB(92, 82, 70), accent = Color3.fromRGB(226, 182, 110) },
		levels = {
			{
				cost = { [R.Stone] = 70, [R.Fiber] = 50, [R.Coal] = 20 },
				maxHealth = 230,
				effects = { craftStation = B.Kitchen, foodPerTick = 2, jobSlots = { [J.Cook] = 3 } },
			},
		},
	},

	[B.Barracks] = {
		id = B.Barracks,
		name = "Barracks",
		implemented = false,
		description = "Trains guards and stores expedition gear.",
		icon = "⚔",
		footprint = { w = 4, d = 4 },
		height = 16,
		maxLevel = 3,
		maxCount = 2,
		requires = { [B.TownHall] = 3 },
		palette = { primary = Color3.fromRGB(84, 78, 84), accent = Color3.fromRGB(210, 120, 100) },
		levels = {
			{
				cost = { [R.Stone] = 140, [R.Iron] = 50, [R.Fiber] = 60 },
				maxHealth = 420,
				effects = { jobSlots = { [J.Guard] = 4 }, storageBonus = 200 },
			},
		},
	},

	[B.ResearchLab] = {
		id = B.ResearchLab,
		name = "Research Laboratory",
		implemented = false,
		description = "Studies relics and crystals. Drives colony technology and the gate research.",
		icon = "✧",
		footprint = { w = 4, d = 4 },
		height = 18,
		maxLevel = 4,
		maxCount = 1,
		unique = true,
		requires = { [B.TownHall] = 3, [B.Workshop] = 2 },
		palette = { primary = Color3.fromRGB(74, 80, 102), accent = Color3.fromRGB(150, 170, 246) },
		levels = {
			{
				cost = { [R.Stone] = 200, [R.Iron] = 80, [R.Crystal] = 20, [R.Relic] = 5 },
				maxHealth = 400,
				effects = { researchPerTick = 2, jobSlots = { [J.Researcher] = 3 } },
			},
		},
	},

	[B.Watchtower] = {
		id = B.Watchtower,
		name = "Watchtower",
		implemented = false,
		description = "Sees further into the dark. Warns the colony earlier when the caves shift.",
		icon = "⌖",
		footprint = { w = 2, d = 2 },
		height = 40,
		maxLevel = 3,
		maxCount = 4,
		requires = { [B.TownHall] = 2 },
		palette = { primary = Color3.fromRGB(90, 84, 72), accent = Color3.fromRGB(226, 196, 120) },
		levels = {
			{
				cost = { [R.Stone] = 90, [R.Fiber] = 40, [R.Iron] = 15 },
				maxHealth = 260,
				effects = { jobSlots = { [J.Guard] = 2 }, shiftWarningBonus = 10 },
			},
		},
	},

	[B.Generator] = {
		id = B.Generator,
		name = "Crystal Generator",
		implemented = false,
		description = "Crystal-fed power. Lights the colony and drives the advanced workshops.",
		icon = "⚡",
		footprint = { w = 3, d = 3 },
		height = 20,
		maxLevel = 3,
		maxCount = 2,
		requires = { [B.ResearchLab] = 1 },
		palette = { primary = Color3.fromRGB(70, 76, 90), accent = Color3.fromRGB(128, 200, 255) },
		levels = {
			{
				cost = { [R.Stone] = 180, [R.Iron] = 90, [R.Crystal] = 40 },
				maxHealth = 380,
				effects = { productionMult = 1.2 },
			},
		},
	},
}

BuildingConfig.Order = {
	B.TownHall,
	B.Housing,
	B.Farm,
	B.Workshop,
	B.Infirmary,
	B.Kitchen,
	B.Barracks,
	B.ResearchLab,
	B.Watchtower,
	B.Generator,
}

function BuildingConfig.get(id)
	return BuildingConfig.Buildings[id]
end

function BuildingConfig.isValid(id)
	return BuildingConfig.Buildings[id] ~= nil
end

function BuildingConfig.levelData(id, level)
	local def = BuildingConfig.get(id)
	if not def then
		return nil
	end
	local index = math.clamp(math.floor(tonumber(level) or 1), 1, #def.levels)
	return def.levels[index], index
end

--[[ Cost to go from `level` to `level + 1`, or nil if already maxed. ]]
function BuildingConfig.upgradeCost(id, level)
	local def = BuildingConfig.get(id)
	if not def then
		return nil
	end
	local nextLevel = (tonumber(level) or 1) + 1
	if nextLevel > #def.levels then
		return nil
	end
	return def.levels[nextLevel].cost, nextLevel
end

--[[ Repair cost scales with missing condition: 30% of the current level's
     build cost at zero health, pro-rata. ]]
function BuildingConfig.repairCost(id, level, health)
	local data = BuildingConfig.levelData(id, level)
	if not data then
		return {}
	end
	local missing = math.clamp(1 - (health / data.maxHealth), 0, 1)
	if missing <= 0.01 then
		return {}
	end
	local cost = {}
	for resource, amount in pairs(data.cost) do
		local needed = math.ceil(amount * 0.3 * missing)
		if needed > 0 then
			cost[resource] = needed
		end
	end
	return cost
end

function BuildingConfig.buildable(mvpOnly)
	local out = {}
	for _, id in ipairs(BuildingConfig.Order) do
		local def = BuildingConfig.Buildings[id]
		if def and (not mvpOnly or def.implemented) then
			table.insert(out, id)
		end
	end
	return out
end

return BuildingConfig
