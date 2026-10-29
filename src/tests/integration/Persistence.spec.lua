--[[
	Persistence.spec.lua
	Profiles, session locking and purchase bookkeeping, driven against a fully
	booted simulated server whose DataStore has real UpdateAsync
	read-modify-write semantics — so the locking protocol actually runs here
	rather than being stubbed out.

	The regressions this is the suite for:

	  R9  disconnecting DURING a load left a lock held by nobody. The load
	      yields on UpdateAsync, so PlayerRemoving could fire while the profile
	      entry did not exist yet; the release was dropped as "not_loaded" and
	      the lock the load had already written stayed behind, locking the
	      player out of their own profile until it timed out.

	  --  a transient DataStore error used to latch the server into in-memory
	      mode for the rest of its life while save() kept returning true. A
	      write that only reached RAM must never be acknowledged: that is how a
	      purchase is taken and not granted, and how a shutdown logs "saves
	      complete" over data that is about to vanish.

	  --  a lock that has been released must never be written back by a save
	      that was already in flight when the player left.

	Each test builds its own server, so nothing leaks between them.
]]

return function(suite, context)
	local newServer = context.newServer

	--[[ The key format DataService stores profiles under; see its keyFor(). ]]
	local KEY_PREFIX = "player_"

	--[[ DataService's tuning constants are file-locals, so nothing can require
	     them — and copying the numbers in here would leave this spec quietly
	     asserting the wrong thing the day someone retunes the autosave. Read
	     them out of the service's own source instead, so a retune moves these
	     tests with it. ]]
	local function tuningOf(server)
		local globals = getfenv(0)
		local luneRequire = type(globals) == "table" and globals.require
		if not luneRequire then
			error("cannot reach Lune's require, so DataService's tuning cannot be read", 0)
		end
		local fs = luneRequire("@lune/fs")
		local source = fs.readFile(server.serverTree.Services.DataService._filePath)

		local function constant(name)
			local value = tonumber(string.match(source, "local " .. name .. "%s*=%s*(%d+)"))
			if not value then
				error(("could not read %s out of DataService's source"):format(name), 0)
			end
			return value
		end

		return {
			autosaveInterval = constant("AUTOSAVE_INTERVAL"),
			degradedRetrySeconds = constant("DEGRADED_RETRY_SECONDS"),
			lockRetryDelay = constant("LOCK_RETRY_DELAY"),
			lockRetryAttempts = constant("LOCK_RETRY_ATTEMPTS"),
			maxReceiptsKept = constant("MAX_RECEIPTS_KEPT"),
		}
	end

	--[[ Shared setup: a booted server with one player whose profile is loaded,
	     plus the handles these tests need. Returned as a table rather than
	     globals so the tests stay readable. ]]
	local function startColony(playerName, options)
		local server = newServer(options)
		local colony = {
			server = server,
			Routes = server.require(server.shared.Routes),
			Enums = server.require(server.shared.Enums),
			Data = server.services.DataService,
			storeName = server.require(server.shared.Config.GameConfig).DataStoreName,
			tuning = tuningOf(server),
		}
		colony.player = server.addPlayer(playerName or "Alice")

		function colony.store()
			return server.dataStores[colony.storeName]
		end

		--[[ What was actually WRITTEN, as opposed to what the service is holding
		     in memory. Nearly everything here turns on that difference. ]]
		function colony.record(player)
			local store = colony.store()
			return store and store.data[KEY_PREFIX .. (player or colony.player).UserId]
		end

		function colony.profile(player)
			return colony.Data:get(player or colony.player)
		end

		function colony.build(buildingId, gx, gz)
			return server.invoke(colony.player, colony.Routes.Request.PlaceBuilding, {
				buildingId = buildingId,
				gx = gx,
				gz = gz,
				rot = 0,
			})
		end

		return colony
	end

	--[[ Run a DataService call that may RETRY.

	     The retry wrapper backs off with task.wait between attempts, and a
	     yielded call only continues when virtual time moves. The test body is
	     the main thread and may not yield at all, so the call runs on a
	     coroutine the simulated scheduler can resume, with time advanced until
	     it returns. A call that never yields simply returns on the first
	     resume. ]]
	local function throughRetries(server, call)
		local returned
		local thread = coroutine.create(function()
			returned = table.pack(call())
		end)

		local started, err = coroutine.resume(thread)
		if not started then
			error("the call threw instead of returning: " .. tostring(err), 0)
		end

		local steps = 0
		while coroutine.status(thread) ~= "dead" and steps < 400 do
			steps += 1
			server.step(0.25)
		end
		if not returned then
			error("the call never returned; the retry budget is supposed to be finite", 0)
		end
		return returned[1], returned[2]
	end

	--[[ A second server contending for the SAME profile.

	     Each simulated server builds its own in-memory DataStore, so the new
	     one is handed the first one's store table: two servers, one store,
	     which is the whole situation session locking exists for. It has to be
	     shared before the second server loads anything.

	     Note the simulator routes error reporting to the most recently created
	     server, so both servers' error lists are checked in these tests. ]]
	local function contendingServer(colony, jobId)
		local other = newServer({ jobId = jobId })
		other.dataStores[colony.storeName] = colony.store()
		local player = other.addPlayer(colony.player.Name)
		return other, player
	end

	-- ── A profile round-trips ────────────────────────────────────────────────

	suite:test("a profile round-trips: what was built is in the written record", function(expect)
		local colony = startColony("Alice")

		local placed = colony.build(colony.Enums.Building.Housing, 6, 0)
		expect.truthy(placed.ok, "could not build a shelter: " .. tostring(placed.reason))

		local live = colony.profile()
		local stoneLeft = live.colony.storage[colony.Enums.Resource.Stone]
		expect.equal(#live.colony.buildings, 2, "expected the granted Town Hall plus the new shelter")

		colony.server.disconnect(colony.player)

		local record = colony.record()
		expect.truthy(record, "nothing was ever written for this player")

		--[[ The in-memory store hands the live table straight back on the very
		     first load, so a test that only compared CONTENTS could pass
		     without a single write having happened. This is the check that the
		     record is a written snapshot. ]]
		expect.notEqual(record, live, "the record is still the live profile table, so nothing was written")

		expect.equal(#record.colony.buildings, 2, "the shelter never reached durable storage")
		expect.equal(
			record.colony.buildings[2].id,
			colony.Enums.Building.Housing,
			"the written placement is not the shelter"
		)
		expect.equal(
			record.colony.storage[colony.Enums.Resource.Stone],
			stoneLeft,
			"the stone the shelter cost was not spent in the written record, so a rejoin would refund it"
		)
		colony.server.assertNoErrors(expect, "round trip")
	end)

	-- ── The session lock ─────────────────────────────────────────────────────

	suite:test("disconnecting releases the session lock", function(expect)
		local colony = startColony("Alice", { jobId = "job-a" })
		expect.equal(colony.record().meta.lockJobId, "job-a", "the load never took the lock")

		colony.server.disconnect(colony.player)

		local record = colony.record()
		expect.equal(
			record.meta.lockJobId,
			"",
			"the lock was left held by a server the player has already left"
		)
		expect.equal(
			record.meta.lockTimestamp,
			0,
			"a released lock kept its timestamp, which the next server reads as a live session"
		)
		expect.falsy(colony.Data:isLoaded(colony.player), "the profile entry outlived the session")
		colony.server.assertNoErrors(expect, "release")
	end)

	suite:test("an autosave refreshes the lock while the player is still here", function(expect)
		local colony = startColony("Alice", { jobId = "job-a" })
		local before = colony.record().meta.lockTimestamp
		expect.greaterThan(before, 0, "the load wrote no lock timestamp")

		--[[ A lock that is never refreshed starts to look abandoned, and after
		     LOCK_TIMEOUT another server may take a profile that is still being
		     played. Refreshing it is the autosave's second job. ]]
		colony.server.advance(colony.tuning.autosaveInterval + 1)

		local record = colony.record()
		expect.greaterThan(
			record.meta.lockTimestamp,
			before,
			"the autosave did not refresh the lock timestamp, so a live session will look abandoned"
		)
		expect.equal(record.meta.lockJobId, "job-a", "the autosave changed the owning job")
		expect.falsy(colony.Data:isReadOnly(colony.player), "the session demoted itself to read-only")
		colony.server.assertNoErrors(expect, "autosave")
	end)

	-- ── R9: leaving during a load ────────────────────────────────────────────

	suite:test("R9: disconnecting during a load still releases the lock", function(expect)
		--[[ Staging this needs the load to YIELD, which the in-memory store
		     never does on its own. A transient outage supplies the yield
		     honestly: DataService's retry wrapper backs off with task.wait
		     between attempts, which is a real yield point in the engine too —
		     a throttled DataStore call lands there every day.

		     Alice joins first because that is what caches the store handle; a
		     broken GetDataStore would fall straight back to memory and never
		     yield at all. ]]
		local colony = startColony("Alice", { jobId = "job-a" })
		local server = colony.server

		server.dataStoreBroken = true
		local bob = server.addPlayer("Bob")
		expect.falsy(
			colony.Data:isLoaded(bob),
			"Bob's load finished immediately, so there is no mid-load window to test"
		)
		expect.falsy(
			colony.record(bob),
			"the load's transform has already run; it was supposed to be suspended"
		)
		server.dataStoreBroken = false

		--[[ The engine clears Parent before firing PlayerRemoving, and so does
		     the simulator — which is exactly what the mid-load release check
		     reads. At this moment the release is dropped as "not_loaded",
		     because there is still no profile entry to release. ]]
		server.disconnect(bob)
		expect.falsy(colony.Data:isLoaded(bob), "the suspended load completed early")

		-- And now the load resumes, takes the lock, and must hand it straight back.
		server.advance(2)

		local record = colony.record(bob)
		expect.truthy(record, "Bob's load never completed")
		expect.equal(
			record.meta.sessionCount,
			1,
			"the load did not write this profile, so it held no lock to drop"
		)
		expect.equal(
			record.meta.lockJobId,
			"",
			"a player who left mid-load left a lock behind that nobody holds, locking them out on rejoin"
		)
		expect.falsy(colony.Data:isLoaded(bob), "the profile entry for a departed player was kept")
		expect.truthy(
			colony.Data:isLoaded(colony.player),
			"the outage took down the session that was already loaded"
		)
		server.assertNoErrors(expect, "mid-load disconnect")
	end)

	-- ── Degradation honesty ──────────────────────────────────────────────────

	suite:test("an outage makes a save report failure instead of lying about it", function(expect)
		local colony = startColony("Alice", { jobId = "job-a" })
		local server = colony.server

		--[[ One healthy save first, so the record in the store is a written
		     snapshot rather than the live table — otherwise the assertions
		     below could not tell a failed write from a successful one. ]]
		local saved = throughRetries(server, function()
			return colony.Data:save(colony.player, { force = true })
		end)
		expect.truthy(saved, "the first, healthy save failed")
		local buildingsOnDisk = #colony.record().colony.buildings

		server.dataStoreBroken = true
		local placed = colony.build(colony.Enums.Building.Farm, -8, 0)
		expect.truthy(placed.ok, "could not build a farm: " .. tostring(placed.reason))

		local ok, reason = throughRetries(server, function()
			return colony.Data:save(colony.player, { force = true })
		end)

		--[[ The point of the fix. A save that reached nothing but RAM used to
		     return true, which is what let a receipt be acknowledged for a
		     grant that would vanish with the server. ]]
		expect.falsy(ok, "a write that only reached memory reported success")
		expect.equal(
			reason,
			"no_persistence",
			"the failure did not name the lack of persistence: " .. tostring(reason)
		)
		expect.truthy(colony.Data:isDegraded(), "the server does not know its own writes are not landing")
		expect.equal(
			#colony.record().colony.buildings,
			buildingsOnDisk,
			"the farm reached the store although every DataStore call was failing"
		)
		expect.atLeast(
			colony.profile().diagnostics.saveFailures,
			1,
			"the failed save was not recorded in the profile's diagnostics"
		)
		server.assertNoErrors(expect, "outage")
	end)

	suite:test("a degraded server retries the real store and persists again", function(expect)
		local colony = startColony("Alice", { jobId = "job-a" })
		local server = colony.server

		server.dataStoreBroken = true
		local placed = colony.build(colony.Enums.Building.Housing, 6, 0)
		expect.truthy(placed.ok, "could not build a shelter: " .. tostring(placed.reason))
		local ok = throughRetries(server, function()
			return colony.Data:save(colony.player, { force = true })
		end)
		expect.falsy(ok, "the save reported success during a full outage")
		expect.truthy(colony.Data:isDegraded(), "the outage was not noticed")

		server.dataStoreBroken = false

		--[[ Recovery is time-based: the service serves from memory for
		     DEGRADED_RETRY_SECONDS and then tries the real store again. Giving
		     up for the life of the server on the first blip — which it used to
		     do — means every player who joins afterwards silently plays a
		     session that is never saved. ]]
		server.advance(colony.tuning.degradedRetrySeconds + 1)
		--[[ Nothing is forced here: the next ordinary autosave is what has to
		     land, because that is what a real recovery looks like. ]]
		server.advance(colony.tuning.autosaveInterval + 1)

		expect.falsy(
			colony.Data:isDegraded(),
			"the server stayed latched in memory mode after the store came back"
		)
		local record = colony.record()
		expect.equal(
			#record.colony.buildings,
			2,
			"the shelter built during the outage never reached the store once it recovered"
		)
		expect.equal(record.meta.lockJobId, "job-a", "recovery lost the session lock")
		expect.falsy(
			colony.Data:isReadOnly(colony.player),
			"the outage left the session unable to save at all"
		)
		server.assertNoErrors(expect, "recovery")
	end)

	-- ── A released lock stays released ───────────────────────────────────────

	suite:test("a save after the lock was released is refused, not written back", function(expect)
		local colony = startColony("Alice", { jobId = "job-a" })
		local server = colony.server

		server.disconnect(colony.player)
		expect.equal(colony.record().meta.lockJobId, "", "the release never wrote an empty lock")

		--[[ Hammer it the way a stray autosave would, not once politely. Any
		     write that lands here puts this server's jobId back on a profile it
		     no longer owns, and the player cannot save on their next server
		     until the lock times out. ]]
		for _ = 1, 10 do
			local ok, reason = throughRetries(server, function()
				return colony.Data:save(colony.player, { force = true })
			end)
			expect.falsy(ok, "a released profile accepted another write")
			expect.equal(reason, "not_loaded", "the refusal was for the wrong reason: " .. tostring(reason))
		end

		expect.equal(colony.record().meta.lockJobId, "", "a save after the release re-acquired the lock")
		expect.equal(
			colony.record().meta.lockTimestamp,
			0,
			"a save after the release refreshed a released lock"
		)
		server.assertNoErrors(expect, "late saves")
	end)

	suite:test(
		"a save still in flight when the player leaves cannot re-take the released lock",
		function(expect)
			--[[ CURRENT BEHAVIOUR, AND A SUSPECTED BUG — see the notes.

		     save()'s transform refuses to re-acquire a lock this server has
		     released, guarded by the _released marker. But the successful
		     release used to clear that marker on its way out, which reopened
		     the window the guard exists to close: a save suspended in its retry
		     backoff when the player left would resume afterwards, find
		     `lockJobId == ""` (which the first guard reads as free) and write
		     this server's jobId back over a lock nobody holds — handing the
		     player's next server a read-only session until LOCK_TIMEOUT lapsed.

		     The marker now outlives the release and `load` clears it when the
		     player rejoins, so the late write is refused with the reason the
		     code has always had a branch for. ]]
			local colony = startColony("Alice", { jobId = "job-a" })
			local server = colony.server

			--[[ An autosave caught mid-retry: the store blips, the first attempt
		     fails, and the call suspends in its backoff. That is exactly where
		     the autosave loop sits when a DataStore throttles it. ]]
			local inFlight
			local autosave = coroutine.create(function()
				inFlight = table.pack(colony.Data:save(colony.player, { force = true }))
			end)
			server.dataStoreBroken = true
			local started, err = coroutine.resume(autosave)
			expect.truthy(started, "the in-flight save threw: " .. tostring(err))
			expect.equal(
				coroutine.status(autosave),
				"suspended",
				"the save never reached its retry backoff, so there is nothing in flight to race"
			)
			server.dataStoreBroken = false

			-- The player leaves while that save is suspended; the release lands first.
			server.disconnect(colony.player)
			expect.equal(colony.record().meta.lockJobId, "", "the release never wrote an empty lock")

			-- And now the suspended save retries, against a store that is healthy again.
			server.advance(5)
			expect.equal(coroutine.status(autosave), "dead", "the in-flight save never finished")
			expect.truthy(inFlight, "the in-flight save returned nothing")

			expect.falsy(
				inFlight[1],
				"a save suspended across the release woke up and re-acquired a lock this server had let go"
			)
			expect.equal(
				inFlight[2],
				"released",
				"the save was refused for some other reason, so the release marker is not what stopped it"
			)
			expect.equal(
				colony.record().meta.lockJobId,
				"",
				"the stale save wrote this server's jobId back over a lock nobody holds"
			)
			expect.falsy(
				colony.Data:isLoaded(colony.player),
				"the departed player's entry was resurrected too"
			)
			expect.equal(
				#colony.record().colony.buildings,
				1,
				"the stale write changed the colony as well as the lock, so the damage is wider than described"
			)
			server.assertNoErrors(expect, "stale in-flight save")
		end
	)

	-- ── Two servers, one profile ─────────────────────────────────────────────

	suite:test("a second server cannot steal a live lock and gets a read-only session", function(expect)
		local colony = startColony("Alice", { jobId = "job-a" })
		--[[ Let the first server's own autosave write the record, so the second
		     server reads a snapshot instead of the live table. ]]
		colony.server.advance(colony.tuning.autosaveInterval + 1)

		local other, visitor = contendingServer(colony, "job-b")
		--[[ Asserted rather than assumed: if the simulator ever numbers players
		     differently per server, these two would stop contending for one
		     profile and the test would prove nothing. ]]
		expect.equal(
			visitor.UserId,
			colony.player.UserId,
			"the two servers are not contending for one profile key"
		)
		expect.falsy(
			other.services.DataService:isLoaded(visitor),
			"the second server took the profile immediately instead of waiting out the lock"
		)

		-- It waits and retries before giving up, which is the whole retry budget.
		other.advance(colony.tuning.lockRetryDelay * colony.tuning.lockRetryAttempts + 1)

		expect.truthy(
			other.services.DataService:isLoaded(visitor),
			"the second server never finished its load"
		)
		expect.truthy(
			other.services.DataService:isReadOnly(visitor),
			"the second server took a lock that was live, so two servers now write one profile"
		)
		expect.equal(colony.record().meta.lockJobId, "job-a", "the live lock changed hands")
		expect.equal(#colony.record().colony.buildings, 1, "the second server wrote over the owner's colony")
		expect.truthy(colony.Data:isLoaded(colony.player), "the owner's session was disturbed")
		colony.server.assertNoErrors(expect, "owning server")
		other.assertNoErrors(expect, "contending server")
	end)

	suite:test("a read-only session never writes, on an autosave or on shutdown", function(expect)
		local colony = startColony("Alice", { jobId = "job-a" })
		colony.server.advance(colony.tuning.autosaveInterval + 1)

		local other, visitor = contendingServer(colony, "job-b")
		expect.equal(
			visitor.UserId,
			colony.player.UserId,
			"the two servers are not contending for one profile key"
		)
		other.advance(colony.tuning.lockRetryDelay * colony.tuning.lockRetryAttempts + 1)
		expect.truthy(other.services.DataService:isReadOnly(visitor), "the second session is not read-only")

		--[[ A read-only session is playable, which is the point — but it must
		     refuse anything that would need saving, and say so. ]]
		local Routes = other.require(other.shared.Routes)
		local placed = other.invoke(visitor, Routes.Request.PlaceBuilding, {
			buildingId = colony.Enums.Building.Housing,
			gx = 6,
			gz = 0,
			rot = 0,
		})
		expect.falsy(placed.ok, "a read-only session was allowed to build something it can never save")
		expect.equal(
			placed.detail,
			"read_only",
			"the refusal does not name the read-only session: " .. tostring(placed.detail)
		)

		local refused, reason = throughRetries(other, function()
			return other.services.DataService:save(visitor, { force = true })
		end)
		expect.falsy(refused, "a read-only session wrote over the profile another server owns")
		expect.equal(reason, "read_only", "the refusal was for the wrong reason: " .. tostring(reason))

		--[[ Count the real DataStore calls rather than trusting the return
		     value: an autosave or a shutdown save that slipped through would be
		     a write over a profile this server does not own. ]]
		local callsBefore = colony.store().calls
		other.advance(colony.tuning.autosaveInterval + 1)
		other.shutdown()

		expect.equal(
			colony.store().calls,
			callsBefore,
			"the read-only session reached the DataStore after all"
		)
		expect.equal(
			colony.record().meta.lockJobId,
			"job-a",
			"the read-only session released a lock it never held"
		)
		expect.falsy(
			other.services.DataService:isLoaded(visitor),
			"the read-only entry was not dropped when the session ended"
		)
		colony.server.assertNoErrors(expect, "owning server")
		other.assertNoErrors(expect, "read-only server")
	end)

	-- ── Purchases ────────────────────────────────────────────────────────────

	suite:test("no purchase can be started in this build, so no receipt can arrive", function(expect)
		--[[ Monetization is hard off and every productId in ShopConfig is 0, so
		     nothing here can drive a real purchase. That is why the receipt
		     tests below exercise the bookkeeping directly: there is deliberately
		     no code path that simulates a successful one. ]]
		local colony = startColony("Alice")
		local ShopConfig = colony.server.require(colony.server.shared.Config.ShopConfig)
		local productId = ShopConfig.Order[1]
		expect.truthy(productId, "the shop catalogue is empty, so this test proves nothing")

		local attempt = colony.server.invoke(colony.player, colony.Routes.Request.PromptPurchase, {
			productId = productId,
		})
		expect.falsy(attempt.ok, "the shop prompted a purchase although monetization is switched off")
		expect.equal(
			attempt.detail,
			"monetization_disabled",
			"the refusal does not name the real reason: " .. tostring(attempt.detail)
		)

		local monetization = colony.profile().monetization
		expect.equal(monetization.rescuesPurchased, 0, "something paid-for was granted without a receipt")
		expect.equal(#monetization.receiptOrder, 0, "a receipt was recorded without a purchase")
		colony.server.assertNoErrors(expect, "shop prompt")
	end)

	suite:test("a PurchaseId is recorded once, however many times it arrives", function(expect)
		local colony = startColony("Alice")

		--[[ Roblox retries receipts until they are acknowledged, so fulfilment
		     has to be idempotent or a retry hands out the grant again. This is
		     the check MonetizationService's ProcessReceipt leans on. ]]
		expect.truthy(colony.Data:recordReceipt(colony.player, 998811), "the first receipt was refused")
		for _ = 1, 5 do
			expect.falsy(
				colony.Data:recordReceipt(colony.player, 998811),
				"a receipt that was already fulfilled was recorded again, so the grant would repeat"
			)
		end

		--[[ Roblox hands PurchaseId over as a string; the same purchase must not
		     become a second receipt because of its type. ]]
		expect.falsy(
			colony.Data:recordReceipt(colony.player, "998811"),
			"the same PurchaseId as a string was treated as a different purchase"
		)
		expect.truthy(
			colony.Data:hasReceipt(colony.player, 998811),
			"the recorded receipt cannot be found again"
		)
		expect.equal(#colony.profile().monetization.receiptOrder, 1, "the retries each left an entry behind")

		expect.truthy(
			colony.Data:recordReceipt(colony.player, 998812),
			"a genuinely different purchase was refused"
		)
		colony.server.assertNoErrors(expect, "receipt idempotency")
	end)

	suite:test("a fulfilled receipt survives the session that recorded it", function(expect)
		--[[ A receipt is only acknowledged once the profile has been SAVED, so
		     what the store holds after the player leaves is what stops Roblox's
		     next retry granting the same purchase twice. ]]
		local colony = startColony("Alice")
		expect.truthy(colony.Data:recordReceipt(colony.player, 998811), "the receipt was refused")

		colony.server.disconnect(colony.player)

		local record = colony.record()
		expect.truthy(
			record.monetization.receipts["998811"],
			"the receipt never reached the store, so a retry after the rejoin would grant it twice"
		)
		expect.contains(
			record.monetization.receiptOrder,
			"998811",
			"the receipt was written without its order entry"
		)
		colony.server.assertNoErrors(expect, "receipt round trip")
	end)

	suite:test("receipt history is trimmed to its cap, keeping the recent ones idempotent", function(expect)
		local colony = startColony("Alice")
		local cap = colony.tuning.maxReceiptsKept
		local newest = cap + 10

		for id = 1, newest do
			expect.truthy(colony.Data:recordReceipt(colony.player, id), ("receipt %d was refused"):format(id))
		end

		local ok = throughRetries(colony.server, function()
			return colony.Data:save(colony.player, { force = true })
		end)
		expect.truthy(ok, "the save that trims the history failed")

		--[[ A profile has a size limit and is written on every autosave, so the
		     history cannot grow forever. Trimming the OLDEST entries is the
		     deliberate trade: idempotency is kept for any purchase a player
		     could plausibly still be retrying, and given up for ancient ones. ]]
		local record = colony.record()
		expect.equal(#record.monetization.receiptOrder, cap, "the history was not trimmed to the cap")
		expect.truthy(
			record.monetization.receipts[tostring(newest)],
			"the newest receipt was trimmed away, so a retry of a purchase just made would grant it twice"
		)
		expect.falsy(record.monetization.receipts["1"], "the oldest receipt survived, so nothing was trimmed")
		expect.falsy(
			colony.Data:recordReceipt(colony.player, newest),
			"a receipt still inside the cap lost its idempotency"
		)
		colony.server.assertNoErrors(expect, "receipt trim")
	end)

	-- ── Shutdown ─────────────────────────────────────────────────────────────

	suite:test("a shutdown saves and releases every lock it holds", function(expect)
		local colony = startColony("Alice", { jobId = "job-a" })
		local bob = colony.server.addPlayer("Bob")
		local placed = colony.build(colony.Enums.Building.Housing, 6, 0)
		expect.truthy(placed.ok, "could not build a shelter: " .. tostring(placed.reason))

		colony.server.shutdown()

		--[[ A server that goes down holding locks strands every player on it
		     for LOCK_TIMEOUT, which on a rolling update is a server full of
		     read-only sessions. ]]
		for _, player in ipairs({ colony.player, bob }) do
			local record = colony.record(player)
			expect.truthy(record, ("nothing was written for %s on shutdown"):format(player.Name))
			expect.equal(
				record.meta.lockJobId,
				"",
				("the shutdown left %s's lock held by a server that no longer exists"):format(player.Name)
			)
			expect.falsy(
				colony.Data:isLoaded(player),
				("%s's profile entry survived the shutdown"):format(player.Name)
			)
		end

		expect.equal(
			#colony.record().colony.buildings,
			2,
			"the shutdown save lost the shelter built this session"
		)
		colony.server.assertNoErrors(expect, "shutdown")
	end)
end
