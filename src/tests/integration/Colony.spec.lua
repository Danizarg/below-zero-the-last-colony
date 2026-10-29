--[[
	Colony.spec.lua
	Colony management, driven against a fully booted simulated server:
	construction, upgrades, colonists, production, crafting and who is allowed
	to touch whose plot.

	Why this layer needs covering
	─────────────────────────────
	The colony is where everything a player earns underground gets spent. A
	refused build that still charges, a demolition that launders resources, or a
	visitor who can reach the owner's buildings all cost someone hours of play
	with nothing to show for it — and none of it is visible from a unit test of
	the arithmetic, because the rules live in the ordering of the service's
	checks rather than in the maths.

	So every refusal here is asserted twice: the reason the client is given, and
	that storage did not move. `assertStorageDelta` is the second half of almost
	every test for exactly that reason.

	Each test builds its own server, so nothing leaks between them.
]]

return function(suite, context)
	local newServer = context.newServer

	--[[ Costs are read out of BuildingConfig rather than written down here, so
	     a balance change moves the expectation with it instead of turning a
	     real assertion into a stale number. Negating a cost map turns "this is
	     the price" into "this is what storage should lose". ]]
	local function negate(cost)
		local out = {}
		for resourceId, amount in pairs(cost) do
			out[resourceId] = -amount
		end
		return out
	end

	local function sumMaps(maps)
		local out = {}
		for _, map in ipairs(maps) do
			for resourceId, amount in pairs(map) do
				out[resourceId] = (out[resourceId] or 0) + amount
			end
		end
		return out
	end

	--[[ Shared setup: a booted server and one player who already has a plot, a
	     granted Town Hall, three colonists and the starting materials. Handles
	     and small helpers are returned as a table so the tests read as colony
	     actions rather than route plumbing. ]]
	local function newColony(playerName)
		local server = newServer()

		local colony = {
			server = server,
			services = server.services,
			Routes = server.require(server.shared.Routes),
			Enums = server.require(server.shared.Enums),
			GameConfig = server.require(server.shared.Config.GameConfig),
			BuildingConfig = server.require(server.shared.Config.BuildingConfig),
			PlotGrid = server.require(server.shared.Lib.PlotGrid),
		}

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

		function colony.buildings()
			return colony.profile().colony.buildings
		end

		function colony.colonists()
			return colony.profile().colony.colonists
		end

		function colony.uidOf(buildingId)
			for _, placement in ipairs(colony.buildings()) do
				if placement.id == buildingId then
					return placement.uid
				end
			end
			return nil
		end

		function colony.placementOf(uid)
			for _, placement in ipairs(colony.buildings()) do
				if placement.uid == uid then
					return placement
				end
			end
			return nil
		end

		-- ── Routes, as the client would call them ──────────────────────────

		function colony.place(buildingId, gx, gz, rotation)
			return server.invoke(colony.player, colony.Routes.Request.PlaceBuilding, {
				buildingId = buildingId,
				gx = gx,
				gz = gz,
				rot = rotation,
			})
		end

		function colony.upgrade(uid)
			return server.invoke(colony.player, colony.Routes.Request.UpgradeBuilding, { uid = uid })
		end

		function colony.repair(uid)
			return server.invoke(colony.player, colony.Routes.Request.RepairBuilding, { uid = uid })
		end

		function colony.remove(uid)
			return server.invoke(colony.player, colony.Routes.Request.RemoveBuilding, { uid = uid })
		end

		function colony.assign(colonistUid, jobId)
			return server.invoke(colony.player, colony.Routes.Request.AssignJob, {
				uid = colonistUid,
				job = jobId,
			})
		end

		function colony.craft(recipeId)
			return server.invoke(colony.player, colony.Routes.Request.Craft, { recipeId = recipeId })
		end

		--[[ The last colony snapshot the server pushed: what the player's own
		     screen would be showing. ]]
		function colony.snapshot()
			return server.lastPush(colony.player, colony.Routes.Push.ColonySync)
		end

		-- ── Storage ────────────────────────────────────────────────────────

		--[[ A copy, so a test can compare before and after without the live
		     profile table changing underneath it. ]]
		function colony.storageSnapshot()
			return table.clone(colony.storage())
		end

		--[[ Top storage up to the summed costs, so a test's intended refusal is
		     never merely a shortfall. Grants go through the service that owns
		     them, which means the colony storage cap applies — a truncated
		     grant is raised immediately rather than left to surface later as a
		     confusing "not enough resources". ]]
		function colony.fund(...)
			for resourceId, amount in pairs(sumMaps({ ... })) do
				local short = amount - colony.held(resourceId)
				if short > 0 then
					local result =
						server.services.InventoryService:addToStorage(colony.player, resourceId, short)
					if result.added < short then
						error(
							("[Colony.spec] could not fund %d %s, storage only took %d: the colony storage cap is in the way of this test"):format(
								short,
								resourceId,
								result.added
							),
							2
						)
					end
				end
			end
		end

		--[[ Spend one resource down to nothing, through the same chokepoint
		     every build uses, rather than editing the profile by hand. ]]
		function colony.drain(resourceId)
			local held = colony.held(resourceId)
			if held > 0 then
				server.services.InventoryService:spendFromStorage(colony.player, { [resourceId] = held })
			end
		end

		--[[
			Assert storage moved by exactly `delta` and by nothing else.

			Every resource mentioned on either side is checked, so an action that
			took one mushroom too many is caught as readily as one that took
			nothing at all. "Charged exactly its cost" and "charged nothing" are
			then the same assertion with different arguments.
		]]
		function colony.assertStorageDelta(expect, before, delta, label)
			local resourceIds = {}
			for resourceId in pairs(before) do
				resourceIds[resourceId] = true
			end
			for resourceId in pairs(colony.storage()) do
				resourceIds[resourceId] = true
			end
			for resourceId in pairs(delta) do
				resourceIds[resourceId] = true
			end

			for resourceId in pairs(resourceIds) do
				local expected = (before[resourceId] or 0) + (delta[resourceId] or 0)
				expect.equal(
					colony.held(resourceId),
					expected,
					("%s: %s should have gone from %d to %d, but storage holds %d"):format(
						label,
						resourceId,
						before[resourceId] or 0,
						expected,
						colony.held(resourceId)
					)
				)
			end
		end

		return colony
	end

	-- ── Construction ─────────────────────────────────────────────────────────

	suite:test("placing a Shelter charges exactly its cost and nothing else", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local cost = colony.BuildingConfig.get(Enums.Building.Housing).levels[1].cost

		local before = colony.storageSnapshot()
		local placed = colony.place(Enums.Building.Housing, 6, 0)

		expect.truthy(placed.ok, "a legal, affordable Shelter was refused: " .. tostring(placed.reason))
		expect.equal(placed.placement.id, Enums.Building.Housing)
		expect.equal(placed.placement.level, 1, "a new building should start at level 1")
		expect.equal(#colony.buildings(), 2, "the placement never reached the profile")

		--[[ Exactly: every line of the cost came out and no other resource
		     moved. A spend that also helped itself to a mushroom would pass a
		     looser "did the stone go down" check. ]]
		colony.assertStorageDelta(expect, before, negate(cost), "placing a Shelter")

		--[[ Placement is only real to the player once it is replicated, so the
		     snapshot is part of the behaviour, not an implementation detail. ]]
		expect.equal(#colony.snapshot().buildings, 2, "the client was never told about the new building")
		colony.server.assertNoErrors(expect, "place")
	end)

	suite:test("a Shelter overlapping an existing one is refused and charges nothing", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local cost = colony.BuildingConfig.get(Enums.Building.Housing).levels[1].cost

		expect.truthy(colony.place(Enums.Building.Housing, 6, 0).ok, "the first Shelter was refused")

		--[[ The second attempt must be affordable, or a refusal would prove
		     nothing about the grid. ]]
		expect.truthy(
			(colony.services.InventoryService:canAffordFromStorage(colony.player, cost)),
			"this test needs the second Shelter to be affordable"
		)

		local before = colony.storageSnapshot()
		local again = colony.place(Enums.Building.Housing, 6, 0)

		expect.falsy(again.ok, "two Shelters were stacked on the same cells")
		expect.equal(again.reason, Enums.Reject.Occupied)
		expect.equal(again.detail, Enums.Building.Housing, "the refusal should name what is in the way")
		expect.equal(#colony.buildings(), 2, "the overlapping Shelter was recorded anyway")
		colony.assertStorageDelta(expect, before, {}, "a refused overlap")
		colony.server.assertNoErrors(expect, "overlap")
	end)

	suite:test("a footprint must fit inside the plot's build area", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local def = colony.BuildingConfig.get(Enums.Building.Housing)
		local limit = colony.PlotGrid.gridHalfExtent()
		colony.fund(def.levels[1].cost)

		--[[ A whole footprint past the boundary: nothing about this placement
		     is salvageable, and the build area is what stops a large building
		     overhanging the neighbouring plot. ]]
		local before = colony.storageSnapshot()
		local outside = colony.place(Enums.Building.Housing, limit + def.footprint.w, 0)

		expect.falsy(outside.ok, "a Shelter was placed over the edge of the plot")
		expect.equal(outside.reason, Enums.Reject.TooFar)
		expect.equal(outside.detail, "out_of_plot")
		colony.assertStorageDelta(expect, before, {}, "a placement outside the plot")

		--[[ The same building a footprint inside the boundary is fine, which is
		     what makes the case above a boundary rather than a blanket refusal
		     of anything far from the centre. ]]
		local inside = colony.place(Enums.Building.Housing, limit - def.footprint.w, 0)
		expect.truthy(inside.ok, "a Shelter well inside the plot was refused: " .. tostring(inside.reason))
		colony.assertStorageDelta(expect, before, negate(def.levels[1].cost), "a placement near the edge")
		colony.server.assertNoErrors(expect, "bounds")
	end)

	suite:test("an unaffordable placement takes none of the cost it could pay", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local cost = colony.BuildingConfig.get(Enums.Building.Housing).levels[1].cost

		--[[ This is the one that matters most in this file. A Shelter costs
		     stone AND fiber; with the fiber gone the player can still pay the
		     stone half, which is exactly the shape of bug that leaves someone
		     poorer with nothing built. The service pays last for this reason,
		     and this test is what holds that ordering in place. ]]
		colony.drain(Enums.Resource.Fiber)
		expect.equal(
			colony.held(Enums.Resource.Fiber),
			0,
			"the fiber was not drained; nothing is being tested"
		)
		expect.atLeast(
			colony.held(Enums.Resource.Stone),
			cost[Enums.Resource.Stone],
			"the player must be able to pay the stone half for this test to mean anything"
		)

		local before = colony.storageSnapshot()
		local attempt = colony.place(Enums.Building.Housing, 6, 0)

		expect.falsy(attempt.ok, "a Shelter the player could not pay for was built")
		expect.equal(attempt.reason, Enums.Reject.NotEnoughResources)
		expect.equal(
			attempt.missing[Enums.Resource.Fiber],
			cost[Enums.Resource.Fiber],
			"the refusal should report the fiber shortfall so the UI can name it"
		)
		colony.assertStorageDelta(expect, before, {}, "a placement nobody could afford")
		expect.equal(#colony.buildings(), 1, "an unpaid building was recorded")
		colony.server.assertNoErrors(expect, "unaffordable place")
	end)

	suite:test("the Workshop is blocked until the Town Hall reaches level 2", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local townHall = colony.BuildingConfig.get(Enums.Building.TownHall)
		local workshop = colony.BuildingConfig.get(Enums.Building.Workshop)
		expect.equal(workshop.requires[Enums.Building.TownHall], 2, "the Workshop's prerequisite has moved")

		--[[ Funded for both, so the prerequisite is the only thing that can
		     refuse the first attempt. ]]
		colony.fund(townHall.levels[2].cost, workshop.levels[1].cost)

		local before = colony.storageSnapshot()
		local blocked = colony.place(Enums.Building.Workshop, -8, 0)
		expect.falsy(blocked.ok, "a Workshop went up with a level 1 Town Hall")
		expect.equal(blocked.reason, Enums.Reject.NoPermission)
		expect.equal(blocked.detail, "requires")
		colony.assertStorageDelta(expect, before, {}, "a placement blocked by a prerequisite")

		local upgraded = colony.upgrade(colony.uidOf(Enums.Building.TownHall))
		expect.truthy(upgraded.ok, "the Town Hall upgrade was refused: " .. tostring(upgraded.reason))
		expect.equal(upgraded.placement.level, 2)
		expect.equal(colony.snapshot().colonyLevel, 2, "colony level should follow the Town Hall")

		local allowed = colony.place(Enums.Building.Workshop, -8, 0)
		expect.truthy(
			allowed.ok,
			"the Workshop is still refused at Town Hall 2: " .. tostring(allowed.reason)
		)
		expect.equal(#colony.buildings(), 2, "the Workshop never reached the profile")
		colony.server.assertNoErrors(expect, "prerequisites")
	end)

	suite:test("a defined but unimplemented building is refused outright", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local def = colony.BuildingConfig.get(Enums.Building.Kitchen)

		expect.truthy(
			colony.GameConfig.MvpContentOnly,
			"this test only means anything while the MVP gate is on"
		)
		expect.falsy(def.implemented, "the Kitchen is implemented now; pick another unfinished building")

		local before = colony.storageSnapshot()
		local attempt = colony.place(Enums.Building.Kitchen, 0, 10)

		--[[ The Kitchen also has a prerequisite it cannot meet, so this pins
		     the order of the checks too: a player is told the building does not
		     exist yet rather than being sent off to build a level 2 Farm for
		     something that would be refused anyway. ]]
		expect.falsy(attempt.ok, "an unimplemented building was placed")
		expect.equal(attempt.reason, Enums.Reject.NotImplemented)
		colony.assertStorageDelta(expect, before, {}, "an unimplemented placement")
		expect.equal(#colony.buildings(), 1, "the unimplemented building was recorded")
		colony.server.assertNoErrors(expect, "not implemented")
	end)

	-- ── Upgrades, repair and demolition ──────────────────────────────────────

	suite:test("upgrading costs the next level's price, and a maxed building is refused", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local def = colony.BuildingConfig.get(Enums.Building.Housing)

		local costs = {}
		for _, levelData in ipairs(def.levels) do
			table.insert(costs, levelData.cost)
		end
		colony.fund(table.unpack(costs))

		local uid = colony.place(Enums.Building.Housing, 6, 0).placement.uid

		for level = 2, #def.levels do
			local before = colony.storageSnapshot()
			local upgraded = colony.upgrade(uid)

			expect.truthy(
				upgraded.ok,
				("upgrade to level %d was refused: %s"):format(level, tostring(upgraded.reason))
			)
			expect.equal(upgraded.placement.level, level, "the upgrade did not raise the level")
			--[[ Each step must cost that level's price, not the first level's:
			     a flat price would make the top of a building free. ]]
			colony.assertStorageDelta(
				expect,
				before,
				negate(def.levels[level].cost),
				("upgrading to level %d"):format(level)
			)
			expect.equal(
				colony.placementOf(uid).health,
				def.levels[level].maxHealth,
				"an upgrade should leave the building at full condition"
			)
		end

		local before = colony.storageSnapshot()
		local maxed = colony.upgrade(uid)
		expect.falsy(maxed.ok, "a maxed building was upgraded past its last defined level")
		expect.equal(maxed.reason, Enums.Reject.LimitReached)
		expect.equal(maxed.detail, "max_level")
		expect.equal(colony.placementOf(uid).level, #def.levels, "the level moved on a refused upgrade")
		colony.assertStorageDelta(expect, before, {}, "an upgrade past max level")
		colony.server.assertNoErrors(expect, "upgrade")
	end)

	suite:test("repair is refused at full health, and priced off the damage otherwise", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local levelData = colony.BuildingConfig.levelData(Enums.Building.Housing, 1)
		local uid = colony.place(Enums.Building.Housing, 6, 0).placement.uid

		--[[ Repair is priced off missing condition, so a repair at full health
		     would be a free click that charges for nothing. ]]
		local before = colony.storageSnapshot()
		local undamaged = colony.repair(uid)
		expect.falsy(undamaged.ok, "paid to repair a building at full health")
		expect.equal(undamaged.reason, Enums.Reject.BadRequest)
		expect.equal(undamaged.detail, "not_damaged")
		colony.assertStorageDelta(expect, before, {}, "repairing an undamaged Shelter")

		--[[ Wear it the way NPC condition decay does rather than editing the
		     placement, so the price is computed from a health value the game
		     could actually produce. ]]
		colony.services.BuildingService:damage(colony.player, uid, levelData.maxHealth * 0.5)
		local damagedHealth = colony.placementOf(uid).health
		expect.lessThan(damagedHealth, levelData.maxHealth, "the damage never landed")

		local cost = colony.BuildingConfig.repairCost(Enums.Building.Housing, 1, damagedHealth)
		expect.truthy(next(cost), "a damaged Shelter should cost something to repair")
		colony.fund(cost)

		local beforeRepair = colony.storageSnapshot()
		local repaired = colony.repair(uid)
		expect.truthy(repaired.ok, "a funded repair was refused: " .. tostring(repaired.reason))
		expect.equal(
			colony.placementOf(uid).health,
			levelData.maxHealth,
			"a paid repair left the building damaged"
		)
		for resourceId, amount in pairs(cost) do
			expect.equal(
				repaired.cost[resourceId],
				amount,
				"the quoted repair cost disagrees with the config"
			)
		end
		colony.assertStorageDelta(expect, beforeRepair, negate(cost), "repairing a damaged Shelter")
		colony.server.assertNoErrors(expect, "repair")
	end)

	suite:test("demolition refunds half, and the Town Hall cannot be demolished", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local cost = colony.BuildingConfig.get(Enums.Building.Housing).levels[1].cost
		local uid = colony.place(Enums.Building.Housing, 6, 0).placement.uid

		--[[ Half, rounded down, and lines that round away are dropped: generous
		     enough that trying a layout is not punished, mean enough that
		     build-and-demolish is not a resource laundry. ]]
		local expectedRefund = {}
		local paid, refunded = 0, 0
		for resourceId, amount in pairs(cost) do
			local half = math.floor(amount * 0.5)
			paid += amount
			if half > 0 then
				expectedRefund[resourceId] = half
				refunded += half
			end
		end

		local before = colony.storageSnapshot()
		local removed = colony.remove(uid)
		expect.truthy(removed.ok, "the Shelter could not be demolished: " .. tostring(removed.reason))

		for resourceId, amount in pairs(expectedRefund) do
			expect.equal(removed.refund[resourceId], amount, "the quoted refund is not half the build cost")
		end
		colony.assertStorageDelta(expect, before, expectedRefund, "demolishing a Shelter")
		expect.lessThan(refunded, paid, "demolition returned everything, which would launder resources")
		expect.equal(#colony.buildings(), 1, "the demolished Shelter is still in the profile")
		expect.falsy(colony.placementOf(uid), "the demolished placement is still addressable")

		--[[ The hall is the colony's anchor and the gate on everything else;
		     removing it would strand the player with no way back. ]]
		local townHallUid = colony.uidOf(Enums.Building.TownHall)
		local beforeHall = colony.storageSnapshot()
		local hall = colony.remove(townHallUid)
		expect.falsy(hall.ok, "the Town Hall was demolished")
		expect.equal(hall.reason, Enums.Reject.NoPermission)
		expect.equal(hall.detail, "cannot_demolish")
		expect.truthy(colony.placementOf(townHallUid), "the Town Hall is gone from the profile")
		colony.assertStorageDelta(expect, beforeHall, {}, "a refused Town Hall demolition")
		colony.server.assertNoErrors(expect, "demolish")
	end)

	-- ── Colonists ────────────────────────────────────────────────────────────

	suite:test("a new colony's colonists start unassigned, and a job needs a workplace", function(expect)
		local colony = newColony()
		local Enums = colony.Enums

		expect.equal(
			#colony.colonists(),
			colony.GameConfig.NPC.StartingColonists,
			"a new colony should be seeded with the configured starting roster"
		)
		for _, colonist in ipairs(colony.colonists()) do
			expect.equal(colonist.job, Enums.Job.Idle, "a freshly seeded colonist should be unassigned")
		end

		--[[ A Farmer with no Farm would otherwise be a colonist producing out
		     of thin air, since production never re-checks the workplace the
		     assignment claimed. ]]
		local attempt = colony.assign(colony.colonists()[1].uid, Enums.Job.Farmer)
		expect.falsy(attempt.ok, "a Farmer was assigned with no Farm to work in")
		expect.equal(attempt.reason, Enums.Reject.NoPermission)
		expect.equal(attempt.detail, "needs_building")
		expect.equal(colony.colonists()[1].job, Enums.Job.Idle, "the refused assignment stuck anyway")
		colony.server.assertNoErrors(expect, "assign without a workplace")
	end)

	suite:test("a Farm opens exactly its Farmer slots and no more", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local slots =
			colony.BuildingConfig.levelData(Enums.Building.Farm, 1).effects.jobSlots[Enums.Job.Farmer]

		expect.truthy(colony.place(Enums.Building.Farm, 0, 9).ok, "the Farm was refused")
		expect.equal(
			colony.snapshot().jobSlots[Enums.Job.Farmer],
			slots,
			"the colony snapshot does not report the Farm's work slots"
		)
		expect.lessThan(
			slots,
			#colony.colonists(),
			"this test needs more colonists than there are Farmer slots"
		)

		for index = 1, slots do
			local assigned = colony.assign(colony.colonists()[index].uid, Enums.Job.Farmer)
			expect.truthy(
				assigned.ok,
				("Farmer %d was refused a free slot: %s"):format(index, tostring(assigned.reason))
			)
			expect.equal(assigned.colonist.job, Enums.Job.Farmer)
		end

		--[[ Slots are the only thing capping production, so one more worker
		     than the Farm has room for has to be refused rather than quietly
		     doubling the colony's output. ]]
		local overflow = colony.assign(colony.colonists()[slots + 1].uid, Enums.Job.Farmer)
		expect.falsy(overflow.ok, "more Farmers were assigned than the Farm has slots for")
		expect.equal(overflow.reason, Enums.Reject.LimitReached)
		expect.equal(overflow.detail, "no_slots")
		expect.equal(
			colony.colonists()[slots + 1].job,
			Enums.Job.Idle,
			"the refused colonist took the job anyway"
		)
		expect.equal(
			colony.snapshot().jobUsage[Enums.Job.Farmer],
			slots,
			"the snapshot disagrees about who is working"
		)
		colony.server.assertNoErrors(expect, "job slots")
	end)

	suite:test("removing a Farm idles its workers and warns the player", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local slots =
			colony.BuildingConfig.levelData(Enums.Building.Farm, 1).effects.jobSlots[Enums.Job.Farmer]

		expect.truthy(colony.place(Enums.Building.Farm, 0, 9).ok, "the Farm was refused")
		for index = 1, slots do
			expect.truthy(
				colony.assign(colony.colonists()[index].uid, Enums.Job.Farmer).ok,
				"a Farmer was refused"
			)
		end

		colony.server.clearPushes()
		local removed = colony.remove(colony.uidOf(Enums.Building.Farm))
		expect.truthy(removed.ok, "the Farm could not be demolished: " .. tostring(removed.reason))

		--[[ A worker left pointing at a building that no longer exists is the
		     kind of orphan that either keeps producing for free or silently
		     stops; both are worse than being told. ]]
		for _, colonist in ipairs(colony.colonists()) do
			expect.equal(
				colonist.job,
				Enums.Job.Idle,
				"a Farmer kept their job after the Farm was demolished"
			)
		end

		local notices = colony.server.pushes(colony.player, colony.Routes.Push.Notify)
		expect.equal(#notices, 1, ("expected one notice about the idled workers, got %d"):format(#notices))
		expect.equal(notices[1].kind, "warning")
		expect.equal(notices[1].title, "Workers idle", "the player was never told their workers had stopped")

		--[[ And the snapshot the client is left holding agrees with the
		     profile. `_afterChange` used to push the colony BEFORE telling
		     NPCService the buildings had changed, and `onBuildingsChanged`
		     pushes only the notice — so the last snapshot after a demolition
		     still listed the workers as farming a Farm that was gone, and went
		     on saying so until some later push happened to correct it. The
		     reassignment now runs first. ]]
		expect.falsy(
			colony.snapshot().jobUsage[Enums.Job.Farmer],
			"the snapshot still has someone farming a Farm that was just demolished"
		)

		--[[ And it stays right through the next production tick, rather than
		     being quietly repaired by it. ]]
		colony.server.advance(colony.GameConfig.NPC.ProductionTickSeconds)
		expect.falsy(
			colony.snapshot().jobUsage[Enums.Job.Farmer],
			"a later colony push still shows someone farming a Farm that no longer exists"
		)
		colony.server.assertNoErrors(expect, "farm removal")
	end)

	-- ── Production ───────────────────────────────────────────────────────────

	suite:test("a Farmer accumulates mushrooms over repeated production ticks", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local tick = colony.GameConfig.NPC.ProductionTickSeconds

		expect.truthy(colony.place(Enums.Building.Farm, 0, 9).ok, "the Farm was refused")

		--[[ Control first: a Farm with nobody in it produces nothing, so the
		     growth below can only come from the assignment. ]]
		local unstaffed = colony.held(Enums.Resource.Mushroom)
		colony.server.advance(tick * 3)
		expect.equal(
			colony.held(Enums.Resource.Mushroom),
			unstaffed,
			"an unstaffed Farm produced mushrooms, so production is not driven by the roster"
		)

		local assigned = colony.assign(colony.colonists()[1].uid, Enums.Job.Farmer)
		expect.truthy(assigned.ok, "could not assign a Farmer: " .. tostring(assigned.reason))

		--[[ Output is deliberately probabilistic: a fractional yield per tick
		     becomes a chance of a whole unit, so the honest assertion is "more
		     than before" over several ticks and never an exact number. ]]
		local before = colony.held(Enums.Resource.Mushroom)
		colony.server.advance(tick * 4)
		local afterFirstRun = colony.held(Enums.Resource.Mushroom)
		expect.greaterThan(afterFirstRun, before, "four production ticks with a Farmer yielded no mushrooms")

		colony.server.advance(tick * 4)
		expect.greaterThan(
			colony.held(Enums.Resource.Mushroom),
			afterFirstRun,
			"production stopped after the first few ticks instead of recurring"
		)

		--[[ All of it happened at home: the colony tick is not a reward for
		     being underground. ]]
		expect.equal(colony.services.ColonyService:zoneOf(colony.player), Enums.Zone.Colony)
		colony.server.assertNoErrors(expect, "production")
	end)

	-- ── Crafting ─────────────────────────────────────────────────────────────

	suite:test("the Stone Pick needs a Workshop, and crafting pays for the tool", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local recipe = colony.services.InventoryService:recipeById("craft_stone_pick")
		expect.truthy(recipe, "the Stone Pick recipe is gone")
		expect.equal(recipe.station, Enums.Building.Workshop, "the Stone Pick's station has moved")

		colony.fund(
			colony.BuildingConfig.get(Enums.Building.TownHall).levels[2].cost,
			colony.BuildingConfig.get(Enums.Building.Workshop).levels[1].cost,
			recipe.cost
		)

		--[[ Funded, so the only thing missing is the bench. A recipe that can
		     be made without its station makes the whole building pointless. ]]
		local before = colony.storageSnapshot()
		local stationless = colony.craft(recipe.id)
		expect.falsy(stationless.ok, "a Workshop recipe was crafted with no Workshop")
		expect.equal(stationless.reason, Enums.Reject.NoPermission)
		expect.equal(stationless.detail, "station")
		colony.assertStorageDelta(expect, before, {}, "a craft with no station")
		expect.falsy(
			colony.profile().colony.tools[recipe.grantsTool],
			"a refused craft granted the tool anyway"
		)

		expect.truthy(colony.upgrade(colony.uidOf(Enums.Building.TownHall)).ok, "could not reach Town Hall 2")
		expect.truthy(colony.place(Enums.Building.Workshop, -8, 0).ok, "the Workshop was refused")

		local beforeCraft = colony.storageSnapshot()
		local crafted = colony.craft(recipe.id)
		expect.truthy(
			crafted.ok,
			"crafting was refused with a Workshop standing: " .. tostring(crafted.reason)
		)
		expect.equal(crafted.recipeId, recipe.id)
		colony.assertStorageDelta(expect, beforeCraft, negate(recipe.cost), "crafting a Stone Pick")

		local tool = colony.profile().colony.tools[recipe.grantsTool]
		expect.truthy(tool, "the craft did not grant the tool")
		expect.greaterThan(tool.durability, 0, "the new tool arrived already broken")
		expect.equal(
			colony.profile().colony.equippedTool,
			recipe.grantsTool,
			"a freshly crafted tool should be the one in hand"
		)
		colony.server.assertNoErrors(expect, "craft")
	end)

	suite:test("crafting without the resources is refused and grants nothing", function(expect)
		local colony = newColony()
		local Enums = colony.Enums
		local recipe = colony.services.InventoryService:recipeById("craft_stone_pick")

		colony.fund(
			colony.BuildingConfig.get(Enums.Building.TownHall).levels[2].cost,
			colony.BuildingConfig.get(Enums.Building.Workshop).levels[1].cost,
			recipe.cost
		)
		expect.truthy(colony.upgrade(colony.uidOf(Enums.Building.TownHall)).ok, "could not reach Town Hall 2")
		expect.truthy(colony.place(Enums.Building.Workshop, -8, 0).ok, "the Workshop was refused")

		--[[ Stone gone, fiber still there: the same partial-payment trap as the
		     build path, through a different service. ]]
		colony.drain(Enums.Resource.Stone)
		expect.atLeast(
			colony.held(Enums.Resource.Fiber),
			recipe.cost[Enums.Resource.Fiber],
			"the player must still be able to pay the fiber half for this test to mean anything"
		)

		local before = colony.storageSnapshot()
		local attempt = colony.craft(recipe.id)
		expect.falsy(attempt.ok, "a tool was crafted out of resources the player did not have")
		expect.equal(attempt.reason, Enums.Reject.NotEnoughResources)
		expect.equal(
			attempt.missing[Enums.Resource.Stone],
			recipe.cost[Enums.Resource.Stone],
			"the refusal should report the stone shortfall"
		)
		colony.assertStorageDelta(expect, before, {}, "a craft nobody could afford")
		expect.falsy(colony.profile().colony.tools[recipe.grantsTool], "the refused craft granted the tool")
		expect.equal(
			colony.profile().colony.equippedTool,
			"bare_hands",
			"the refused craft equipped something"
		)
		colony.server.assertNoErrors(expect, "unaffordable craft")
	end)

	-- ── Permissions ──────────────────────────────────────────────────────────

	suite:test("a visitor cannot build, upgrade or demolish in someone else's colony", function(expect)
		local colony = newColony("Alice")
		local Enums, Routes, server = colony.Enums, colony.Routes, colony.server
		local ColonyService = colony.services.ColonyService

		local shelterUid = colony.place(Enums.Building.Housing, 6, 0).placement.uid
		local ownerPlot = ColonyService:plotOf(colony.player)
		local ownerBuildingCount = #colony.buildings()

		local visitor = server.addPlayer("Bob")
		expect.notEqual(ColonyService:plotOf(visitor), ownerPlot, "both players ended up on one plot")

		--[[ Walking into someone else's colony is allowed and grants nothing,
		     which is the whole point of the visit route reporting canManage. ]]
		local visited = server.invoke(visitor, Routes.Request.VisitColony, { userId = colony.player.UserId })
		expect.truthy(visited.ok, "visiting a colony was refused outright: " .. tostring(visited.reason))
		expect.equal(visited.plotIndex, ownerPlot, "the visitor was sent to the wrong plot")
		expect.falsy(visited.canManage, "a visitor was told they may manage the plot they are standing on")
		expect.falsy((ColonyService:canManage(visitor, ownerPlot)), "a visitor passed the permission gate")

		local before = colony.storageSnapshot()

		--[[ The build routes carry a uid, not a plot: ownership is resolved
		     from the actor, never from the payload. These calls name the
		     OWNER's Shelter, which is the shape the exploit would take. ]]
		local upgrade = server.invoke(visitor, Routes.Request.UpgradeBuilding, { uid = shelterUid })
		expect.falsy(upgrade.ok, "a visitor upgraded a building in someone else's colony")
		expect.equal(upgrade.reason, Enums.Reject.BadRequest)

		local demolish = server.invoke(visitor, Routes.Request.RemoveBuilding, { uid = shelterUid })
		expect.falsy(demolish.ok, "a visitor demolished a building in someone else's colony")
		expect.equal(demolish.reason, Enums.Reject.BadRequest)

		local repair = server.invoke(visitor, Routes.Request.RepairBuilding, { uid = shelterUid })
		expect.falsy(repair.ok, "a visitor repaired a building in someone else's colony")

		--[[ And a visitor's own build lands on their own plot even while they
		     are standing in the owner's: there is no payload that aims
		     construction at another colony. ]]
		local visitorPlace = server.invoke(visitor, Routes.Request.PlaceBuilding, {
			buildingId = Enums.Building.Housing,
			gx = -8,
			gz = 8,
		})
		expect.truthy(
			visitorPlace.ok,
			"the visitor could not build at home: " .. tostring(visitorPlace.reason)
		)
		expect.equal(
			#colony.services.DataService:get(visitor).colony.buildings,
			2,
			"the visitor's own colony did not get the Shelter they paid for"
		)

		expect.equal(
			#colony.buildings(),
			ownerBuildingCount,
			"a visitor's actions changed the owner's buildings"
		)
		expect.equal(colony.placementOf(shelterUid).level, 1, "the owner's Shelter was upgraded by a visitor")
		colony.assertStorageDelta(expect, before, {}, "everything a visitor tried")

		--[[ The control: the identical upgrade from the owner goes through, so
		     the refusals above were about who was asking and not about a uid
		     the server simply could not resolve. ]]
		colony.fund(colony.BuildingConfig.get(Enums.Building.Housing).levels[2].cost)
		local ownerUpgrade = colony.upgrade(shelterUid)
		expect.truthy(
			ownerUpgrade.ok,
			"the owner could not upgrade their own Shelter: " .. tostring(ownerUpgrade.reason)
		)
		expect.equal(ownerUpgrade.placement.level, 2)
		server.assertNoErrors(expect, "visitor permissions")
	end)
end
