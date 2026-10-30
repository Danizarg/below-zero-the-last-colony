# DEVELOPMENT STATUS

**Version 0.1.0-mvp** · 76 Lua files, ~29,650 lines · 3 Lune tools, ~650 lines

## How to read this

| Mark | Meaning |
|---|---|
| ✅ **Implemented** | Code exists, is complete, and can be meaningfully tested |
| 🟡 **Partial** | Works, with a stated limitation or an unfinished edge |
| 🏗 **Architected** | Config, data model and call sites exist; behaviour deliberately refuses rather than pretending |
| ❌ **Not started** | No code |

### What has actually been verified

The toolchain is installed, so these all genuinely ran:

| Check | Command | Result |
|---|---|---|
| Rojo builds the place file | `rojo build -o build/BelowZero.rbxlx` | **pass** — 1,272 KB. Rojo validates every `$properties` name and type against its reflection database, so the Lighting, Players and Workspace properties are all real |
| Luau parses, via a real parser | `selene src` | **0 parse errors** across all 85 files |
| Static analysis | `selene src` | **0 errors, 0 warnings** |
| Formatting | `stylua --check src tools` | **clean** (44 files were reformatted to get there) |
| Unit suite, headless | `lune run tools/run-tests` | **129 passed, 0 failed** in 0.7s |
| Integration suite, headless | `lune run tools/run-integration` | **130 passed, 0 failed** in 10s — a fresh server booted per test, playing real expeditions. Repeated runs, identical |
| Every module loads | `lune run tools/load-check` | **67 of 67 ModuleScripts load** |
| Every constant reference resolves | `lune run tools/ref-check` | **4,717 references, 0 dangling** — no mistyped enum, route or theme token anywhere |
| Every cross-service call is real | `lune run tools/call-check` | **327 calls, 0 broken** — no typo'd `self.context.X:method()`, none over-applied |
| Structural check | `node` heuristic over block/bracket balance | **0 problems** |

**What that does and does not mean.** The pure logic is genuinely tested: the
cave generator and the night maze shift are swept across 120 seeds × 3
difficulties, asserting door symmetry, full reachability, that no occupied room
is ever sealed, and that objective rooms never move. Inventory atomicity, the
RNG's determinism, plot geometry and every cross-config reference are covered
too. The load check proves all 67 modules' top-level code runs, which is the
failure mode that would otherwise take the whole server down at startup.

**What is still unverified is engine behaviour.** Nothing here has run inside
Roblox. Instances being assembled correctly, UI actually rendering and laying
out, monster pathfinding, DataStore persistence and multiplayer are all
untested — that is what the manual checklist in [SETUP.md](SETUP.md) §5 is for.
So for anything marked ✅ below that touches the engine, read it as "written,
reviewed, and it loads" rather than "seen working".

Two real bugs were caught by these checks rather than by reading the code,
which is the argument for having them:

- `MonsterBase:onDamaged` accepted a damage amount and ignored it, so bare
  hands drove the Stalker off exactly as well as an Iron Blade — in the one
  encounter where running is the intended answer. (Found by Selene's
  unused-variable warning.)
- `ResourceConfig.NodesPerRoom` allocated a resource node to Monster Nests, but
  no node definition listed that room, so nests would have silently spawned
  nothing. (Found by `ConfigIntegrity.spec`.)

### Semantic review

Static tools cannot find logic bugs, so the codebase also went through a
six-dimension review — server authority and exploits, lifecycle state machines,
concurrency and teardown, persistence and purchases, the client/server data
contract, and cross-service nil safety — with every finding adversarially
verified by three independent lenses before it counted. 18 raised, 16 survived,
collapsing to **13 distinct root causes, all now fixed**.

The five that mattered most, because each broke a feature the README advertises:

| Bug | Consequence |
|---|---|
| `_extract` never banked ancient keys into `escape.keys` | **The escape objective was unreachable by playing well.** Keys landed in colony storage, which no gate code reads. Failing a run banked them correctly — exactly backwards |
| `_die` cleared the downed entry before zeroing Health | The `HealthChanged` safety net re-downed the player it had just killed, the new timer expired, and `_die` ran again — **an infinite loop in which a player could never actually die**, so spectate and rescue were unreachable |
| `leaveExpedition` had no `member.state` guard, and `_extract` never cleared `_byUser` | A settled player still resolved to a live session and could re-settle repeatedly. `settle` recomputes from `member.xpEarned`, which is never reset, so **every call re-granted the whole run's XP and another point of role mastery** |
| A transient DataStore error latched the server into in-memory mode permanently while `save()` kept returning success | **Silent total data loss** for every player who joined afterwards, and `ProcessReceipt` acknowledging purchases that existed only in RAM |
| `phaseEndsAt` was a server `os.clock()` value the HUD subtracted its own `os.clock()` from | `os.clock()` is process-relative, so **the phase clock and the shift countdown both displayed garbage** — the single most important number on screen |

The other eight: a mid-expedition disconnect lost the whole recoverable haul
(`InventoryService` cleared the bag before `ExpeditionService` could deposit it,
because it connects `PlayerRemoving` first); disconnecting mid-load left the
profile lock written and held; an in-flight autosave could re-acquire a released
lock; `endSession` could rip a rejoined player out of their new expedition; a
rescue within 2s of death reused the corpse that `_die` had already scheduled for
destruction; unknown route names skipped the token bucket entirely, making
unbounded log writes reachable from the client; the spectate overlay never
cleared after a rescue; and the ability cooldown shade never drained.

Two findings were **rejected** by verification — the agents that raised them were
wrong, which is what the adversarial pass is for.

### What the simulation found

`tools/sim.luau` (1,389 lines) boots all sixteen services against a modelled
DataModel: a hand-written Instance tree with working signals, a virtual clock
driving `os.clock`, `os.time` and all of `task`, a second clock that moves
`os.time()` alone so hours can pass with the server idle, and a real in-memory
DataStore with genuine `UpdateAsync` read-modify-write semantics. 130 tests
across 9 spec files then play the game through it.

It found **fourteen bugs**. Eight in its first week, four of those in code that
had already passed static analysis, a six-dimension semantic review and 129
unit tests; five more since, found by specs written to close the gaps the
first eight left, and by a sweep over every place the server consults session
state:

| Bug | Consequence | Found by |
|---|---|---|
| A wiped run was torn down on the tick after the last death | **Solo players could never use the free rescue.** The session closed within half a second of the only player dying, so the rescue the death screen had just offered came back `wrong_zone`. In a party the session stayed open because teammates were alive, so this only ever hit people playing alone. The shop, the docs and the UI all promise "one free rescue, always available" | `sim.luau` itself |
| The R5 corpse fix gated the reload on `player.Character` being nil | Destroying a character does **not** clear that property, so the reload was skipped and the rescued player was revived into the corpse anyway — then the pending destroy pulled it out from under them | `sim.luau` itself |
| `DataService` released the profile synchronously, first, in `PlayerRemoving` | The entire recoverable haul of every disconnecting player, lost in mock and degraded mode. See the two-of-thirteen note above | `Disconnect.spec` |
| A member who had already **died** was skipped by the disconnect deposit | Dying and then disconnecting destroyed the haul outright, while dying and waiting out the run kept the death fraction of it. `endSession` cannot make it up afterwards, because the profile leaves with the player | `Death.spec` author, reading the handler |
| The release cleared `_released[userId]`, the marker that blocks a late write | A read-only session for the player's next server, for the full lock timeout. See above | `Persistence.spec` |
| `BuildingService:_afterChange` pushed the colony snapshot *before* reassigning workers | After a demolition the client was still told the job usage of a building that was gone, and went on being told it until some later push happened to correct it. Cosmetic, but it reads as a lost worker | `Colony.spec` |
| The offline notice read out what the colonists *made*, not what storage *took* | `addToStorage` truncates at the colony cap, so a returning player with a full store was told their colonists had produced **5,295 mushrooms when five units fit**. Same class as acknowledging a write that only reached RAM: someone is left counting on resources that are not there | `Offline.spec` |
| `_settleOffline` settled, and announced, a **read-only** session | `profileLoaded` fires for a read-only entry exactly as for a healthy one. A profile whose migration was refused — a rollback after a schema bump — got up to eight hours of production, a notice saying so, and no write of any of it. It also moved `lastProductionAt` in memory, so the absence was not even owed any more | `Offline.spec` |
| A tick that only *spent* moved storage without pushing it | `simulate` writes `storage.items` directly; the only push in the function sits in the deposit loop behind `added > 0`, and the colony snapshot carries no storage. A Cook eating the larder down showed the player nothing — a stale resource strip, stale units, a Craft button still enabled for a recipe the server would refuse | `Production.spec` |
| The online production tick ran for **read-only** sessions | Gated on `isLoaded`, which a read-only session satisfies. Storage spent, output banked, food, condition, research and skill advanced and pushed every ten seconds for the whole session, none of it ever written. The online twin of the `_settleOffline` bug above | read-only sweep, `Offline.spec` |
| A load that fell back to memory handed out a **writable** template | After five failed DataStore attempts the load re-ran its transform against memory, got a fresh template for a player memory had never seen, and accepted it as loaded and writable. The first autosave after the store recovered wrote that template over the real record and reported success — a new colony replacing a veteran's. Fixed by provenance: a memory-born session is pinned to memory for life and never written to the store, so it stays playable (Studio without API access depends on that) and the real record survives | read-only sweep, `Persistence.spec` |
| A load refused by migration kept the lock it took | The lock is written by the load transform before anything looks at the version; a read-only session never saves and so never released it, and every other server showed the player a starter colony "because another server still holds your save" for the full lock timeout | read-only sweep, `Persistence.spec` |
| A read-only session could run a whole expedition | Start, settlement, XP, levels, role mastery, the haul and banked keys were all gated on `isLoaded` — announced in full, lost at the door | read-only sweep, `Expedition.spec` |
| Five more profile mutations gated on `isLoaded` alone | `repair`, `recruit`, `useConsumable`, `setRole` and `Monetization.prompt` — the last of which could have taken Robux for a grant that could never be kept. All refuse now with the same reason and detail; a read-only party member dropped from an expedition start is told why | review of d6660d5, `Persistence.spec` |

All fourteen are fixed, and each has a test that asserts the **fixed**
behaviour and fails if it regresses. Every row from the storage push down was
verified by mutation: putting the old code back fails exactly that row's test
and nothing else.

It also found a defect in the test suite itself, which is worth recording
because it is the failure mode that makes a harness worse than no harness.
`ExpeditionService:_newSeed` mixes in global `math.random`, which Lune seeds
differently per process, so every run drew a different cave; `quantise` turns a
fractional yield into a probability, so the harvest assertion was a coin flip
and failed about one run in thirty. Every spec that depends on cave content now
passes an explicit seed. Separately, simulated characters were not being parented
into the Workspace, which made `_die`'s `character.Parent` guards inert — **a
test was passing for the wrong reason**, and fixing the harness is what exposed
the incomplete R5 fix above.

When this section was first written every one of those thirteen fixes was
**reasoned, not observed**, and nine of them sat in paths no headless test could
reach. That is no longer the case, and what changed the position is the next
section: a simulated server now drives them. Eleven of the thirteen have a named
regression test; the remaining two (the spectate overlay and the cooldown shade)
are client rendering and stay in the [SETUP.md](SETUP.md) §5 checklist.

**Two of the thirteen were not actually fixed.** Both looked right and both were
wrong, and only the simulation showed it — which is the entire argument for
having built it:

- *"A mid-expedition disconnect lost the whole recoverable haul."* Deferring
  `InventoryService`'s bag cleanup moved the second obstacle out of the way and
  left the first one standing: `DataService` loads first, so **its**
  `PlayerRemoving` handler released the profile before `ExpeditionService` could
  deposit anything into it. On a live server this happened to work, because a
  real `UpdateAsync` yields and lets the later handlers run. It does **not**
  yield in mock mode or while the store is degraded, so in exactly those
  configurations the whole haul — Ancient Keys included — was still being lost.
- *"An in-flight autosave could re-acquire a released lock."* The guard was
  added; the release then cleared the marker the guard reads, so the window was
  still open. A save suspended in its retry backoff woke up, saw an empty
  `lockJobId`, and wrote its own jobId back over a lock nobody held — leaving the
  player's next server read-only for the full two-minute lock timeout.

### First Studio run

Everything above was verified headlessly. The place has now been opened in
Studio once, on a session without DataStore API access. What that first look
established, in order of confidence:

- **Works first time.** The server boots, the client connects, the HUD fills
  from the profile — colony card, resource bar, NEXT hint — and the DataStore
  fallback is detected and reported on the HUD exactly as designed.
- **Found and fixed, confirmed by a second screenshot.** Every panel opened as
  an empty block. `Shell.lua` set `ZIndexBehavior.Global`, under which a
  panel's contents — UIKit defaults to ZIndex 1 — drew behind the opaque panel
  card at ZIndex 50. One line; now `Sibling`. The first change in this project
  verified by something rendering rather than by a test.
- **Found and fixed, not yet confirmed.** Job buttons carried only an icon (for
  Idle, literally `·`) and no name; the close glyph `✕` and five resource icons
  have no outline in Gotham and drew as boxes. Names added, `X` substituted,
  the icons swapped for neighbours of glyphs that were seen to render. The
  swaps are inferred from one screenshot and need another look.
- **Found and fixed, not yet confirmed.** The character could not be moved,
  and the world read as a close-up of a tan slab in darkness. Both from one
  line: `RoleService` welds a shoulder lamp onto every body, `PartFactory`
  anchors everything it makes, and an anchored part is always its assembly's
  root — so the Weld moved the *character* to the lamp, at the world origin,
  and pinned it there. The lamp is unanchored and pre-placed now; the
  simulated character has a torso so the kit is built headlessly, and
  `Colony.spec` asserts nothing welded into a fresh body is anchored. The
  spawn pad also rests on the ground now instead of inside it, and
  `SpawnOffset` moved from 118 to 72 so the player lands inside the
  campfire's light rather than 74 studs from the nearest one. No headless
  test runs physics, so this is reasoned and asserted, not observed. If a
  body still cannot move, the Studio **Output** window (View → Output) is
  the first thing to capture.
- **Open, by design.** The colony starts at `3/2 colonists`:
  `StartingColonists` is 3 and TownHall level 1 houses 2, so the first hint
  is to build a Shelter. It reads as broken. Whether the fix is two starting
  colonists or three beds is a balance decision, deliberately not made here.

No test covers any of this and none can today: the integration harness boots
server services and never instantiates client UI. [SETUP.md](SETUP.md) §5
owns it.

---

## First Playable Milestone

The brief lists sixteen things the vertical slice must contain. Status of each:

| # | Requirement | Status | Notes |
|---|---|---|---|
| 1 | A stylised underground colony | ✅ | Procedural cavern, 9 plots, stalactites, columns, glowing flora, campfires, lanterns |
| 2 | A controllable player character | ✅ | Spawning owned explicitly by `SurvivalService`; role stats applied server-side |
| 3 | Five functional colony buildings | ✅ | Town Hall, Shelter, Farm, Workshop, Infirmary — all with 3–4 levels, visible upgrades and real effects |
| 4 | Working inventory and resources | ✅ | 9 resources, weight-based bag, unit-based storage, 4 tools, 5 recipes |
| 5 | NPC worker assignments | ✅ | 7 jobs, simulated production, visible rigs, offline catch-up |
| 6 | Runner, Medic and Guardian roles | ✅ | Passives, actives, mastery ladders, server-applied stats |
| 7 | Cave entrance interaction | ✅ | `ProximityPrompt` on an arch, opens the expedition lobby |
| 8 | Procedurally assembled cave, 10–15 rooms | ✅ | Deterministic, seeded, validated; 10/13/15 by difficulty |
| 9 | Day/night cycle | ✅ | 4 phases, configurable, with lighting and audio response |
| 10 | Working maze shift | ✅ | Warned, validated, rolled back on failure, never seals a player in |
| 11 | Two enemy types | ✅ | Cave Crawler (a fight) and the Stalker (a problem); shared state machine |
| 12 | Resource harvesting | ✅ | 8 node types, server-validated, tool tiers, stamina cost, respawn |
| 13 | One ancient key objective | ✅ | Key pickup, pillar puzzles, First Gate with a staged ladder |
| 14 | Extraction and return to colony | ✅ | Two exits, hold-to-extract, bag deposited, results screen |
| 15 | Persistent rewards and upgrades | 🟡 | Written and complete; **untestable until DataStores are enabled** (SETUP.md §3) |
| 16 | Solo and up to four-player | ✅ | Solo is a party of one; cap 4, scaling tables cover 5–8 |
| 17 | Basic UI | ✅ | Main menu, 2 HUDs, 7 panels, 3 notification tiers, keyboard/mouse/gamepad/touch |
| 18 | Reliable save handling | 🟡 | Session locking, retries, migration, read-only fallback — all written, none exercised |

**Target: an enjoyable 15–25 minute experience.** Medium is a 22-minute
expedition plus colony time, so the arithmetic works. Whether it is *enjoyable*
is the one thing this document cannot claim.

---

## By system

### Foundation

| System | Status | Notes |
|---|---|---|
| Rojo project | ✅ | `default.project.json`, lighting/sound/physics configured |
| Toolchain manifest | ✅ | `rokit install` installed all four tools at exactly the pinned versions (Rojo 7.4.4, StyLua 0.20.0, Selene 0.27.1, Lune 0.8.9) |
| Shared config | ✅ | 11 config modules, all data, no behaviour |
| Enums | ✅ | Persisted string ids with a "never rename without a migration" rule |
| Networking | ✅ | One router, 3 remotes, per-route rate limits, payload sanitising |
| Logging | ✅ | Tagged, debug-gated, throttled variant for hot paths |
| Pure libraries | ✅ | `CaveLayout`, `Inventory`, `Rng`, `RoomRules`, `PlotGrid` |
| Persistence | 🟡 | Complete, including locking and migration. Migration chain is empty (v1 is the first schema) — correct, but means the migration path is unexercised |
| Procedural geometry | ✅ | `PartFactory`: blocks, wedges, walls-with-doorways, lights, prompts, labels, scatters, mushrooms, lanterns, arches |

### Colony

| System | Status | Notes |
|---|---|---|
| Cavern + plots | ✅ | 9 plots, claimed on join, released on leave, ground recolours when owned |
| Plot permissions | ✅ | One gate (`canManage`); no code path spends another player's resources |
| Building placement | ✅ | Grid snap (half-cell for even footprints), rotation, bounds, overlap, affordability |
| Placement preview | ✅ | Client ghost using the **same** `PlotGrid` maths as the server |
| Upgrade / repair / demolish | ✅ | Visible level changes; 50% refund; Town Hall protected |
| Colony effects | ✅ | Declarative; condition-scaled; no system reads a building id |
| Colonists + jobs | ✅ | 7 jobs, slot validation, orphan reassignment with a notice |
| Production simulation | ✅ | Probabilistic quantisation so fractional output is not lost |
| Visible colonists | ✅ | Capped at 10/plot, one shared loop, skipped when unobserved |
| Offline production | ✅ | 8h cap, 50% efficiency, condition floored at 55. Paid once, capped, never into a session that cannot be saved — 14 tests in `Offline.spec` |
| Crafting | ✅ | Station + level gating, atomic payment, greyed rows with reasons |
| Colony visiting | ✅ | Walk or jump; directory in the colony panel; always read-only |
| Research points | 🟡 | Accumulated by Researcher colonists and the lab, but **nothing spends them yet** |

### Caves and expeditions

| System | Status | Notes |
|---|---|---|
| Layout generation | ✅ | Pure, deterministic, self-validating |
| Room geometry | ✅ | 11 kinds, 16 prop builders, biome theming, floors never rebuilt |
| Biomes | 🟡 | 3 defined; Crystal Reach only appears on Hard, so it is the least exercised |
| Maze shift | ✅ | Full contract implemented and tested across hundreds of seeds |
| Expedition clock | ✅ | 4 phases, shift scheduling, warnings at 30s and 10s |
| Resource nodes | ✅ | Seeded placement, biome bias, server-validated harvest, respawn, never re-rolled by a shift |
| Monsters | ✅ | Shared state machine, LOD ticking, noise propagation, night surge |
| Combat | ✅ | Melee only, server-validated, latency-tolerant reach |
| Survival stats | ✅ | Health/stamina/hunger, fall damage from height, damage log |
| Downed / revive / death | ✅ | Clamped damage, server-channelled revive, spectate, free rescue |
| Objectives | ✅ | Keys, pillar puzzles with a seeded order, First Gate stage 1 |
| Extraction | ✅ | Two exits, server-verified room, full deposit |
| Results and rewards | ✅ | XP with breakdown, levels, mastery, unlock callouts |
| Party | ✅ | Private codes, public listing, readiness, leadership handover, map marks |
| Expedition transport | 🟡 | `"local"` implemented. `"teleport"` **refuses to start** with a clear message rather than half-working |

### Client

| System | Status | Notes |
|---|---|---|
| Store (read model) | ✅ | Every push route lands in one place |
| UIKit | ✅ | 20+ components, all themed, all ≥44px touch targets |
| Shell | ✅ | 5 layers, lazy panels, hotkeys, hides nav underground |
| Main menu | ✅ | All 7 entries the brief asks for |
| Colony HUD | ✅ | Resources updated in place, plus a derived "what to do next" line |
| Expedition HUD | ✅ | Clock, shift countdown, vitals, team, objectives, bag, ability, overlays |
| Panels | ✅ | Colony (3 tabs), Build (2 tabs), Roles, Expeditions, Inventory, Shop, Results, Settings |
| Notifications | ✅ | Toast / alert / full-screen warning |
| Input | ✅ | Keyboard, mouse, gamepad, touch cluster |
| Placement controller | ✅ | Ghost, rotation, validity banner |
| Audio | 🟡 | Mixer, 40 cues, phase beds, random ambience, crossfades — and **completely silent**, because no asset IDs ship with this project. Reported once at startup |
| Atmosphere | ✅ | Per-biome, per-phase lighting; vignette; camera shake; distance-capped campfire particles |
| Route rendering | ✅ | Pathfinder trail with beams; discovery markers |
| Minimap | 🟡 | The server sends a discovered-rooms map snapshot; the HUD shows counts but **does not draw it** |

### Monetization

| System | Status | Notes |
|---|---|---|
| Shop catalogue | ✅ | 10 products, categorised, cosmetic-only bar one |
| Purchase flow | 🏗 | `ProcessReceipt` complete and idempotent, saves before acknowledging. **Switched off; every product id is 0** |
| Game pass sync | ✅ | Ownership checked on join, only when monetization is enabled |
| Rescues | ✅ | Free rescue always first; paid rescue consumes a receipt-backed balance |
| Cosmetic application | 🏗 | Ownership and equipping are stored and validated; **nothing renders a cosmetic yet** |

### Testing

| System | Status | Notes |
|---|---|---|
| Test harness | ✅ | Self-contained; no external dependency. Runs in Studio on Play, or headlessly via `lune run tools/run-tests` |
| CaveLayout spec | ✅ | 23 tests, sweeping 120 seeds × 3 difficulties |
| ConfigIntegrity spec | ✅ | 56 tests over cross-config references and design invariants |
| Inventory spec | ✅ | 21 tests: atomicity, capacity, loss rules, determinism |
| Rng spec | ✅ | 15 tests: determinism, ranges, weighting, shuffle correctness |
| PlotGrid spec | ✅ | 14 tests: round-trips, snapping, bounds, overlap |
| Module load check | ✅ | `lune run tools/load-check` requires all 67 ModuleScripts. Selene proves code parses; this proves it loads, which is the failure that takes a server down at startup |
| Simulated server | ✅ | `tools/sim.luau` boots all 16 services against a modelled DataModel: working signals, a virtual clock over `os.clock`/`os.time`/`task`, a separate wall clock that moves `os.time()` alone so hours can pass with the server idle, `rejoin` for bringing the same account back, and an in-memory DataStore with real `UpdateAsync` semantics. Lune's own `Instance` could not be used — `@lune/roblox` manipulates place files, so it has no signals and cannot derive `Position` from `CFrame` |
| Expedition spec | ✅ | 17 tests: the key banking regression end to end, re-settle hammering, harvest and depletion, range, cross-session, extraction gating, abandon recovery, per-player loot, world-slot isolation |
| Monsters spec | ✅ | 16 tests: the Crawler is killable and the Stalker is not, damage-scaled interest loss, no spawns in safe rooms, difficulty scaling, every refusal path, the 1-HP floor, downed immunity |
| Clock spec | ✅ | 14 tests: prep → day → dusk → night on the configured durations, no phase ending early, one announcement per boundary, the duration contract, the shift schedule and its two warnings, layout validity after every shift, timeout settlement and teardown |
| Death spec | ✅ | 13 tests: the clamp that makes instant death impossible, the downed window per difficulty, the R2 death loop, the R5 corpse reuse, the solo rescue window, revive channelling and interruption, death settlement |
| Disconnect spec | ✅ | 12 tests: the R8 haul and key banking, mid-load disconnect releasing the lock, party and session teardown, abandon as the contrast case |
| Persistence spec | ✅ | 18 tests: session locking across two servers sharing one store, the read-only fallback, degradation and recovery, the late-write guard, idempotent receipts, autosave refresh. Tuning constants are matched out of the service's own source rather than hard-coded |
| Colony spec | ✅ | 17 tests: placement, upgrade, repair, demolition and their exact costs and refunds, grid bounds and overlap, visitor isolation, worker assignment and production, storage atomicity on every refusal |
| Offline spec | ✅ | 15 tests: an absence is paid once and only once, capped at 8 hours with the remainder discarded rather than banked, reduced against the same time played, settled before the returning player's first snapshot, reported as what storage took rather than what was made, never granted into a session that cannot be written, and never below the condition floor or short a colonist |
| Production spec | ✅ | 8 tests: a job that cannot pay its inputs does not work and spends nothing — with the `pairs` precondition asserted so a change in iteration order fails loudly — a stocked larder as the control, a spend-only tick still pushing storage and withdrawing a recipe the colonists ate out of reach, the buildings-only food rate pinned against the real one, condition decay to the unit and a Guard holding it, one job's `skillGain` per worked tick and none for an idler |
| Integration test run | ✅ | `lune run tools/run-integration` runs all 130 in 10s against a fresh server per test; exits non-zero, so it can gate a commit or CI. 10 consecutive runs gave identical results |
| Headless test run | ✅ | `tools/harness.luau` builds a fake instance tree over the real files and supplies the datatypes Lune lacks. `lune run tools/run-tests` runs all 129 in 0.7s; exits non-zero, so it can gate a commit or CI |

---

## Known limitations

### Deliberate

1. **One Place.** Colony and caves coexist at different coordinates. The
   `"teleport"` path exists and refuses to run rather than inventing a `PlaceId`.
2. **Nine plots in one cavern**, not per-player instances. Argued in
   GAME_DESIGN.md §6.
3. **No external assets at all.** Every structure, monster and prop is built from
   primitives. No model, image, sound or animation ID appears anywhere.
4. **Melee only.** One validated attack path.
5. **Four-player cap** against an eight-player design.
6. **Three of six roles.** The rest refuse honestly.
7. **Five of ten buildings.** The rest are blocked behind `MvpContentOnly`.
8. **One gate stage of three.** Later stages refuse and name themselves.
9. **No temperature system.** Specified in the brief as optional and "for later
   biomes"; not started.

### Unresolved

| Item | Impact | Where |
|---|---|---|
| Monsters slide rather than walk | Visual. No animations ship, and a custom rig with no `Animator` has nothing to play | `AI/MonsterBase.lua` |
| No monster health bar beyond Roblox's default | Minor readability gap | `AI/MonsterBase.lua` |
| Map snapshot is sent but not drawn | Players navigate by memory and the Pathfinder ability | `UI/ExpeditionHUD.lua` |
| Research points accumulate with nothing to spend them on | Dead-end progression stat | `NPCService`, `ColonyService` |
| Cosmetics are owned and equipped but never rendered | The shop grants nothing visible | `MonetizationService` |
| `Watchtower.shiftWarningBonus` is summed but never read | Config promises an effect that does nothing | `BuildingConfig`, `ExpeditionService` |
| Migration chain is empty | The migration path has never run on real data | `Data/Migrations.lua` |
| Rokit may not put its shims on `PATH` | Installed through WinGet, only Rokit's own directory reached the user `PATH`; `~/.rokit/bin` never did, so no new shell or reboot helps. SETUP.md §1 has the check and the fix | `rokit.toml` |
| No rate limit on `ProximityPrompt` spam beyond the route budget | The route budgets cover it, but prompt-triggered requests are the most spammable surface | `Util/Net.lua` |
| The movement fix is unconfirmed on screen | The anchored-lamp root cause is fixed and asserted structurally, but no headless test runs physics. If a body still cannot move, capture the Output window first | `RoleService`, `Colony.spec` |
| A session whose store is down when it leaves loses progress since its last autosave | Inherent to an outage: the release lands in memory and nothing flushes memory back when the store recovers; the real record also keeps this server's lock until it expires | `DataService` |
| Mid-session degradation is never shown to the client | `degraded` and `readOnly` ride only the join-time `GetProfile` reply, so a session that degrades later keeps a clean HUD | `ColonyService`, `Store` |
| Preference routes still run on a read-only profile | `AssignJob`, `EquipTool`, `SetSetting`, `LoadoutSupplies`, `DepositBag` — harmless, since nothing is kept, but inconsistent with the rest | `NPCService`, `InventoryService` |
| A party whose leader disconnects mid-run is never released | `session.partyCode` is stored but never used | `ExpeditionService`, `PartyService` |
| Colonist rigs wander through the Town Hall footprint and the spawn | Cosmetic; rigs are non-colliding decor | `NPCService` |
| A spawn with a role below 100 max health flashes damage once | `SurvivalService` pushes 100/100 before `RoleService` clamps max health | `AtmosphereController` |
| Several icons may still render as boxes | Gotham lacks the glyphs; five resource icons were swapped on the strength of one screenshot and the job icons were not touched | `ResourceConfig`, `JobConfig` |
| The colony starts at 3/2 colonists | Reads as broken: `StartingColonists` is 3 against TownHall housing of 2 | `GameConfig`, `BuildingConfig` |

---

## What to build next

In the order I would actually do it.

### 1. Play it

The static side is done: the suite passes, every module loads, Selene is clean
and Rojo builds. What is left is everything the engine owns, and the only way to
find those bugs is to press Play. Expect to spend the first session fixing
things this document calls ✅.

The most likely failure sites, in order. Note that the load check already ruled
out the cheapest class of error in all of them (bad require paths, nil indexes
while building tables), so what remains is genuinely runtime behaviour:

1. **Client UI layout.** The most code, and the hardest to verify without
   looking at it. Every panel builds its tree correctly in the sense that it
   loads and runs; whether `UIKit.panel`'s header seam, the `AutomaticSize`
   chains and the scrolling frames actually lay out as intended is unknown.
2. **`MonsterBase` rig assembly.** Custom Humanoid rigs are fussy about
   `HumanoidRootPart` naming, `HipHeight` and weld order. If monsters spawn
   face-down or refuse to move, it is here.
3. **`BuildingBuilder` roof wedges.** The pitch maths composes three rotations
   and is pure guesswork until seen.
4. **Service start-up ordering around `profileLoaded`.** Deliberately deferred
   in `DataService`, but only reasoning says that is sufficient.
5. **The maze shift's geometry rebuild.** The layout half is proven by tests;
   that `RoomLibrary.buildShell` tears down exactly the right parts and leaves
   the floor is not.

### 2. Draw the minimap

The server already sends everything needed. This is the single biggest
playability win available: the caves are navigable now only by memory, and after
a shift memory is exactly what stops working.

### 3. Spend research points

Either a colony tech tree or gate-research progress. Right now the stat
accumulates and does nothing, which is worse than not having it.

### 4. Render cosmetics

Ownership, equipping and validation all exist. A skin that changes nothing makes
the whole shop feel fake.

### 5. The gaps the simulation still cannot reach

Done, and it found thirteen bugs — see **What the simulation found** above. What it
deliberately leaves uncovered, each for a stated reason, is the honest next
increment:

- ~~**A job that cannot pay its inputs.**~~ Covered since: `Production.spec`
  reaches it online, at the skill where the Cook's mushroom is certain on
  every tick, and asserts the `pairs` precondition so a change in iteration
  order fails loudly rather than going quietly vacuous. Writing it is what
  found the storage-push bug above.
- **`productionMult`.** Only level-2 buildings carry it, so asserting it means
  funding an upgrade and then separating an 8% multiplier from a probabilistic
  path.
- **The shift rollback branch.** `CaveService` rolls a failed shift back and warns;
  no seed tried produced a shift that failed validation, so the branch is
  unreached without forcing internals.
- **Multi-player shift protection.** Two members in different rooms, both
  protected — needs a real party inside a shift test.
- **`LimitReached`** for `maxCount` and the 48-building cap: placing 48 buildings
  per test is slow for what it proves.
- **Recruitment and housing population caps**, and the `craft_iron_pick`
  station-level gate (observed working, not asserted).
- **Offline skill gain is not scaled**, and that is a balance decision, not a
  bug to fix quietly. `skillGain` is granted flat per tick while output is
  halved, so one absence of half an hour takes a worker from skill 1 to the
  ceiling and the whole shallow curve is skipped. `Offline.spec` pins the
  invariant — it stops at the ceiling — and records the tension; see open
  question 5 in [GAME_DESIGN.md](GAME_DESIGN.md).
- **Building food ignores the offline scale too.** `effects.foodPerTick` is
  never multiplied by `globalMult`, where `efficiencyScale` lives — and it
  ignores it online as well, so an absence yields the same food as being
  present. Not an exploit, but not what "50% offline" says either.
  `Offline.spec` pins the arithmetic as it is. Same category as skill: a
  one-line change and a balance decision, recorded in GAME_DESIGN.md rather
  than made quietly.
- **Anything physical.** There is no physics headlessly. The lamp that pinned
  every body to the world origin was invisible to 128 green tests; it is now
  asserted structurally — nothing welded into a freshly spawned body is
  anchored — rather than observed.
- **The expedition member notice.** A read-only member dropped from a start is
  told why; the harness has no party-of-two helper yet, so the leader refusal
  is tested and the member path is not.
- **Anything visual.** `workspace:Raycast` returns nil and nothing renders, so the
  shift tests assert on the *layout* — doors, reachability, validity — not on
  geometry. The spectate overlay and the ability cooldown shade are the two
  semantic-review fixes with no test for this reason.

### 6. Finish the Cook

Easiest of the three remaining roles: Emergency Rations is a radius heal over two
stats, and all the plumbing exists.

### 7. The Engineer's beacon

Hardest and most interesting, because it directly threatens the maze shift. The
constraints are already in config (one use, 6s channel, banned at night); the
work is implementing them and then play-testing whether they are enough.

### 8. Monster animation

Even two poses alternating would substantially improve how the Crawler reads.
Needs either animation assets or procedural `CFrame` leg movement.

### 9. Raise the party cap to eight

Scaling tables already cover it. Needs load-testing with eight players and
probably a second look at monster tick budgets.

### 10. Chapter 2

Gate stages 2 and 3, Crystal Reach as a real destination, and whatever the
surface turns out to be.
