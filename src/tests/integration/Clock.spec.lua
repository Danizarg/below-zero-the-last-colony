--[[
	Clock.spec.lua
	The expedition clock and the maze shift, driven against a fully booted
	simulated server.

	This is the game's defining mechanic, so the parts that are easy to get
	subtly wrong are pinned here rather than assumed:

	  * the phase order and the fact that each phase lasts exactly as long as
	    DifficultyConfig says it does — the tests read the durations out of the
	    session's own difficulty, so changing the config changes the test
	  * the countdown CONTRACT. The server must send remaining DURATIONS, never
	    a server `os.clock()` reading. `os.clock()` is process-relative, so a
	    server clock value means nothing on a client: the HUD used to subtract
	    its own `os.clock()` from the server's and render the difference, which
	    is garbage. These tests assert the numbers on the wire behave like
	    durations — bounded by the phase they belong to, and falling.
	  * the fairness guarantee the whole shift rests on: whatever the walls do,
	    the room a player is standing in keeps a doorway and keeps a route to an
	    extraction point.
	  * dusk is deliberately pure warning. The first shift is scheduled for the
	    END of dusk so the "RETURN TO THE COLONY" alert is actionable; if
	    geometry started moving during dusk the warning would be a lie.

	Determinism: every run is started with an explicit seed (accepted because
	GameConfig.Debug is on), so the layout, the biome and every shift are fixed.
	Nothing here reads a wall clock — `advanceTo` drives virtual time only.

	Each test builds its own server, so nothing leaks between them.
]]

return function(suite, context)
	local newServer = context.newServer
	local CFrame = context.roblox.CFrame

	--[[ A stable fingerprint of the geometry: each room's kind and its four
	     doorways, walked in the layout's own room order so it never depends on
	     table iteration order. Comparing two prints is how a test can say "not
	     one wall moved" without reaching into the shift code. ]]
	local function geometryPrint(layout, directions)
		local parts = {}
		for _, key in ipairs(layout.order) do
			local cell = layout.cells[key]
			local doors = {}
			for _, dir in ipairs(directions) do
				table.insert(doors, cell.doors[dir] and "1" or "0")
			end
			table.insert(parts, ("%s=%s/%s"):format(key, tostring(cell.kind), table.concat(doors)))
		end
		return table.concat(parts, "|")
	end

	--[[ Shared setup: a player, a started expedition on a known seed, and the
	     handles a clock test needs. Returned as a table rather than globals so
	     tests stay readable. ]]
	local function startRun(seed, difficultyId)
		local server = newServer()
		local Routes = server.require(server.shared.Routes)
		local Enums = server.require(server.shared.Enums)
		local CaveLayout = server.require(server.shared.Lib.CaveLayout)

		local player = server.addPlayer("Alice")
		local startResult = server.invoke(player, Routes.Request.StartExpedition, {
			difficultyId = difficultyId or "easy",
			seed = seed,
		})

		local session = server.services.ExpeditionService:sessionOf(player)
		local cave = session and server.services.CaveService:caveFor(session.id)
		local durations = session and session.difficulty.phaseDurations

		local run = {
			server = server,
			Routes = Routes,
			Enums = Enums,
			CaveLayout = CaveLayout,
			player = player,
			startResult = startResult,
			session = session,
			cave = cave,
			services = server.services,
			durations = durations,
		}

		--[[ Every phase boundary as an absolute point on the virtual clock,
		     anchored to the session's OWN origin — `startedAt`, the os.clock()
		     reading at the moment ExpeditionService built it. Two things make a
		     zero anchor wrong: the simulated clock deliberately starts at
		     SIM_START_CLOCK rather than 0 (a zero-initialised cooldown would
		     otherwise read as "already on cooldown"), and the start handler may
		     itself consume virtual time. Offsetting from the session's own origin
		     is correct under both. No number here is hard-coded from the config. ]]
		local origin = session and session.startedAt or 0
		run.endOf = {
			prep = origin + durations.prep,
			day = origin + durations.prep + durations.day,
			dusk = origin + durations.prep + durations.day + durations.dusk,
			night = origin + durations.prep + durations.day + durations.dusk + durations.night,
		}

		--[[ Step to an absolute moment rather than by a delta. A test that first
		     walks the player somewhere spends a second on room tracking, and with
		     relative advances that second would push every later boundary out of
		     reach. ]]
		function run.advanceTo(moment)
			local remaining = moment - server.now()
			if remaining > 0 then
				server.advance(remaining)
			end
		end

		function run.sync()
			return server.lastPush(player, Routes.Push.ExpeditionSync)
		end

		function run.standIn(cellKey)
			player.Character.PrimaryPart.CFrame =
				CFrame.new(server.services.CaveService:worldPositionOfCell(session.id, cellKey))
			--[[ Room tracking runs on a Heartbeat interval, so give it a tick to
			     notice; `roomOf` is what the shift's protection reads. ]]
			server.advance(1)
		end

		function run.doorCount(cellKey)
			local cell = cave.layout.cells[cellKey]
			if not cell then
				return 0
			end
			local count = 0
			for _, dir in ipairs(Enums.DirectionList) do
				if cell.doors[dir] then
					count += 1
				end
			end
			return count
		end

		function run.geometry()
			return geometryPrint(cave.layout, Enums.DirectionList)
		end

		function run.profile()
			return server.services.DataService:get(player)
		end

		function run.bag()
			return server.services.InventoryService:bagOf(player)
		end

		return run
	end

	-- ── The phase order ──────────────────────────────────────────────────────

	suite:test("the clock walks prep → day → dusk → night on the configured durations", function(expect)
		local run = startRun(20260101)
		expect.truthy(run.startResult.ok, "start was refused: " .. tostring(run.startResult.reason))
		expect.truthy(run.session, "no session was created")
		expect.equal(run.session.phase, run.Enums.Phase.Prep, "a fresh run must begin in prep")

		local schedule = {
			{ phase = run.Enums.Phase.Day, at = run.endOf.prep },
			{ phase = run.Enums.Phase.Dusk, at = run.endOf.day },
			{ phase = run.Enums.Phase.Night, at = run.endOf.dusk },
		}

		for index, step in ipairs(schedule) do
			run.advanceTo(step.at)

			expect.equal(
				run.session.phase,
				step.phase,
				("after %ds the session should be in %s, not %s"):format(
					step.at,
					step.phase,
					tostring(run.session.phase)
				)
			)
			--[[ Exactly one announcement per boundary. A clock that fires its push
			     from a tick rather than from the transition would send one every
			     half second for the rest of the phase. ]]
			expect.equal(
				run.server.pushCount(run.player, run.Routes.Push.PhaseChanged),
				index,
				("expected %d phase announcements by %s, got %d"):format(
					index,
					step.phase,
					run.server.pushCount(run.player, run.Routes.Push.PhaseChanged)
				)
			)
			expect.equal(
				run.server.lastPush(run.player, run.Routes.Push.PhaseChanged).phase,
				run.session.phase,
				"the announced phase disagrees with the phase the session is actually in"
			)
			expect.equal(
				run.sync().phase,
				run.session.phase,
				"the session snapshot disagrees with the session's own phase"
			)
		end

		run.server.assertNoErrors(expect, "phase order")
	end)

	suite:test("no phase ends before its configured duration is up", function(expect)
		--[[ The order alone would still pass if every phase lasted a second. This
		     is the half that proves the durations are honoured: one second short
		     of each boundary the old phase is still running. ]]
		local run = startRun(20260101)

		local checks = {
			{ phase = run.Enums.Phase.Prep, at = run.endOf.prep - 1 },
			{ phase = run.Enums.Phase.Day, at = run.endOf.day - 1 },
			{ phase = run.Enums.Phase.Dusk, at = run.endOf.dusk - 1 },
			{ phase = run.Enums.Phase.Night, at = run.endOf.night - 1 },
		}

		for _, check in ipairs(checks) do
			run.advanceTo(check.at)
			expect.equal(
				run.session.phase,
				check.phase,
				("%s ended early: at %ds the session was already in %s"):format(
					check.phase,
					check.at,
					tostring(run.session.phase)
				)
			)
			expect.truthy(
				run.services.ExpeditionService:sessionOf(run.player),
				("the run was already over at %ds"):format(check.at)
			)
		end

		--[[ And the last second really does finish it, so the test above is not
		     passing because the clock stopped. ]]
		run.advanceTo(run.endOf.night)
		expect.falsy(
			run.services.ExpeditionService:sessionOf(run.player),
			"night ran out and the run carried on anyway"
		)
		run.server.assertNoErrors(expect, "phase durations")
	end)

	suite:test("each phase change announces itself once, with that phase's own duration", function(expect)
		local run = startRun(20260101)
		run.advanceTo(run.endOf.dusk) -- through day and dusk, into night

		local announcements = run.server.pushes(run.player, run.Routes.Push.PhaseChanged)
		expect.equal(
			#announcements,
			3,
			("three boundaries were crossed, so three announcements are due; got %d"):format(#announcements)
		)

		local expected = {
			{ phase = run.Enums.Phase.Day, duration = run.durations.day },
			{ phase = run.Enums.Phase.Dusk, duration = run.durations.dusk },
			{ phase = run.Enums.Phase.Night, duration = run.durations.night },
		}

		for index, entry in ipairs(expected) do
			local push = announcements[index]
			expect.equal(push.phase, entry.phase, ("announcement %d names the wrong phase"):format(index))
			expect.equal(
				push.duration,
				entry.duration,
				("the %s announcement does not carry the duration DifficultyConfig gives %s"):format(
					entry.phase,
					entry.phase
				)
			)
			--[[ A phase that has only just begun has all of itself left. This is
			     also the field the HUD counts down from, so it must be a duration
			     and not a deadline. ]]
			expect.isType(
				push.remaining,
				"number",
				("the %s announcement carries no `remaining`, so the HUD has nothing to count"):format(
					entry.phase
				)
			)
			expect.equal(
				push.remaining,
				entry.duration,
				("%s was announced with %s of %s seconds already gone"):format(
					entry.phase,
					tostring(entry.duration - push.remaining),
					tostring(entry.duration)
				)
			)
		end

		run.server.assertNoErrors(expect, "phase announcements")
	end)

	-- ── The countdown contract: durations, never timestamps ──────────────────

	suite:test("R: ExpeditionSync counts a duration DOWN and never ships a clock reading", function(expect)
		--[[ The regression. The server used to hand the client `phaseEndsAt`, an
		     absolute `os.clock()` deadline. `os.clock()` is process-relative, so
		     that number means nothing in another process: the HUD subtracted its
		     own `os.clock()` from it and rendered the difference, which is
		     garbage — a timer that could read hours, or negative.

		     Two things catch that here. A deadline would sit perfectly STILL for
		     the whole phase, so the field must fall as time passes; and a clock
		     reading has no reason to stay inside the phase it describes, so it
		     must be bounded by its own phaseDuration. ]]
		local run = startRun(20260101)
		run.advanceTo(run.endOf.prep) -- into day, the longest phase to measure in

		local atDayStart = run.sync()
		expect.equal(atDayStart.phase, run.Enums.Phase.Day, "guard: this test measures inside day")
		expect.equal(
			atDayStart.phaseDuration,
			run.durations.day,
			"the snapshot's phaseDuration is not the configured length of day"
		)
		expect.inRange(
			atDayStart.phaseRemaining,
			0,
			atDayStart.phaseDuration,
			"phaseRemaining is outside the phase it belongs to, which is what a raw clock value looks like"
		)
		expect.near(
			atDayStart.phaseRemaining,
			run.durations.day,
			1,
			"the first snapshot of a phase should have very nearly the whole phase still to run"
		)

		local elapsed = 120
		run.advanceTo(run.endOf.prep + elapsed)
		local later = run.sync()

		expect.lessThan(
			later.phaseRemaining,
			atDayStart.phaseRemaining,
			"phaseRemaining did not fall as time passed: a deadline timestamp would have stayed exactly where it was"
		)
		expect.near(
			atDayStart.phaseRemaining - later.phaseRemaining,
			elapsed,
			1,
			"two minutes of simulated time did not take two minutes off the countdown"
		)
		expect.atMost(
			later.phaseRemaining,
			run.session.difficulty.totalSeconds,
			"phaseRemaining is longer than the entire expedition, so it cannot be a remaining duration"
		)
		expect.equal(
			later.phaseDuration,
			run.durations.day,
			"phaseDuration drifted mid-phase; the client needs it fixed to draw a progress bar"
		)

		run.server.assertNoErrors(expect, "phase countdown")
	end)

	suite:test("R: no push in a whole run carries an absolute clock value", function(expect)
		--[[ The broad net under the test above: sweep every snapshot of a full
		     1530-second run and check that no time-shaped field ever leaves the
		     range a DURATION could occupy. By the end the server's own clock has
		     passed the whole run length, so if any field were a clock reading it
		     would be sitting up there in the thousands with it. ]]
		local run = startRun(20260101)
		run.advanceTo(run.endOf.night)

		local longestPhase =
			math.max(run.durations.prep, run.durations.day, run.durations.dusk, run.durations.night)
		--[[ The widest gap the shift schedule can produce: the whole of dusk
		     before the first one, then the configured interval. ]]
		local longestShiftGap = math.max(run.durations.dusk, run.session.difficulty.shiftIntervalSeconds)

		local syncs = run.server.pushes(run.player, run.Routes.Push.ExpeditionSync)
		expect.atLeast(#syncs, 100, "a run this long should have pushed a snapshot on every clock tick")

		local highest = 0
		for index, sync in ipairs(syncs) do
			expect.isType(
				sync.phaseRemaining,
				"number",
				("snapshot %d went out with no phaseRemaining at all"):format(index)
			)
			expect.inRange(
				sync.phaseRemaining,
				0,
				longestPhase,
				("snapshot %d sent phaseRemaining=%s, which no phase of this difficulty is long enough to explain"):format(
					index,
					tostring(sync.phaseRemaining)
				)
			)
			if sync.nextShiftIn ~= nil then
				expect.inRange(
					sync.nextShiftIn,
					0,
					longestShiftGap,
					("snapshot %d sent nextShiftIn=%s, longer than the longest gap the schedule can produce"):format(
						index,
						tostring(sync.nextShiftIn)
					)
				)
			end
			highest = math.max(highest, sync.phaseRemaining)
		end

		expect.atLeast(run.server.now(), run.endOf.night, "guard: the run did not actually play out in full")
		--[[ And the bound above is not passing because every number was zero: the
		     countdown really does start at the top of the longest phase. ]]
		expect.near(
			highest,
			longestPhase,
			1,
			"no snapshot ever carried close to a full phase, so these numbers are not tracking a phase at all"
		)
		expect.lessThan(
			highest,
			run.server.now(),
			"the largest number ever sent is of the order of the server's clock rather than of a phase"
		)

		for index, push in ipairs(run.server.pushes(run.player, run.Routes.Push.PhaseChanged)) do
			expect.inRange(
				push.remaining,
				0,
				longestPhase,
				("phase announcement %d carries a `remaining` no phase could explain"):format(index)
			)
			expect.inRange(
				push.duration,
				0,
				longestPhase,
				("phase announcement %d carries a `duration` no phase could explain"):format(index)
			)
		end

		for index, push in ipairs(run.server.pushes(run.player, run.Routes.Push.ShiftWarning)) do
			--[[ A warning's lead time is a handful of seconds by design; anything
			     large here would be a deadline wearing a countdown's name. ]]
			expect.inRange(
				push.secondsRemaining,
				1,
				60,
				("shift warning %d announced a lead time of %s seconds"):format(
					index,
					tostring(push.secondsRemaining)
				)
			)
		end

		run.server.assertNoErrors(expect, "payload sweep")
	end)

	-- ── The shift schedule ───────────────────────────────────────────────────

	suite:test("the shift countdown appears only when dusk begins, and then falls", function(expect)
		local run = startRun(20260101)

		run.advanceTo(run.endOf.prep)
		expect.falsy(
			run.sync().nextShiftIn,
			"a shift was already on the clock during the day, long before anyone was warned"
		)
		run.advanceTo(run.endOf.prep + 60)
		expect.falsy(run.sync().nextShiftIn, "a shift appeared on the clock mid-day")

		run.advanceTo(run.endOf.day)
		local atDusk = run.sync()
		expect.isType(atDusk.nextShiftIn, "number", "dusk began without scheduling the first shift")
		expect.near(
			atDusk.nextShiftIn,
			run.durations.dusk,
			1,
			"the first shift should be a whole dusk away: dusk is meant to be warning time, not shifting time"
		)

		local elapsed = 100
		run.advanceTo(run.endOf.day + elapsed)
		local later = run.sync()
		expect.lessThan(later.nextShiftIn, atDusk.nextShiftIn, "the shift countdown is not moving")
		expect.near(
			atDusk.nextShiftIn - later.nextShiftIn,
			elapsed,
			1,
			"the shift countdown did not fall at one second per second"
		)

		run.server.assertNoErrors(expect, "shift countdown")
	end)

	suite:test("dusk is pure warning: not one wall moves until night falls", function(expect)
		--[[ The first shift is scheduled for the END of dusk on purpose. The dusk
		     alert tells the player to get out; if the geometry started changing
		     while that alert was on screen the warning would be worthless. ]]
		local run = startRun(12345)

		run.advanceTo(run.endOf.day)
		local before = run.geometry()
		--[[ Guard: an empty fingerprint would match an empty fingerprint, and the
		     comparison below would prove nothing. ]]
		expect.atLeast(#before, #run.cave.layout.order, "the geometry fingerprint is empty")

		run.advanceTo(run.endOf.dusk - 1)
		expect.equal(run.session.phase, run.Enums.Phase.Dusk, "guard: this test measures inside dusk")
		expect.equal(
			run.server.pushCount(run.player, run.Routes.Push.ShiftApplied),
			0,
			"a shift was applied during dusk, which is supposed to be pure warning"
		)
		expect.equal(run.session.shiftsApplied, 0, "the session counted a shift before night fell")
		expect.equal(
			run.geometry(),
			before,
			"the cave's doors or room kinds changed during dusk even though no shift was announced"
		)
		expect.atLeast(
			run.server.pushCount(run.player, run.Routes.Push.ShiftWarning),
			2,
			"dusk passed without warning the player that the caves were about to shift"
		)

		run.server.assertNoErrors(expect, "dusk")
	end)

	suite:test("the first shift is announced twice, then lands as night falls", function(expect)
		local run = startRun(12345)

		run.advanceTo(run.endOf.dusk - 1)
		local warnings = run.server.pushes(run.player, run.Routes.Push.ShiftWarning)
		expect.equal(
			#warnings,
			2,
			("expected the two scheduled warnings before the first shift, got %d"):format(#warnings)
		)
		expect.equal(warnings[1].secondsRemaining, 30, "the first warning did not come 30 seconds out")
		expect.equal(warnings[2].secondsRemaining, 10, "the second warning did not come 10 seconds out")
		expect.equal(
			run.server.pushCount(run.player, run.Routes.Push.ShiftApplied),
			0,
			"the shift landed before its own warnings had finished"
		)

		run.advanceTo(run.endOf.dusk)
		expect.equal(run.session.phase, run.Enums.Phase.Night, "guard: night should have fallen")
		expect.equal(run.session.shiftsApplied, 1, "the first shift did not land with nightfall")

		local applied = run.server.lastPush(run.player, run.Routes.Push.ShiftApplied)
		expect.truthy(applied, "the caves shifted without telling the players")
		expect.equal(applied.shiftNumber, 1, "the first shift was not announced as the first")
		expect.atLeast(applied.changed, 1, "a shift that rearranged no rooms is not a shift")
		expect.atLeast(
			applied.opened + applied.closed,
			1,
			"a shift that opened and closed no passages would leave the maze exactly as it was"
		)
		--[[ Any room a player is in may have gained or lost a doorway, so the map
		     has to come with the announcement or their own room reads stale. ]]
		expect.truthy(applied.map, "the shift did not refresh the player's map")

		run.server.assertNoErrors(expect, "first shift")
	end)

	suite:test("every shift of the night is counted and announced", function(expect)
		local run = startRun(12345)
		local interval = run.session.difficulty.shiftIntervalSeconds

		run.advanceTo(run.endOf.dusk)
		expect.equal(run.session.shiftsApplied, 1, "guard: the first shift lands with nightfall")

		for number = 2, 3 do
			run.advanceTo(run.endOf.dusk + interval * (number - 1))
			expect.equal(
				run.session.shiftsApplied,
				number,
				("shift %d did not arrive on the difficulty's %ds interval"):format(number, interval)
			)
			expect.equal(
				run.server.pushCount(run.player, run.Routes.Push.ShiftApplied),
				number,
				("%d shifts have happened but the players were told about %d"):format(
					number,
					run.server.pushCount(run.player, run.Routes.Push.ShiftApplied)
				)
			)
			expect.equal(
				run.server.lastPush(run.player, run.Routes.Push.ShiftApplied).shiftNumber,
				number,
				"the announcement's shift number does not match how many have happened"
			)
			--[[ Every shift gets the same pair of warnings, so nobody is ever
			     rearranged without notice. ]]
			expect.equal(
				run.server.pushCount(run.player, run.Routes.Push.ShiftWarning),
				number * 2,
				("expected two warnings per shift; after %d shifts there were %d"):format(
					number,
					run.server.pushCount(run.player, run.Routes.Push.ShiftWarning)
				)
			)
		end

		run.server.assertNoErrors(expect, "shift schedule")
	end)

	-- ── The fairness guarantee ───────────────────────────────────────────────

	suite:test("the layout is still valid after a night of shifts", function(expect)
		--[[ The shift mutates the layout in place and is supposed to validate the
		     result before any geometry moves, rolling back if it broke an
		     invariant. So after any number of shifts the live layout must still
		     satisfy the same contract the generator did: symmetric doors, nothing
		     opening into empty space, every room reachable, every room able to
		     reach an extraction point, every objective still in a live cell. ]]
		local run = startRun(8675309)
		local interval = run.session.difficulty.shiftIntervalSeconds

		local before = run.CaveLayout.validate(run.cave.layout)
		expect.truthy(before.ok, "guard: the generated cave was already invalid")

		for number = 1, 3 do
			run.advanceTo(run.endOf.dusk + interval * (number - 1))
			expect.equal(
				run.session.shiftsApplied,
				number,
				("guard: shift %d should have landed"):format(number)
			)

			local validation = run.CaveLayout.validate(run.cave.layout)
			expect.truthy(
				validation.ok,
				("the cave is broken after shift %d: %s"):format(
					number,
					table.concat(validation.errors, " | ")
				)
			)
		end

		run.server.assertNoErrors(expect, "layout after shifts")
	end)

	suite:test("the room a player stands in keeps a door and a route out", function(expect)
		--[[ This is the promise the whole mechanic rests on. Walls may move, but
		     nobody may be sealed into a room, and nobody may be cut off from
		     every way home — otherwise a shift is a death sentence rather than a
		     complication.

		     The player waits in the vault, which the generator places as far from
		     the entrance as it can, so this is the hardest case for the route
		     check. ]]
		local run = startRun(8675309)
		expect.truthy(run.cave.layout.vaultKey, "no vault was placed")
		run.standIn(run.cave.layout.vaultKey)
		expect.equal(
			run.services.CaveService:roomOf(run.player),
			run.cave.layout.vaultKey,
			"the server does not believe the player is standing in the vault"
		)

		local interval = run.session.difficulty.shiftIntervalSeconds
		for number = 1, 3 do
			run.advanceTo(run.endOf.dusk + interval * (number - 1))
			expect.equal(
				run.session.shiftsApplied,
				number,
				("guard: shift %d should have landed"):format(number)
			)

			local room = run.services.CaveService:roomOf(run.player)
			expect.truthy(room, ("the player had no room at all after shift %d"):format(number))
			expect.atLeast(
				run.doorCount(room),
				1,
				("shift %d sealed the player into room %s with no doorway out"):format(number, tostring(room))
			)
			expect.truthy(
				run.CaveLayout.pathToExtraction(run.cave.layout, room),
				("shift %d cut room %s off from every extraction point"):format(number, tostring(room))
			)
		end

		run.server.assertNoErrors(expect, "occupied room after shifts")
	end)

	-- ── Night running out ────────────────────────────────────────────────────

	suite:test("a survivor of a timeout is settled on the TIMEOUT fraction", function(expect)
		local run = startRun(20260101)
		local Inventory = run.services.InventoryService

		--[[ Put a known quantity in through the service rather than by reaching
		     into the table, so the capacity rules apply. ]]
		Inventory:addToBag(run.player, run.Enums.Resource.Stone, 100)
		local storedBefore = run.profile().colony.storage[run.Enums.Resource.Stone] or 0

		local timeoutFraction = run.session.difficulty.lootKeptOnTimeoutFraction
		local deathFraction = run.session.difficulty.lootKeptOnDeathFraction
		expect.notEqual(
			timeoutFraction,
			deathFraction,
			"guard: this test cannot tell the two settlement paths apart if their fractions are equal"
		)

		run.advanceTo(run.endOf.night)

		local storedAfter = run.profile().colony.storage[run.Enums.Resource.Stone] or 0
		local recovered = storedAfter - storedBefore

		--[[ Rounding is in the player's favour (ceil), matching every other
		     settlement path. ]]
		expect.equal(
			recovered,
			math.ceil(100 * timeoutFraction),
			"a timed-out haul was not cut by the difficulty's timeout fraction"
		)
		expect.notEqual(
			recovered,
			math.ceil(100 * deathFraction),
			"the run was settled as a death rather than a timeout, so the wrong fraction was applied"
		)
		expect.falsy(next(run.bag().items), "the bag was not emptied when the run was settled")

		run.server.assertNoErrors(expect, "timeout settlement")
	end)

	suite:test("a survivor caught by nightfall gets one results screen, outcome 'timeout'", function(expect)
		local run = startRun(20260101)
		local xpBefore = run.profile().progression.xp

		run.advanceTo(run.endOf.night)

		local results = run.server.pushes(run.player, run.Routes.Push.Results)
		expect.equal(#results, 1, ("expected exactly one results screen, got %d"):format(#results))
		expect.equal(
			results[1].outcome,
			"timeout",
			"a player who simply ran out of night was not reported as a timeout"
		)
		expect.falsy(
			results[1].extracted,
			"being caught underground at dawn was recorded as a clean extraction"
		)
		expect.equal(
			results[1].keptFraction,
			run.session.difficulty.lootKeptOnTimeoutFraction,
			"the results screen quotes a different kept fraction from the one the settlement used"
		)
		expect.equal(
			results[1].shiftsSurvived,
			run.session.shiftsApplied,
			"the results screen disagrees with the session about how many shifts happened"
		)
		expect.atLeast(results[1].shiftsSurvived, 1, "a full night passed without a single shift")
		expect.equal(
			run.profile().progression.xp - xpBefore,
			results[1].xpGained,
			"the results screen disagrees with the profile about XP"
		)
		expect.atLeast(
			run.profile().progression.expeditionsFailed or 0,
			1,
			"a timeout was not counted as a failed expedition"
		)

		run.server.assertNoErrors(expect, "timeout results")
	end)

	suite:test("a timed-out run is torn down: no session, no cave, back in the colony", function(expect)
		--[[ Nobody may be left standing in a cave that has been deleted, and a
		     settled player must stop resolving to a live session — that mapping
		     is what every expedition route gates on. ]]
		local run = startRun(20260101)
		local sessionId = run.session.id

		run.advanceTo(run.endOf.night)

		expect.falsy(
			run.services.ExpeditionService:sessionOf(run.player),
			"a player whose night ran out still resolves to a live session"
		)
		expect.falsy(
			run.services.ExpeditionService:sessionById(sessionId),
			"the finished session was left in the registry"
		)
		expect.falsy(run.services.CaveService:caveFor(sessionId), "the cave outlived the expedition")
		expect.falsy(
			run.services.CaveService:roomOf(run.player),
			"the server still thinks the player is standing in a room of a deleted cave"
		)
		expect.equal(
			run.services.ColonyService:zoneOf(run.player),
			run.Enums.Zone.Colony,
			"the player was not returned to the colony"
		)
		--[[ A timeout must leave the colony alone; losing a run is never allowed
		     to cost the thing the player is building. ]]
		expect.atLeast(#run.profile().colony.buildings, 1, "the timeout disturbed the colony")

		run.server.assertNoErrors(expect, "teardown")
	end)
end
