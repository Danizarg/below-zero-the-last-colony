--[[
	Death.spec.lua
	Downed → death → revive → rescue, driven against a fully booted simulated
	server.

	This is the regression suite for the two bugs that broke the failure half of
	the game loop — the half the README promises is never a dead end:

	  R2  `_die` cleared the downed entry BEFORE zeroing Health, so the
	      `HealthChanged` safety net saw health<=0 with isDowned false and
	      re-downed the player it had just killed. The fresh timer then expired,
	      `_die` ran again, and so on forever. A player could never actually
	      die, which made the whole spectate-and-rescue flow unreachable.

	  R5  A rescue inside the two virtual seconds between `_die` zeroing the
	      Humanoid and `character:Destroy()` firing reused the corpse. The player
	      came back as a Humanoid at zero health, and the pending destroy then
	      removed that body from under them, leaving an Alive member with no
	      character for the rest of the run.

	`applyDamage` is the only route from full health to downed, and it clamps so
	that no single hit can kill a standing player — "avoid unpredictable instant
	deaths" is a design rule, so one enormous hit is a legitimate way to reach
	the downed state and is asserted as such below.

	Each test builds its own server, so nothing leaks between them.
]]

return function(suite, context)
	local newServer = context.newServer
	local CFrame = context.roblox.CFrame
	local Vector3 = context.roblox.Vector3

	--[[ Shared setup. `mates` asks for a second player in the same session:
	     most of this file needs one, either to do the reviving or simply to keep
	     the session alive after the first player dies. A solo death ends the run
	     on the very next expedition tick (nobody left Alive or Downed), which
	     would settle the player back into the colony and put the rescue and
	     spectate paths out of reach. ]]
	local function startRun(difficultyId, mates)
		local server = newServer()
		local Routes = server.require(server.shared.Routes)
		local Enums = server.require(server.shared.Enums)
		local GameConfig = server.require(server.shared.Config.GameConfig)

		local player = server.addPlayer("Alice")
		local mate = nil

		if mates then
			mate = server.addPlayer("Bob")
			local created = server.invoke(player, Routes.Request.CreateParty, { visibility = "private" })
			server.invoke(mate, Routes.Request.JoinParty, { code = created.party.code })
			--[[ `allReady` ignores the leader, so only the joiner has to toggle. ]]
			server.invoke(mate, Routes.Request.SetReady, { ready = true })
		end

		--[[ A fixed seed keeps the cave layout identical on every run. The
		     server only honours a client seed because GameConfig.Debug is on. ]]
		local started = server.invoke(player, Routes.Request.StartExpedition, {
			difficultyId = difficultyId or "easy",
			seed = 20261029,
		})

		local run = {
			server = server,
			Routes = Routes,
			Enums = Enums,
			GameConfig = GameConfig,
			player = player,
			mate = mate,
			startResult = started,
			session = server.services.ExpeditionService:sessionOf(player),
			services = server.services,
		}

		function run.member(who)
			return run.session.members[(who or player).UserId]
		end

		function run.humanoid(who)
			local character = (who or player).Character
			return character and character:FindFirstChildOfClass("Humanoid") or nil
		end

		function run.window()
			return run.session.difficulty.downedSeconds
		end

		--[[ One huge hit. The clamp in applyDamage turns it into the downed
		     state rather than a death, which is the only way a test can get
		     from full health to downed without modelling a monster fight. ]]
		function run.knockDown(who, source)
			return run.services.SurvivalService:applyDamage(who or player, 500, source or "cave crawler")
		end

		--[[ Step in 0.25s slices until `predicate` holds. Services accumulate
		     Heartbeat deltas and act on thresholds, so a coarser slice would
		     skip their work. Returns the virtual time at which it became true,
		     which the R5 test needs to prove it acted inside the 2s window. ]]
		function run.advanceUntil(predicate, limitSeconds)
			local deadline = run.server.now() + (limitSeconds or 200)
			while not predicate() do
				if run.server.now() >= deadline then
					return nil
				end
				run.server.step(0.25)
			end
			return run.server.now()
		end

		function run.advanceUntilDead(who)
			local member = run.member(who)
			return run.advanceUntil(function()
				return member.state == Enums.MemberState.Dead
			end, run.window() + 10)
		end

		function run.moveTo(who, position)
			who.Character.PrimaryPart.CFrame = CFrame.new(position)
			run.server.advance(1)
		end

		return run
	end

	-- ── The downed state itself ──────────────────────────────────────────────

	suite:test("one huge hit leaves a standing player downed, never dead", function(expect)
		local run = startRun("easy", true)
		local Survival = run.services.SurvivalService

		expect.truthy(run.startResult.ok, "the run never started: " .. tostring(run.startResult.reason))
		local maxHealth = run.humanoid().MaxHealth
		local dealt = run.knockDown()

		--[[ "Avoid unpredictable instant deaths": the clamp has to leave exactly
		     DownedHealth behind no matter how big the hit was. ]]
		expect.lessThan(dealt, maxHealth, "a single hit was allowed to remove the player's whole health bar")
		expect.equal(run.humanoid().Health, 1, "a downed player should be left on DownedHealth, not killed")
		expect.truthy(Survival:isDowned(run.player), "a player on 1 HP was not put into the downed state")
		expect.equal(run.member().state, run.Enums.MemberState.Downed, "the session roster still says alive")
		expect.equal(run.member(run.mate).state, run.Enums.MemberState.Alive, "the teammate was downed too")
		run.server.assertNoErrors(expect, "knock down")
	end)

	suite:test("the downed window comes from the difficulty, not a constant", function(expect)
		--[[ The window is the player's whole chance of being saved, so it has to
		     track the difficulty they chose rather than a global number. ]]
		local easy = startRun("easy", true)
		easy.knockDown()
		local easyPush = easy.server.lastPush(easy.player, easy.Routes.Push.Downed)
		expect.truthy(easyPush, "no Downed push reached the player who went down")
		expect.equal(
			easyPush.seconds,
			easy.window(),
			"the Downed push advertised a window the session does not use"
		)
		expect.equal(easyPush.userId, easy.player.UserId, "the Downed push named the wrong player")
		expect.equal(easyPush.cause, "cave crawler", "the death screen cannot say what put the player down")

		--[[ The teammate has to see it too, or there is nobody to come running. ]]
		local mateSaw = easy.server.lastPush(easy.mate, easy.Routes.Push.Downed)
		expect.truthy(mateSaw, "the teammate was never told their ally is down")
		expect.equal(mateSaw.userId, easy.player.UserId, "the teammate's alert named the wrong player")

		local hard = startRun("hard", true)
		hard.knockDown()
		local hardPush = hard.server.lastPush(hard.player, hard.Routes.Push.Downed)
		expect.equal(hardPush.seconds, hard.window(), "hard advertised a window its difficulty does not set")
		expect.lessThan(
			hardPush.seconds,
			easyPush.seconds,
			"hard gave at least as long to be rescued as easy"
		)

		easy.server.assertNoErrors(expect, "easy window")
		hard.server.assertNoErrors(expect, "hard window")
	end)

	suite:test("an Infirmary extends the downed window", function(expect)
		--[[ A colony investment that pays off inside the caves is the loop the
		     whole game is built on, so this is worth pinning down.

		     The building is written straight into the profile: reaching an
		     Infirmary through colony/place needs a level-3 Town Hall and a pile
		     of resources, which is BuildingService's test to write, not this
		     one. ]]
		local plain = startRun("easy", true)
		plain.knockDown()
		local baseline = plain.server.lastPush(plain.player, plain.Routes.Push.Downed).seconds

		local run = startRun("easy", true)
		local profile = run.services.DataService:get(run.player)
		table.insert(profile.colony.buildings, {
			uid = "infirmary-under-test",
			id = run.Enums.Building.Infirmary,
			gx = 8,
			gz = 8,
			rot = 0,
			level = 1,
			health = 220,
		})
		run.services.BuildingService:invalidate(run.player)

		local bonus = run.services.BuildingService:effectsFor(run.player).reviveWindowBonus
		expect.greaterThan(
			bonus,
			0,
			"a level 1 Infirmary grants no reviveWindowBonus to extend anything with"
		)

		run.knockDown()
		local extended = run.server.lastPush(run.player, run.Routes.Push.Downed).seconds
		expect.equal(
			extended,
			baseline + bonus,
			"the Infirmary's revive window bonus never reached the caves"
		)

		--[[ And the extension is real time, not just a number on the HUD: the
		     player must still be down at the point the un-extended window would
		     have killed them. ]]
		run.server.advance(baseline + 1)
		expect.truthy(
			run.services.SurvivalService:isDowned(run.player),
			"the Infirmary owner died on the base window anyway, so the bonus was advertised but not applied"
		)
		plain.server.assertNoErrors(expect, "baseline window")
		run.server.assertNoErrors(expect, "extended window")
	end)

	suite:test("a downed player cannot be damaged further", function(expect)
		--[[ Monsters finishing off a downed teammate would make the revive
		     window meaningless, so damage while downed is a no-op — and in
		     particular it must not re-enter `down` and restart the countdown. ]]
		local run = startRun("easy", true)
		run.knockDown()
		run.server.advance(10)

		local remainingBefore = run.services.SurvivalService:downedRemaining(run.player)
		local dealt = run.services.SurvivalService:applyDamage(run.player, 50, "second crawler")

		expect.equal(dealt, 0, "a downed player was damaged again")
		expect.equal(run.humanoid().Health, 1, "damage while downed moved the Humanoid off DownedHealth")
		expect.equal(
			run.server.pushCount(run.player, run.Routes.Push.Downed),
			1,
			"hitting a downed player pushed a second Downed event, so the countdown was restarted"
		)
		expect.atMost(
			run.services.SurvivalService:downedRemaining(run.player),
			remainingBefore,
			"the downed timer went back up after a hit, which would make the window unlosable"
		)
		expect.truthy(run.services.SurvivalService:isDowned(run.player), "the player stopped being downed")
		run.server.assertNoErrors(expect, "damage while downed")
	end)

	-- ── R2: death happens exactly once ───────────────────────────────────────

	suite:test("R2: the downed timer running out kills the player exactly once", function(expect)
		local run = startRun("easy", true)
		run.knockDown()

		--[[ Past the full window, with a second to spare so the stat tick that
		     notices has definitely run. ]]
		run.server.advance(run.window() + 1)

		expect.equal(
			run.member().state,
			run.Enums.MemberState.Dead,
			"the downed window expired without the player dying"
		)
		expect.falsy(
			run.services.SurvivalService:isDowned(run.player),
			"a dead player is still carrying a downed entry, so a fresh timer is running against them"
		)

		local ended = run.server.pushes(run.player, run.Routes.Push.ExpeditionEnded)
		expect.equal(#ended, 1, ("the player died %d times, not once"):format(#ended))
		expect.truthy(ended[1].spectating, "the death did not put the player into spectate")
		expect.equal(ended[1].cause, "cave crawler", "the death screen cannot say what killed the player")
		expect.equal(#ended[1].damageSummary, 1, "the death push carried no account of what did the damage")
		expect.truthy(
			string.find(ended[1].damageSummary[1], "cave crawler", 1, true),
			"the damage summary does not name the crawler that did it: "
				.. tostring(ended[1].damageSummary[1])
		)

		--[[ The actual loop. Before the fix, `_die` cleared the downed entry and
		     then zeroed Health, so HealthChanged re-downed the corpse: a new
		     Downed push, a new window, another `_die` — one more of each per
		     tick, forever. Sitting here for another full window is what proves
		     it terminates. ]]
		local downedPushes = run.server.pushCount(run.player, run.Routes.Push.Downed)
		run.server.advance(run.window() + 30)

		expect.equal(
			run.server.pushCount(run.player, run.Routes.Push.ExpeditionEnded),
			1,
			"the player died again after being dead, which is the R2 loop"
		)
		expect.equal(
			run.server.pushCount(run.player, run.Routes.Push.Downed),
			downedPushes,
			"a dead player was re-downed by the HealthChanged safety net"
		)
		expect.equal(
			run.member().state,
			run.Enums.MemberState.Dead,
			"the member state flipped back off Dead after the death completed"
		)
		expect.truthy(run.session, "the session ended even though a teammate is still alive")
		run.server.assertNoErrors(expect, "death loop")
	end)

	suite:test("R2: death is a state nobody can revive or extract out of", function(expect)
		--[[ The other half of "death completes": once it has happened, the
		     paths meant for someone still underground have to refuse. ]]
		local run = startRun("easy", true)
		run.knockDown()
		run.server.advance(run.window() + 1)
		expect.equal(run.member().state, run.Enums.MemberState.Dead, "the player never died")

		local revive = run.server.invoke(run.mate, run.Routes.Request.Revive, { userId = run.player.UserId })
		expect.falsy(revive.ok, "a teammate revived a dead player, which would skip the rescue flow entirely")
		expect.equal(revive.detail, "not_downed")

		local extract = run.server.invoke(run.player, run.Routes.Request.RequestExtraction)
		expect.falsy(extract.ok, "a dead player walked out of the cave")
		expect.equal(extract.detail, "not_alive")
		run.server.assertNoErrors(expect, "dead player routes")
	end)

	-- ── R5: a rescue inside the destroy window ───────────────────────────────

	suite:test("R5: a rescue two seconds after death does not reuse the corpse", function(expect)
		local run = startRun("easy", true)
		run.knockDown()

		local diedAt = run.advanceUntilDead()
		expect.truthy(diedAt, "the player never died, so the destroy window was never opened")

		--[[ `_die` zeroes the Humanoid and schedules `character:Destroy()` two
		     virtual seconds later. For that window the player is still wearing
		     the corpse, which is the state the bug reused. ]]
		local corpse = run.player.Character
		expect.truthy(corpse, "the body was cleared immediately, so there is no 2s window to test")
		local corpseHumanoid = corpse:FindFirstChildOfClass("Humanoid")
		expect.truthy(
			corpseHumanoid,
			"the corpse has no Humanoid, so this is not the state _die leaves behind"
		)
		expect.equal(
			corpseHumanoid.Health,
			0,
			"_die did not zero the Humanoid, so nothing is pending destruction"
		)

		local rescue = run.server.invoke(run.player, run.Routes.Request.RequestRescue, {})
		expect.lessThan(
			run.server.now() - diedAt,
			2,
			"the rescue landed outside the 2s destroy window, so it did not exercise R5 at all"
		)
		expect.truthy(rescue.ok, "the free rescue was refused: " .. tostring(rescue.reason))
		expect.truthy(rescue.free, "the free rescue was billed as a paid one")
		expect.equal(run.member().state, run.Enums.MemberState.Alive, "the rescued player is not alive again")
		expect.equal(
			run.services.ColonyService:zoneOf(run.player),
			run.Enums.Zone.Expedition,
			"the rescued player was not put back underground"
		)

		--[[ The regression itself. Before the fix the rescue handed the corpse
		     straight back, so the player stood up as a Humanoid at zero health.
		     This assertion fails the moment that returns, and it keeps passing
		     if the rescue ever does hand over a living body. ]]
		local body = run.player.Character
		local humanoid = body and body:FindFirstChildOfClass("Humanoid")
		expect.falsy(
			humanoid and humanoid.Health <= 0,
			"the rescue revived the player into the corpse _die had already scheduled for destruction"
		)

		--[[ And the positive half: a rescued player gets a body they can
		     actually use. That took two passes at R5. The first destroyed the
		     corpse and then asked `if not player.Character then
		     player:LoadCharacter() end` — but destroying a character does not
		     clear that property, so the reload was skipped and the player was
		     revived into the corpse regardless. The gate is now on the body
		     being UNUSABLE (missing, unparented, no Humanoid, or a Humanoid at
		     zero health) rather than on the reference being absent. ]]
		expect.truthy(humanoid, "the rescue left the player with no Humanoid, so they have no usable body")
		expect.greaterThan(
			humanoid.Health,
			0,
			"the rescued player is wearing a Humanoid at zero health, which is the corpse reuse itself"
		)
		expect.notEqual(
			body,
			corpse,
			"the rescue handed back the very Model `_die` had already scheduled for destruction"
		)
		expect.truthy(body.Parent, "the fresh body was never parented into the world")

		--[[ Past the destroy deadline. The pending `task.delay` checks
		     `character.Parent` before acting, and destroying the corpse during
		     the rescue is what makes it a no-op, so the player must not be left
		     with nothing. Simulated characters are parented into the Workspace
		     (tools/sim.luau), so the `character.Parent` guard inside the pending
		     destroy is genuinely exercised here rather than skipped on a nil
		     Parent — which is how an earlier, incomplete version of this fix
		     managed to look correct. ]]
		run.server.advance(3)
		expect.truthy(
			run.player.Character,
			"the pending destroy pulled the body out from under a rescued, living member"
		)
		expect.equal(
			run.member().state,
			run.Enums.MemberState.Alive,
			"the rescued member stopped being alive once the destroy timer fired"
		)
		run.server.assertNoErrors(expect, "rescue inside the destroy window")
	end)

	suite:test("the free rescue is capped per expedition and nothing quietly grants another", function(expect)
		local run = startRun("easy", true)
		local cap = run.GameConfig.Monetization.FreeRescuesPerExpedition
		expect.atLeast(cap, 1, "there is no free rescue at all, so death IS a dead end")

		run.knockDown()
		run.advanceUntilDead()
		local firstDeath = run.server.lastPush(run.player, run.Routes.Push.ExpeditionEnded)
		expect.equal(
			firstDeath.freeRescuesRemaining,
			cap,
			"the death screen offered the wrong number of free rescues"
		)

		for _ = 1, cap do
			local taken = run.server.invoke(run.player, run.Routes.Request.RequestRescue, {})
			expect.truthy(taken.ok, "a free rescue inside the cap was refused: " .. tostring(taken.reason))
		end
		expect.equal(
			run.services.ExpeditionService:rescuesRemaining(run.player),
			0,
			"the free rescues were spent but the allowance did not go down"
		)

		--[[ Back on their feet, and down again. The harness has to hand them a
		     body first: see the R5 test — the rescue cannot load one here. ]]
		run.player:LoadCharacter()
		run.server.advance(0.5)
		run.knockDown(nil, "second crawler")
		run.advanceUntilDead()
		expect.equal(run.member().state, run.Enums.MemberState.Dead, "the second death never completed")

		local secondDeath = run.server.lastPush(run.player, run.Routes.Push.ExpeditionEnded)
		expect.equal(
			secondDeath.freeRescuesRemaining,
			0,
			"the death screen offered a rescue that no longer exists"
		)

		local again = run.server.invoke(run.player, run.Routes.Request.RequestRescue, {})
		expect.falsy(again.ok, "a second free rescue was granted beyond the per-expedition cap")
		expect.equal(again.detail, "no_free_rescue")
		expect.equal(again.reason, run.Enums.Reject.LimitReached)

		--[[ And the paid path is a refusal, not an optimistic grant: only a
		     verified receipt tops that balance up. ]]
		local paid = run.server.invoke(run.player, run.Routes.Request.RequestRescue, { paid = true })
		expect.falsy(paid.ok, "a paid rescue was granted to a player who has never bought one")
		expect.equal(paid.detail, "no_paid_rescue")
		expect.equal(
			run.member().state,
			run.Enums.MemberState.Dead,
			"a refused rescue brought the player back anyway"
		)
		run.server.assertNoErrors(expect, "rescue cap")
	end)

	-- ── Reviving a teammate ──────────────────────────────────────────────────

	suite:test("a teammate standing over you revives you, after the full hold", function(expect)
		local run = startRun("easy", true)
		local Survival = run.services.SurvivalService
		run.knockDown()

		--[[ Both players spawn at the tunnel mouth, so Bob is already in range. ]]
		local began = run.server.invoke(run.mate, run.Routes.Request.Revive, { userId = run.player.UserId })
		expect.truthy(began.ok, "a revive at point-blank range was refused: " .. tostring(began.reason))
		expect.greaterThan(began.duration, 0, "the revive reported no hold duration")

		--[[ The revive is server-channelled: the client cannot shortcut the
		     hold, so nothing happens until the duration has actually elapsed. ]]
		run.server.advance(began.duration / 2)
		expect.truthy(Survival:isDowned(run.player), "the revive completed before the hold was finished")
		expect.equal(run.server.pushCount(run.player, run.Routes.Push.Revived), 0, "an early Revived push")

		run.server.advance(began.duration)
		expect.falsy(Survival:isDowned(run.player), "the hold completed but the player is still down")
		expect.equal(run.member().state, run.Enums.MemberState.Alive, "the roster still says downed")

		local revived = run.server.lastPush(run.player, run.Routes.Push.Revived)
		expect.truthy(revived, "nobody was told the revive succeeded")
		expect.equal(
			revived.byUserId,
			run.mate.UserId,
			"the revive was not credited to the teammate who did it"
		)

		--[[ Back up, but not back to full: a revive is a second chance, not a
		     heal, so the granted fraction has to be applied. ]]
		local humanoid = run.humanoid()
		local expected = humanoid.MaxHealth * run.GameConfig.Survival.ReviveGrantedHealthFraction
		expect.near(
			humanoid.Health,
			expected,
			1,
			"a revived player did not come back on the granted fraction"
		)
		expect.lessThan(humanoid.Health, humanoid.MaxHealth, "a revive healed the player to full")
		run.server.assertNoErrors(expect, "revive")
	end)

	suite:test("a revive is refused from across the room", function(expect)
		--[[ The server re-measures the distance itself; a client claiming to be
		     kneeling over a teammate it is nowhere near gets refused. ]]
		local run = startRun("easy", true)
		run.knockDown()
		run.moveTo(run.mate, run.player.Character.PrimaryPart.Position + Vector3.new(60, 0, 0))

		local attempt = run.server.invoke(run.mate, run.Routes.Request.Revive, { userId = run.player.UserId })
		expect.falsy(attempt.ok, "a revive was started from 60 studs away")
		expect.equal(attempt.reason, run.Enums.Reject.TooFar)

		run.server.advance(run.GameConfig.Survival.ReviveHoldSeconds * 2)
		expect.truthy(
			run.services.SurvivalService:isDowned(run.player),
			"a refused revive completed anyway once enough time passed"
		)
		expect.equal(run.server.pushCount(run.player, run.Routes.Push.Revived), 0, "a Revived push was sent")
		run.server.assertNoErrors(expect, "far revive")
	end)

	suite:test("walking away mid-channel cancels the revive", function(expect)
		--[[ Distance is re-checked every revive tick, not just at the start,
		     which is what makes a rescue under pressure a real decision. ]]
		local run = startRun("easy", true)
		run.knockDown()

		local began = run.server.invoke(run.mate, run.Routes.Request.Revive, { userId = run.player.UserId })
		expect.truthy(began.ok, "the revive never started: " .. tostring(began.reason))

		run.server.advance(began.duration / 2)
		run.moveTo(run.mate, run.player.Character.PrimaryPart.Position + Vector3.new(60, 0, 0))
		run.server.advance(began.duration * 2)

		expect.truthy(
			run.services.SurvivalService:isDowned(run.player),
			"the revive completed even though the reviver left mid-channel"
		)
		expect.equal(
			run.member().state,
			run.Enums.MemberState.Downed,
			"the roster was brought back up anyway"
		)
		expect.equal(run.server.pushCount(run.player, run.Routes.Push.Revived), 0, "a Revived push was sent")

		local interrupted = false
		for _, notify in ipairs(run.server.pushes(run.mate, run.Routes.Push.Notify)) do
			if notify.title == "Revive interrupted" then
				interrupted = true
			end
		end
		expect.truthy(interrupted, "the reviver was never told why their hold stopped doing anything")
		run.server.assertNoErrors(expect, "cancelled revive")
	end)

	-- ── What death costs ─────────────────────────────────────────────────────

	suite:test("a dead player's bag is settled with the difficulty's death fraction", function(expect)
		--[[ Dying must never be free, and must never cost everything either:
		     the recovery fraction is the difficulty's promise.

		     Solo, deliberately: with nobody left Alive or Downed the run ends
		     itself, and that is the path which settles a dead member. It no
		     longer ends on the very NEXT tick, though — see below. ]]
		local run = startRun("easy", false)
		local Inventory = run.services.InventoryService
		local fraction = run.session.difficulty.lootKeptOnDeathFraction
		expect.lessThan(
			fraction,
			1,
			"the easy death fraction keeps everything, so there is nothing to assert"
		)

		--[[ Through the service rather than into the table, so the bag's own
		     capacity rules apply to the haul. ]]
		Inventory:addToBag(run.player, run.Enums.Resource.Stone, 100)
		local profile = run.services.DataService:get(run.player)
		local storedBefore = profile.colony.storage[run.Enums.Resource.Stone] or 0

		run.knockDown()
		expect.truthy(run.advanceUntilDead(), "the player never died, so nothing was settled")

		--[[ A wiped run is held open while anyone in it can still be rescued.
		     Without that window the tick closed a solo session inside half a
		     second of the only player dying, and the free rescue the death
		     screen had just offered them came back `wrong_zone` — so the one
		     rescue the shop, the docs and the UI all promise was unreachable
		     for anybody playing alone. The window is read from the service so
		     this test follows it rather than pinning 25 seconds. ]]
		local grace = run.services.ExpeditionService:rescueWindowSeconds()
		expect.atLeast(grace, 1, "there is no rescue window, so a solo death cannot be answered at all")
		expect.truthy(
			run.services.ExpeditionService:sessionOf(run.player),
			"the run was torn down before the rescue window lapsed, so a solo player cannot be rescued"
		)
		run.server.advance(grace + 2)

		expect.falsy(
			run.services.ExpeditionService:sessionOf(run.player),
			"the rescue window lapsed and the run still carried on without its only member"
		)
		expect.equal(
			run.services.ColonyService:zoneOf(run.player),
			run.Enums.Zone.Colony,
			"a wiped player was left standing in the cave"
		)

		local results = run.server.pushes(run.player, run.Routes.Push.Results)
		expect.equal(#results, 1, ("expected exactly one results screen, got %d"):format(#results))
		expect.equal(results[1].outcome, "died", "a death was settled as something other than a death")
		expect.equal(
			results[1].keptFraction,
			fraction,
			"the results screen quotes a fraction nothing applied"
		)

		--[[ Rounding is in the player's favour (ceil), the same rule the
		     abandon path uses. ]]
		local recovered = (profile.colony.storage[run.Enums.Resource.Stone] or 0) - storedBefore
		expect.equal(recovered, math.ceil(100 * fraction), "the death recovery fraction was not applied")
		expect.lessThan(recovered, 100, "dying kept the whole haul, which would dodge the loss rules")
		expect.falsy(next(Inventory:bagOf(run.player).items), "the bag was not emptied by the settlement")
		run.server.assertNoErrors(expect, "death settlement")
	end)

	suite:test("being reduced to nothing in the colony heals you instead of downing you", function(expect)
		--[[ There is no downed state at home: nobody is coming to rescue you
		     from your own colony, so a player left lying there would be stuck
		     with no way out. `down` heals them to full instead. ]]
		local server = newServer()
		local Routes = server.require(server.shared.Routes)
		local Enums = server.require(server.shared.Enums)
		local player = server.addPlayer("Alice")

		expect.equal(
			server.services.ColonyService:zoneOf(player),
			Enums.Zone.Colony,
			"the player did not start at home"
		)
		local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
		local dealt = server.services.SurvivalService:applyDamage(player, 500, "a very long fall")

		expect.greaterThan(dealt, 0, "damage in the colony was ignored outright")
		expect.equal(
			humanoid.Health,
			humanoid.MaxHealth,
			"a player bottomed out at home was not healed back up"
		)
		expect.falsy(
			server.services.SurvivalService:isDowned(player),
			"the colony put a player into the downed state"
		)
		expect.equal(
			server.pushCount(player, Routes.Push.Downed),
			0,
			"a Downed push was sent from the colony"
		)
		expect.equal(
			server.pushCount(player, Routes.Push.ExpeditionEnded),
			0,
			"a player died in their own colony, with no expedition to die in"
		)
		server.assertNoErrors(expect, "colony damage")
	end)
end
