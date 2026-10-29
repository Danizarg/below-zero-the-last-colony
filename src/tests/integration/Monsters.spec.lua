--[[
	Monsters.spec.lua
	Monster spawning, melee combat, and the two creatures being genuinely
	different problems.

	The design brief is explicit that different enemies should require different
	strategies rather than different amounts of health. That claim is only worth
	anything if it is enforced, so the headline test here is that the Cave
	Crawler can be killed and the Stalker cannot — and that attacking the
	Stalker reports back clearly enough for a player to learn to run.
]]

return function(suite, context)
	local newServer = context.newServer
	local CFrame = context.roblox.CFrame
	local Vector3 = context.roblox.Vector3

	--[[ A FIXED SEED on every run. Monster placement is seeded, and on an easy
     solo run the count multiplier is 0.3, so an unseeded layout can legally
     contain no monsters at all — which would make these tests flake rather
     than fail honestly. ]]
	local SEED = 4242

	local function startRun(difficultyId)
		local server = newServer()
		local Routes = server.require(server.shared.Routes)
		local Enums = server.require(server.shared.Enums)
		local MonsterConfig = server.require(server.shared.Config.MonsterConfig)

		local player = server.addPlayer("Alice")
		server.invoke(
			player,
			Routes.Request.StartExpedition,
			{ difficultyId = difficultyId or "medium", seed = SEED }
		)
		local session = server.services.ExpeditionService:sessionOf(player)

		local run = {
			server = server,
			Routes = Routes,
			Enums = Enums,
			MonsterConfig = MonsterConfig,
			player = player,
			session = session,
			services = server.services,
		}

		function run.moveTo(position)
			player.Character.PrimaryPart.CFrame = CFrame.new(position)
			server.advance(0.5)
		end

		--[[ Monsters live in a per-session table keyed by id. Finding one by
		     type is how a test gets a target without depending on where the
		     generator happened to put it. ]]
		function run.findMonster(monsterType)
			for id, monster in pairs(server.services.MonsterService._bySession[session.id] or {}) do
				if not monsterType or monster.def.id == monsterType then
					return id, monster
				end
			end
			return nil, nil
		end

		function run.monsterCount(monsterType)
			local count = 0
			for _, monster in pairs(server.services.MonsterService._bySession[session.id] or {}) do
				if (not monsterType or monster.def.id == monsterType) and monster:isAlive() then
					count += 1
				end
			end
			return count
		end

		--[[ Stand next to a monster and give it full stamina, so a refusal in a
		     test is about the thing under test rather than about being tired. ]]
		function run.engage(monster)
			run.moveTo(monster:position())
			local stats = server.services.SurvivalService:statsOf(player)
			stats.stamina = stats.staminaMax
		end

		function run.attack(monsterId)
			return server.invoke(player, Routes.Request.Attack, { monsterId = monsterId })
		end

		return run
	end

	-- ── Spawning ─────────────────────────────────────────────────────────────

	suite:test("an expedition is populated with monsters", function(expect)
		local run = startRun("medium")
		expect.atLeast(run.monsterCount(), 1, "the cave spawned no monsters at all")
		run.server.assertNoErrors(expect, "populate")
	end)

	suite:test("only Cave Crawlers spawn at the start of a run", function(expect)
		--[[ The Stalker is gated behind dusk and a maze shift. Finding one at
		     spawn would mean its introduction rules are not being applied. ]]
		local run = startRun("medium")
		expect.equal(run.monsterCount(run.Enums.Monster.Stalker), 0, "the Stalker appeared before dusk")
		expect.atLeast(run.monsterCount(run.Enums.Monster.CaveCrawler), 1)
	end)

	suite:test("a harder difficulty spawns more monsters than an easier one", function(expect)
		--[[ Same seed on both, so the comparison is about the difficulty
		     multiplier and not about two different layouts. ]]
		local easy = newServer()
		local hard = newServer()

		local function populateAndCount(server, difficultyId)
			local Routes = server.require(server.shared.Routes)
			local player = server.addPlayer("Alice")
			server.invoke(
				player,
				Routes.Request.StartExpedition,
				{ difficultyId = difficultyId, seed = 4242 }
			)
			local session = server.services.ExpeditionService:sessionOf(player)
			local count = 0
			for _ in pairs(server.services.MonsterService._bySession[session.id] or {}) do
				count += 1
			end
			return count, session
		end

		local easyCount = populateAndCount(easy, "easy")
		local hardCount = populateAndCount(hard, "hard")

		expect.greaterThan(
			hardCount,
			easyCount,
			("hard spawned %d monsters, easy spawned %d"):format(hardCount, easyCount)
		)
	end)

	suite:test("no monster spawns in the tunnel mouth or an extraction chamber", function(expect)
		--[[ Arriving into a fight, or having to fight to reach an exit, is the
		     thing MonsterConfig's zero budgets for those rooms prevent. ]]
		local run = startRun("hard")
		local cave = run.services.CaveService:caveFor(run.session.id)

		local safeKinds = {}
		for _, key in ipairs(cave.layout.extractionKeys) do
			safeKinds[key] = true
		end
		safeKinds[cave.layout.entranceKey] = true

		for _, monster in pairs(run.services.MonsterService._bySession[run.session.id] or {}) do
			expect.falsy(
				safeKinds[monster.homeCellKey],
				("a %s spawned in safe room %s"):format(monster.def.id, tostring(monster.homeCellKey))
			)
		end
	end)

	-- ── Melee ────────────────────────────────────────────────────────────────

	suite:test("attacking a Cave Crawler in reach damages it", function(expect)
		local run = startRun("medium")
		local monsterId, monster = run.findMonster(run.Enums.Monster.CaveCrawler)
		expect.truthy(monsterId, "no Cave Crawler to attack")

		run.engage(monster)
		local before = monster.humanoid.Health

		local result = run.attack(monsterId)
		expect.truthy(result.ok, "the swing was refused: " .. tostring(result.reason))
		expect.truthy(result.hit, "the swing missed a monster the player is standing on")
		expect.lessThan(monster.humanoid.Health, before, "the hit did no damage")
		expect.atLeast(result.damage, 1)
		run.server.assertNoErrors(expect, "melee")
	end)

	suite:test("killing a Cave Crawler credits the kill and awards XP", function(expect)
		local run = startRun("medium")
		local monsterId, monster = run.findMonster(run.Enums.Monster.CaveCrawler)
		run.engage(monster)

		local member = run.session.members[run.player.UserId]
		local xpBefore = member.xpEarned or 0

		--[[ Swing until it dies. Each swing costs stamina and is gated by the
		     tool cooldown, so time has to pass and stamina has to be topped
		     up — that is what engage() handles. ]]
		local guard = 0
		while monster:isAlive() and guard < 60 do
			guard += 1
			run.engage(monster)
			run.attack(monsterId)
		end

		expect.falsy(monster:isAlive(), "the Crawler would not die in 60 swings")
		expect.atLeast(member.kills or 0, 1, "the kill was not credited")
		expect.greaterThan(member.xpEarned or 0, xpBefore, "killing a monster awarded no XP")
		expect.atLeast(run.session.stats.monstersKilled or 0, 1)
		run.server.assertNoErrors(expect, "kill")
	end)

	suite:test("the Stalker cannot be killed, and says so", function(expect)
		--[[ The core of "different enemies need different strategies". If this
		     ever starts passing damage through, the Stalker silently becomes a
		     damage race with a 400 health bar — exactly what the brief rules
		     out. ]]
		local run = startRun("medium")

		--[[ Introduce it on its own terms rather than by hand: a shift has to
		     have happened and the clock has to be at dusk or later. ]]
		run.services.CaveService:applyShift(run.session.id, { run.player }, 2)
		run.session.phase = run.Enums.Phase.Night
		local spawned = run.services.MonsterService:trySpawnStalker(run.session)
		expect.truthy(spawned, "the Stalker refused to spawn at night after a shift")

		local monsterId, stalker = run.findMonster(run.Enums.Monster.Stalker)
		expect.truthy(monsterId, "the Stalker spawned but is not in the session table")
		expect.falsy(stalker.def.killable, "the Stalker is configured as killable")

		run.engage(stalker)
		local before = stalker.humanoid.Health

		local result = run.attack(monsterId)
		expect.truthy(result.ok)
		expect.truthy(result.hit, "the swing missed")
		expect.equal(stalker.humanoid.Health, before, "the Stalker took damage")
		expect.falsy(result.killable, "the client was told the Stalker is killable")
		expect.equal(result.remainingHealth, nil, "a health figure was sent for an unkillable monster")

		--[[ Hitting it costs it INTEREST instead, which is what buys a retreat. ]]
		expect.lessThan(stalker.interest, 1.5, "the hit did not reduce the Stalker's interest")
		run.server.assertNoErrors(expect, "stalker")
	end)

	suite:test("a heavier weapon drives the Stalker off faster than bare hands", function(expect)
		--[[ This was a real bug: onDamaged took a damage amount and ignored it,
		     so bare hands were exactly as effective as an Iron Blade in the one
		     encounter where running is the answer. ]]
		local run = startRun("medium")
		local MonsterConfig = run.MonsterConfig
		local stalkerDef = MonsterConfig.get(run.Enums.Monster.Stalker)

		run.services.CaveService:applyShift(run.session.id, { run.player }, 2)
		run.session.phase = run.Enums.Phase.Night
		run.services.MonsterService:trySpawnStalker(run.session)
		local _, stalker = run.findMonster(run.Enums.Monster.Stalker)

		local reference = stalkerDef.interestLossReferenceDamage or 26

		stalker.interest = 1.0
		stalker:onDamaged(reference, run.player)
		local afterSolidHit = 1.0 - stalker.interest

		stalker.interest = 1.0
		stalker:onDamaged(6, run.player) -- bare hands
		local afterWeakHit = 1.0 - stalker.interest

		expect.greaterThan(
			afterSolidHit,
			afterWeakHit,
			"a solid hit cost the Stalker no more interest than a bare-handed one"
		)
		expect.greaterThan(afterWeakHit, 0, "a weak hit should still count for something")
	end)

	suite:test("a swing is refused out of range and does no damage", function(expect)
		local run = startRun("medium")
		local monsterId, monster = run.findMonster(run.Enums.Monster.CaveCrawler)

		run.engage(monster)
		run.moveTo(monster:position() + Vector3.new(400, 0, 400))
		local before = monster.humanoid.Health

		local result = run.attack(monsterId)
		--[[ The swing itself still happens — it costs stamina whether or not it
		     connects, which is what makes wild swinging a real cost — but it
		     must not land. ]]
		expect.truthy(result.ok, "the swing errored instead of missing")
		expect.falsy(result.hit, "a monster 560 studs away was hit")
		expect.equal(result.reason, "out_of_reach")
		expect.equal(monster.humanoid.Health, before, "an out-of-range swing did damage")
	end)

	suite:test("a monster in another session cannot be attacked", function(expect)
		local run = startRun("medium")
		local bob = run.server.addPlayer("Bob")
		run.server.invoke(bob, run.Routes.Request.StartExpedition, { difficultyId = "easy" })
		local bobSession = run.services.ExpeditionService:sessionOf(bob)

		local foreignId, foreignMonster
		for id, monster in pairs(run.services.MonsterService._bySession[bobSession.id] or {}) do
			foreignId, foreignMonster = id, monster
			break
		end
		expect.truthy(foreignId, "the second session has no monsters")

		local before = foreignMonster.humanoid.Health
		local result = run.attack(foreignId)
		expect.falsy(result.hit, "hit a monster in someone else's expedition")
		expect.equal(foreignMonster.humanoid.Health, before, "damaged another session's monster")
	end)

	suite:test("swinging costs stamina and is refused when exhausted", function(expect)
		local run = startRun("medium")
		local monsterId, monster = run.findMonster(run.Enums.Monster.CaveCrawler)
		run.engage(monster)

		local stats = run.services.SurvivalService:statsOf(run.player)
		local before = stats.stamina
		run.attack(monsterId)
		expect.lessThan(stats.stamina, before, "the swing was free")

		--[[ Clear the tool's swing cooldown before testing the stamina gate, or
		     the refusal comes back as on_cooldown and proves nothing about
		     stamina. 0.9s is past bare hands' 0.75s cooldown but short of the
		     1.2s regen delay, so stamina stays where it is put. ]]
		run.server.advance(0.9)
		stats.stamina = 0

		local exhausted = run.attack(monsterId)
		expect.falsy(exhausted.ok, "swung with no stamina")
		expect.equal(exhausted.detail, "no_stamina")
	end)

	suite:test("a dead player cannot attack", function(expect)
		local run = startRun("medium")
		local monsterId, monster = run.findMonster(run.Enums.Monster.CaveCrawler)
		run.engage(monster)

		run.session.members[run.player.UserId].state = run.Enums.MemberState.Dead
		local result = run.attack(monsterId)
		expect.falsy(result.ok, "a dead player landed a hit")
		expect.equal(result.detail, "not_alive")
	end)

	-- ── Monsters hurting players ─────────────────────────────────────────────

	suite:test("a monster attack damages the player through the survival clamp", function(expect)
		local run = startRun("medium")
		local monsterId, monster = run.findMonster(run.Enums.Monster.CaveCrawler)
		run.engage(monster)

		local humanoid = run.player.Character:FindFirstChildOfClass("Humanoid")
		local before = humanoid.Health

		local dealt = run.services.CombatService:monsterAttack(monster, run.player)
		expect.atLeast(dealt, 1, "the monster's attack did nothing")
		expect.lessThan(humanoid.Health, before)

		--[[ Nothing may kill a standing player outright: the floor is the
		     downed state, never death. ]]
		expect.atLeast(humanoid.Health, 1, "a monster hit took the player below 1 health")
		run.server.assertNoErrors(expect, "monster attack")
	end)

	suite:test("a monster cannot finish off a downed player", function(expect)
		--[[ Standing over a downed teammate denying the revive is a dead end,
		     not tension, so a downed player is immune. ]]
		local run = startRun("medium")
		local _, monster = run.findMonster(run.Enums.Monster.CaveCrawler)
		run.engage(monster)

		run.services.SurvivalService:applyDamage(run.player, 1000, "test")
		expect.truthy(run.services.SurvivalService:isDowned(run.player), "the player should be downed")

		local humanoid = run.player.Character:FindFirstChildOfClass("Humanoid")
		local whileDowned = humanoid.Health

		local dealt = run.services.CombatService:monsterAttack(monster, run.player)
		expect.equal(dealt, 0, "a downed player was damaged further")
		expect.equal(humanoid.Health, whileDowned)
	end)

	-- ── Noise ────────────────────────────────────────────────────────────────

	suite:test("noise reaches monsters without erroring", function(expect)
		--[[ Noise is the Stalker's primary sense and is reported from a dozen
		     call sites, so the plumbing being sound matters more than the
		     specific interest arithmetic. ]]
		local run = startRun("medium")
		local _, monster = run.findMonster()
		expect.truthy(monster, "no monster to hear anything")

		for _, kind in ipairs({ "mine", "attack", "sprint", "hurt", "ability", "revive" }) do
			run.services.MonsterService:reportNoise(run.session.id, monster:position(), kind)
		end

		--[[ An unknown noise kind must be ignored rather than throwing, because
		     it would come from a typo'd call site in otherwise working code. ]]
		run.services.MonsterService:reportNoise(run.session.id, monster:position(), "not_a_real_noise")
		run.services.MonsterService:reportNoise(nil, monster:position(), "mine")

		run.server.assertNoErrors(expect, "noise")
	end)

	suite:test("tearing down a session removes its monsters", function(expect)
		local run = startRun("medium")
		expect.atLeast(run.monsterCount(), 1)

		run.services.MonsterService:clearSession(run.session.id)
		expect.equal(
			run.services.MonsterService._bySession[run.session.id],
			nil,
			"the session's monster table survived teardown"
		)
		run.server.assertNoErrors(expect, "teardown")
	end)
end
