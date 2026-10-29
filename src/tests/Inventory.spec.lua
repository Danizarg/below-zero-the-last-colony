--[[
	Inventory.spec.lua

	Inventory arithmetic is where duplication exploits live, so the properties
	worth proving are the ones that stop an item appearing from nowhere or a cost
	being half-paid.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("BelowZero")
local Enums = require(Shared.Enums)
local Inventory = require(Shared.Lib.Inventory)
local ResourceConfig = require(Shared.Config.ResourceConfig)

local R = Enums.Resource

local function unitLimits(capacity, stackLimit)
	return {
		capacity = capacity,
		measure = "units",
		stackLimit = stackLimit,
		defs = ResourceConfig.Resources,
		consumableDefs = ResourceConfig.Consumables,
	}
end

local function weightLimits(capacity, stackLimit)
	return {
		capacity = capacity,
		measure = "weight",
		stackLimit = stackLimit,
		defs = ResourceConfig.Resources,
		consumableDefs = ResourceConfig.Consumables,
	}
end

return function(suite)
	-- ── Adding ───────────────────────────────────────────────────────────────

	suite:test("adds what fits and reports the overflow", function(expect)
		local bag = Inventory.new()
		local result = Inventory.add(bag, R.Stone, 10, unitLimits(100))
		expect.equal(result.added, 10)
		expect.equal(result.overflow, 0)
		expect.equal(Inventory.count(bag, R.Stone), 10)
	end)

	suite:test("respects a per-resource stack limit", function(expect)
		local bag = Inventory.new()
		local result = Inventory.add(bag, R.Stone, 500, unitLimits(10000, 200))
		expect.equal(result.added, 200, "should cap at the stack limit")
		expect.equal(result.overflow, 300)
		expect.equal(result.reason, Enums.Reject.InventoryFull)
	end)

	suite:test("respects a total unit capacity", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Stone, 80, unitLimits(100))
		local result = Inventory.add(bag, R.Fiber, 50, unitLimits(100))
		expect.equal(result.added, 20, "only 20 units of room were left")
		expect.equal(result.overflow, 30)
		expect.equal(Inventory.totalUnits(bag), 100)
	end)

	suite:test("respects a total weight capacity, and weight is per resource", function(expect)
		--[[ Crystal weighs 3 and Stone weighs 1, so a 30-weight bag holds ten
		     crystals or thirty stone. Getting this wrong would make heavy
		     resources free to carry. ]]
		local bag = Inventory.new()
		local crystal = Inventory.add(bag, R.Crystal, 20, weightLimits(30))
		expect.equal(crystal.added, 10, "3 weight each, so 10 fit in 30")
		expect.equal(Inventory.totalWeight(bag, ResourceConfig.Resources, ResourceConfig.Consumables), 30)

		local stoneBag = Inventory.new()
		local stone = Inventory.add(stoneBag, R.Stone, 50, weightLimits(30))
		expect.equal(stone.added, 30, "1 weight each, so 30 fit in 30")
	end)

	suite:test("refuses a full inventory outright rather than adding zero quietly", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Stone, 100, unitLimits(100))
		local result = Inventory.add(bag, R.Stone, 1, unitLimits(100))
		expect.equal(result.added, 0)
		expect.equal(result.reason, Enums.Reject.InventoryFull)
	end)

	suite:test("rejects nonsense input without erroring", function(expect)
		local bag = Inventory.new()
		expect.equal(Inventory.add(bag, R.Stone, 0, unitLimits(100)).reason, Enums.Reject.BadRequest)
		expect.equal(Inventory.add(bag, R.Stone, -5, unitLimits(100)).added, 0)
		expect.equal(Inventory.add(bag, 42, 5, unitLimits(100)).reason, Enums.Reject.BadRequest)
	end)

	-- ── Removing ─────────────────────────────────────────────────────────────

	suite:test("removes exactly, or not at all", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Iron, 5, unitLimits(100))

		local short = Inventory.remove(bag, R.Iron, 6)
		expect.equal(short.removed, 0, "a partial removal would be a duplication bug")
		expect.equal(short.reason, Enums.Reject.NotEnoughResources)
		expect.equal(short.short, 1)
		expect.equal(Inventory.count(bag, R.Iron), 5, "nothing should have been taken")

		local exact = Inventory.remove(bag, R.Iron, 5)
		expect.equal(exact.removed, 5)
		expect.equal(Inventory.count(bag, R.Iron), 0)
	end)

	suite:test("an emptied slot is cleared rather than left at zero", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Coal, 3, unitLimits(100))
		Inventory.remove(bag, R.Coal, 3)
		expect.equal(bag.items[R.Coal], nil, "a zero entry would show up in the UI as an empty row")
		expect.truthy(Inventory.isEmpty(bag))
	end)

	-- ── Paying ───────────────────────────────────────────────────────────────

	suite:test("canAfford reports every shortfall", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Stone, 5, unitLimits(1000))

		local ok, missing = Inventory.canAfford(bag, { [R.Stone] = 10, [R.Fiber] = 4 })
		expect.falsy(ok)
		expect.equal(missing[R.Stone], 5)
		expect.equal(missing[R.Fiber], 4)
	end)

	suite:test("paying is atomic: a failed cost deducts nothing", function(expect)
		--[[ This is the property that matters most. A build that takes the stone
		     and then discovers there is no fiber would quietly destroy
		     resources. ]]
		local bag = Inventory.new()
		Inventory.add(bag, R.Stone, 20, unitLimits(1000))
		Inventory.add(bag, R.Fiber, 2, unitLimits(1000))

		local result = Inventory.pay(bag, { [R.Stone] = 10, [R.Fiber] = 6 })
		expect.falsy(result.paid)
		expect.equal(Inventory.count(bag, R.Stone), 20, "stone should not have been spent")
		expect.equal(Inventory.count(bag, R.Fiber), 2, "fiber should not have been spent")
	end)

	suite:test("paying an affordable cost deducts every line", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Stone, 20, unitLimits(1000))
		Inventory.add(bag, R.Fiber, 10, unitLimits(1000))

		local result = Inventory.pay(bag, { [R.Stone] = 12, [R.Fiber] = 6 })
		expect.truthy(result.paid)
		expect.equal(Inventory.count(bag, R.Stone), 8)
		expect.equal(Inventory.count(bag, R.Fiber), 4)
	end)

	suite:test("an empty cost always succeeds and changes nothing", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Stone, 5, unitLimits(1000))
		local result = Inventory.pay(bag, {})
		expect.truthy(result.paid)
		expect.equal(Inventory.count(bag, R.Stone), 5)
	end)

	-- ── Loss on failure ──────────────────────────────────────────────────────

	suite:test("loss keeps the configured fraction and rounds in the player's favour", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Stone, 10, unitLimits(1000))

		local split = Inventory.applyLoss(bag, 0.4, {})
		--[[ ceil(10 * 0.4) = 4, and the remainder is lost. Rounding up means a
		     single item is never destroyed by a rounding rule. ]]
		expect.equal(split.kept.items[R.Stone], 4)
		expect.equal(split.lost[R.Stone], 6)
	end)

	suite:test("a single item survives any non-zero recovery rate", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Relic, 1, unitLimits(1000))
		local split = Inventory.applyLoss(bag, 0.1, {})
		expect.equal(split.kept.items[R.Relic], 1, "ceil(1 * 0.1) should be 1, not 0")
	end)

	suite:test("protected resources are never lost", function(expect)
		--[[ Ancient keys are flagged protectedOnDeath in config, so a failed run
		     must never cost escape progress. ]]
		local bag = Inventory.new()
		Inventory.add(bag, R.AncientKey, 2, unitLimits(1000))
		Inventory.add(bag, R.Stone, 10, unitLimits(1000))

		local split = Inventory.applyLoss(bag, 0, { [R.AncientKey] = true })
		expect.equal(split.kept.items[R.AncientKey], 2, "keys should survive a total loss")
		expect.equal(split.lost[R.AncientKey], nil)
		expect.equal(split.lost[R.Stone], 10)
	end)

	suite:test("the resource flagged protectedOnDeath in config is the ancient key", function(expect)
		--[[ Ties the test above to the real config, so changing the flag without
		     thinking about it fails here. ]]
		local protectedIds = {}
		for id, def in pairs(ResourceConfig.Resources) do
			if def.protectedOnDeath then
				table.insert(protectedIds, id)
			end
		end
		expect.equal(#protectedIds, 1, "expected exactly one protected resource")
		expect.equal(protectedIds[1], R.AncientKey)
	end)

	suite:test("consumables are always consumed by a failure", function(expect)
		local bag = Inventory.new()
		Inventory.addConsumable(bag, "glowroot_salve", 3, unitLimits(1000))
		local split = Inventory.applyLoss(bag, 1, {})
		expect.equal(split.lost["glowroot_salve"], 3, "half a salve is not a meaningful reward")
	end)

	-- ── Merging ──────────────────────────────────────────────────────────────

	suite:test("merging reports what did not fit", function(expect)
		local storage = Inventory.new()
		Inventory.add(storage, R.Stone, 95, unitLimits(100))

		local bag = Inventory.new()
		Inventory.add(bag, R.Stone, 20, unitLimits(1000))

		local result = Inventory.merge(storage, bag, function()
			return unitLimits(100)
		end)

		expect.equal(result.moved[R.Stone], 5)
		expect.equal(result.leftover[R.Stone], 15)
		expect.truthy(result.anyOverflow)
	end)

	suite:test("merging is deterministic when storage is full", function(expect)
		--[[ With limited room, which items get in must not depend on table
		     iteration order, or the same run would pay out differently each
		     time. ]]
		local function run()
			local storage = Inventory.new()
			Inventory.add(storage, R.Stone, 8, unitLimits(10))

			local bag = Inventory.new()
			Inventory.add(bag, R.Coal, 5, unitLimits(1000))
			Inventory.add(bag, R.Crystal, 5, unitLimits(1000))
			Inventory.add(bag, R.Iron, 5, unitLimits(1000))

			local result = Inventory.merge(storage, bag, function()
				return unitLimits(10)
			end)

			local keys = {}
			for id, amount in pairs(result.moved) do
				table.insert(keys, id .. "=" .. amount)
			end
			table.sort(keys)
			return table.concat(keys, ",")
		end

		expect.equal(run(), run(), "the same merge produced different results")
	end)

	-- ── Presentation ─────────────────────────────────────────────────────────

	suite:test("toList follows the configured order and skips empties", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Crystal, 1, unitLimits(1000))
		Inventory.add(bag, R.Stone, 1, unitLimits(1000))

		local list = Inventory.toList(bag, ResourceConfig.Order)
		expect.equal(#list, 2)
		expect.equal(list[1].id, R.Stone, "stone comes first in ResourceConfig.Order")
		expect.equal(list[2].id, R.Crystal)
	end)

	suite:test("clone is a deep copy", function(expect)
		local bag = Inventory.new()
		Inventory.add(bag, R.Stone, 5, unitLimits(1000))
		local copy = Inventory.clone(bag)
		Inventory.remove(bag, R.Stone, 5)
		expect.equal(Inventory.count(copy, R.Stone), 5, "the clone should not follow the original")
	end)
end
