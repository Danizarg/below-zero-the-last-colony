--[[
	Expedition.spec.lua
	The core loop, driven against a fully booted simulated server.

	This is the regression suite for the bugs that made the game's headline
	feature unreachable:

	  R1  an ancient key brought home by a clean extraction was never banked
	      into escape.keys, so the First Gate could never be opened by playing
	      well — while FAILING a run banked it correctly
	  R3  a settled member could call expedition/leave repeatedly, re-granting
	      the whole run's XP and another point of role mastery every time

	Each test builds its own server, so nothing leaks between them.
]]

return function(suite, context)
	local newServer = context.newServer
	local CFrame = context.roblox.CFrame

	--[[ Shared setup: a player, a started expedition, and the handles a test
	     needs. Returned as a table rather than globals so tests stay readable. ]]
	local function startRun(difficultyId)
		local server = newServer()
		local Routes = server.require(server.shared.Routes)
		local Enums = server.require(server.shared.Enums)

		local player = server.addPlayer("Alice")
		local result = server.invoke(server.services and player or player, Routes.Request.StartExpedition, {
			difficultyId = difficultyId or "easy",
		})

		local session = server.services.ExpeditionService:sessionOf(player)
		local cave = session and server.services.CaveService:caveFor(session.id)

		local run = {
			server = server,
			Routes = Routes,
			Enums = Enums,
			player = player,
			startResult = result,
			session = session,
			cave = cave,
			services = server.services,
		}

		function run.moveTo(position)
			player.Character.PrimaryPart.CFrame = CFrame.new(position)
			--[[ Room tracking runs on a Heartbeat interval, so give it a tick
			     to notice. Interaction range is checked against the real
			     position immediately, but `roomOf` is what extraction uses. ]]
			server.advance(1)
		end

		function run.toCell(cellKey)
			run.moveTo(server.services.CaveService:worldPositionOfCell(session.id, cellKey))
		end

		--[[ Interactables are registered with an offset from their room centre,
		     so a test has to stand where the object actually is rather than at
		     the middle of the room. ]]
		function run.findInteractable(kind)
			for id, entry in pairs(server.services.ObjectiveService._interactables) do
				if entry.kind == kind and entry.sessionId == session.id then
					return id, entry
				end
			end
			return nil, nil
		end

		function run.profile()
			return server.services.DataService:get(player)
		end

		function run.bag()
			return server.services.InventoryService:bagOf(player)
		end

		return run
	end

	-- ── The run starts at all ────────────────────────────────────────────────

	suite:test("an expedition starts and puts the player underground", function(expect)
		local run = startRun("easy")

		expect.truthy(run.startResult.ok, "start was refused: " .. tostring(run.startResult.reason))
		expect.truthy(run.session, "no session was created")
		expect.equal(run.session.phase, run.Enums.Phase.Prep)
		expect.equal(run.services.ColonyService:zoneOf(run.player), run.Enums.Zone.Expedition)
		expect.atLeast(#run.cave.layout.order, 10, "Easy should generate at least 10 rooms")
		run.server.assertNoErrors(expect, "start")
	end)

	suite:test("a new colony arrives with a Town Hall, colonists and materials", function(expect)
		local server = newServer()
		local player = server.addPlayer("Alice")
		local profile = server.services.DataService:get(player)

		expect.truthy(profile, "the profile never loaded")
		expect.equal(#profile.colony.buildings, 1, "expected exactly the granted Town Hall")
		expect.equal(profile.colony.buildings[1].id, "town_hall")
		expect.equal(#profile.colony.colonists, 3)
		expect.atLeast(profile.colony.storage.stone or 0, 1, "a new player needs something to build with")
		expect.truthy(player.Character, "the player never got a character")
		expect.truthy(server.services.ColonyService:plotOf(player), "no plot was claimed")
		server.assertNoErrors(expect, "join")
	end)

	-- ── R1: keys must reach escape.keys on a CLEAN extraction ────────────────

	suite:test("R1: a key taken and extracted cleanly is banked into escape.keys", function(expect)
		local run = startRun("easy")
		local keyId, keyEntry = run.findInteractable("key")
		expect.truthy(keyId, "the generator placed no ancient key")

		run.moveTo(keyEntry.position)
		local collected = run.server.invoke(run.player, run.Routes.Request.Interact, { id = keyId })
		expect.truthy(collected.ok, "could not take the key: " .. tostring(collected.reason))
		expect.equal(run.bag().items[run.Enums.Resource.AncientKey], 1, "the key did not reach the bag")

		run.toCell(run.cave.layout.entranceKey)
		local extracted = run.server.invoke(run.player, run.Routes.Request.RequestExtraction)
		expect.truthy(extracted.ok, "extraction was refused: " .. tostring(extracted.reason))

		local profile = run.profile()
		--[[ The whole point. Before the fix the key landed in colony storage,
		     which no gate code reads, so extracting well made it unusable. ]]
		expect.equal(profile.escape.keys, 1, "the key was not banked into escape.keys")
		expect.falsy(
			profile.colony.storage[run.Enums.Resource.AncientKey],
			"the key was left in colony storage, where the gate cannot see it"
		)
		run.server.assertNoErrors(expect, "extract with key")
	end)

	suite:test("R1: a banked key opens the First Gate on the next run", function(expect)
		local run = startRun("easy")

		local keyId, keyEntry = run.findInteractable("key")
		run.moveTo(keyEntry.position)
		run.server.invoke(run.player, run.Routes.Request.Interact, { id = keyId })
		run.toCell(run.cave.layout.entranceKey)
		run.server.invoke(run.player, run.Routes.Request.RequestExtraction)
		expect.equal(run.profile().escape.keys, 1)

		-- A second expedition, to reach a gate with the key already banked.
		local second =
			run.server.invoke(run.player, run.Routes.Request.StartExpedition, { difficultyId = "easy" })
		expect.truthy(second.ok, "the second expedition was refused: " .. tostring(second.reason))

		local session = run.services.ExpeditionService:sessionOf(run.player)
		local gateId, gateEntry
		for id, entry in pairs(run.services.ObjectiveService._interactables) do
			if entry.kind == "gate" and entry.sessionId == session.id then
				gateId, gateEntry = id, entry
			end
		end
		expect.truthy(gateId, "no gate was placed")

		run.player.Character.PrimaryPart.CFrame = CFrame.new(gateEntry.position)
		run.server.advance(1)

		local examined = run.server.invoke(run.player, run.Routes.Request.Interact, { id = gateId })
		expect.truthy(examined.ok)
		expect.equal(examined.keysBanked, 1, "the gate cannot see the banked key")
		expect.truthy(examined.canUnlock, "the gate refuses a key the player definitely has")

		local unlocked = run.server.invoke(run.player, run.Routes.Request.UnlockGate)
		expect.truthy(unlocked.ok, "unlock failed: " .. tostring(unlocked.reason))
		expect.equal(unlocked.stage, 1)
		expect.equal(run.profile().escape.gateStagesUnlocked, 1)

		--[[ Escaping must never reset the colony. The brief is explicit. ]]
		expect.equal(#run.profile().colony.buildings, 1, "opening the gate disturbed the colony")
		run.server.assertNoErrors(expect, "gate unlock")
	end)

	suite:test("a one-shot key cannot be taken twice", function(expect)
		local run = startRun("easy")
		local keyId, keyEntry = run.findInteractable("key")
		run.moveTo(keyEntry.position)

		local first = run.server.invoke(run.player, run.Routes.Request.Interact, { id = keyId })
		expect.truthy(first.ok)

		local second = run.server.invoke(run.player, run.Routes.Request.Interact, { id = keyId })
		expect.falsy(second.ok, "the same key was taken twice")
		expect.equal(second.detail, "already_taken")
		expect.equal(run.bag().items[run.Enums.Resource.AncientKey], 1, "the bag gained a duplicate key")
	end)

	-- ── R3: a settled member cannot be settled again ─────────────────────────

	suite:test("R3: leaving after extracting is refused and grants nothing more", function(expect)
		local run = startRun("easy")

		run.toCell(run.cave.layout.entranceKey)
		local extracted = run.server.invoke(run.player, run.Routes.Request.RequestExtraction)
		expect.truthy(extracted.ok)

		local profile = run.profile()
		local xpAfterExtract = profile.progression.xp
		local levelAfterExtract = profile.progression.level
		local roleId = profile.progression.selectedRole
		local masteryAfterExtract = profile.progression.roleMastery[roleId] or 0

		--[[ Hammer it the way an exploit would, not once politely. Before the
		     fix each call re-granted the entire run's XP plus a mastery point,
		     because settle recomputes from member.xpEarned, which is never
		     reset. ]]
		for _ = 1, 20 do
			local again = run.server.invoke(run.player, run.Routes.Request.LeaveExpedition)
			expect.falsy(again.ok, "a settled member was allowed to leave again")
		end

		local after = run.profile()
		expect.equal(after.progression.xp, xpAfterExtract, "XP was granted more than once")
		expect.equal(after.progression.level, levelAfterExtract, "level changed on a repeated settle")
		expect.equal(
			after.progression.roleMastery[roleId] or 0,
			masteryAfterExtract,
			"role mastery was granted more than once"
		)
		run.server.assertNoErrors(expect, "repeated leave")
	end)

	suite:test("R3: extracting clears the session binding", function(expect)
		--[[ The structural half of the same fix. While the mapping survived, a
		     settled player kept resolving to a live session, which is what let
		     them back into settlement paths meant for someone underground. ]]
		local run = startRun("easy")
		expect.truthy(run.services.ExpeditionService:sessionOf(run.player), "expected a live session")

		run.toCell(run.cave.layout.entranceKey)
		run.server.invoke(run.player, run.Routes.Request.RequestExtraction)

		expect.falsy(
			run.services.ExpeditionService:sessionOf(run.player),
			"an extracted player still resolves to a live session"
		)
		expect.equal(run.services.ColonyService:zoneOf(run.player), run.Enums.Zone.Colony)
	end)

	suite:test("extraction is refused away from an extraction point", function(expect)
		local run = startRun("easy")

		--[[ Stand in the vault, which is deliberately the furthest room from
		     the entrance and never an exit. ]]
		expect.truthy(run.cave.layout.vaultKey, "no vault was placed")
		run.toCell(run.cave.layout.vaultKey)

		local attempt = run.server.invoke(run.player, run.Routes.Request.RequestExtraction)
		expect.falsy(attempt.ok, "extracted from the middle of the cave")
		expect.equal(attempt.detail, "not_at_extraction")
		expect.truthy(run.services.ExpeditionService:sessionOf(run.player), "the run ended anyway")
	end)

	-- ── Harvesting and the bag ───────────────────────────────────────────────

	suite:test("harvesting puts resources in the bag and depletes the node", function(expect)
		local run = startRun("easy")
		local NodeService = run.services.NodeService

		--[[ Find a node this player can actually work with bare hands: tier 0,
		     so no tool is required. ]]
		local nodeId, node
		for id, candidate in pairs(NodeService._nodes) do
			if candidate.sessionId == run.session.id and candidate.def.tier == 0 then
				nodeId, node = id, candidate
				break
			end
		end
		expect.truthy(nodeId, "the generator placed no tier-0 node")

		run.moveTo(node.position)
		local before = run.bag().items[node.def.resource] or 0

		local first = run.server.invoke(run.player, run.Routes.Request.HarvestNode, { nodeId = nodeId })
		expect.truthy(first.ok, "harvest was refused: " .. tostring(first.reason))
		expect.atLeast(first.gained, 1, "the swing yielded nothing")
		expect.atLeast(
			run.bag().items[node.def.resource] or 0,
			before + 1,
			"the resource never reached the bag"
		)

		--[[ Empty it. Each swing is rate-limited by the tool cooldown, so time
		     has to pass between them. ]]
		local guard = 0
		while not node.depleted and guard < 40 do
			guard += 1
			run.server.advance(1)
			run.server.invoke(run.player, run.Routes.Request.HarvestNode, { nodeId = nodeId })
		end
		expect.truthy(node.depleted, "the node never depleted")

		local afterDepleted =
			run.server.invoke(run.player, run.Routes.Request.HarvestNode, { nodeId = nodeId })
		expect.falsy(afterDepleted.ok, "harvested a depleted node")
		run.server.assertNoErrors(expect, "harvest")
	end)

	suite:test("harvesting is refused from too far away", function(expect)
		local run = startRun("easy")
		local nodeId, node
		for id, candidate in pairs(run.services.NodeService._nodes) do
			if candidate.sessionId == run.session.id and candidate.def.tier == 0 then
				nodeId, node = id, candidate
				break
			end
		end

		--[[ The server re-measures distance itself; a client claiming to be
		     next to a node it is nowhere near gets refused. ]]
		run.moveTo(node.position + context.roblox.Vector3.new(500, 0, 500))
		local attempt = run.server.invoke(run.player, run.Routes.Request.HarvestNode, { nodeId = nodeId })
		expect.falsy(attempt.ok, "harvested a node 700 studs away")
		expect.equal(attempt.reason, run.Enums.Reject.TooFar)
	end)

	suite:test("a node from another session cannot be harvested", function(expect)
		local run = startRun("easy")
		local other = run.server.addPlayer("Bob")
		run.server.invoke(other, run.Routes.Request.StartExpedition, { difficultyId = "easy" })
		local otherSession = run.services.ExpeditionService:sessionOf(other)
		expect.notEqual(otherSession.id, run.session.id, "both players landed in one session")

		local foreignNodeId
		for id, candidate in pairs(run.services.NodeService._nodes) do
			if candidate.sessionId == otherSession.id then
				foreignNodeId = id
				break
			end
		end
		expect.truthy(foreignNodeId, "the second session has no nodes")

		local attempt =
			run.server.invoke(run.player, run.Routes.Request.HarvestNode, { nodeId = foreignNodeId })
		expect.falsy(attempt.ok, "harvested a node belonging to another expedition")
		expect.equal(attempt.reason, run.Enums.Reject.BadRequest)
	end)

	-- ── Rewards are granted exactly once ────────────────────────────────────

	suite:test("a clean extraction grants XP once and sends one results screen", function(expect)
		local run = startRun("easy")
		run.toCell(run.cave.layout.entranceKey)

		local before = run.profile().progression.xp
		run.server.invoke(run.player, run.Routes.Request.RequestExtraction)

		local results = run.server.pushes(run.player, run.Routes.Push.Results)
		expect.equal(#results, 1, ("expected exactly one results screen, got %d"):format(#results))
		expect.equal(results[1].outcome, "extracted")
		expect.truthy(results[1].extracted)

		local gained = run.profile().progression.xp - before
		expect.atLeast(gained, 1, "a successful extraction granted no XP")
		expect.equal(results[1].xpGained, gained, "the results screen disagrees with the profile")
	end)

	suite:test("extracted resources become permanent colony storage", function(expect)
		local run = startRun("easy")
		local Inventory = run.services.InventoryService

		--[[ Put a known quantity in the bag through the service rather than by
		     reaching into the table, so the capacity rules apply. ]]
		Inventory:addToBag(run.player, run.Enums.Resource.Stone, 25)
		local storedBefore = run.profile().colony.storage[run.Enums.Resource.Stone] or 0

		run.toCell(run.cave.layout.entranceKey)
		run.server.invoke(run.player, run.Routes.Request.RequestExtraction)

		local storedAfter = run.profile().colony.storage[run.Enums.Resource.Stone] or 0
		expect.equal(storedAfter, storedBefore + 25, "a clean extraction did not keep everything")
		expect.falsy(next(run.bag().items), "the bag was not emptied")
	end)

	suite:test("abandoning a run loses the difficulty's share of the haul", function(expect)
		local run = startRun("medium")
		local Inventory = run.services.InventoryService

		Inventory:addToBag(run.player, run.Enums.Resource.Stone, 100)
		local storedBefore = run.profile().colony.storage[run.Enums.Resource.Stone] or 0
		local keptFraction = run.session.difficulty.lootKeptOnDeathFraction

		local left = run.server.invoke(run.player, run.Routes.Request.LeaveExpedition)
		expect.truthy(left.ok, "could not abandon the run: " .. tostring(left.reason))

		local storedAfter = run.profile().colony.storage[run.Enums.Resource.Stone] or 0
		local recovered = storedAfter - storedBefore

		--[[ Rounding is in the player's favour (ceil), so recovery is the
		     fraction rounded up, never down. ]]
		expect.equal(recovered, math.ceil(100 * keptFraction), "the recovery fraction was not applied")
		expect.lessThan(recovered, 100, "abandoning kept everything, which would dodge the loss rules")
		run.server.assertNoErrors(expect, "abandon")
	end)

	-- ── Party scoping ────────────────────────────────────────────────────────

	suite:test("two solo players get separate caves and separate loot", function(expect)
		local run = startRun("easy")
		local bob = run.server.addPlayer("Bob")
		run.server.invoke(bob, run.Routes.Request.StartExpedition, { difficultyId = "easy" })

		local aliceSession = run.session
		local bobSession = run.services.ExpeditionService:sessionOf(bob)
		expect.notEqual(aliceSession.id, bobSession.id)

		local aliceCave = run.services.CaveService:caveFor(aliceSession.id)
		local bobCave = run.services.CaveService:caveFor(bobSession.id)
		expect.notEqual(aliceCave.origin.X, bobCave.origin.X, "two caves share a world slot")

		--[[ Personal loot: there is no shared pool, so Bob's harvest must not
		     touch Alice's bag. ]]
		run.services.InventoryService:addToBag(bob, run.Enums.Resource.Iron, 7)
		expect.falsy(run.bag().items[run.Enums.Resource.Iron], "loot leaked between players")
	end)

	suite:test("starting a second expedition while already in one is refused", function(expect)
		local run = startRun("easy")
		local again =
			run.server.invoke(run.player, run.Routes.Request.StartExpedition, { difficultyId = "easy" })
		expect.falsy(again.ok, "started two expeditions at once")
		expect.equal(again.detail, "already_in_expedition")
	end)
end
