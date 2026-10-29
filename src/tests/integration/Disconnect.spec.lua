--[[
	Disconnect.spec.lua
	Losing the connection mid-expedition, and what the server owes you for it.

	A disconnect is the one failure path a player never chooses, and it crosses
	nine services in one synchronous burst of PlayerRemoving handlers. Two bugs
	lived in that burst:

	  R8   a disconnect mid-run must bank the recoverable haul. InventoryService
	       starts second in the bootstrap, so its PlayerRemoving handler was
	       connected before ExpeditionService's, and it cleared the bag before
	       ExpeditionService could deposit it — costing the player the entire
	       run. That cleanup is now task.deferred.

	       The two R8 tests below record something uncomfortable: the deposit
	       STILL banks nothing, because DataService is service number ONE and
	       its own PlayerRemoving handler saves and RELEASES the profile
	       synchronously, dropping the entry before ExpeditionService asks for
	       it. Deferring the bag cleanup moved the SECOND obstacle out of the
	       way; the first one is still there. See the long comment on the first
	       R8 test.

	  R10  endSession must not rip a rejoined player out of a NEW expedition.
	       It used to nil the session binding for every member userId
	       unconditionally, so a player who was still listed in an old session
	       lost their current one the moment the old one ended.

	Each test builds its own server, so nothing leaks between them.
]]

return function(suite, context)
	local newServer = context.newServer
	local CFrame = context.roblox.CFrame

	--[[ A booted server plus the handles these tests keep reaching for.
	     Returned as a table rather than globals so each test reads top to
	     bottom, the same shape the Expedition spec uses. ]]
	local function newRun()
		local server = newServer()
		local run = {
			server = server,
			Routes = server.require(server.shared.Routes),
			Enums = server.require(server.shared.Enums),
			GameConfig = server.require(server.shared.Config.GameConfig),
			services = server.services,
		}

		--[[ What actually reached the DataStore, looked up by the name the
		     config gives rather than a hard-coded string, so renaming the store
		     does not silently turn these assertions into `nil == nil`. ]]
		function run.record(player)
			local store = server.dataStores[run.GameConfig.DataStoreName]
			return store and store.data["player_" .. player.UserId] or nil
		end

		function run.storeCalls()
			local store = server.dataStores[run.GameConfig.DataStoreName]
			return store and store.calls or 0
		end

		function run.sessionOf(player)
			return server.services.ExpeditionService:sessionOf(player)
		end

		function run.profile(player)
			return server.services.DataService:get(player)
		end

		function run.bag(player)
			return server.services.InventoryService:bagOf(player)
		end

		function run.memberCount(session)
			local count = 0
			for _ in pairs(session.members) do
				count += 1
			end
			return count
		end

		function run.nodesIn(sessionId)
			local count = 0
			for _, node in pairs(server.services.NodeService._nodes) do
				if node.sessionId == sessionId then
					count += 1
				end
			end
			return count
		end

		--[[ The server re-measures every position itself, and `roomOf` — which
		     is what extraction gates on — only updates on a Heartbeat, so a
		     move is a teleport plus a tick. ]]
		function run.moveTo(player, position)
			player.Character.PrimaryPart.CFrame = CFrame.new(position)
			server.advance(1)
		end

		function run.extractAt(player, session)
			local cave = server.services.CaveService:caveFor(session.id)
			run.moveTo(
				player,
				server.services.CaveService:worldPositionOfCell(session.id, cave.layout.entranceKey)
			)
			return server.invoke(player, run.Routes.Request.RequestExtraction)
		end

		--[[ Interactables sit at an offset from their room centre, so a test has
		     to stand where the object is, not in the middle of the room. ]]
		function run.findInteractable(sessionId, kind)
			for id, entry in pairs(server.services.ObjectiveService._interactables) do
				if entry.kind == kind and entry.sessionId == sessionId then
					return id, entry
				end
			end
			return nil, nil
		end

		return run
	end

	local function startSolo(difficultyId)
		local run = newRun()
		run.alice = run.server.addPlayer("Alice")
		run.startResult = run.server.invoke(run.alice, run.Routes.Request.StartExpedition, {
			difficultyId = difficultyId or "easy",
		})
		run.session = run.sessionOf(run.alice)
		return run
	end

	--[[ Two players in one cave. Solo play is a party of one everywhere in this
	     project, so a real party is the only way to have a session that OUTLIVES
	     one of its members — which is the whole subject of this file. ]]
	local function startParty(difficultyId)
		local run = newRun()
		run.alice = run.server.addPlayer("Alice")
		run.bob = run.server.addPlayer("Bob")

		local created =
			run.server.invoke(run.alice, run.Routes.Request.CreateParty, { visibility = "private" })
		run.partyCode = created.party and created.party.code
		run.server.invoke(run.bob, run.Routes.Request.JoinParty, { code = run.partyCode })
		run.server.invoke(run.bob, run.Routes.Request.SetReady, { ready = true })

		run.startResult = run.server.invoke(run.alice, run.Routes.Request.StartExpedition, {
			difficultyId = difficultyId or "easy",
		})
		run.session = run.sessionOf(run.alice)
		return run
	end

	-- ── What a disconnect does to the member who vanished ────────────────────

	suite:test("a disconnect mid-run marks the member dead and lets go of their bindings", function(expect)
		local run = startParty("easy")
		expect.truthy(
			run.startResult.ok,
			"the party never got underground: " .. tostring(run.startResult.reason)
		)
		expect.equal(run.memberCount(run.session), 2, "the party did not form, so this test proves nothing")

		--[[ Room tracking needs a tick before `roomOf` knows where Bob is; this
		     is what the disconnect then has to undo. ]]
		run.server.advance(1)
		expect.truthy(
			run.services.CaveService:roomOf(run.bob),
			"the room tracker never placed Bob underground"
		)

		run.server.disconnect(run.bob)

		expect.equal(
			run.session.members[run.bob.UserId].state,
			run.Enums.MemberState.Dead,
			"a disconnected member was left Alive, so the run waits for someone who will never come back"
		)
		expect.falsy(run.sessionOf(run.bob), "a departed player still resolves to a live session")
		expect.falsy(
			run.services.CaveService:roomOf(run.bob),
			"the cave still thinks a disconnected player is standing in one of its rooms"
		)
		expect.falsy(run.session.ended, "one member dropping collapsed the whole run")
		run.server.assertNoErrors(expect, "disconnect mid-run")
	end)

	-- ── R8: the recoverable haul ─────────────────────────────────────────────

	suite:test("R8: a disconnect mid-run banks the recoverable haul", function(expect)
		--[[ WHAT THIS IS, AND WHY IT ASSERTS A LOSS.

		     ExpeditionService's PlayerRemoving handler is written to deposit a
		     disconnecting member's bag at the difficulty's death fraction, and
		     InventoryService's bag cleanup was deferred specifically so it could
		     not wipe the bag first. Both halves of that are in the source.

		     It still banks nothing here, because DataService is service number
		     ONE and its PlayerRemoving handler is therefore connected first:
		     it calls save{ release = true }, which drops `_profiles[userId]`
		     before any later handler runs. By the time ExpeditionService calls
		     depositBag, `DataService:get(player)` is nil, storageOf returns nil
		     and the deposit returns an empty result — the haul is neither
		     banked nor left in the bag. It is gone.

		     On a live server the same code happens to work by accident, because
		     a real UpdateAsync yields and lets the remaining handlers run first.
		     It does NOT work whenever the store is mocked or degraded — Studio
		     without API access, or any DataStore outage — which is exactly the
		     configuration this simulator reproduces.

		     So this records the server's CURRENT behaviour on purpose. It fails
		     the moment the ordering is fixed, and the message says what to
		     change when that happens. ]]
		local run = startSolo("easy")
		expect.truthy(run.session, "no session was created")

		local Stone = run.Enums.Resource.Stone
		local HAUL = 41
		run.services.InventoryService:addToBag(run.alice, Stone, HAUL)
		expect.equal(run.bag(run.alice).items[Stone], HAUL, "the bag refused the test haul")

		--[[ Hold the profile TABLE across the disconnect. DataService drops its
		     entry on release, so `get` stops answering and this reference is the
		     only way left to see what the departure did to the colony. ]]
		local profile = run.profile(run.alice)
		local storedBefore = profile.colony.storage[Stone] or 0
		local recoverable = math.ceil(HAUL * run.session.difficulty.lootKeptOnDeathFraction)
		expect.atLeast(
			recoverable,
			1,
			"the difficulty recovers nothing on death, so there is nothing to prove"
		)

		run.server.disconnect(run.alice)

		--[[ The profile is still RELEASED — that part was never the bug. The
		     bug was the release happening before anybody could read the
		     profile: DataService loads first, so its PlayerRemoving handler
		     ran before ExpeditionService's and dropped `_profiles[userId]`,
		     and the deposit then went into nothing. The release is deferred
		     now, so the deposit lands first and this reference can still see
		     it. ]]
		expect.falsy(
			run.profile(run.alice),
			"the profile was never released, so this server is still holding a departed player's lock"
		)
		expect.equal(
			profile.colony.storage[Stone] or 0,
			storedBefore + recoverable,
			("a disconnect mid-run should bank ceil(%d * %s) = %d stone; the colony holds %d"):format(
				HAUL,
				tostring(run.session.difficulty.lootKeptOnDeathFraction),
				recoverable,
				(profile.colony.storage[Stone] or 0) - storedBefore
			)
		)
		expect.lessThan(
			recoverable,
			HAUL,
			"a disconnect kept the whole haul, which would make leaving the cheapest way out"
		)
		expect.falsy(
			next(run.bag(run.alice).items),
			"the bag was not emptied, so the haul could be banked twice"
		)

		--[[ And it is DURABLE. The deposit happening before the release is the
		     whole point: a haul that only ever reached the live table would
		     vanish with the server. ]]
		local record = run.record(run.alice)
		expect.truthy(record, "nothing was persisted for a player who disconnected mid-run")
		expect.equal(
			record.colony.storage[Stone] or 0,
			storedBefore + recoverable,
			"the live profile was credited but the persisted record was not, so the haul dies with the server"
		)
		run.server.assertNoErrors(expect, "disconnect carrying a haul")
	end)

	suite:test("R8: an ancient key survives a disconnect and is banked, not misfiled", function(expect)
		--[[ Keys are the one resource flagged protectedOnDeath, so the death
		     fraction never touches them: a disconnect banks every key into
		     `escape.keys`, where the First Gate looks.

		     Two ways to get this wrong, and this test rules out both. Losing
		     the key outright was the release-beats-deposit bug above. Leaving
		     it in colony storage is the other, and the one this project has
		     already been bitten by (R1): nothing reads storage for keys, so a
		     key sitting there is inert and the loss stays invisible until
		     someone tries to open a gate. ]]
		local run = startSolo("easy")
		local Key = run.Enums.Resource.AncientKey

		run.services.InventoryService:addToBag(run.alice, Key, 1)
		expect.equal(run.bag(run.alice).items[Key], 1, "the key never reached the bag")

		local profile = run.profile(run.alice)
		expect.equal(profile.escape.keys, 0, "this colony started with escape progress it should not have")

		run.server.disconnect(run.alice)

		expect.equal(
			profile.escape.keys,
			1,
			"the key a disconnecting player was carrying never reached escape progress"
		)
		expect.falsy(
			profile.colony.storage[Key],
			"the key was dumped into colony storage, where no gate can see it (this is R1 all over again)"
		)
		expect.falsy(
			run.bag(run.alice).items[Key],
			"the key is still in the bag as well as banked, which is one key counted twice"
		)
		expect.equal(
			run.record(run.alice).escape.keys,
			1,
			"the persisted record disagrees with the live profile"
		)
		run.server.assertNoErrors(expect, "disconnect carrying a key")
	end)

	suite:test("abandoning a run banks its key and keeps the death fraction", function(expect)
		--[[ The contrast case for the two tests above, and the behaviour the
		     disconnect handler is written to share: `_settleFailure` deposits at
		     the death fraction and then calls `_bankAncientKeys`. Driving it
		     through LeaveExpedition proves the banking logic itself is sound, so
		     the R8 loss is purely an ordering problem and not a missing rule.

		     The key is taken from the cave rather than handed to the bag, so a
		     real artefact makes the whole trip. ]]
		local run = startSolo("easy")
		local Stone = run.Enums.Resource.Stone
		local Key = run.Enums.Resource.AncientKey

		local keyId, keyEntry = run.findInteractable(run.session.id, "key")
		expect.truthy(keyId, "the generator placed no ancient key")
		run.moveTo(run.alice, keyEntry.position)
		local taken = run.server.invoke(run.alice, run.Routes.Request.Interact, { id = keyId })
		expect.truthy(taken.ok, "could not take the key: " .. tostring(taken.reason))

		local HAUL = 41
		run.services.InventoryService:addToBag(run.alice, Stone, HAUL)
		local storedBefore = run.profile(run.alice).colony.storage[Stone] or 0
		local keptFraction = run.session.difficulty.lootKeptOnDeathFraction

		local left = run.server.invoke(run.alice, run.Routes.Request.LeaveExpedition)
		expect.truthy(left.ok, "could not abandon the run: " .. tostring(left.reason))

		local profile = run.profile(run.alice)
		expect.equal(profile.escape.keys, 1, "an abandoned run did not bank its key into escape.keys")
		expect.falsy(
			profile.colony.storage[Key],
			"the key was left in colony storage, where the gate cannot see it"
		)
		--[[ Rounding is in the player's favour: 41 * 0.75 is 30.75, so a correct
		     recovery is 31 and a floor would give 30. ]]
		expect.equal(
			profile.colony.storage[Stone] - storedBefore,
			math.ceil(HAUL * keptFraction),
			"the recovery fraction was not applied, or was rounded against the player"
		)
		run.server.assertNoErrors(expect, "abandon with a key")
	end)

	suite:test("a disconnect is not a settlement: no results screen, no XP", function(expect)
		--[[ A results screen is a reward being granted, and `settle` recomputes
		     its payout from member.xpEarned, which is never reset (R3). Pushing
		     one at a player who has already gone would be a free re-settlement
		     waiting to be collected, and endSession's `if player then` guard is
		     what stops the run's own end from doing it after the fact. ]]
		local run = startSolo("easy")
		local profile = run.profile(run.alice)
		local xpBefore = profile.progression.xp

		run.server.disconnect(run.alice)

		expect.equal(
			run.server.pushCount(run.alice, run.Routes.Push.Results),
			0,
			"a results screen was pushed at a player who had already left"
		)
		expect.equal(
			run.record(run.alice).progression.xp,
			xpBefore,
			"XP was granted for walking out of a run by losing the connection"
		)

		--[[ And again once the run itself ends with nobody left in it: the
		     member entry is still in session.members, so endSession walks over
		     it. It must not settle a player it cannot find. ]]
		run.server.advance(1)
		expect.truthy(run.session.ended, "the empty session never ended, so endSession was never exercised")
		expect.equal(
			run.server.pushCount(run.alice, run.Routes.Push.Results),
			0,
			"endSession settled a member who was no longer on the server"
		)
		run.server.assertNoErrors(expect, "disconnect settlement")
	end)

	-- ── The party is not punished for one dropped connection ─────────────────

	suite:test("a disconnected member does not block the party: the rest still extract", function(expect)
		local run = startParty("easy")
		expect.equal(run.memberCount(run.session), 2, "the party did not form, so this test proves nothing")

		local Stone = run.Enums.Resource.Stone
		run.services.InventoryService:addToBag(run.alice, Stone, 30)
		local storedBefore = run.profile(run.alice).colony.storage[Stone] or 0

		run.server.disconnect(run.bob)
		--[[ Several ticks, because the clock is also what ends a run that has
		     nobody active left in it — Alice is still down there, so it must
		     not. ]]
		run.server.advance(2)
		expect.falsy(run.session.ended, "the run ended on Bob's disconnect while Alice was still underground")
		expect.equal(
			run.sessionOf(run.alice),
			run.session,
			"Alice lost her session when her teammate dropped"
		)

		local extracted = run.extractAt(run.alice, run.session)
		expect.truthy(extracted.ok, "extraction was refused: " .. tostring(extracted.reason))
		expect.equal(
			run.profile(run.alice).colony.storage[Stone],
			storedBefore + 30,
			"a clean extraction was docked because a teammate had disconnected"
		)

		local results = run.server.pushes(run.alice, run.Routes.Push.Results)
		expect.equal(#results, 1, ("expected exactly one results screen, got %d"):format(#results))
		expect.equal(results[1].outcome, "extracted", "the survivor's run was not recorded as an extraction")
		run.server.assertNoErrors(expect, "party survives a disconnect")
	end)

	suite:test("the last member disconnecting ends the run and tears the cave down", function(expect)
		--[[ Nobody is left to extract, so the clock must not keep a whole cave,
		     its nodes and its monsters alive for the rest of the night. Cave
		     slots are capped (MaxConcurrentSessions), so a leak here eventually
		     refuses other players' expeditions. ]]
		local run = startSolo("easy")
		local sessionId = run.session.id
		expect.truthy(run.services.CaveService:caveFor(sessionId), "no cave was built")
		expect.atLeast(run.nodesIn(sessionId), 1, "the generator placed no nodes, so teardown proves nothing")

		run.server.disconnect(run.alice)
		run.server.advance(1)

		expect.truthy(run.session.ended, "a session with nobody in it was left running")
		expect.equal(run.session.phase, run.Enums.Phase.Ended, "the ended session kept a live phase")
		expect.falsy(
			run.services.CaveService:caveFor(sessionId),
			"the cave was left standing after everyone in it had gone"
		)
		expect.falsy(
			run.services.ExpeditionService:sessionById(sessionId),
			"the finished session is still in the registry"
		)
		expect.equal(run.nodesIn(sessionId), 0, "the dead session's resource nodes were never cleared")
		run.server.assertNoErrors(expect, "last member leaves")
	end)

	-- ── R10: ending one session must not touch another ───────────────────────

	suite:test("R10: ending an old session must not pull a member out of their new one", function(expect)
		--[[ THE REGRESSION.

		     endSession used to walk session.members and nil `_byUser[userId]`
		     unconditionally. That is wrong whenever a userId is still listed in
		     an old session while their binding already points at a newer one —
		     the case the fix's own comment describes as disconnecting mid-run,
		     rejoining and starting a fresh expedition before the first times
		     out. The old run ending then silently emptied the new run's player
		     out of it, bag and all.

		     The simulator mints a fresh UserId on every addPlayer (sim.luau's
		     `nextUserId += 1`), so a literal rejoin cannot reuse an id. This
		     drives the structurally identical state instead, and does it the way
		     a party actually behaves: Alice extracts early, so she is still a
		     MEMBER of the first run while her binding has moved on to a second
		     one. Bob is still below, which keeps the first run alive long enough
		     for her to start it.

		     Under the old code the assertion on sessionOf(alice) fails: ending
		     the first run clears a binding that belongs to the second. ]]
		local run = startParty("easy")
		local first = run.session
		expect.truthy(first, "the party never got underground")
		expect.equal(run.memberCount(first), 2, "the party did not form, so this test proves nothing")

		local out = run.extractAt(run.alice, first)
		expect.truthy(out.ok, "Alice could not extract: " .. tostring(out.reason))
		expect.equal(
			first.members[run.alice.UserId].state,
			run.Enums.MemberState.Extracted,
			"an extracted member must stay in the member list; otherwise endSession never sees her"
		)
		expect.equal(run.sessionOf(run.bob), first, "Bob was pulled out of the first run by Alice extracting")

		local again =
			run.server.invoke(run.alice, run.Routes.Request.StartExpedition, { difficultyId = "easy" })
		expect.truthy(again.ok, "a settled member could not start a fresh run: " .. tostring(again.detail))
		local second = run.sessionOf(run.alice)
		expect.truthy(second, "the second expedition reported success but produced no session")
		expect.notEqual(second.id, first.id, "the second run reused the first session")

		local Stone = run.Enums.Resource.Stone
		run.services.InventoryService:addToBag(run.alice, Stone, 18)
		local storedBefore = run.profile(run.alice).colony.storage[Stone] or 0

		--[[ Now kill the FIRST run. Its member list still names Alice. ]]
		run.server.disconnect(run.bob)
		run.server.advance(1)
		expect.truthy(first.ended, "the first run never ended, so the guard was never exercised")

		expect.equal(
			run.sessionOf(run.alice),
			second,
			"ending the old run ripped Alice out of the new one she was standing in"
		)
		expect.falsy(second.ended, "the old run ending ended the new one too")
		expect.equal(
			run.services.ColonyService:zoneOf(run.alice),
			run.Enums.Zone.Expedition,
			"Alice was sent back to the colony by someone else's run finishing"
		)
		expect.equal(
			run.bag(run.alice).items[Stone],
			18,
			"the new run's bag was emptied when the old run ended"
		)

		--[[ The observable consequence, not just the binding: she can still
		     finish the run she is actually in. ]]
		local secondOut = run.extractAt(run.alice, second)
		expect.truthy(
			secondOut.ok,
			"Alice could not extract from her own live run: " .. tostring(secondOut.reason)
		)
		expect.equal(
			run.profile(run.alice).colony.storage[Stone],
			storedBefore + 18,
			"the second run's haul never reached storage"
		)
		run.server.assertNoErrors(expect, "old session ends under a new one")
	end)

	suite:test("R10: one session ending leaves an unrelated live session alone", function(expect)
		--[[ The same guard from the other direction, and a check that the
		     teardown is scoped by session id: ending Alice's run must not take
		     Bob's cave, nodes or room binding with it. ]]
		local run = newRun()
		local alice = run.server.addPlayer("Alice")
		local bob = run.server.addPlayer("Bob")
		run.server.invoke(alice, run.Routes.Request.StartExpedition, { difficultyId = "easy" })
		run.server.invoke(bob, run.Routes.Request.StartExpedition, { difficultyId = "easy" })

		local aliceSession = run.sessionOf(alice)
		local bobSession = run.sessionOf(bob)
		expect.truthy(aliceSession, "Alice never started a run")
		expect.truthy(bobSession, "Bob never started a run")
		expect.notEqual(aliceSession.id, bobSession.id, "both players landed in one session")

		local bobNodes = run.nodesIn(bobSession.id)
		expect.atLeast(bobNodes, 1, "Bob's cave has no nodes, so the scoping check proves nothing")

		run.server.disconnect(alice)
		run.server.advance(1)
		expect.truthy(aliceSession.ended, "Alice's empty run never ended")

		expect.equal(run.sessionOf(bob), bobSession, "Bob lost his session when an unrelated one ended")
		expect.falsy(bobSession.ended, "an unrelated session ending ended Bob's run too")
		expect.truthy(run.services.CaveService:caveFor(bobSession.id), "the wrong cave was torn down")
		expect.equal(run.nodesIn(bobSession.id), bobNodes, "the wrong session's nodes were cleared")
		expect.truthy(
			run.services.CaveService:roomOf(bob),
			"Bob was unbound from a cave he is still standing in"
		)

		local out = run.extractAt(bob, bobSession)
		expect.truthy(
			out.ok,
			"Bob could not extract after someone else's run ended: " .. tostring(out.reason)
		)
		run.server.assertNoErrors(expect, "unrelated session ends")
	end)

	-- ── Persistence and the colony ───────────────────────────────────────────

	suite:test("a disconnect writes the profile back and drops the session lock", function(expect)
		--[[ A profile that is not written on leave is a lost session, and a lock
		     that is not released locks the player out of their own save until it
		     times out two minutes later. Both are checked against what actually
		     reached the store, not against the live table. ]]
		local run = newRun()
		local alice = run.server.addPlayer("Alice")
		local Iron = run.Enums.Resource.Iron

		local callsAfterJoin = run.storeCalls()
		expect.atLeast(callsAfterJoin, 1, "joining never touched the DataStore, so there was no load to lock")

		--[[ A change made AFTER the load, so the record below can only match if
		     a second write really happened on the way out. ]]
		run.services.InventoryService:addToStorage(alice, Iron, 9)
		local ironHeld = run.profile(alice).colony.storage[Iron]
		expect.atLeast(ironHeld, 9, "the iron never reached colony storage")

		run.server.disconnect(alice)

		local record = run.record(alice)
		expect.truthy(record, "nothing was ever persisted for this player")
		expect.equal(
			record.colony.storage[Iron],
			ironHeld,
			"the persisted record predates the last change, so the leave write never landed"
		)
		expect.equal(run.storeCalls(), callsAfterJoin + 1, "the disconnect did not write the profile back")
		expect.equal(
			record.meta.lockJobId,
			"",
			"the session lock was left held by a server the player has already left"
		)
		expect.equal(
			record.meta.lockTimestamp,
			0,
			"a released lock kept its timestamp, so it still looks live"
		)
		run.server.assertNoErrors(expect, "save on disconnect")
	end)

	suite:test("disconnecting in the colony after a clean run keeps every scrap of it", function(expect)
		--[[ The loss rules apply to a bag underground, never to a colony. A
		     player who extracted and then dropped out while standing at home
		     must not have the death fraction applied to loot that was already
		     banked, and must not be settled a second time. ]]
		local run = startSolo("easy")
		local Stone = run.Enums.Resource.Stone

		run.services.InventoryService:addToBag(run.alice, Stone, 24)
		local storedBefore = run.profile(run.alice).colony.storage[Stone] or 0

		local extracted = run.extractAt(run.alice, run.session)
		expect.truthy(extracted.ok, "extraction was refused: " .. tostring(extracted.reason))
		expect.equal(
			run.profile(run.alice).colony.storage[Stone],
			storedBefore + 24,
			"a clean extraction did not keep everything"
		)
		expect.falsy(run.sessionOf(run.alice), "the extracted player still resolves to a live session")
		expect.equal(
			run.services.ColonyService:zoneOf(run.alice),
			run.Enums.Zone.Colony,
			"the extracted player was never returned to the colony"
		)

		local buildingsBefore = #run.profile(run.alice).colony.buildings
		run.server.disconnect(run.alice)

		local record = run.record(run.alice)
		expect.equal(
			record.colony.storage[Stone],
			storedBefore + 24,
			"a colony disconnect applied an expedition loss to loot that was already home"
		)
		expect.equal(#record.colony.buildings, buildingsBefore, "the colony lost a building on disconnect")
		expect.atLeast(#record.colony.colonists, 3, "the colony lost colonists on disconnect")
		expect.equal(
			run.server.pushCount(run.alice, run.Routes.Push.Results),
			1,
			"the colony disconnect produced a second results screen for a run already settled"
		)
		run.server.assertNoErrors(expect, "colony disconnect")
	end)

	suite:test("a disconnected leader hands the party on instead of stranding it", function(expect)
		--[[ Leadership is proved by behaviour, not by reading the party table:
		     only the leader may start an expedition, so Bob going from refused
		     to allowed is the handover. Without it a party whose leader drops in
		     the lobby could never run again. ]]
		local run = newRun()
		local alice = run.server.addPlayer("Alice")
		local bob = run.server.addPlayer("Bob")

		local created = run.server.invoke(alice, run.Routes.Request.CreateParty, { visibility = "private" })
		expect.truthy(created.ok, "the party was not created: " .. tostring(created.reason))
		local joined = run.server.invoke(bob, run.Routes.Request.JoinParty, { code = created.party.code })
		expect.truthy(joined.ok, "Bob could not join: " .. tostring(joined.reason))
		run.server.invoke(bob, run.Routes.Request.SetReady, { ready = true })

		local blocked = run.server.invoke(bob, run.Routes.Request.StartExpedition, { difficultyId = "easy" })
		expect.falsy(blocked.ok, "a member who is not the leader was allowed to start the expedition")
		expect.equal(blocked.detail, "not_leader", "the refusal was for some other reason than leadership")

		run.server.disconnect(alice)

		local started = run.server.invoke(bob, run.Routes.Request.StartExpedition, { difficultyId = "easy" })
		expect.truthy(
			started.ok,
			"the party was stranded when its leader disconnected: " .. tostring(started.detail)
		)
		expect.truthy(run.sessionOf(bob), "the start succeeded but produced no session")
		expect.falsy(run.sessionOf(alice), "the departed leader was dragged into the new run")
		run.server.assertNoErrors(expect, "leader disconnects in the lobby")
	end)
end
