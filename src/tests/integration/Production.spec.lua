--[[
	Production.spec.lua
	The ONLINE production tick: what the colony does every ten seconds while
	the player is standing in it, and what the client is told about it.

	Why this layer needs covering
	─────────────────────────────
	`NPCService:simulate` is one function used two ways. Offline.spec drives it
	through `_settleOffline` — many ticks in one call at half efficiency, paid
	on a join. This spec drives the other caller: the `RunService.Heartbeat`
	connection in `NPCService:start`, one tick at a time at efficiency scale 1,
	whose return value is thrown away.

	The scale is the whole reason this file exists. `quantise` turns a
	fractional per-tick amount into `floor(amount)` plus a chance of one more
	unit, so any demand below one whole unit is sometimes ZERO and the job
	legitimately works for free that tick. Offline halves everything, and the
	Cook's mushroom — the largest input in the game at 1.0 per tick — comes to
	0.935 at the skill ceiling. Offline therefore cannot hold a job short of
	its inputs on purpose, and the central promise of the consume loop,

	    inputs are resolved to whole units, THEN checked, THEN spent, and a job
	    that cannot pay produces nothing and spends nothing — never a partial
	    deduction

	is unreachable from there. Online at the ceiling the same input is 1.87, so
	it is demanded on every single tick, and the invariant can be held under a
	microscope. That is what the first three tests do.

	The rest covers the other half of a tick: what reaches the client. A spend
	writes `storage.items` directly rather than going through
	`InventoryService:spendFromStorage`, and the colony snapshot the tick sends
	afterwards carries no storage at all — so for a colony whose only worker
	eats rather than produces, the resource strip, the units line and
	`recipes[].available` used to be left behind indefinitely, with the Craft
	button still lit for a recipe the server would refuse. Those are tests 4
	and 5.

	What this cannot reach
	──────────────────────
	`Net.fire` records the payload by reference (tools/sim.luau) and
	`pushStorage` passes the live `profile.colony.storage` table, so a recorded
	packet's `storage` field ALIASES the server's own storage and tracks it
	however stale the packet is. Nothing here may assert on it; the assertions
	are on `used`, `capacity` and `recipes`, which are computed at push time
	and so are genuinely frozen into the packet. A real RemoteEvent serialises
	by value and would freeze the item map too — that part is inference from
	Roblox remote semantics rather than something this harness can show.

	Nor does anything here prove the client DRAWS what it is sent: that the
	resource strip reads `storage` and the Craft button reads
	`recipes[].available` is read off src/client/UI, not executed.

	Each test builds its own server, so nothing leaks between them.
]]

return function(suite, context)
	local newServer = context.newServer

	--[[ Replay a per-tick step `n` times from a starting value. Exact float
	     equality is only available this way round, because the service
	     iterates: twenty Farmer ticks of +0.05 skill land on
	     2.0000000000000009 and the closed form `1 + 20 * 0.05` lands on 2.0.
	     Asserting the closed form would fail for a reason that has nothing to
	     do with the game, and asserting `near` would stop catching the small
	     drifts worth catching. ]]
	local function replay(start, n, step)
		local value = start
		for _ = 1, n do
			value = step(value)
		end
		return value
	end

	--[[ The lowest level of `buildingId` whose effects open a slot for
	     `jobId`, read out of BuildingConfig. The Cook is the only reachable
	     job that consumes anything, and level 1 of its Farm has no room for
	     one — so every test here has to find that level rather than write a 2
	     into the spec and break when the slot moves. ]]
	local function levelWithSlotFor(BuildingConfig, buildingId, jobId)
		for level, data in ipairs(BuildingConfig.get(buildingId).levels) do
			if (((data.effects or {}).jobSlots or {})[jobId] or 0) > 0 then
				return level
			end
		end
		return nil
	end

	--[[ The lowest whole skill at which an input priced at `perTick` is
	     CERTAIN — the point where `perTick * efficiency(skill)` reaches one
	     whole unit and `quantise` can no longer round it away. Below it a
	     starved job sometimes needs nothing and works for free, which is
	     exactly what makes these tests impossible offline. ]]
	local function certainInputSkill(JobConfig, perTick)
		for skill = 1, JobConfig.MaxSkill do
			if perTick * JobConfig.efficiency(skill) >= 1 then
				return skill
			end
		end
		return nil
	end

	--[[ Shared setup: a booted server and one player with a plot, a granted
	     Town Hall, three unassigned colonists and the starting materials. ]]
	local function newColony(playerName, options)
		local server = newServer(options)

		local colony = {
			server = server,
			services = server.services,
			Routes = server.require(server.shared.Routes),
			Enums = server.require(server.shared.Enums),
			GameConfig = server.require(server.shared.Config.GameConfig),
			BuildingConfig = server.require(server.shared.Config.BuildingConfig),
			JobConfig = server.require(server.shared.Config.JobConfig),
			ResourceConfig = server.require(server.shared.Config.ResourceConfig),
			Inventory = server.require(server.shared.Lib.Inventory),
		}
		colony.NPC = colony.GameConfig.NPC
		colony.player = server.addPlayer(playerName or "Alice")

		function colony.profile()
			return server.services.DataService:get(colony.player)
		end

		function colony.storage()
			return colony.profile().colony.storage
		end

		function colony.held(resourceId)
			return colony.storage()[resourceId] or 0
		end

		--[[ A copy, not the table. Every test that measures a spend needs a
		     BEFORE it can still read afterwards, and the profile's storage is
		     mutated in place by the tick. ]]
		function colony.storageSnapshot()
			return table.clone(colony.storage())
		end

		function colony.unitsHeld()
			return colony.Inventory.totalUnits(server.services.InventoryService:storageOf(colony.player))
		end

		function colony.colonists()
			return colony.profile().colony.colonists
		end

		function colony.effects()
			return server.services.BuildingService:effectsFor(colony.player)
		end

		--[[ Everything a tick charges the larder for, summed over the WHOLE
		     roster in the service's own order: `foodUse` is accumulated
		     outside the `works` guard, so an unemployed colonist and a
		     colonist whose job is blocked both still eat. Summed with the same
		     iteration as the tick so the float lands on the same bits. ]]
		function colony.foodUsePerTick()
			local total = 0
			for _, colonist in ipairs(colony.colonists()) do
				total += colony.JobConfig.get(colonist.job).foodUse or 0
			end
			return total
		end

		-- ── Routes, as the client would call them ──────────────────────────

		--[[ Top storage up to `amount` of each resource named, through the
		     same chokepoint a harvest goes through. A short fill is an error
		     rather than a quiet half-setup: a test funded below its cost would
		     go on to measure a refusal it never meant to cause. ]]
		function colony.fund(expect, cost)
			for resourceId, amount in pairs(cost) do
				local short = amount - colony.held(resourceId)
				if short > 0 then
					local result =
						server.services.InventoryService:addToStorage(colony.player, resourceId, short)
					expect.equal(
						result.added,
						short,
						("storage would only take %d of the %d %s this test needs, so its setup never happened"):format(
							result.added,
							short,
							resourceId
						)
					)
				end
			end
		end

		function colony.place(expect, buildingId, gx, gz)
			colony.fund(expect, colony.BuildingConfig.get(buildingId).levels[1].cost)
			local placed = server.invoke(colony.player, colony.Routes.Request.PlaceBuilding, {
				buildingId = buildingId,
				gx = gx,
				gz = gz,
				rot = 0,
			})
			expect.truthy(placed.ok, ("the %s was refused: %s"):format(buildingId, tostring(placed.reason)))
			for _, placement in ipairs(colony.profile().colony.buildings) do
				if placement.id == buildingId then
					return placement
				end
			end
			expect.fail(("the %s was accepted and never appeared on the plot"):format(buildingId))
			return nil
		end

		--[[ Place `buildingId` and raise it to `level`, funding each step out
		     of BuildingConfig. Done through the real routes because the job
		     slots a level opens come from building effects, and seeding a
		     placement by hand would skip the recalculation that grants them. ]]
		function colony.buildTo(expect, buildingId, level, gx, gz)
			local placement = colony.place(expect, buildingId, gx, gz)
			for step = 2, level do
				colony.fund(expect, colony.BuildingConfig.get(buildingId).levels[step].cost)
				local upgraded = server.invoke(
					colony.player,
					colony.Routes.Request.UpgradeBuilding,
					{ uid = placement.uid }
				)
				expect.truthy(
					upgraded.ok,
					("the %s could not be raised to level %d: %s"):format(
						buildingId,
						step,
						tostring(upgraded.reason)
					)
				)
			end
			expect.equal(
				placement.level,
				level,
				("the %s ended on level %d rather than %d, so the job slots this test needs are not open"):format(
					buildingId,
					placement.level,
					level
				)
			)
			return placement
		end

		--[[ Put the `index`th colonist on `jobId` and hand the record back, so
		     a test can read their skill afterwards without searching for
		     them. ]]
		function colony.assign(expect, index, jobId)
			local colonist = colony.colonists()[index]
			expect.truthy(colonist, ("there is no colonist %d on this roster"):format(index))
			local assigned = server.invoke(colony.player, colony.Routes.Request.AssignJob, {
				uid = colonist.uid,
				job = jobId,
			})
			expect.truthy(
				assigned.ok,
				("%s was refused: %s/%s"):format(jobId, tostring(assigned.reason), tostring(assigned.detail))
			)
			return colonist
		end

		-- ── Time, and what the ticks sent ──────────────────────────────────

		--[[ `n` production ticks of ordinary play, with the push log cleared
		     first so everything read afterwards belongs to the window.

		     The tick count is then ASSERTED rather than assumed. Every exact
		     figure in this file is a starting value plus `n` applications of a
		     per-tick amount, so a tick fired twice or skipped turns an
		     equality into a mystery. The online tick pushes a colony snapshot
		     every time it runs, which is what makes the count observable from
		     outside — and nothing else in a quiet colony pushes that route. ]]
		function colony.ticks(expect, n)
			server.clearPushes()
			server.advance(n * colony.NPC.ProductionTickSeconds + 1, 1)
			expect.equal(
				#server.pushes(colony.player, colony.Routes.Push.ColonySync),
				n,
				("%d production ticks were asked for and the server ran a different number, so every figure measured over this window is measured over the wrong one"):format(
					n
				)
			)
		end

		--[[ The InventorySync packets that are the STORE rather than the
		     expedition bag. Both share the route and each push is a partial
		     payload — `pushBag` carries `bagUsed` and no `used` at all — so
		     the store's packets are the ones reporting `used`. ]]
		function colony.storagePushes()
			local out = {}
			for _, payload in ipairs(server.pushes(colony.player, colony.Routes.Push.InventorySync)) do
				if payload.used ~= nil then
					table.insert(out, payload)
				end
			end
			return out
		end

		function colony.lastStoragePush()
			local pushes = colony.storagePushes()
			return pushes[#pushes]
		end

		function colony.recipeIn(payload, recipeId)
			for _, recipe in ipairs((payload or {}).recipes or {}) do
				if recipe.id == recipeId then
					return recipe
				end
			end
			return nil
		end

		-- ── The one roster that can go short of its inputs ──────────────────

		--[[ The smallest colony in which a job can be held short of its
		     inputs: the Cook, on a Farm raised to the level that has a slot
		     for one, with a Guard beside them and one colonist left idle.

		     The Guard is not decoration. `globalMult` multiplies every
		     efficiency by `clamp(condition / 100, 0.4, 1)`, so without a
		     repairer the colony's slow condition decay changes the arithmetic
		     on every tick after the first and nothing exact can be asserted
		     over a run. A Guard repairs 0.8 per tick against a decay of
		     1/240, so condition clamps back to ConditionMax every tick and the
		     factor is exactly 1. Each test that depends on that asserts it.

		     The Cook's skill is WRITTEN rather than trained. Training it would
		     take 180 worked ticks of a Cook that is being deliberately starved
		     — the very thing that stops it learning — so this is setup, not
		     gameplay, and it is the colonist's own field that the tick itself
		     writes. `skill` is passed in so a test can pick the lowest skill
		     that makes an input certain and still watch for learning. ]]
		function colony.staffCook(expect, skill)
			local Enums, JobConfig = colony.Enums, colony.JobConfig
			local cookJob = JobConfig.get(Enums.Job.Cook)
			expect.truthy(next(cookJob.consumes), "the Cook consumes nothing, so this whole spec is vacuous")

			local farmLevel = levelWithSlotFor(colony.BuildingConfig, cookJob.requires, Enums.Job.Cook)
			expect.truthy(
				farmLevel,
				("no level of %s has a slot for a Cook, so the only consuming job in the game is unreachable"):format(
					tostring(cookJob.requires)
				)
			)
			colony.buildTo(expect, cookJob.requires, farmLevel, 0, 9)

			local cook = colony.assign(expect, 1, Enums.Job.Cook)
			colony.assign(expect, 2, Enums.Job.Guard)
			cook.skill = skill

			--[[ Nobody is on a producing job, so nothing in these tests can
			     deposit: that keeps the spend the only thing moving storage,
			     and `produces` being empty for a Cook is what makes the
			     deposit loop a no-op rather than a second source of noise. ]]
			expect.falsy(
				next(cookJob.produces),
				"the Cook produces a resource now, so these tests measure two things"
			)
			return cook
		end

		return colony
	end

	-- ── The input contract ───────────────────────────────────────────────────

	suite:test("a job that cannot pay for its inputs does not work at all", function(expect)
		local colony = newColony()
		local Enums, JobConfig = colony.Enums, colony.JobConfig
		local ticks = 20

		--[[ The lowest skill at which the Cook's mushroom demand is certain,
		     rather than the ceiling: it makes every tick deterministic AND
		     leaves room above for the skill assertion at the bottom. ]]
		local cookJob = JobConfig.get(Enums.Job.Cook)
		local mushroomPerTick = cookJob.consumes[Enums.Resource.Mushroom]
		local skill = certainInputSkill(JobConfig, mushroomPerTick)
		expect.truthy(
			skill,
			"no skill makes the Cook's mushroom input certain, so nothing in this spec can hold a job short on purpose"
		)
		expect.lessThan(
			skill,
			JobConfig.MaxSkill,
			"the certain-input skill is at the ceiling, so the skill assertion below cannot move"
		)

		local cook = colony.staffCook(expect, skill)

		--[[ The larder is emptied of the Cook's first input and stocked with
		     its second, so the shortage is unambiguous and the job is blocked
		     on every single tick. ]]
		colony.storage()[Enums.Resource.Mushroom] = nil
		colony.fund(expect, { [Enums.Resource.Coal] = 50 })
		local coalBefore = colony.held(Enums.Resource.Coal)

		local effects = colony.effects()
		expect.equal(
			effects.productionMult,
			1,
			"this colony has a production bonus, so the figures below are derived against the wrong multiplier"
		)
		local foodUse = colony.foodUsePerTick()
		local foodBefore = colony.profile().colony.food

		colony.ticks(expect, ticks)

		--[[ The proof that the Cook was blocked on EVERY tick rather than most
		     of them, and the reason this is an equality rather than a
		     direction. A Cook that worked once would have added
		     `foodValuePerTick * efficiency` to the larder that tick, and the
		     figure below has none of it in: it is the buildings' growth minus
		     what the roster ate, and nothing else. Replayed tick by tick
		     because the service iterates. ]]
		local expectedFood = replay(foodBefore, ticks, function(food)
			return math.max(0, food + ((effects.foodPerTick or 0) - foodUse))
		end)
		expect.equal(
			colony.profile().colony.food,
			expectedFood,
			("a starved Cook still added food value: %d ticks moved the larder to %.4f where buildings alone give %.4f"):format(
				ticks,
				colony.profile().colony.food,
				expectedFood
			)
		)

		--[[ And the second input was never even priced. Mushroom is the first
		     key the consume loop reaches, so the `break` fires before coal is
		     quantised at all — a blocked job is not a job that pays for part
		     of its shopping list. ]]
		expect.equal(
			colony.held(Enums.Resource.Coal),
			coalBefore,
			"a Cook that could not buy its mushrooms was still charged for coal"
		)

		--[[ Learning sits inside the same `canWork` guard as the output, so a
		     colonist who never worked never improved. Without this a blocked
		     job would still ratchet towards the ceiling, and a colony could
		     train a workforce on an empty larder. ]]
		expect.equal(
			cook.skill,
			skill,
			("a Cook that worked none of %d ticks learned anyway, reaching skill %.4f"):format(
				ticks,
				cook.skill
			)
		)
		colony.server.assertNoErrors(expect, "blocked job")
	end)

	suite:test("a job that cannot pay spends nothing, not even the input it could afford", function(expect)
		local colony = newColony()
		local Enums, JobConfig = colony.Enums, colony.JobConfig
		local ticks = 120

		local cookJob = JobConfig.get(Enums.Job.Cook)
		local cook = colony.staffCook(expect, JobConfig.MaxSkill)

		--[[ THE PRECONDITION, and the reason this test is worth writing at
		     all. The consume loop walks `consumes` with `pairs`, resolves each
		     input into `toSpend`, and breaks out the moment one of them cannot
		     be paid. If the SHORT input is reached first, nothing has been put
		     in `toSpend` yet and "it spent nothing" is true for free — the
		     test would pass while proving nothing about atomicity. The case
		     worth pinning is the other one: an input the colony CAN pay,
		     already resolved and sitting in `toSpend`, which the break has to
		     leave alone.

		     So the order is asserted rather than hoped for. Luau's table
		     iteration order is not part of the language's contract; if it ever
		     changes, this fails here with an explanation instead of quietly
		     becoming a test of nothing. The fix if it does is to swap which
		     input the larder is stocked with below. ]]
		local firstKey = next(cookJob.consumes)
		expect.equal(
			firstKey,
			Enums.Resource.Mushroom,
			("this test stocks mushrooms and starves the colony of coal so that the AFFORDABLE input is resolved first and the break has something to wrongly deduct. `pairs` now reaches %s first instead, which makes the run below vacuous: stock %s and starve the colony of the other input."):format(
				tostring(firstKey),
				tostring(firstKey)
			)
		)

		--[[ Stocked with the first input, stripped of the second. The second
		     input is priced under one whole unit per tick — 0.2 at skill 1 —
		     so `quantise` demands it on some ticks and not others: the ticks
		     it is demanded are the ticks the Cook is blocked, and the ticks it
		     is not are a working control that runs in the same loop. ]]
		local larder = 50
		colony.storage()[Enums.Resource.Coal] = nil
		colony.storage()[Enums.Resource.Mushroom] = larder

		local demand = cookJob.consumes[Enums.Resource.Mushroom] * JobConfig.efficiency(JobConfig.MaxSkill)
		local effects = colony.effects()
		local foodUse = colony.foodUsePerTick()
		local idleFood = (effects.foodPerTick or 0) - foodUse
		local workedFood = idleFood
			+ (cookJob.foodValuePerTick or 0) * JobConfig.efficiency(JobConfig.MaxSkill)

		local NPCService = colony.services.NPCService
		local blocked, worked = 0, 0

		for tick = 1, ticks do
			--[[ The larder is topped back up each time so that mushroom can
			     never be the short input: the only shortage under test is the
			     second one. Through `addToStorage` rather than a profile
			     write, so the stack limit stays honest.

			     And the tick is run through `simulate` directly rather than
			     through the heartbeat, because the heartbeat throws the
			     summary away and `inputsShort` is the only way to know which
			     ticks were blocked. It is the same function the tick calls,
			     with the same arguments the tick passes; what that leaves
			     unproven is the heartbeat's wiring, which the test above
			     covers. ]]
			colony.fund(expect, { [Enums.Resource.Mushroom] = larder })
			local before = colony.storageSnapshot()
			local foodBefore = colony.profile().colony.food

			local summary = NPCService:simulate(colony.player, 1, 1)
			expect.truthy(summary, ("the production tick refused to run at all on tick %d"):format(tick))

			local foodMoved = colony.profile().colony.food - foodBefore

			if summary.inputsShort then
				blocked += 1

				--[[ The invariant, in its strongest form: not "mushroom did
				     not move" but "NOTHING moved". A partial deduction of any
				     resource shows up here. ]]
				local after = colony.storageSnapshot()
				for resourceId, amount in pairs(before) do
					expect.equal(
						after[resourceId] or 0,
						amount,
						("a job that could not pay its inputs was charged anyway: %s went from %d to %d on tick %d"):format(
							resourceId,
							amount,
							after[resourceId] or 0,
							tick
						)
					)
				end
				for resourceId, amount in pairs(after) do
					expect.truthy(
						before[resourceId],
						("%s (%d units) appeared in storage on tick %d, which a blocked job cannot have made"):format(
							resourceId,
							amount,
							tick
						)
					)
				end

				--[[ Cross-check on the flag itself, so the test cannot be
				     satisfied by a summary that simply claims to be short:
				     a blocked Cook adds no food value, and the larder moving
				     by the working figure instead would catch it. ]]
				expect.near(
					foodMoved,
					idleFood,
					0.01,
					("tick %d reported its inputs short and the colony gained a working Cook's food anyway"):format(
						tick
					)
				)
			else
				worked += 1

				--[[ And on the ticks it COULD pay, the deduction is the whole
				     resolved amount — bounded by what `quantise` can return
				     for this demand and never a fraction of it. ]]
				local spent = before[Enums.Resource.Mushroom] - colony.held(Enums.Resource.Mushroom)
				expect.inRange(
					spent,
					math.floor(demand),
					math.ceil(demand),
					("a working Cook was charged %d mushrooms on tick %d against a resolved demand of %.4f"):format(
						spent,
						tick,
						demand
					)
				)
				expect.near(
					foodMoved,
					workedFood,
					0.01,
					("tick %d reported its inputs satisfied and the colony gained nothing for it"):format(
						tick
					)
				)
			end
		end

		--[[ Both arms have to have been taken, or the loop above tested one
		     thing twice. Which ticks fall which way is a coin flip on the
		     second input's fractional demand, so this is the one assertion
		     here that is not deterministic: with the demand at
		     `0.2 * efficiency` the chance of a run this long landing entirely
		     on one side is smaller than the chance of the machine mis-adding
		     the floats. If it ever does fire, re-run before reading anything
		     into it. ]]
		expect.greaterThan(
			blocked,
			0,
			("none of %d ticks ran short of the second input, so nothing above tested a blocked job"):format(
				ticks
			)
		)
		expect.greaterThan(
			worked,
			0,
			("the Cook was blocked on all %d ticks, so the deduction on a working tick was never checked"):format(
				ticks
			)
		)
		expect.equal(cook.skill, JobConfig.MaxSkill, "a colonist at the ceiling learned past it")
		colony.server.assertNoErrors(expect, "no partial deduction")
	end)

	suite:test("a job that can pay works every tick and is charged what it owes", function(expect)
		local colony = newColony()
		local Enums, JobConfig = colony.Enums, colony.JobConfig
		local ticks = 10

		--[[ The control for the two tests above. Without it they could both be
		     passing because the Cook was never able to work at all — a job
		     slot that is not open, a building a level too low, a roster entry
		     the tick skips — rather than because of the shortage they set
		     up. Same colony, same skill, same route in: the only difference is
		     a stocked larder. ]]
		local cookJob = JobConfig.get(Enums.Job.Cook)
		colony.staffCook(expect, JobConfig.MaxSkill)

		local efficiency = JobConfig.efficiency(JobConfig.MaxSkill)
		local demand = cookJob.consumes[Enums.Resource.Mushroom] * efficiency
		local coalDemand = cookJob.consumes[Enums.Resource.Coal] * efficiency

		colony.fund(expect, { [Enums.Resource.Mushroom] = 100, [Enums.Resource.Coal] = 100 })
		local before = colony.storageSnapshot()

		local effects = colony.effects()
		expect.equal(effects.productionMult, 1, "a production bonus would move every figure below")
		local foodUse = colony.foodUsePerTick()
		local foodBefore = colony.profile().colony.food

		colony.ticks(expect, ticks)

		--[[ The Cook worked on every one of these ticks, and the larder says
		     so to the unit: the buildings' growth, plus the Cook's food value
		     at its efficiency, minus what the roster ate — written in the
		     service's own order, because `(a + b) - c` and `(a - c) + b` are
		     different floats and this is an equality. ]]
		local expectedFood = replay(foodBefore, ticks, function(food)
			return math.max(
				0,
				food + (((effects.foodPerTick or 0) + (cookJob.foodValuePerTick or 0) * efficiency) - foodUse)
			)
		end)
		expect.equal(
			colony.profile().colony.food,
			expectedFood,
			("a Cook with a full larder missed a tick: %d ticks moved the larder to %.4f against %.4f for working all of them"):format(
				ticks,
				colony.profile().colony.food,
				expectedFood
			)
		)
		expect.equal(
			colony.profile().colony.condition,
			colony.NPC.ConditionMax,
			"the Guard did not hold condition at full, so the efficiency the figures above assume is wrong"
		)

		--[[ Paid for, every tick, within what `quantise` can resolve — and no
		     more. An input over-charged by a rounding slip is a slow leak
		     nobody notices until a larder empties in half the expected
		     time. ]]
		local mushroomSpent = before[Enums.Resource.Mushroom] - colony.held(Enums.Resource.Mushroom)
		expect.inRange(
			mushroomSpent,
			ticks * math.floor(demand),
			ticks * math.ceil(demand),
			("%d ticks of a working Cook cost %d mushrooms, outside the %d..%d a demand of %.4f can resolve to"):format(
				ticks,
				mushroomSpent,
				ticks * math.floor(demand),
				ticks * math.ceil(demand),
				demand
			)
		)

		--[[ The second input is priced under a whole unit, so it is free on
		     the ticks it rounds down. What must hold is the ceiling: never
		     more than one tick's worth per tick. ]]
		local coalSpent = before[Enums.Resource.Coal] - colony.held(Enums.Resource.Coal)
		expect.inRange(
			coalSpent,
			ticks * math.floor(coalDemand),
			ticks * math.ceil(coalDemand),
			("%d ticks charged %d coal, outside the %d..%d a demand of %.4f can resolve to"):format(
				ticks,
				coalSpent,
				ticks * math.floor(coalDemand),
				ticks * math.ceil(coalDemand),
				coalDemand
			)
		)

		--[[ Storage holds whole positive units and loses the key entirely at
		     zero, the same shape `Inventory.remove` leaves behind. A zero left
		     sitting in the table would ship to the client as a resource the
		     player holds none of. ]]
		for resourceId, amount in pairs(colony.storage()) do
			expect.equal(
				amount % 1,
				0,
				("storage holds %s in fractions of a unit: %f"):format(resourceId, amount)
			)
			expect.greaterThan(amount, 0, ("storage holds a non-positive amount of %s"):format(resourceId))
		end
		colony.server.assertNoErrors(expect, "working job")
	end)

	-- ── What the client is told ──────────────────────────────────────────────

	suite:test("a tick that only spends still tells the client what is left", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local ticks = 20

		--[[ A colony with a consumer and no producer: a Cook eating down
		     mushrooms brought home from an expedition while nobody is on a
		     producing job. Every tick moves storage DOWN and nothing is ever
		     deposited.

		     That is the shape that used to go unreported. A spend writes
		     `storage.items` directly, so no push comes from it; the only push
		     inside the tick is the one in `addToStorage`, guarded on
		     `added > 0`; and the colony snapshot sent afterwards carries no
		     storage. So the player's resource strip, their units line and
		     their recipe list all stayed at whatever was last pushed, and went
		     on being redrawn every ten seconds as though freshly confirmed —
		     until some unrelated action happened to push storage. Nothing in
		     the client re-requests the profile after startup, so sitting still
		     and managing the colony was enough to keep it wrong. ]]
		colony.staffCook(expect, colony.JobConfig.MaxSkill)
		colony.fund(expect, { [Enums.Resource.Mushroom] = 100, [Enums.Resource.Coal] = 100 })

		local unitsBefore = colony.unitsHeld()
		colony.ticks(expect, ticks)

		expect.lessThan(
			colony.unitsHeld(),
			unitsBefore,
			"the Cook ate nothing over this window, so there is no spend here for the client to be told about"
		)

		local pushed = colony.lastStoragePush()
		expect.truthy(
			pushed,
			("%d production ticks spent %d units of storage and sent the client not one inventory packet"):format(
				ticks,
				unitsBefore - colony.unitsHeld()
			)
		)

		--[[ Asserted on `used` and not on `storage`: the harness records the
		     payload by reference and `pushStorage` passes the live profile
		     table, so `storage` aliases the server's own and would match
		     however stale the packet was. `used` is computed at push time and
		     is the one number in there that can be left behind. ]]
		expect.equal(
			pushed.used,
			colony.unitsHeld(),
			("the client was last told the colony holds %s units and it holds %d"):format(
				tostring(pushed.used),
				colony.unitsHeld()
			)
		)
		expect.equal(
			pushed.capacity,
			colony.services.InventoryService:storageCapacity(colony.player),
			"the client's storage capacity is out of date"
		)

		--[[ The companion assertion, and the one that makes the above mean
		     something: the colony snapshot is NOT a storage packet and must
		     never be mistaken for one. If it ever starts carrying storage,
		     this whole test is about a hole that has been filled somewhere
		     else, and it should be reconsidered rather than deleted. ]]
		local snapshot = colony.server.lastPush(colony.player, colony.Routes.Push.ColonySync)
		expect.truthy(snapshot, "the tick sent no colony snapshot either")
		expect.falsy(snapshot.storage, "the colony snapshot now carries storage items")
		expect.falsy(snapshot.used, "the colony snapshot now carries a storage unit count")
		expect.falsy(snapshot.capacity, "the colony snapshot now carries a storage capacity")
		colony.server.assertNoErrors(expect, "spend replication")
	end)

	suite:test(
		"a recipe the colonists ate out of reach is withdrawn before it can be clicked",
		function(expect)
			local colony = newColony()
			local Enums = colony.Enums
			local recipeId = "cook_mushroom"

			--[[ The sharpest consequence of a spend the client is not told about,
		     and the only one that costs the player a click rather than a
		     misread. `recipes[].available` is computed server-side against
		     storage and shipped only with a storage push, and ColonyPanel
		     enables the Craft button from it. A stale packet therefore leaves
		     the button lit for a recipe the colonists have already eaten out
		     of reach — and the refusal that follows does not push storage
		     either, so clicking it again changes nothing. ]]
			local recipe = colony.services.InventoryService:recipeById(recipeId)
			expect.truthy(
				recipe,
				("the %s recipe is gone, so this test has nothing to measure"):format(recipeId)
			)

			colony.staffCook(expect, colony.JobConfig.MaxSkill)

			--[[ Stocked to one unit over the recipe's price. Two ticks cost
		     between two and four mushrooms, so what is left is always under
		     the price and the outcome does not depend on how `quantise`
		     falls. ]]
			local cost = recipe.cost[Enums.Resource.Mushroom]
			expect.truthy(
				cost,
				("%s no longer costs mushrooms, so a Cook cannot price it out of reach"):format(recipeId)
			)
			colony.fund(expect, { [Enums.Resource.Coal] = 20 })
			colony.storage()[Enums.Resource.Mushroom] = cost + 1
			colony.services.InventoryService:pushStorage(colony.player)

			local baseline = colony.recipeIn(colony.lastStoragePush(), recipeId)
			expect.truthy(baseline, ("the storage packet carries no entry for %s"):format(recipeId))
			expect.truthy(
				baseline.available,
				"the colony cannot afford this recipe before the ticks even run, so nothing below is a change"
			)

			colony.ticks(expect, 2)

			expect.lessThan(
				colony.held(Enums.Resource.Mushroom),
				cost,
				"two ticks left the colony still able to afford the recipe, so the setup did not bite"
			)

			local pushed = colony.lastStoragePush()
			local offered = colony.recipeIn(pushed, recipeId)
			expect.truthy(
				offered,
				"the colonists ate the recipe out of reach and the client was never sent a new recipe list"
			)
			expect.falsy(
				offered.available,
				"the client is still being offered a recipe the colony can no longer pay for, so the Craft button is lit for a click the server will refuse"
			)

			--[[ And the other half of the agreement: the server really would
		     refuse it. Asserting the panel's flag alone would pass just as
		     well if the flag were wrong in the other direction. ]]
			local crafted =
				colony.server.invoke(colony.player, colony.Routes.Request.Craft, { recipeId = recipeId })
			expect.falsy(
				crafted.ok,
				"the craft succeeded, so the client was right and this test is asserting the wrong agreement"
			)
			colony.server.assertNoErrors(expect, "recipe availability")
		end
	)

	suite:test(
		"the food rate the client is shown is the buildings' figure, not the colony's",
		function(expect)
			local colony = newColony()
			local Enums = colony.Enums
			local ticks = 20

			--[[ A colony that is quietly running down: one Farmer, one Guard, one
		     colonist left idle, on a Farm at level 1. The buildings grow 3
		     food a tick and the roster eats 3.1, so the larder falls — while
		     the only food-rate figure in the snapshot, `foodPerTick`, is the
		     buildings' growth alone and reads +3.

		     That number is correct for what it is. The defect was in the
		     client presenting it as a net: ColonyPanel printed it as "Food per
		     tick" with a signed format, next to the stored figure, which is
		     exactly how a player decides whether their colony feeds itself.
		     The row now names its source. This test pins the gap so nobody
		     relabels it back without seeing what the field actually holds —
		     and pins the real rate, which nothing outside the tick
		     computes. ]]
			colony.place(expect, Enums.Building.Farm, 0, 9)
			colony.assign(expect, 1, Enums.Job.Farmer)
			colony.assign(expect, 2, Enums.Job.Guard)

			local effects = colony.effects()
			expect.equal(effects.productionMult, 1, "a production bonus would move the figures below")
			local foodUse = colony.foodUsePerTick()
			local foodBefore = colony.profile().colony.food

			--[[ No job on this roster has a `foodValuePerTick`, so the colony's
		     real rate has no efficiency term in it at all and is exact. ]]
			for _, colonist in ipairs(colony.colonists()) do
				expect.falsy(
					colony.JobConfig.get(colonist.job).foodValuePerTick,
					("%s adds food value, so the rate below is no longer exact"):format(colonist.job)
				)
			end

			colony.ticks(expect, ticks)

			local expectedFood = replay(foodBefore, ticks, function(food)
				return math.max(0, food + ((effects.foodPerTick or 0) - foodUse))
			end)
			expect.equal(
				colony.profile().colony.food,
				expectedFood,
				"the larder did not move by exactly the buildings' growth minus what the roster eats"
			)

			local snapshot = colony.server.lastPush(colony.player, colony.Routes.Push.ColonySync)
			expect.truthy(snapshot, "the colony sent no snapshot over this window")

			local measured = (colony.profile().colony.food - foodBefore) / ticks
			expect.lessThan(
				measured,
				0,
				"this colony is not running its larder down, so there is no disagreement here to pin"
			)
			expect.equal(
				snapshot.foodPerTick,
				effects.foodPerTick,
				"the snapshot's foodPerTick is no longer the buildings' figure — if it now carries the colony's net rate, ColonyPanel's label should go back to saying so"
			)
			expect.greaterThan(
				snapshot.foodPerTick,
				0,
				"the buildings in this colony no longer grow food, so the two figures no longer disagree in sign"
			)
			colony.server.assertNoErrors(expect, "food rate")
		end
	)

	-- ── The tick's own arithmetic ────────────────────────────────────────────

	suite:test(
		"a tick wears the colony down by exactly its decay, and a Guard holds it at full",
		function(expect)
			local colony = newColony()
			local NPC = colony.NPC
			local ticks = 20

			--[[ Nobody assigned and nothing built beyond the granted Town Hall, so
		     the only thing touching condition is the decay. Both arms are
		     computed from config, so a retune moves them rather than breaking
		     them. ]]
			local conditionBefore = colony.profile().colony.condition
			local researchBefore = colony.profile().colony.research or 0
			local foodBefore = colony.profile().colony.food
			local foodUse = colony.foodUsePerTick()
			expect.greaterThan(
				foodBefore - foodUse * ticks,
				0,
				"this colony starves inside the window, and a starvation penalty would be charged on top of the decay"
			)

			colony.ticks(expect, ticks)

			local decay = (NPC.ConditionDecayPerHour / 3600) * NPC.ProductionTickSeconds
			local expectedCondition = replay(conditionBefore, ticks, function(condition)
				return math.clamp(condition - decay, NPC.ConditionFloor, NPC.ConditionMax)
			end)
			expect.equal(
				colony.profile().colony.condition,
				expectedCondition,
				("%d ticks with nobody repairing moved condition to %.6f rather than the configured %.6f"):format(
					ticks,
					colony.profile().colony.condition,
					expectedCondition
				)
			)

			--[[ Research is granted only by the Researcher and by the Research
		     Lab's effects, and the Lab is not implemented — so the Researcher
		     has no building to require and research cannot move at all. The
		     assertion is equality, which is what would catch a job crediting
		     it by accident. ]]
			expect.equal(
				colony.profile().colony.research or 0,
				researchBefore,
				"research moved in a colony with no Research Lab, which no reachable job can do"
			)

			--[[ The other arm: one Guard out-repairs the decay several times over,
		     so condition sits at the ceiling rather than merely falling more
		     slowly. That is what pins `conditionFactor` to exactly 1 for every
		     test in this file that asserts an exact efficiency. ]]
			local repaired = newColony("Bram")
			repaired.assign(expect, 1, repaired.Enums.Job.Guard)
			repaired.ticks(expect, ticks)
			expect.equal(
				repaired.profile().colony.condition,
				NPC.ConditionMax,
				("a Guard on the roster let condition fall to %.6f"):format(
					repaired.profile().colony.condition
				)
			)
			colony.server.assertNoErrors(expect, "bare decay")
			repaired.server.assertNoErrors(expect, "guarded decay")
		end
	)

	suite:test(
		"a worked tick teaches exactly one job's skillGain, and an idle one teaches nothing",
		function(expect)
			local colony = newColony()
			local Enums, JobConfig = colony.Enums, colony.JobConfig
			local ticks = 20

			--[[ A Farmer, because it consumes nothing: it works on every tick
		     without the larder deciding anything, so the skill curve is the
		     only variable. The Guard beside it keeps condition at the ceiling,
		     which matters because `globalMult` would otherwise change the
		     efficiency every tick — skill gain is flat and unscaled, but the
		     colonist beside it is the control for that. ]]
			colony.place(expect, Enums.Building.Farm, 0, 9)
			local farmer = colony.assign(expect, 1, Enums.Job.Farmer)
			colony.assign(expect, 2, Enums.Job.Guard)

			local idle = colony.colonists()[3]
			expect.equal(
				idle.job,
				Enums.Job.Idle,
				"the third colonist is not idle, so there is no control here"
			)

			local skillBefore = farmer.skill
			local idleSkillBefore = idle.skill
			local buildingsBefore = #colony.profile().colony.buildings
			local population = #colony.colonists()

			colony.ticks(expect, ticks)

			--[[ Iterated, not multiplied: `math.min(MaxSkill, skill + gain)` is
		     applied once per worked tick, and twenty applications of +0.05
		     from 1 land on 2.0000000000000009 while `1 + 20 * 0.05` lands on
		     2.0. The closed form would fail here for a reason that has nothing
		     to do with the game. ]]
			local gain = JobConfig.get(Enums.Job.Farmer).skillGain
			local expectedSkill = replay(skillBefore, ticks, function(skill)
				return math.min(JobConfig.MaxSkill, skill + gain)
			end)
			expect.equal(
				farmer.skill,
				expectedSkill,
				("%d worked ticks took a Farmer to skill %.17g rather than the configured %.17g"):format(
					ticks,
					farmer.skill,
					expectedSkill
				)
			)
			expect.atMost(
				farmer.skill,
				JobConfig.MaxSkill,
				"a colonist's skill went past the ceiling, which would scale their output without limit"
			)
			expect.equal(
				idle.skill,
				idleSkillBefore,
				"an unassigned colonist learned a trade by standing around, which would let a player train a workforce for free"
			)

			--[[ And the tick writes only skill, health and storage: it never
		     inserts or removes a colonist or a building. A tick that loses one
		     is a player's progress gone with nothing on screen to explain
		     it. ]]
			expect.equal(#colony.colonists(), population, "a production tick cost the colony a colonist")
			expect.equal(
				#colony.profile().colony.buildings,
				buildingsBefore,
				"a production tick changed how many buildings the colony has"
			)
			colony.server.assertNoErrors(expect, "skill gain")
		end
	)
end
