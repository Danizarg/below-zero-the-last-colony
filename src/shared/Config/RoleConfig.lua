--[[
	RoleConfig.lua

	Six specialisations. Runner, Medic and Guardian are implemented end to end
	for the MVP (`implemented = true`). Cook, Engineer and Researcher are fully
	specified here and have server ability handlers registered, but those
	handlers return Reject.NotImplemented so nothing silently pretends to work.

	Mastery: each role levels independently from expedition performance, and
	mastery tiers unlock passive upgrades listed in `upgrades`.
]]

local Enums = require(script.Parent.Parent.Enums)
local Role = Enums.Role

local RoleConfig = {}

--[[
	Stat fields, all multiplicative against the base character unless noted:
	  walkSpeed        absolute studs/sec
	  maxHealth        absolute
	  staminaMax       absolute
	  staminaRegen     multiplier on GameConfig.Survival.StaminaRegenPerSecond
	  harvestMult      multiplier on node yield-per-hit
	  damageMult       multiplier on outgoing melee damage
	  damageTakenMult  multiplier on incoming damage
	  reviveSpeedMult  multiplier on revive speed (higher = faster)
	  carryBonus       flat added expedition bag capacity
]]
RoleConfig.Roles = {
	[Role.Runner] = {
		id = Role.Runner,
		name = "Runner",
		implemented = true,
		tagline = "First in, first out.",
		description = "Scouts ahead, reads the tunnels and finds the way home when the maze turns.",
		accent = Color3.fromRGB(126, 206, 226),
		icon = "➤",

		stats = {
			walkSpeed = 19,
			maxHealth = 85,
			staminaMax = 135,
			staminaRegen = 1.35,
			harvestMult = 0.9,
			damageMult = 0.85,
			damageTakenMult = 1.1,
			reviveSpeedMult = 1,
			carryBonus = 0,
		},

		passives = {
			{
				id = "trap_sense",
				name = "Trap Sense",
				description = "Traps and hazards within 40 studs are outlined for you.",
			},
			{
				id = "cartographer",
				name = "Cartographer",
				description = "Rooms you enter are revealed to the whole party's objective tracker.",
			},
			{
				id = "sure_footed",
				name = "Sure-Footed",
				description = "Takes 40% less fall damage.",
				data = { fallDamageMult = 0.6 },
			},
		},

		ability = {
			id = "pathfinder",
			name = "Pathfinder",
			description = "Lights a route from where you stand to the nearest extraction point.",
			cooldown = 45,
			duration = 12,
			staminaCost = 20,
			radius = 0,
		},

		upgrades = {
			{ mastery = 3, id = "runner_speed_1", name = "Light Step", effect = { walkSpeed = 1 } },
			{ mastery = 6, id = "runner_cd_1", name = "Keen Eye", effect = { abilityCooldown = -8 } },
			{ mastery = 10, id = "runner_stam_1", name = "Second Wind", effect = { staminaMax = 20 } },
			{ mastery = 15, id = "runner_dur_1", name = "Long Sight", effect = { abilityDuration = 6 } },
			{ mastery = 20, id = "runner_speed_2", name = "Tunnel Born", effect = { walkSpeed = 2 } },
		},
	},

	[Role.Medic] = {
		id = Role.Medic,
		name = "Medic",
		implemented = true,
		tagline = "Nobody stays down.",
		description = "Keeps the party upright, turns glowroot into medicine and buys time for the fallen.",
		accent = Color3.fromRGB(132, 226, 186),
		icon = "✚",

		stats = {
			walkSpeed = 15,
			maxHealth = 100,
			staminaMax = 110,
			staminaRegen = 1.1,
			harvestMult = 1,
			damageMult = 0.8,
			damageTakenMult = 1,
			reviveSpeedMult = 2.2,
			carryBonus = 10,
		},

		passives = {
			{
				id = "field_medicine",
				name = "Field Medicine",
				description = "Salves heal 60% more in your hands.",
				data = { healingMult = 1.6 },
			},
			{
				id = "triage",
				name = "Triage",
				description = "Downed teammates within 30 studs lose their timer 30% slower.",
				data = { downedSlowRadius = 30, downedSlowMult = 0.7 },
			},
			{
				id = "steady_hands",
				name = "Steady Hands",
				description = "Reviving no longer costs stamina.",
			},
		},

		ability = {
			id = "field_stabilization",
			name = "Field Stabilization",
			description = "Freezes the revive timer of every downed ally nearby and heals those standing.",
			cooldown = 60,
			duration = 15,
			staminaCost = 25,
			radius = 32,
			healPerSecond = 3,
		},

		upgrades = {
			{ mastery = 3, id = "medic_rev_1", name = "Fast Hands", effect = { reviveSpeedMult = 0.3 } },
			{ mastery = 6, id = "medic_rad_1", name = "Wide Call", effect = { abilityRadius = 10 } },
			{ mastery = 10, id = "medic_hp_1", name = "Hardened", effect = { maxHealth = 15 } },
			{ mastery = 15, id = "medic_cd_1", name = "Prepared", effect = { abilityCooldown = -12 } },
			{ mastery = 20, id = "medic_heal_1", name = "Master Physician", effect = { healingMult = 0.4 } },
		},
	},

	[Role.Guardian] = {
		id = Role.Guardian,
		name = "Guardian",
		implemented = true,
		tagline = "Behind me.",
		description = "Holds the line in a corridor so everyone else can get past it.",
		accent = Color3.fromRGB(230, 164, 104),
		icon = "◈",

		stats = {
			walkSpeed = 13,
			maxHealth = 150,
			staminaMax = 120,
			staminaRegen = 1,
			harvestMult = 1,
			damageMult = 1.45,
			damageTakenMult = 0.75,
			reviveSpeedMult = 0.9,
			carryBonus = 20,
		},

		passives = {
			{
				id = "bulwark",
				name = "Bulwark",
				description = "Takes 25% less damage from all sources.",
				data = { damageTakenMult = 0.75 },
			},
			{
				id = "taunt_presence",
				name = "Presence",
				description = "Monsters within 25 studs prefer you over your teammates.",
				data = { aggroRadius = 25, aggroWeight = 2.5 },
			},
			{
				id = "heavy_swing",
				name = "Heavy Swing",
				description = "Melee hits stagger Cave Crawlers, interrupting their attack.",
				data = { staggerSeconds = 0.9 },
			},
		},

		ability = {
			id = "last_stand",
			name = "Last Stand",
			description = "You and nearby allies take sharply reduced damage for a short window.",
			cooldown = 70,
			duration = 10,
			staminaCost = 30,
			radius = 28,
			damageReduction = 0.55,
		},

		upgrades = {
			{ mastery = 3, id = "guard_hp_1", name = "Thick Hide", effect = { maxHealth = 20 } },
			{ mastery = 6, id = "guard_dmg_1", name = "Crushing Blow", effect = { damageMult = 0.15 } },
			{ mastery = 10, id = "guard_rad_1", name = "Rallying Cry", effect = { abilityRadius = 8 } },
			{ mastery = 15, id = "guard_cd_1", name = "Unyielding", effect = { abilityCooldown = -15 } },
			{ mastery = 20, id = "guard_dr_1", name = "Immovable", effect = { damageTakenMult = -0.1 } },
		},
	},

	-- ───────────────────────────────────────────────────────────────────────────
	-- Architected for later expansion. Selectable only when
	-- GameConfig.MvpContentOnly is false.
	-- ───────────────────────────────────────────────────────────────────────────

	[Role.Cook] = {
		id = Role.Cook,
		name = "Cook",
		implemented = false,
		tagline = "An army marches on its stomach.",
		description = "Stretches supplies further and keeps the party's stamina topped up.",
		accent = Color3.fromRGB(232, 200, 128),
		icon = "♨",

		stats = {
			walkSpeed = 15,
			maxHealth = 95,
			staminaMax = 125,
			staminaRegen = 1.2,
			harvestMult = 1.4, -- food nodes specifically, handled by RoleService
			damageMult = 0.8,
			damageTakenMult = 1,
			reviveSpeedMult = 1,
			carryBonus = 25,
		},

		passives = {
			{ id = "efficient_kitchen", name = "Efficient Kitchen", description = "Recipes cost 25% less." },
			{ id = "provisioner", name = "Provisioner", description = "Consumables weigh nothing for you." },
		},

		ability = {
			id = "emergency_rations",
			name = "Emergency Rations",
			description = "Restores hunger and stamina to every nearby teammate.",
			cooldown = 75,
			duration = 0,
			staminaCost = 0,
			radius = 30,
			hungerRestore = 40,
			staminaRestore = 50,
		},

		upgrades = {
			{ mastery = 5, id = "cook_carry_1", name = "Deep Pack", effect = { carryBonus = 15 } },
			{ mastery = 10, id = "cook_cd_1", name = "Always Cooking", effect = { abilityCooldown = -15 } },
		},
	},

	[Role.Engineer] = {
		id = Role.Engineer,
		name = "Engineer",
		implemented = false,
		tagline = "Give me ten seconds.",
		description = "Repairs gear, drops deployables and can improvise a way out.",
		accent = Color3.fromRGB(174, 180, 196),
		icon = "⚙",

		stats = {
			walkSpeed = 15,
			maxHealth = 105,
			staminaMax = 115,
			staminaRegen = 1.05,
			harvestMult = 1.15,
			damageMult = 0.95,
			damageTakenMult = 0.95,
			reviveSpeedMult = 1.1,
			carryBonus = 30,
		},

		passives = {
			{ id = "field_repair", name = "Field Repair", description = "Repair tools mid-expedition." },
			{
				id = "mechanist",
				name = "Mechanist",
				description = "Mechanical puzzles show their solution order.",
			},
		},

		ability = {
			id = "emergency_beacon",
			name = "Emergency Beacon",
			description = "Plants a temporary safe extraction point. Limited uses per expedition.",
			cooldown = 150,
			duration = 45,
			staminaCost = 40,
			radius = 18,
			--[[ Balancing note: an on-demand extraction point would defeat the
			     maze shift entirely, which is the game's defining mechanic. The
			     beacon is therefore capped per expedition, takes a long channel
			     and cannot be placed during Night. ]]
			maxUsesPerExpedition = 1,
			channelSeconds = 6,
			bannedPhases = { Enums.Phase.Night },
		},

		upgrades = {
			{ mastery = 5, id = "eng_dur_1", name = "Tool Sense", effect = { durabilityLossMult = -0.25 } },
			{ mastery = 10, id = "eng_beacon_1", name = "Spare Parts", effect = { abilityDuration = 20 } },
		},
	},

	[Role.Researcher] = {
		id = Role.Researcher,
		name = "Researcher",
		implemented = false,
		tagline = "Someone wrote this down. Once.",
		description = "Reads the ruins, finds the clues and turns relics into colony progress.",
		accent = Color3.fromRGB(196, 158, 236),
		icon = "✧",

		stats = {
			walkSpeed = 15,
			maxHealth = 90,
			staminaMax = 110,
			staminaRegen = 1.05,
			harvestMult = 1,
			damageMult = 0.75,
			damageTakenMult = 1.1,
			reviveSpeedMult = 1,
			carryBonus = 10,
		},

		passives = {
			{ id = "antiquarian", name = "Antiquarian", description = "Relic nodes yield double." },
			{ id = "scholar", name = "Scholar", description = "Research points earned +35%." },
		},

		ability = {
			id = "ancient_insight",
			name = "Ancient Insight",
			description = "Reveals the nearest hidden objective or clue.",
			cooldown = 90,
			duration = 20,
			staminaCost = 15,
			radius = 0,
		},

		upgrades = {
			{ mastery = 5, id = "res_relic_1", name = "Careful Hands", effect = { harvestMult = 0.2 } },
			{
				mastery = 10,
				id = "res_cd_1",
				name = "Pattern Recognition",
				effect = { abilityCooldown = -20 },
			},
		},
	},
}

RoleConfig.Order = { Role.Runner, Role.Medic, Role.Guardian, Role.Cook, Role.Engineer, Role.Researcher }

RoleConfig.Default = Role.Runner

function RoleConfig.get(id)
	return RoleConfig.Roles[id]
end

function RoleConfig.isValid(id)
	return RoleConfig.Roles[id] ~= nil
end

--[[ Roles a player may actually select right now. ]]
function RoleConfig.selectable(mvpOnly)
	local out = {}
	for _, id in ipairs(RoleConfig.Order) do
		local role = RoleConfig.Roles[id]
		if role and (not mvpOnly or role.implemented) then
			table.insert(out, id)
		end
	end
	return out
end

--[[
	Fold mastery upgrades into a flat stat table.
	@param roleId string
	@param mastery number  current mastery level for that role
	@return table stats, table ability
]]
function RoleConfig.resolve(roleId, mastery)
	local role = RoleConfig.get(roleId) or RoleConfig.get(RoleConfig.Default)
	mastery = math.max(0, math.floor(tonumber(mastery) or 0))

	--[[ Shallow copies, so mastery upgrades below mutate the result rather than
	     the config. Both tables are flat, so a shallow clone is the whole job. ]]
	local stats = table.clone(role.stats)
	local ability = table.clone(role.ability)

	local extras = { healingMult = 1, durabilityLossMult = 1 }
	for _, passive in ipairs(role.passives) do
		if passive.data then
			for key, value in pairs(passive.data) do
				extras[key] = value
			end
		end
	end

	local unlocked = {}
	for _, upgrade in ipairs(role.upgrades) do
		if mastery >= upgrade.mastery then
			table.insert(unlocked, upgrade.id)
			for key, delta in pairs(upgrade.effect) do
				if key == "abilityCooldown" then
					ability.cooldown = math.max(5, ability.cooldown + delta)
				elseif key == "abilityDuration" then
					ability.duration = ability.duration + delta
				elseif key == "abilityRadius" then
					ability.radius = ability.radius + delta
				elseif key == "healingMult" or key == "durabilityLossMult" then
					extras[key] = (extras[key] or 1) + delta
				elseif stats[key] ~= nil then
					stats[key] = stats[key] + delta
				else
					stats[key] = delta
				end
			end
		end
	end

	-- Clamp anything an upgrade chain could push somewhere silly.
	stats.walkSpeed = math.clamp(stats.walkSpeed, 8, 32)
	stats.maxHealth = math.clamp(stats.maxHealth, 40, 400)
	stats.damageTakenMult = math.clamp(stats.damageTakenMult, 0.35, 2)
	stats.staminaMax = math.clamp(stats.staminaMax, 50, 300)

	return stats, ability, extras, unlocked
end

return RoleConfig
