--[[
	JobConfig.lua
	NPC colonist jobs and what they produce per production tick.

	Production is simulated, not acted out. One tick multiplies a job's output by
	the colonist's skill, the colony's production multiplier and its condition.
	See NPCService.
]]

local Enums = require(script.Parent.Parent.Enums)
local J = Enums.Job
local R = Enums.Resource
local B = Enums.Building

local JobConfig = {}

--[[
	produces     { [resource] = perTick } at skill 1
	consumes     { [resource] = perTick } required, else the job idles
	requires     building that must exist to open this job (nil = none)
	skillGain    skill points earned per tick worked
	foodUse      food eaten per tick by a colonist doing this job
]]
JobConfig.Jobs = {
	[J.Farmer] = {
		id = J.Farmer,
		name = "Farmer",
		icon = "✿",
		description = "Grows mushrooms and glowroot.",
		requires = B.Farm,
		produces = { [R.Mushroom] = 2.0, [R.Herb] = 0.35 },
		consumes = {},
		skillGain = 0.05,
		foodUse = 1,
		accent = Color3.fromRGB(150, 196, 122),
	},
	[J.Cook] = {
		id = J.Cook,
		name = "Cook",
		icon = "♨",
		description = "Turns raw harvest into stored rations, wasting less of it.",
		requires = B.Farm,
		produces = {},
		consumes = { [R.Mushroom] = 1.0, [R.Coal] = 0.2 },
		--[[ Cooks do not produce a resource; they add food value, handled as a
		     colony-wide effect in NPCService. ]]
		foodValuePerTick = 4,
		skillGain = 0.05,
		foodUse = 1,
		accent = Color3.fromRGB(226, 182, 110),
	},
	[J.Miner] = {
		id = J.Miner,
		name = "Miner",
		icon = "⛏",
		description = "Works the seams around the colony for stone, coal and iron.",
		requires = B.Workshop,
		produces = { [R.Stone] = 2.5, [R.Coal] = 0.9, [R.Iron] = 0.45 },
		consumes = {},
		skillGain = 0.06,
		foodUse = 1.5,
		accent = Color3.fromRGB(176, 122, 96),
	},
	[J.Builder] = {
		id = J.Builder,
		name = "Builder",
		icon = "⚒",
		description = "Repairs structures and gathers fungal fiber for construction.",
		requires = B.Workshop,
		produces = { [R.Fiber] = 2.2 },
		consumes = {},
		--[[ Builders also restore building condition; see NPCService. ]]
		repairPerTick = 3,
		skillGain = 0.05,
		foodUse = 1.2,
		accent = Color3.fromRGB(198, 132, 78),
	},
	[J.Medic] = {
		id = J.Medic,
		name = "Medic",
		icon = "✚",
		description = "Keeps colonists healthy and stocks the infirmary.",
		requires = B.Infirmary,
		produces = { [R.Herb] = 0.6 },
		consumes = {},
		--[[ Reduces colony condition decay and heals injured colonists. ]]
		conditionRepairPerTick = 1.5,
		skillGain = 0.04,
		foodUse = 1,
		accent = Color3.fromRGB(126, 216, 196),
	},
	[J.Guard] = {
		id = J.Guard,
		name = "Guard",
		icon = "⚔",
		description = "Watches the tunnel mouths. Slows condition decay at night.",
		requires = B.TownHall,
		produces = {},
		consumes = {},
		conditionRepairPerTick = 0.8,
		skillGain = 0.03,
		foodUse = 1.3,
		accent = Color3.fromRGB(210, 120, 100),
	},
	[J.Researcher] = {
		id = J.Researcher,
		name = "Researcher",
		icon = "✧",
		description = "Studies relics for colony research points.",
		requires = B.ResearchLab,
		produces = {},
		consumes = { [R.Relic] = 0.05 },
		researchPerTick = 1.2,
		skillGain = 0.05,
		foodUse = 1,
		accent = Color3.fromRGB(150, 170, 246),
	},
	[J.Idle] = {
		id = J.Idle,
		name = "Unassigned",
		icon = "·",
		description = "Standing around. Assign them something.",
		requires = nil,
		produces = {},
		consumes = {},
		skillGain = 0,
		foodUse = 0.8,
		accent = Color3.fromRGB(140, 144, 154),
	},
}

JobConfig.Order = { J.Farmer, J.Miner, J.Builder, J.Cook, J.Medic, J.Guard, J.Researcher, J.Idle }

--[[ Skill 1..10. Efficiency curve is deliberately shallow so a fresh colonist
     is useful immediately and a veteran is worth about twice as much. ]]
JobConfig.MaxSkill = 10

function JobConfig.get(id)
	return JobConfig.Jobs[id] or JobConfig.Jobs[J.Idle]
end

function JobConfig.isValid(id)
	return JobConfig.Jobs[id] ~= nil
end

function JobConfig.efficiency(skill)
	skill = math.clamp(tonumber(skill) or 1, 1, JobConfig.MaxSkill)
	return 0.7 + (skill - 1) * 0.13
end

--[[ A few colonist names so the roster reads like people, not slot indices. ]]
JobConfig.NamePool = {
	"Ash",
	"Bram",
	"Cinder",
	"Dell",
	"Ember",
	"Fen",
	"Garrow",
	"Hollis",
	"Isa",
	"Juno",
	"Kerrin",
	"Lark",
	"Mossa",
	"Nael",
	"Oren",
	"Pell",
	"Quill",
	"Rook",
	"Sable",
	"Tamsin",
	"Urd",
	"Vesper",
	"Wren",
	"Yarrow",
}

return JobConfig
