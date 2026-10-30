--[[
	Offline.spec.lua
	Offline production: what the colony does while nobody is watching, and what
	the player is told about it when they come back.

	Why this layer needs covering
	─────────────────────────────
	`NPCService:_settleOffline` is the one piece of the game that runs for time
	the player was not present for. Nothing about it is observable from a unit
	test, because it is defined entirely by the gap between two wall-clock
	stamps stored in a profile — and until `tools/sim.luau` grew
	`advanceWallClock`, nothing in the simulation could produce that gap either.
	Advancing the simulation instead would have run thousands of ONLINE
	production ticks and so tested the opposite code path.

	What makes it worth covering is what it hands out: up to eight hours of
	resources, granted in one go, at a moment the player cannot see coming. Two
	ways that goes wrong, and both of them are the same bug twice —

	  --  the absence is paid more than once. A rejoin loop would then be a
	      resource printer, which is the duplication exploit the brief is
	      explicit about.

	  --  the player is TOLD they were paid when they were not. A notice that
	      over-reports is the same class of lie as a save that only reached
	      RAM being acknowledged: both leave someone counting on resources that
	      are not there. Two of these were live when this spec was written —
	      the notice read out the simulated figure rather than what the colony
	      storage cap actually let through, and a read-only session was settled
	      and announced in full despite nothing it did ever being written.

	So the assertions here come in pairs: what moved in the profile, and what
	the player was told moved.

	What this cannot reach
	──────────────────────
	`os.clock()` and `os.time()` are deliberately decoupled by the harness, as
	they are across a real rejoin onto a different server. That is faithful for
	the gap itself but it means nothing here proves the engine stamps
	`os.time()` the way the simulation does, and a real DataStore round trip
	between the two sessions is still only covered by SETUP.md §5.

	Each test builds its own server, so nothing leaks between them.
]]

return function(suite, context)
	local newServer = context.newServer

	local MINUTE = 60
	local HOUR = 60 * 60

	--[[ The key format DataService stores profiles under; see its keyFor(). ]]
	local KEY_PREFIX = "player_"

	--[[ The title of the offline notice, which is also the only thing
	     identifying it among the pushes on a join. If it is ever reworded, this
	     line is what has to move with it. ]]
	local AWAY_TITLE = "While you were away"

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
			Migrations = server.require(server.shared.Data.Migrations),
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

		--[[ Measured through the same function the storage cap is measured with,
		     consumables included, so a test comparing this against the capacity
		     is comparing like with like. ]]
		function colony.unitsHeld()
			return colony.Inventory.totalUnits(server.services.InventoryService:storageOf(colony.player))
		end

		function colony.colonists()
			return colony.profile().colony.colonists
		end

		function colony.capacity()
			return server.services.InventoryService:storageCapacity(colony.player)
		end

		-- ── Routes, as the client would call them ──────────────────────────

		function colony.place(buildingId, gx, gz)
			return server.invoke(colony.player, colony.Routes.Request.PlaceBuilding, {
				buildingId = buildingId,
				gx = gx,
				gz = gz,
				rot = 0,
			})
		end

		function colony.assign(colonistUid, jobId)
			return server.invoke(colony.player, colony.Routes.Request.AssignJob, {
				uid = colonistUid,
				job = jobId,
			})
		end

		-- ── The written record, as opposed to what is held in memory ────────

		function colony.store()
			return server.dataStores[colony.GameConfig.DataStoreName]
		end

		function colony.record()
			local store = colony.store()
			return store and store.data[KEY_PREFIX .. colony.player.UserId]
		end

		-- ── Leaving and coming back ────────────────────────────────────────

		function colony.leave()
			server.disconnect(colony.player)
		end

		--[[ `seconds` of wall-clock time pass with this server doing nothing,
		     then the same account comes back. See scheduler.jumpWallClock in
		     tools/sim.luau for why the two clocks part company here. ]]
		function colony.returnAfter(seconds)
			server.advanceWallClock(seconds)
			colony.player = server.rejoin(colony.player)
			return colony.player
		end

		--[[ Away and back. Pushes are cleared at the moment of departure, so
		     everything a test reads afterwards belongs to the return. ]]
		function colony.away(seconds)
			colony.leave()
			server.clearPushes()
			return colony.returnAfter(seconds)
		end

		--[[ The offline notice, or nil. Found by title rather than position so
		     an unrelated notice on the same join cannot shift it. ]]
		function colony.awayNotice()
			for _, notice in ipairs(server.pushes(colony.player, colony.Routes.Push.Notify)) do
				if notice.title == AWAY_TITLE then
					return notice
				end
			end
			return nil
		end

		--[[ What the notice claims was produced of one resource, read back out
		     of the sentence the player sees. The resource's display name comes
		     from config rather than being written in here, so renaming a
		     resource moves the expectation with it. ]]
		function colony.reportedGain(resourceId)
			local notice = colony.awayNotice()
			if not notice or type(notice.body) ~= "string" then
				return nil
			end
			local def = colony.ResourceConfig.get(resourceId)
			local name = def and def.name or resourceId
			return tonumber(string.match(notice.body, name .. "%s*%+(%d+)"))
		end

		--[[ Top storage up to `target` total units, spread over whatever will
		     still take some. No single resource can do it: every one of them has
		     a per-stack limit well under the colony's capacity, so filling with
		     stone alone stops at 200 and the cap is never reached. `skip` leaves
		     a resource alone when a test needs its stack to stay open — so that
		     what truncates a deposit is the colony cap and not the stack. ]]
		function colony.fillTo(expect, target, skip)
			skip = skip or {}
			for resourceId in pairs(colony.ResourceConfig.Resources) do
				local short = target - colony.unitsHeld()
				if short <= 0 then
					break
				end
				if not skip[resourceId] then
					colony.services.InventoryService:addToStorage(colony.player, resourceId, short)
				end
			end
			expect.equal(
				colony.unitsHeld(),
				target,
				"storage could not be topped up to the brim, so nothing below is testing the cap"
			)
		end

		--[[ A Farm with one Farmer in it: the smallest colony that produces
		     anything at all, and the only setup most of these tests need. ]]
		function colony.staff(expect)
			local placed = colony.place(colony.Enums.Building.Farm, 0, 9)
			expect.truthy(placed.ok, "the Farm was refused: " .. tostring(placed.reason))
			local assigned = colony.assign(colony.colonists()[1].uid, colony.Enums.Job.Farmer)
			expect.truthy(assigned.ok, "the Farmer was refused: " .. tostring(assigned.reason))
			return colony
		end

		return colony
	end

	-- ── The grant ────────────────────────────────────────────────────────────

	suite:test("a colonist works through an absence and the colony is richer for it", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		colony.staff(expect)

		local before = colony.held(Enums.Resource.Mushroom)
		colony.away(2 * HOUR)

		expect.greaterThan(
			colony.held(Enums.Resource.Mushroom),
			before,
			"two hours of absence with a Farmer on the roster produced nothing"
		)

		--[[ And the clock is reset to NOW, which is what stops the same two
		     hours being paid again on the next join. ]]
		expect.equal(
			colony.profile().colony.lastProductionAt,
			colony.server.wallClock(),
			"the production clock was not moved up to the moment the absence was settled"
		)

		local notice = colony.awayNotice()
		expect.truthy(notice, "the colony produced while the player was away and never told them")
		expect.equal(
			colony.reportedGain(Enums.Resource.Mushroom),
			colony.held(Enums.Resource.Mushroom) - before,
			"the notice reports a different number of mushrooms than storage actually gained"
		)
		colony.server.assertNoErrors(expect, "offline grant")
	end)

	suite:test("an unstaffed colony produces nothing over the same absence", function(expect)
		local colony = newColony()
		local Enums = colony.Enums

		--[[ The Farm is built but nobody is put in it, so anything that appears
		     in storage came from the settle itself rather than from the
		     roster. ]]
		expect.truthy(colony.place(Enums.Building.Farm, 0, 9).ok, "the Farm was refused")

		local before = colony.unitsHeld()
		colony.away(2 * HOUR)

		expect.equal(
			colony.unitsHeld(),
			before,
			"an absence produced resources with nobody assigned to produce them"
		)

		--[[ The player is still told what happened, because two hours DID pass
		     and their colony's condition moved with them. The body is the one
		     that promises nothing. ]]
		local notice = colony.awayNotice()
		expect.truthy(notice, "two hours passed and the player was told nothing at all")
		expect.falsy(
			colony.reportedGain(Enums.Resource.Mushroom),
			"the notice credits mushrooms to a Farm that had nobody working it"
		)
		colony.server.assertNoErrors(expect, "unstaffed absence")
	end)

	suite:test(
		"the first snapshot a returning player gets already has the settled colony in it",
		function(expect)
			local colony = newColony()
			colony.staff(expect)

			local conditionBefore = colony.profile().colony.condition
			colony.away(2 * HOUR)

			--[[ The settle runs inside profileLoaded, and ColonyService pushes the
		     first snapshot in that same handler. If the order ever inverts, the
		     returning player's screen shows the colony as they left it and goes
		     on showing it until some later push happens to correct it — the
		     same bug `BuildingService:_afterChange` had after a demolition.

		     Condition is the probe rather than food: a staffed Farm's foodPerTick
		     outpaces three colonists eating, so food RISES over an absence and a
		     `lessThan` on it would fail for a reason that has nothing to do with
		     ordering. Condition only ever decays while nobody is assigned to
		     repair it. ]]
			local first = colony.server.pushes(colony.player, colony.Routes.Push.ColonySync)[1]
			expect.truthy(first, "a returning player got no colony snapshot at all")

			expect.lessThan(
				first.condition,
				conditionBefore,
				"the first snapshot still shows the condition the colony had before the absence, so the settle landed after the push"
			)
			expect.equal(
				first.condition,
				colony.profile().colony.condition,
				"the first snapshot disagrees with the profile about condition"
			)
			expect.equal(
				first.food,
				colony.profile().colony.food,
				"the first snapshot disagrees with the profile about food"
			)

			--[[ The store and the expedition bag share the InventorySync route and
		     each push is a partial payload — pushBag carries `bagUsed` and no
		     `used` at all — so the store's push is the last one that reports
		     `used`, not simply the last one sent.

		     `used` is also the only field in that payload computed at push time:
		     `storage` is the live profile table, so comparing THAT would pass
		     however late the push went out. ]]
			local storagePush
			for _, payload in ipairs(colony.server.pushes(colony.player, colony.Routes.Push.InventorySync)) do
				if payload.used ~= nil then
					storagePush = payload
				end
			end
			expect.truthy(storagePush, "a returning player was never sent the contents of their store")
			expect.equal(
				storagePush.used,
				colony.unitsHeld(),
				"the storage the client was left holding does not add up to what the colony has"
			)
			colony.server.assertNoErrors(expect, "settle ordering")
		end
	)

	-- ── Paid once, and only once ─────────────────────────────────────────────

	suite:test("rejoining twice does not pay for the same absence twice", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		colony.staff(expect)

		--[[ Short absences deliberately. Two hours of a Farmer fills a colony
		     store to its cap, and a third absence with nowhere to put anything
		     would look exactly like a grant that never happened. ]]
		colony.away(5 * MINUTE)
		local afterFirst = colony.held(Enums.Resource.Mushroom)
		local settledAt = colony.profile().colony.lastProductionAt
		expect.greaterThan(afterFirst, 0, "the first absence paid nothing, so this test proves nothing")

		--[[ Straight back out and in with no time passing. A rejoin loop that
		     pays each time is a resource printer. ]]
		colony.away(0)
		expect.equal(
			colony.held(Enums.Resource.Mushroom),
			afterFirst,
			"the same absence was paid a second time on an immediate rejoin"
		)
		expect.falsy(colony.awayNotice(), "the player was told they had been away when no time had passed")
		expect.equal(
			colony.profile().colony.lastProductionAt,
			settledAt,
			"a rejoin with nothing owed still moved the production clock"
		)

		--[[ And the guard is not simply "never pay twice": a genuine second
		     absence is still paid. ]]
		colony.away(5 * MINUTE)
		expect.greaterThan(
			colony.held(Enums.Resource.Mushroom),
			afterFirst,
			"a second, real absence was not paid at all"
		)
		colony.server.assertNoErrors(expect, "double payment")
	end)

	suite:test(
		"an absence longer than the cap is paid at the cap, and the rest is not banked",
		function(expect)
			local colony = newColony()
			local Enums = colony.Enums
			local cap = colony.NPC.OfflineProductionMaxHours
			colony.staff(expect)

			colony.away(5 * cap * HOUR)

			local notice = colony.awayNotice()
			expect.truthy(notice, "a very long absence produced no notice at all")

			local hours = tonumber(string.match(notice.detail or "", "([%d%.]+)%s+hours"))
			expect.truthy(
				hours,
				"the notice does not say how long the colony worked: " .. tostring(notice.detail)
			)
			expect.near(
				hours,
				cap,
				0.05,
				("an absence of %d hours was paid as %s, not capped at %d"):format(
					5 * cap,
					tostring(hours),
					cap
				)
			)

			--[[ The hours beyond the cap are DISCARDED rather than carried
		     forward. Banking them would turn a long absence into an annuity
		     paid out one rejoin at a time, which is the cap's whole purpose
		     defeated on a delay. ]]
			local held = colony.held(Enums.Resource.Mushroom)
			expect.equal(
				colony.profile().colony.lastProductionAt,
				colony.server.wallClock(),
				"the production clock was left behind the present, so the uncapped remainder is still owed"
			)

			colony.away(0)
			expect.equal(
				colony.held(Enums.Resource.Mushroom),
				held,
				"the hours past the cap were banked and paid out on the next join"
			)
			colony.server.assertNoErrors(expect, "offline cap")
		end
	)

	suite:test("an absence pays less than being there for it", function(expect)
		local absence = 10 * MINUTE
		local Enums = newColony("Probe").Enums

		--[[ Two colonies, the same length of time, the same work: one with the
		     player present for all of it, one with the player away for all of
		     it.

		     The bound is a wide band rather than a ratio, and it has to be. Both
		     servers seed NPCService's RNG from the same clock, but the one with a
		     player present spends draws on rig movement between production ticks
		     — `_updateRigs` pulls from the same `self._rng` — so the two streams
		     part company immediately. Production is quantised through those draws,
		     so an exact multiple would be asserting against a stream rather than
		     against the rule. Half of a hundred-odd mushrooms is many standard
		     deviations clear of the band either way. ]]
		local present = newColony("Alice")
		present.staff(expect)
		local presentBefore = present.held(Enums.Resource.Mushroom)
		present.server.advance(absence, 1)
		local presentGain = present.held(Enums.Resource.Mushroom) - presentBefore

		local absent = newColony("Alice")
		absent.staff(expect)
		local absentBefore = absent.held(Enums.Resource.Mushroom)
		absent.away(absence)
		local absentGain = absent.held(Enums.Resource.Mushroom) - absentBefore

		expect.greaterThan(presentGain, 0, "ten minutes of being there produced nothing to compare against")
		expect.greaterThan(absentGain, 0, "ten minutes of absence produced nothing at all")
		expect.lessThan(
			absentGain,
			presentGain,
			("being away paid %d mushrooms against %d for being there, so offline is not reduced at all"):format(
				absentGain,
				presentGain
			)
		)
		expect.greaterThan(
			absentGain,
			presentGain / 4,
			("being away paid %d against %d, far below the %d%% the config promises"):format(
				absentGain,
				presentGain,
				math.floor(absent.NPC.OfflineProductionEfficiency * 100)
			)
		)
		present.server.assertNoErrors(expect, "online run")
		absent.server.assertNoErrors(expect, "offline run")
	end)

	-- ── Inputs, and the limits of storage ────────────────────────────────────

	suite:test("an absence only ever produces what the roster's jobs produce", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		colony.staff(expect)

		--[[ What a Farmer makes, straight out of JobConfig. The set of resources
		     that may move over this absence is exactly that: a production map
		     written against the wrong key, or a job crediting something it has no
		     business making, shows up here as a resource outside the set
		     changing. Nothing on this roster consumes anything, so nothing may
		     go DOWN either.

		     The matching invariant for a job that cannot pay its inputs is not
		     reachable from this spec: offline efficiency holds every per-tick
		     input under one whole unit, so quantisation sometimes asks for
		     nothing and the job legitimately works for free. That one belongs
		     with online production, where the scale is 1. ]]
		local produces = colony.JobConfig.get(Enums.Job.Farmer).produces
		expect.truthy(next(produces), "a Farmer produces nothing, so this test cannot show anything")

		local before = {}
		for resourceId in pairs(colony.ResourceConfig.Resources) do
			before[resourceId] = colony.held(resourceId)
		end

		colony.away(30 * MINUTE)

		local grew = {}
		for resourceId in pairs(colony.ResourceConfig.Resources) do
			local held = colony.held(resourceId)
			expect.atLeast(held, 0, ("storage holds a negative amount of %s"):format(resourceId))
			if held > before[resourceId] then
				grew[resourceId] = true
			elseif held < before[resourceId] then
				expect.fail(
					("%s was spent over an absence in which no job on the roster consumes it"):format(
						resourceId
					)
				)
			end
		end

		for resourceId in pairs(grew) do
			expect.truthy(
				produces[resourceId],
				("%s appeared over an absence and nothing on the roster produces it"):format(resourceId)
			)
		end
		for resourceId in pairs(produces) do
			expect.truthy(
				grew[resourceId],
				("a Farmer worked half an hour and produced no %s at all"):format(resourceId)
			)
		end
		colony.server.assertNoErrors(expect, "production map")
	end)

	suite:test("offline production never pushes storage past its capacity", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		colony.staff(expect)

		--[[ Filled to five units short of the cap first, so the eight hours
		     below have to be truncated rather than merely fitting. The Farmer's
		     own outputs are left out of the fill, so their stacks stay open and
		     it is the colony cap that stops the deposit. ]]
		local capacity = colony.capacity()
		colony.fillTo(expect, capacity - 5, colony.JobConfig.get(Enums.Job.Farmer).produces)

		local mushroomsBefore = colony.held(Enums.Resource.Mushroom)
		colony.away(8 * HOUR)

		expect.atMost(
			colony.unitsHeld(),
			capacity,
			("eight hours of offline production put %d units into a store that holds %d"):format(
				colony.unitsHeld(),
				capacity
			)
		)

		--[[ And the notice reports what was KEPT, not what was made. Eight
		     hours of a Farmer is thousands of mushrooms and the cap let five
		     units through; the notice used to read out the thousands. A
		     returning player who checks that number against their own store
		     has to find it there. ]]
		local gained = colony.held(Enums.Resource.Mushroom) - mushroomsBefore
		local reported = colony.reportedGain(Enums.Resource.Mushroom)
		if gained > 0 then
			expect.equal(
				reported,
				gained,
				("the notice promised %s mushrooms and storage took %d"):format(tostring(reported), gained)
			)
		else
			expect.falsy(reported, "the notice credited mushrooms that a full store never accepted")
		end
		colony.server.assertNoErrors(expect, "storage cap")
	end)

	-- ── What the absence costs ───────────────────────────────────────────────

	suite:test("an absence eats food and wears the colony down by exactly its decay", function(expect)
		local colony = newColony()
		local NPC = colony.NPC
		local ticks = 20
		local population = #colony.colonists()

		--[[ Nobody is assigned, so there is no production to muddy the
		     arithmetic: every colonist eats at the idle rate and the only thing
		     touching condition is the decay. Both expectations are computed
		     from config, so a retune moves them rather than breaking them. ]]
		local idleFoodUse = colony.JobConfig.get(colony.Enums.Job.Idle).foodUse
		local foodBefore = colony.profile().colony.food
		local conditionBefore = colony.profile().colony.condition
		local expectedEaten = idleFoodUse * population * ticks
		expect.lessThan(expectedEaten, foodBefore, "this test needs an absence the colony can afford to eat")

		colony.away(ticks * NPC.ProductionTickSeconds)

		expect.near(
			colony.profile().colony.food,
			foodBefore - expectedEaten,
			0.01,
			("%d colonists over %d ticks should have eaten %.1f food"):format(
				population,
				ticks,
				expectedEaten
			)
		)

		local decay = (NPC.ConditionDecayPerHour / 3600) * NPC.ProductionTickSeconds * ticks
		expect.near(
			colony.profile().colony.condition,
			conditionBefore - decay,
			0.01,
			"condition did not fall by exactly the configured decay over the absence"
		)

		expect.equal(
			#colony.colonists(),
			population,
			"a colonist was lost to an absence, which is never supposed to happen"
		)
		colony.server.assertNoErrors(expect, "absence costs")
	end)

	suite:test("no run of absences can take the colony below its condition floor", function(expect)
		local colony = newColony()
		local NPC = colony.NPC
		local population = #colony.colonists()

		--[[ Four maximum-length absences with nobody working and nothing to
		     eat. Starvation costs condition on top of the decay, so this is the
		     worst case the game can produce — and it has to bottom out at the
		     floor rather than at zero. A colony that can be lost by not logging
		     in is a colony nobody comes back to. ]]
		for _ = 1, 4 do
			colony.away((NPC.OfflineProductionMaxHours + 1) * HOUR)
		end

		expect.equal(colony.profile().colony.food, 0, "four maximum absences did not exhaust the larder")
		expect.equal(
			colony.profile().colony.condition,
			NPC.ConditionFloor,
			"repeated absences did not settle on the condition floor"
		)
		expect.equal(#colony.colonists(), population, "absence cost the colony a colonist")
		expect.truthy(colony.profile().colony.buildings[1], "absence demolished the colony's buildings")
		colony.server.assertNoErrors(expect, "condition floor")
	end)

	suite:test("colonists learn across an absence, and never past the skill ceiling", function(expect)
		local colony = newColony()
		colony.staff(expect)

		local uid = colony.colonists()[1].uid
		local function skillOf()
			for _, colonist in ipairs(colony.colonists()) do
				if colonist.uid == uid then
					return colonist.skill
				end
			end
			return nil
		end

		expect.equal(skillOf(), 1, "a fresh colonist is supposed to start at skill 1")
		colony.away(8 * HOUR)

		--[[ Skill is the one thing a tick grants that is NOT scaled by the
		     offline efficiency, so a single long absence takes a worker to the
		     ceiling — the thirty-minute ramp the curve describes is skipped
		     whole. Whether that is the intended reading of
		     OfflineProductionEfficiency is a balance question, recorded in
		     DEVELOPMENT_STATUS rather than decided here; what is asserted is
		     the invariant, which is that it stops at the ceiling. ]]
		expect.greaterThan(skillOf(), 1, "a colonist worked for eight hours and learned nothing")
		expect.atMost(
			skillOf(),
			colony.JobConfig.MaxSkill,
			"a colonist's skill went past the ceiling, which would scale their output without limit"
		)

		local worked = skillOf()
		colony.away(8 * HOUR)
		expect.atMost(skillOf(), colony.JobConfig.MaxSkill, "a second absence pushed skill past the ceiling")
		expect.atLeast(skillOf(), worked, "a colonist forgot their trade over an absence")
		colony.server.assertNoErrors(expect, "skill ceiling")
	end)

	-- ── What survives, and what must not be promised ─────────────────────────

	suite:test("a colony settled on a rejoin is written, not just handed over", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		colony.staff(expect)

		colony.away(2 * HOUR)
		local granted = colony.held(Enums.Resource.Mushroom)
		expect.greaterThan(granted, 0, "the absence paid nothing, so there is nothing to persist")

		--[[ Leaving is what banks it. Until the release save lands, the grant
		     exists only in this server's memory — which is exactly the state a
		     read-only session is stuck in permanently, and the next test. ]]
		colony.leave()

		local record = colony.record()
		expect.truthy(record, "nothing was ever written for this player")
		expect.equal(
			record.colony.storage[Enums.Resource.Mushroom],
			granted,
			"the offline production was granted in memory and never written"
		)
		expect.equal(
			record.colony.lastProductionAt,
			colony.server.wallClock(),
			"the written production clock is behind the grant it was paid for, so the absence is owed again"
		)
		colony.server.assertNoErrors(expect, "persisted grant")
	end)

	suite:test("a read-only session is never told it earned anything", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		colony.staff(expect)
		colony.leave()

		--[[ A profile saved by a NEWER build than this one. Migrations refuses
		     to touch it — downgrading would delete whatever the newer build
		     added — and DataService hands the player a read-only session
		     carrying the real stored data, including its real lastProductionAt.
		     That is the one path that reaches `_settleOffline` with an absence
		     to pay and no way to ever bank it. A rollback after a schema bump
		     is precisely when it happens.

		     Numbers are snapshotted rather than the tables: the simulated store
		     hands back the live table, so a comparison against `record()` after
		     the fact could be comparing a table with itself. ]]
		local record = colony.record()
		expect.truthy(record, "nothing was written, so there is no record to make unreadable")
		record.version = colony.Migrations.Target + 1

		local storedMushrooms = record.colony.storage[Enums.Resource.Mushroom] or 0
		local storedProducedAt = record.colony.lastProductionAt
		local storedBuildings = #record.colony.buildings

		colony.server.clearPushes()
		colony.returnAfter(4 * HOUR)

		expect.truthy(
			colony.services.DataService:isReadOnly(colony.player),
			"a profile from a newer build was loaded for writing, which is a far worse bug than this test is for"
		)

		--[[ It really is the stored profile, not the fresh template a
		     locked-out session gets — otherwise there would be no absence here
		     to wrongly pay for and this test would pass on nothing. ]]
		expect.equal(
			#colony.profile().colony.buildings,
			storedBuildings,
			"this read-only session is holding a fresh template, so it has no absence to settle"
		)

		expect.equal(
			colony.held(Enums.Resource.Mushroom),
			storedMushrooms,
			"four hours of production was granted into a session that will never be written"
		)
		expect.falsy(
			colony.awayNotice(),
			"the player was told their colonists had produced resources that cannot be saved"
		)

		--[[ And the absence is still OWED: leaving lastProductionAt alone is
		     what lets the next session that can write pay it in full. ]]
		expect.equal(
			colony.profile().colony.lastProductionAt,
			storedProducedAt,
			"the production clock was moved up in a session that cannot save it, so the absence is now lost"
		)
		colony.server.assertNoErrors(expect, "read-only settle")
	end)

	suite:test("a read-only session is not simulated while the player is there either", function(expect)
		local colony = newColony()
		colony.staff(expect)
		colony.leave()

		--[[ The same tampered record as the test above — a profile from a newer
		     build, refused by Migrations, loaded read-only with its real data.
		     That test covers the absence being paid at LOAD. This one covers the
		     rest of the session: the online production tick fires every ten
		     seconds and gated on `isLoaded` alone, which does not consider
		     readOnly, so a read-only colony spent storage, banked output and
		     advanced food, condition, research and skill for as long as the
		     player stayed, pushed every bit of it to the client, and wrote none
		     of it. Hours of visible progress, gone at the door. ]]
		local record = colony.record()
		expect.truthy(record, "nothing was written, so there is no record to make unreadable")
		record.version = colony.Migrations.Target + 1

		colony.returnAfter(0)
		expect.truthy(
			colony.services.DataService:isReadOnly(colony.player),
			"a profile from a newer build was loaded for writing, which is a far worse bug than this test is for"
		)

		--[[ Snapshotted AFTER the rejoin, so the offline settle — correctly
		     skipped, and covered above — is not what gets measured. Condition
		     is the probe: with no Guard on the roster it decays on every
		     simulated tick and nothing else touches it, so any movement at all
		     means a tick ran. Food is the second witness. ]]
		local conditionBefore = colony.profile().colony.condition
		local foodBefore = colony.profile().colony.food
		colony.server.clearPushes()

		--[[ Positive control: a WRITABLE session on the same server, over the
		     same ticks. If it does not move either, the ticks never ran — or ran
		     and threw — and "nothing moved" below would be true for the wrong
		     reason. ]]
		local bob = colony.server.addPlayer("Bob")
		local bobBefore = colony.services.DataService:get(bob).colony.condition

		local ticks = 12
		colony.server.advance(ticks * colony.NPC.ProductionTickSeconds + 1, 1)

		expect.equal(
			colony.profile().colony.condition,
			conditionBefore,
			("%d production ticks ran against a session that will never be written"):format(ticks)
		)
		expect.equal(
			colony.profile().colony.food,
			foodBefore,
			"the larder moved in a session that cannot save it"
		)
		expect.equal(
			#colony.server.pushes(colony.player, colony.Routes.Push.ColonySync),
			0,
			"the client was shown colony progress that is thrown away the moment they leave"
		)
		expect.truthy(
			colony.services.DataService:get(bob).colony.condition < bobBefore,
			"the writable session on the same server did not decay either, so the ticks never ran and the assertions above prove nothing"
		)
		colony.server.assertNoErrors(expect, "read-only online tick")
	end)

	suite:test("a colony that has never produced starts its clock instead of paying out", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		colony.staff(expect)

		--[[ `lastProductionAt` is stamped when a profile is created, so zero
		     only turns up in a profile old enough to predate the field. Paying
		     an absence measured from the epoch would hand that player the full
		     cap for having been away since 1970. ]]
		colony.profile().colony.lastProductionAt = 0
		colony.services.DataService:markDirty(colony.player)
		--[[ Read before leaving: the profile goes with the player, and
		     `colony.held` would be reading a nil profile after the release. ]]
		local before = colony.held(Enums.Resource.Mushroom)
		colony.leave()
		expect.equal(colony.record().colony.lastProductionAt, 0, "the zeroed clock was not written")

		colony.server.clearPushes()
		colony.returnAfter(4 * HOUR)

		expect.equal(
			colony.held(Enums.Resource.Mushroom),
			before,
			"a profile with no production clock was paid as though it had been away for ever"
		)
		expect.falsy(colony.awayNotice(), "the player was credited with an absence that was never measured")
		expect.equal(
			colony.profile().colony.lastProductionAt,
			colony.server.wallClock(),
			"the clock was not started, so the next join will pay out from the epoch instead"
		)
		colony.server.assertNoErrors(expect, "unstamped clock")
	end)
end
