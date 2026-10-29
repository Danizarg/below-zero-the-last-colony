--[[
	ConfigIntegrity.spec.lua

	Most of this game is data, so most of what can quietly break is a dangling
	reference between two config files: a job that needs a building that no
	longer exists, a room that lists a prop with no builder, a recipe pointing at
	a deleted tool.

	None of that errors at require time; it just silently does nothing at
	runtime. These tests turn every such reference into a failing test instead.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local AudioConfig = require(Shared.Config.AudioConfig)
local BuildingConfig = require(Shared.Config.BuildingConfig)
local DifficultyConfig = require(Shared.Config.DifficultyConfig)
local Enums = require(Shared.Enums)
local GameConfig = require(Shared.Config.GameConfig)
local JobConfig = require(Shared.Config.JobConfig)
local MonsterConfig = require(Shared.Config.MonsterConfig)
local ProfileTemplate = require(Shared.Data.ProfileTemplate)
local ResourceConfig = require(Shared.Config.ResourceConfig)
local RoleConfig = require(Shared.Config.RoleConfig)
local RoomConfig = require(Shared.Config.RoomConfig)
local RoomRules = require(Shared.Lib.RoomRules)
local Routes = require(Shared.Routes)
local ShopConfig = require(Shared.Config.ShopConfig)

local function valueSet(enumTable)
	local set = {}
	for _, value in pairs(enumTable) do
		set[value] = true
	end
	return set
end

return function(suite)
	local resourceIds = valueSet(Enums.Resource)
	local buildingIds = valueSet(Enums.Building)
	local jobIds = valueSet(Enums.Job)
	local roomKinds = valueSet(Enums.RoomKind)
	local roleIds = valueSet(Enums.Role)

	-- ── Resources ────────────────────────────────────────────────────────────

	suite:test("every resource in the enum has a definition, and vice versa", function(expect)
		for id in pairs(resourceIds) do
			expect.truthy(ResourceConfig.Resources[id], ("resource %s has no definition"):format(id))
		end
		for id in pairs(ResourceConfig.Resources) do
			expect.truthy(resourceIds[id], ("resource %s is defined but not in Enums.Resource"):format(id))
		end
	end)

	suite:test("ResourceConfig.Order lists every resource exactly once", function(expect)
		local seen = {}
		for _, id in ipairs(ResourceConfig.Order) do
			expect.falsy(seen[id], ("%s appears twice in Order"):format(id))
			seen[id] = true
			expect.truthy(ResourceConfig.Resources[id], ("Order names unknown resource %s"):format(id))
		end
		for id in pairs(ResourceConfig.Resources) do
			expect.truthy(seen[id], ("%s is missing from Order, so the UI will never show it"):format(id))
		end
	end)

	suite:test("every resource has a sane stack limit, weight and rarity", function(expect)
		for id, def in pairs(ResourceConfig.Resources) do
			expect.greaterThan(def.stackLimit, 0, ("%s has a non-positive stack limit"):format(id))
			expect.atLeast(def.weight, 0, ("%s has a negative weight"):format(id))
			expect.truthy(
				ResourceConfig.RarityColor[def.rarity],
				("%s has rarity %q with no colour"):format(id, tostring(def.rarity))
			)
			expect.truthy(def.icon and def.icon ~= "", ("%s has no icon glyph"):format(id))
		end
	end)

	-- ── Harvest nodes ────────────────────────────────────────────────────────

	suite:test("every node yields a real resource and spawns in real rooms", function(expect)
		for id, node in pairs(ResourceConfig.Nodes) do
			expect.truthy(
				resourceIds[node.resource],
				("node %s yields unknown resource %s"):format(id, node.resource)
			)
			expect.greaterThan(node.hits, 0, ("node %s can never be depleted"):format(id))
			expect.greaterThan(node.yieldPerHit, 0, ("node %s yields nothing"):format(id))
			expect.atLeast(#node.rooms, 1, ("node %s can never spawn anywhere"):format(id))
			for _, kind in ipairs(node.rooms) do
				expect.truthy(roomKinds[kind], ("node %s lists unknown room kind %s"):format(id, kind))
			end
		end
	end)

	suite:test("every room kind that wants nodes has at least one it can host", function(expect)
		for kind, count in pairs(ResourceConfig.NodesPerRoom) do
			expect.truthy(roomKinds[kind], ("NodesPerRoom names unknown room kind %s"):format(kind))
			if count > 0 then
				local candidates = ResourceConfig.nodesForRoom(kind)
				expect.atLeast(
					#candidates,
					1,
					("room %s asks for %d nodes but no node lists it"):format(kind, count)
				)
			end
		end
	end)

	suite:test("a node's required tool tier is reachable with a craftable tool", function(expect)
		local bestTier = 0
		for _, tool in pairs(ResourceConfig.Tools) do
			bestTier = math.max(bestTier, tool.tier)
		end
		for id, node in pairs(ResourceConfig.Nodes) do
			expect.atMost(
				node.tier,
				bestTier,
				("node %s needs tier %d but the best tool is tier %d"):format(id, node.tier, bestTier)
			)
		end
	end)

	-- ── Tools and recipes ────────────────────────────────────────────────────

	suite:test("tool costs reference real resources", function(expect)
		for id, tool in pairs(ResourceConfig.Tools) do
			for resourceId in pairs(tool.cost or {}) do
				expect.truthy(
					resourceIds[resourceId],
					("tool %s costs unknown resource %s"):format(id, resourceId)
				)
			end
			expect.greaterThan(tool.swingCooldown, 0, ("tool %s has no swing cooldown"):format(id))
		end
	end)

	suite:test("bare hands are free, indestructible and always available", function(expect)
		--[[ The fallback tool is what stops a broken pick from ending a run. ]]
		local hands = ResourceConfig.Tools.bare_hands
		expect.truthy(hands, "bare_hands must exist as the fallback tool")
		expect.equal(hands.maxDurability, 0, "bare hands must never break")
		expect.equal(next(hands.cost), nil, "bare hands must cost nothing")
		expect.equal(hands.tier, 0)
	end)

	suite:test("every recipe is reachable and grants something real", function(expect)
		local seen = {}
		for _, recipe in ipairs(ResourceConfig.Recipes) do
			expect.falsy(seen[recipe.id], ("duplicate recipe id %s"):format(recipe.id))
			seen[recipe.id] = true

			if recipe.station then
				expect.truthy(
					buildingIds[recipe.station],
					("recipe %s needs unknown station %s"):format(recipe.id, recipe.station)
				)
				local def = BuildingConfig.get(recipe.station)
				expect.atMost(
					recipe.stationLevel or 1,
					#def.levels,
					("recipe %s needs %s level %d but it only goes to %d"):format(
						recipe.id,
						recipe.station,
						recipe.stationLevel or 1,
						#def.levels
					)
				)
			end

			for resourceId in pairs(recipe.cost or {}) do
				expect.truthy(
					resourceIds[resourceId],
					("recipe %s costs unknown resource %s"):format(recipe.id, resourceId)
				)
			end

			local grantsSomething = recipe.grantsTool ~= nil or recipe.grantsConsumable ~= nil
			expect.truthy(grantsSomething, ("recipe %s grants nothing"):format(recipe.id))

			if recipe.grantsTool then
				expect.truthy(
					ResourceConfig.Tools[recipe.grantsTool],
					("recipe %s grants unknown tool %s"):format(recipe.id, recipe.grantsTool)
				)
			end
			if recipe.grantsConsumable then
				expect.truthy(
					ResourceConfig.Consumables[recipe.grantsConsumable.id],
					("recipe %s grants unknown consumable %s"):format(recipe.id, recipe.grantsConsumable.id)
				)
			end
		end
	end)

	suite:test("every consumable does something", function(expect)
		for id, def in pairs(ResourceConfig.Consumables) do
			local total = (def.hunger or 0) + (def.stamina or 0) + (def.health or 0)
			expect.greaterThan(total, 0, ("consumable %s has no effect"):format(id))
			expect.greaterThan(def.stackLimit, 0, ("consumable %s cannot be stacked"):format(id))
		end
	end)

	-- ── Buildings ────────────────────────────────────────────────────────────

	suite:test("every building in the enum has a definition, and vice versa", function(expect)
		for id in pairs(buildingIds) do
			expect.truthy(BuildingConfig.Buildings[id], ("building %s has no definition"):format(id))
		end
		for id in pairs(BuildingConfig.Buildings) do
			expect.truthy(buildingIds[id], ("building %s is not in Enums.Building"):format(id))
		end
	end)

	suite:test("BuildingConfig.Order lists every building exactly once", function(expect)
		local seen = {}
		for _, id in ipairs(BuildingConfig.Order) do
			expect.falsy(seen[id], ("%s appears twice in Order"):format(id))
			seen[id] = true
		end
		for id in pairs(BuildingConfig.Buildings) do
			expect.truthy(seen[id], ("%s is missing from Order"):format(id))
		end
	end)

	suite:test("building prerequisites reference real buildings at real levels", function(expect)
		for id, def in pairs(BuildingConfig.Buildings) do
			for requiredId, requiredLevel in pairs(def.requires or {}) do
				expect.truthy(
					buildingIds[requiredId],
					("%s requires unknown building %s"):format(id, requiredId)
				)
				local requiredDef = BuildingConfig.get(requiredId)
				expect.atMost(
					requiredLevel,
					#requiredDef.levels,
					("%s needs %s level %d but it only reaches %d"):format(
						id,
						requiredId,
						requiredLevel,
						#requiredDef.levels
					)
				)
			end
		end
	end)

	suite:test("no building requires itself, directly or in a short cycle", function(expect)
		--[[ A cycle would make a building permanently unbuildable, which is the
		     kind of thing nobody notices until a player reports it. ]]
		local function requires(id, targetId, depth)
			if depth > 8 then
				return false
			end
			local def = BuildingConfig.get(id)
			for requiredId in pairs(def and def.requires or {}) do
				if requiredId == targetId then
					return true
				end
				if requires(requiredId, targetId, depth + 1) then
					return true
				end
			end
			return false
		end

		for id in pairs(BuildingConfig.Buildings) do
			expect.falsy(requires(id, id, 0), ("%s is in a prerequisite cycle"):format(id))
		end
	end)

	suite:test("every building level has a cost, health and effects", function(expect)
		for id, def in pairs(BuildingConfig.Buildings) do
			expect.atLeast(#def.levels, 1, ("%s has no levels"):format(id))
			for level, data in ipairs(def.levels) do
				expect.greaterThan(data.maxHealth, 0, ("%s level %d has no health"):format(id, level))
				expect.truthy(data.effects, ("%s level %d has no effects table"):format(id, level))
				for resourceId in pairs(data.cost or {}) do
					expect.truthy(
						resourceIds[resourceId],
						("%s level %d costs unknown resource %s"):format(id, level, resourceId)
					)
				end
			end
			expect.greaterThan(def.footprint.w, 0, ("%s has no width"):format(id))
			expect.greaterThan(def.footprint.d, 0, ("%s has no depth"):format(id))
		end
	end)

	suite:test("building job slots reference real jobs", function(expect)
		for id, def in pairs(BuildingConfig.Buildings) do
			for level, data in ipairs(def.levels) do
				for jobId in pairs((data.effects or {}).jobSlots or {}) do
					expect.truthy(
						jobIds[jobId],
						("%s level %d opens unknown job %s"):format(id, level, jobId)
					)
				end
			end
		end
	end)

	suite:test("a building's footprint fits inside a plot", function(expect)
		local PlotGrid = require(Shared.Lib.PlotGrid)
		local limit = PlotGrid.gridHalfExtent() * 2
		for id, def in pairs(BuildingConfig.Buildings) do
			expect.atMost(
				math.max(def.footprint.w, def.footprint.d),
				limit,
				("%s is larger than the whole build area"):format(id)
			)
		end
	end)

	suite:test("upgrade costs rise with level", function(expect)
		--[[ A later level that costs less than an earlier one would make
		     upgrading strictly better than building, which is not the intent. ]]
		local function total(cost)
			local sum = 0
			for _, amount in pairs(cost or {}) do
				sum += amount
			end
			return sum
		end

		for id, def in pairs(BuildingConfig.Buildings) do
			for level = 2, #def.levels do
				expect.greaterThan(
					total(def.levels[level].cost),
					total(def.levels[level - 1].cost),
					("%s level %d does not cost more than level %d"):format(id, level, level - 1)
				)
			end
		end
	end)

	-- ── Jobs ─────────────────────────────────────────────────────────────────

	suite:test("every job has a definition and a workplace that exists", function(expect)
		for id in pairs(jobIds) do
			expect.truthy(JobConfig.Jobs[id], ("job %s has no definition"):format(id))
		end
		for id, job in pairs(JobConfig.Jobs) do
			expect.truthy(jobIds[id], ("job %s is not in Enums.Job"):format(id))
			if job.requires then
				expect.truthy(
					buildingIds[job.requires],
					("job %s needs unknown building %s"):format(id, job.requires)
				)
			end
			for resourceId in pairs(job.produces or {}) do
				expect.truthy(resourceIds[resourceId], ("job %s produces unknown %s"):format(id, resourceId))
			end
			for resourceId in pairs(job.consumes or {}) do
				expect.truthy(resourceIds[resourceId], ("job %s consumes unknown %s"):format(id, resourceId))
			end
		end
	end)

	suite:test("every non-idle job is openable by some building", function(expect)
		--[[ A job no building ever opens can never be assigned, which would make
		     it dead config rather than content. ]]
		local openable = {}
		for _, def in pairs(BuildingConfig.Buildings) do
			for _, data in ipairs(def.levels) do
				for jobId in pairs((data.effects or {}).jobSlots or {}) do
					openable[jobId] = true
				end
			end
		end
		for id in pairs(JobConfig.Jobs) do
			if id ~= Enums.Job.Idle then
				expect.truthy(openable[id], ("no building ever opens a %s position"):format(id))
			end
		end
	end)

	suite:test("job efficiency rises with skill and stays positive", function(expect)
		local previous = 0
		for skill = 1, JobConfig.MaxSkill do
			local efficiency = JobConfig.efficiency(skill)
			expect.greaterThan(efficiency, previous, ("efficiency did not rise at skill %d"):format(skill))
			previous = efficiency
		end
		expect.greaterThan(JobConfig.efficiency(1), 0, "a fresh colonist must be worth something")
	end)

	-- ── Rooms ────────────────────────────────────────────────────────────────

	suite:test("RoomConfig and RoomRules cover exactly the same kinds", function(expect)
		for kind in pairs(roomKinds) do
			expect.truthy(RoomConfig.Rooms[kind], ("room kind %s has no visual config"):format(kind))
			expect.truthy(RoomRules.Rules[kind], ("room kind %s has no generation rule"):format(kind))
		end
		for kind in pairs(RoomConfig.Rooms) do
			expect.truthy(roomKinds[kind], ("RoomConfig has unknown kind %s"):format(kind))
		end
		for kind in pairs(RoomRules.Rules) do
			expect.truthy(roomKinds[kind], ("RoomRules has unknown kind %s"):format(kind))
		end
	end)

	suite:test("every room's props have a definition and a builder", function(expect)
		local RoomLibrary = nil
		--[[ RoomLibrary is server-only, so the builder table is checked through
		     the prop's `kind` against the known set instead of requiring it. ]]
		local knownKinds = {
			arch = true,
			cart = true,
			crate = true,
			lantern = true,
			scatter = true,
			beam = true,
			mushrooms = true,
			pool = true,
			sign = true,
			sac = true,
			web = true,
			pillar = true,
			tiles = true,
			gate = true,
			plinth = true,
			ladder = true,
		}

		for kind, room in pairs(RoomConfig.Rooms) do
			for _, propId in ipairs(room.props or {}) do
				local spec = RoomConfig.Props[propId]
				expect.truthy(spec, ("room %s lists unknown prop %s"):format(kind, propId))
				if spec then
					expect.truthy(
						knownKinds[spec.kind],
						("prop %s has kind %q with no builder"):format(propId, tostring(spec.kind))
					)
				end
			end
		end
		_ = RoomLibrary
	end)

	suite:test("door rules are satisfiable", function(expect)
		--[[ A rule that no door signature can satisfy would make the kind
		     unusable, and the generator would fall back silently. ]]
		for kind in pairs(RoomRules.Rules) do
			local satisfiable = false
			for mask = 1, 15 do
				local doors = {
					N = bit32.band(mask, 1) ~= 0,
					E = bit32.band(mask, 2) ~= 0,
					S = bit32.band(mask, 4) ~= 0,
					W = bit32.band(mask, 8) ~= 0,
				}
				if RoomRules.doorsSatisfy(kind, doors) then
					satisfiable = true
					break
				end
			end
			expect.truthy(satisfiable, ("no door layout satisfies %s"):format(kind))
		end
	end)

	suite:test("every door signature has at least one filler kind that fits", function(expect)
		--[[ This is what stops the generator from reaching its "should be
		     unreachable" fallback branch. ]]
		for mask = 1, 15 do
			local doors = {
				N = bit32.band(mask, 1) ~= 0,
				E = bit32.band(mask, 2) ~= 0,
				S = bit32.band(mask, 4) ~= 0,
				W = bit32.band(mask, 8) ~= 0,
			}
			local kinds = RoomRules.kindsFor(doors)
			expect.atLeast(#kinds, 1, ("no filler kind fits door mask %d"):format(mask))
		end
	end)

	suite:test("at least one extraction kind and one shift-protected kind exist", function(expect)
		local extraction, protected = 0, 0
		for kind in pairs(RoomRules.Rules) do
			if RoomRules.isExtraction(kind) then
				extraction += 1
			end
			if RoomRules.isShiftProtected(kind) then
				protected += 1
			end
		end
		expect.atLeast(extraction, 1, "no room kind is an exit")
		expect.atLeast(protected, 1, "no room kind is protected from a shift")
	end)

	suite:test("every biome has a palette and every difficulty has biomes", function(expect)
		for id, biome in pairs(RoomConfig.Biomes) do
			expect.truthy(biome.rock, ("biome %s has no rock colour"):format(id))
			expect.greaterThan(biome.fogEnd, 0, ("biome %s has no fog distance"):format(id))
			for nodeId in pairs(biome.nodeBias or {}) do
				expect.truthy(
					ResourceConfig.Nodes[nodeId],
					("biome %s biases unknown node %s"):format(id, nodeId)
				)
			end
		end
		for _, difficultyId in ipairs(DifficultyConfig.Order) do
			local pool = RoomConfig.BiomesByDifficulty[difficultyId]
			expect.atLeast(#(pool or {}), 1, ("%s has no biomes"):format(difficultyId))
			for _, biomeId in ipairs(pool) do
				expect.truthy(
					RoomConfig.Biomes[biomeId],
					("%s lists unknown biome %s"):format(difficultyId, biomeId)
				)
			end
		end
	end)

	-- ── Roles ────────────────────────────────────────────────────────────────

	suite:test("every role has stats, an ability and an upgrade ladder", function(expect)
		for id in pairs(roleIds) do
			expect.truthy(RoleConfig.Roles[id], ("role %s has no definition"):format(id))
		end
		for id, role in pairs(RoleConfig.Roles) do
			expect.truthy(roleIds[id], ("role %s is not in Enums.Role"):format(id))
			expect.truthy(role.ability and role.ability.id, ("role %s has no ability"):format(id))
			expect.greaterThan(role.ability.cooldown, 0, ("role %s has a zero cooldown"):format(id))
			expect.greaterThan(role.stats.walkSpeed, 0, ("role %s cannot move"):format(id))
			expect.greaterThan(role.stats.maxHealth, 0, ("role %s has no health"):format(id))

			local previous = 0
			for _, upgrade in ipairs(role.upgrades) do
				expect.greaterThan(
					upgrade.mastery,
					previous,
					("role %s upgrades are not in mastery order"):format(id)
				)
				previous = upgrade.mastery
				expect.atMost(
					upgrade.mastery,
					GameConfig.Rewards.MaxRoleMastery,
					("role %s has an upgrade above the mastery cap"):format(id)
				)
			end
		end
	end)

	suite:test("ability ids are unique across roles", function(expect)
		--[[ RoleService dispatches on ability id, so two roles sharing one would
		     silently run the wrong effect. ]]
		local seen = {}
		for id, role in pairs(RoleConfig.Roles) do
			local abilityId = role.ability.id
			expect.falsy(
				seen[abilityId],
				("ability %s is used by both %s and %s"):format(abilityId, tostring(seen[abilityId]), id)
			)
			seen[abilityId] = id
		end
	end)

	suite:test("the three MVP roles are marked implemented and the rest are not", function(expect)
		local implemented = RoleConfig.selectable(true)
		table.sort(implemented)
		expect.equal(#implemented, 3, "the MVP promises exactly three playable roles")
		expect.contains(implemented, Enums.Role.Runner)
		expect.contains(implemented, Enums.Role.Medic)
		expect.contains(implemented, Enums.Role.Guardian)
	end)

	suite:test("resolve folds mastery upgrades into stats", function(expect)
		local baseStats = RoleConfig.resolve(Enums.Role.Runner, 0)
		local masteredStats = RoleConfig.resolve(Enums.Role.Runner, GameConfig.Rewards.MaxRoleMastery)
		expect.greaterThan(
			masteredStats.walkSpeed,
			baseStats.walkSpeed,
			"a fully mastered Runner should be faster"
		)
	end)

	suite:test("resolve clamps stats even at maximum mastery", function(expect)
		for id in pairs(RoleConfig.Roles) do
			local stats = RoleConfig.resolve(id, 999)
			expect.inRange(stats.walkSpeed, 8, 32, ("%s walk speed escaped its clamp"):format(id))
			expect.inRange(stats.maxHealth, 40, 400, ("%s health escaped its clamp"):format(id))
			expect.inRange(stats.damageTakenMult, 0.35, 2, ("%s mitigation escaped its clamp"):format(id))
		end
	end)

	-- ── Monsters ─────────────────────────────────────────────────────────────

	suite:test("every monster has coherent senses, combat and spawn rules", function(expect)
		for id, def in pairs(MonsterConfig.Monsters) do
			expect.greaterThan(def.maxHealth, 0, ("%s has no health"):format(id))
			expect.greaterThan(def.damage, 0, ("%s deals no damage"):format(id))
			expect.greaterThan(def.attackWindup, 0, ("%s attacks with no telegraph"):format(id))
			expect.greaterThan(def.chaseSpeed, 0, ("%s cannot chase"):format(id))
			expect.atLeast(
				def.loseTargetRange,
				def.sightRange,
				("%s forgets targets closer than it can see them"):format(id)
			)
			for _, kind in ipairs(def.spawnRooms or {}) do
				expect.truthy(roomKinds[kind], ("%s spawns in unknown room %s"):format(id, kind))
			end
			for _, drop in ipairs(def.drops or {}) do
				expect.truthy(
					resourceIds[drop.resource],
					("%s drops unknown resource %s"):format(id, drop.resource)
				)
				expect.inRange(drop.chance or 1, 0, 1, ("%s has an impossible drop chance"):format(id))
			end
		end
	end)

	suite:test("the Cave Crawler is a fight and the Stalker is not", function(expect)
		--[[ The brief asks that different enemies need different strategies
		     rather than different amounts of health. This encodes that. ]]
		local crawler = MonsterConfig.get(Enums.Monster.CaveCrawler)
		local stalker = MonsterConfig.get(Enums.Monster.Stalker)

		expect.truthy(crawler.killable, "the Crawler should be killable")
		expect.falsy(stalker.killable, "the Stalker should not be a damage race")
		expect.greaterThan(
			stalker.hearingRange,
			crawler.hearingRange * 2,
			"the Stalker should hunt by sound far better than the Crawler"
		)
		expect.lessThan(
			stalker.sightRange,
			crawler.sightRange,
			"the Stalker should be the blinder of the two"
		)
		expect.truthy(stalker.crowdAversionCount, "the Stalker needs counterplay")
		expect.truthy(stalker.lightAversionThreshold, "the Stalker needs a light-based escape")
	end)

	suite:test("extraction rooms are lit above the Stalker's aversion threshold", function(expect)
		--[[ This is what makes the exits safe ground. If an extraction room were
		     dim, the Stalker could camp it. ]]
		local threshold = MonsterConfig.get(Enums.Monster.Stalker).lightAversionThreshold
		for kind, room in pairs(RoomConfig.Rooms) do
			if RoomRules.isExtraction(kind) then
				expect.atLeast(
					room.lightLevel,
					threshold,
					("%s is lit at %.2f, below the Stalker's %.2f aversion"):format(
						kind,
						room.lightLevel,
						threshold
					)
				)
			end
		end
	end)

	suite:test("monster spawn budgets name real room kinds", function(expect)
		for kind in pairs(MonsterConfig.BaseCountPerRoom) do
			expect.truthy(roomKinds[kind], ("monster budget names unknown room %s"):format(kind))
		end
		expect.equal(
			MonsterConfig.BaseCountPerRoom[Enums.RoomKind.Entrance],
			0,
			"the tunnel mouth must be safe to arrive in"
		)
		expect.equal(
			MonsterConfig.BaseCountPerRoom[Enums.RoomKind.ExtractionChamber],
			0,
			"an exit must be safe to reach"
		)
	end)

	-- ── Difficulty ───────────────────────────────────────────────────────────

	suite:test("Medium matches the brief's stated clock", function(expect)
		--[[ 3 minutes prep, 10 day, 3 dusk, 6 night. Pinned because it is a
		     stated design target, not an incidental number. ]]
		local medium = DifficultyConfig.get(Enums.Difficulty.Medium)
		expect.equal(medium.phaseDurations.prep, 180)
		expect.equal(medium.phaseDurations.day, 600)
		expect.equal(medium.phaseDurations.dusk, 180)
		expect.equal(medium.phaseDurations.night, 360)
	end)

	suite:test("resolve sums the clock correctly and keeps at least one key", function(expect)
		for _, difficultyId in ipairs(DifficultyConfig.Order) do
			for partySize = 1, 8 do
				local resolved = DifficultyConfig.resolve(difficultyId, partySize)
				local sum = resolved.phaseDurations.prep
					+ resolved.phaseDurations.day
					+ resolved.phaseDurations.dusk
					+ resolved.phaseDurations.night
				expect.equal(resolved.totalSeconds, sum, ("%s clock does not add up"):format(difficultyId))
				expect.atLeast(
					resolved.keysRequired,
					1,
					("%s at party size %d needs no keys"):format(difficultyId, partySize)
				)
			end
		end
	end)

	suite:test("solo faces fewer monsters, not weaker ones", function(expect)
		--[[ The brief asks solo to scale enemy pressure. Dropping count keeps a
		     fight reading the same; gutting health would make it a different
		     game. ]]
		local solo = DifficultyConfig.resolve(Enums.Difficulty.Medium, 1)
		local full = DifficultyConfig.resolve(Enums.Difficulty.Medium, 4)

		expect.lessThan(solo.monsterCountMultiplier, full.monsterCountMultiplier * 0.7)
		expect.atLeast(solo.monsterHealthMultiplier, full.monsterHealthMultiplier * 0.85)
	end)

	suite:test("difficulty rises monotonically where it should", function(expect)
		local easy = DifficultyConfig.get(Enums.Difficulty.Easy)
		local medium = DifficultyConfig.get(Enums.Difficulty.Medium)
		local hard = DifficultyConfig.get(Enums.Difficulty.Hard)

		expect.lessThan(easy.monsterDamageMultiplier, medium.monsterDamageMultiplier)
		expect.lessThan(medium.monsterDamageMultiplier, hard.monsterDamageMultiplier)

		expect.greaterThan(easy.downedSeconds, medium.downedSeconds)
		expect.greaterThan(medium.downedSeconds, hard.downedSeconds)

		expect.lessThan(easy.rewardMultiplier, medium.rewardMultiplier)
		expect.lessThan(medium.rewardMultiplier, hard.rewardMultiplier)

		expect.greaterThan(easy.lootKeptOnDeathFraction, hard.lootKeptOnDeathFraction)
		expect.atMost(easy.roomCount, hard.roomCount)
	end)

	suite:test("an unknown difficulty falls back rather than erroring", function(expect)
		local resolved = DifficultyConfig.resolve("nonsense", 3)
		expect.equal(resolved.id, DifficultyConfig.Default)
		expect.falsy(DifficultyConfig.isValid("nonsense"))
	end)

	-- ── Routes ───────────────────────────────────────────────────────────────

	suite:test("no route name is duplicated within its table", function(expect)
		for tableName, routes in pairs({ Request = Routes.Request, Event = Routes.Event, Push = Routes.Push }) do
			local seen = {}
			for key, value in pairs(routes) do
				expect.isType(value, "string", ("Routes.%s.%s is not a string"):format(tableName, key))
				expect.falsy(
					seen[value],
					("Routes.%s has %q twice (%s and %s)"):format(
						tableName,
						value,
						tostring(seen[value]),
						key
					)
				)
				seen[value] = key
			end
		end
	end)

	suite:test("request and event routes do not collide", function(expect)
		--[[ Both are client to server. A shared name would still work, because
		     they use different remotes, but it would be a trap for the next
		     person reading the code. ]]
		local requests = {}
		for _, value in pairs(Routes.Request) do
			requests[value] = true
		end
		for key, value in pairs(Routes.Event) do
			expect.falsy(requests[value], ("event %s reuses request route %q"):format(key, value))
		end
	end)

	suite:test("every rate limit names a real route", function(expect)
		local known = {}
		for _, value in pairs(Routes.Request) do
			known[value] = true
		end
		for _, value in pairs(Routes.Event) do
			known[value] = true
		end
		for route, limits in pairs(Routes.Limits) do
			expect.truthy(known[route], ("a rate limit is set for unknown route %q"):format(route))
			expect.greaterThan(limits.burst, 0, ("route %q has a zero burst"):format(route))
			expect.greaterThan(limits.window, 0, ("route %q has a zero window"):format(route))
		end
	end)

	suite:test("the hot gameplay routes all have explicit limits", function(expect)
		--[[ These are the routes a scripted client would hammer. Relying on the
		     default budget for them would be an oversight rather than a choice. ]]
		for _, route in ipairs({
			Routes.Request.HarvestNode,
			Routes.Request.Attack,
			Routes.Request.UseAbility,
			Routes.Request.Revive,
			Routes.Request.Interact,
			Routes.Request.StartExpedition,
			Routes.Request.PlaceBuilding,
		}) do
			expect.truthy(Routes.limitsFor(route), ("route %q has no explicit rate limit"):format(route))
		end
	end)

	-- ── Shop ─────────────────────────────────────────────────────────────────

	suite:test("no product declares a disallowed gameplay effect", function(expect)
		for id, product in pairs(ShopConfig.Products) do
			if product.gameplayEffect then
				expect.truthy(
					ShopConfig.AllowedGameplayEffects[product.gameplayEffect],
					("product %s declares disallowed effect %q"):format(id, product.gameplayEffect)
				)
			end
		end
	end)

	suite:test("exactly one product affects gameplay, and it is the rescue", function(expect)
		local effectful = {}
		for id, product in pairs(ShopConfig.Products) do
			if product.gameplayEffect then
				table.insert(effectful, id)
			end
		end
		expect.equal(#effectful, 1, "the shop should have exactly one non-cosmetic product")
		expect.equal(effectful[1], "emergency_rescue")
		expect.truthy(ShopConfig.Products.emergency_rescue.maxPerExpedition, "the rescue must be capped")
		expect.truthy(
			ShopConfig.Products.emergency_rescue.bannedInRanked,
			"the rescue must be ranked-excluded"
		)
	end)

	suite:test("no product is live, so nothing can be purchased yet", function(expect)
		--[[ This test is meant to fail the day real product ids are pasted in,
		     as a prompt to verify the purchase flow before shipping it. ]]
		for id, product in pairs(ShopConfig.Products) do
			expect.equal(
				tonumber(product.productId) or 0,
				0,
				("product %s has a real id; verify the purchase flow, then update this test"):format(id)
			)
		end
		expect.falsy(
			GameConfig.Monetization.Enabled,
			"monetization should stay off until the flow is verified"
		)
	end)

	suite:test("every product is listed in Order and has a real category", function(expect)
		local categories = {}
		for _, category in ipairs(ShopConfig.CategoryOrder) do
			categories[category] = true
			expect.truthy(ShopConfig.CategoryMeta[category], ("category %s has no metadata"):format(category))
		end

		local seen = {}
		for _, id in ipairs(ShopConfig.Order) do
			expect.truthy(ShopConfig.Products[id], ("Order names unknown product %s"):format(id))
			expect.falsy(seen[id], ("%s appears twice in Order"):format(id))
			seen[id] = true
		end
		for id, product in pairs(ShopConfig.Products) do
			expect.truthy(seen[id], ("product %s is missing from Order"):format(id))
			expect.truthy(
				categories[product.category],
				("product %s has unknown category %s"):format(id, tostring(product.category))
			)
		end
	end)

	suite:test("a free rescue is always available", function(expect)
		expect.atLeast(
			GameConfig.Monetization.FreeRescuesPerExpedition,
			1,
			"players must never need a purchase to continue"
		)
	end)

	-- ── Audio ────────────────────────────────────────────────────────────────

	suite:test("every audio cue names a real mixer group", function(expect)
		for name, cue in pairs(AudioConfig.Cues) do
			expect.truthy(
				AudioConfig.Groups[cue.group],
				("cue %s uses unknown group %s"):format(name, tostring(cue.group))
			)
		end
		for name, group in pairs(AudioConfig.Groups) do
			if group.parent then
				expect.truthy(
					AudioConfig.Groups[group.parent],
					("group %s has unknown parent %s"):format(name, group.parent)
				)
			end
		end
	end)

	suite:test("phase beds and random ambience reference real cues", function(expect)
		for phase, bed in pairs(AudioConfig.PhaseBeds) do
			expect.truthy(
				AudioConfig.Cues[bed.ambience],
				("phase %s uses unknown cue %s"):format(phase, bed.ambience)
			)
			if bed.sting then
				expect.truthy(
					AudioConfig.Cues[bed.sting],
					("phase %s stings unknown cue %s"):format(phase, bed.sting)
				)
			end
		end
		for phase, entries in pairs(AudioConfig.RandomAmbience) do
			for _, entry in ipairs(entries) do
				expect.truthy(
					AudioConfig.Cues[entry.cue],
					("random ambience for %s uses unknown cue %s"):format(phase, entry.cue)
				)
				expect.lessThan(
					entry.every[1],
					entry.every[2],
					("%s has an inverted interval"):format(entry.cue)
				)
			end
		end
	end)

	suite:test("no audio asset ID has been invented", function(expect)
		--[[ The project ships with no sound assets. An id appearing here would
		     mean someone guessed one, which would either 404 or play something
		     unrelated and unlicensed. ]]
		local withIds = {}
		for name, cue in pairs(AudioConfig.Cues) do
			if cue.assetId and cue.assetId ~= "" then
				table.insert(withIds, name)
			end
		end
		expect.equal(
			#withIds,
			0,
			("these cues have asset IDs; confirm they are real and licensed, then update this test: %s"):format(
				table.concat(withIds, ", ")
			)
		)
	end)

	-- ── Profile ──────────────────────────────────────────────────────────────

	suite:test("a new profile is playable and matches the data version", function(expect)
		local profile = ProfileTemplate.create(1700000000, "Tester")
		expect.equal(profile.version, GameConfig.DataVersion)
		expect.equal(profile.progression.level, 1)
		expect.truthy(profile.colony.name ~= "", "a colony should be named")
		expect.truthy(profile.colony.tools.bare_hands, "a new player needs the fallback tool")
		expect.equal(profile.colony.equippedTool, "bare_hands")
		expect.truthy(RoleConfig.isValid(profile.progression.selectedRole), "the default role must exist")

		local starting = 0
		for resourceId, amount in pairs(profile.colony.storage) do
			expect.truthy(resourceIds[resourceId], ("starting storage has unknown %s"):format(resourceId))
			starting += amount
		end
		expect.greaterThan(starting, 0, "a new player should start with something to build with")
	end)

	suite:test("starting resources cover the first two buildings", function(expect)
		--[[ A new player who cannot afford anything has nothing to do before
		     their first expedition, which is the worst possible opening. ]]
		local profile = ProfileTemplate.create(1700000000, "Tester")
		local storage = profile.colony.storage

		for _, buildingId in ipairs({ Enums.Building.Housing, Enums.Building.Farm }) do
			local cost = BuildingConfig.get(buildingId).levels[1].cost
			for resourceId, amount in pairs(cost) do
				expect.atLeast(
					storage[resourceId] or 0,
					amount,
					("a new player cannot afford a %s: needs %d %s"):format(buildingId, amount, resourceId)
				)
			end
		end
	end)

	suite:test("the profile template stores nothing derived", function(expect)
		--[[ Derived values frozen into a save mean a balance change never
		     reaches existing players. Storage capacity, role stats and colony
		     effects are all computed at runtime, so they must not appear here. ]]
		local profile = ProfileTemplate.Template
		expect.equal(profile.colony.storageCapacity, nil, "storage capacity is derived from buildings")
		expect.equal(profile.colony.population, nil, "population cap is derived from buildings")
		expect.equal(profile.progression.walkSpeed, nil, "role stats are derived from config")
	end)
end
