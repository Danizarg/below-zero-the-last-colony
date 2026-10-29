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
| Rojo builds the place file | `rojo build -o build/BelowZero.rbxlx` | **pass** — 991 KB. Rojo validates every `$properties` name and type against its reflection database, so the Lighting, Players and Workspace properties are all real |
| Luau parses, via a real parser | `selene src` | **0 parse errors** across all 76 files |
| Static analysis | `selene src` | **0 errors, 0 warnings** |
| Formatting | `stylua --check src` | **clean** (44 files were reformatted to get there) |
| Spec suite, headless | `lune run tools/run-tests` | **129 passed, 0 failed** in 0.7s |
| Every module loads | `lune run tools/load-check` | **67 of 67 ModuleScripts load** |
| Every constant reference resolves | `lune run tools/ref-check` | **3,820 references, 0 dangling** — no mistyped enum, route or theme token anywhere |
| Every cross-service call is real | `lune run tools/call-check` | **313 calls, 0 broken** — no typo'd `self.context.X:method()`, none over-applied |
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

**Important caveat:** these fixes are reasoned, not observed. Nine of the
thirteen are in engine-dependent paths that the headless harness cannot reach, so
they are covered by the regression steps in [SETUP.md](SETUP.md) §5 rather than
by a test. The four that static tooling can police (the rate-limit gap, and the
three config/contract issues) now have assertions.

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
| Offline production | ✅ | 8h cap, 50% efficiency, condition floored at 55 |
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
| Server integration tests | ❌ | Nothing drives a full expedition end to end. The harness could grow into it — the services load, so stubbing Heartbeat and stepping the clock is the next increment. Manual checklist in SETUP.md §5 covers it today |
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
| Rokit needs a new shell after install | Its shims land in `~/.rokit/bin`, which an already-open terminal does not see | `rokit.toml` |
| No rate limit on `ProximityPrompt` spam beyond the route budget | The route budgets cover it, but prompt-triggered requests are the most spammable surface | `Util/Net.lua` |

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

### 5. Integration tests for a full expedition

A headless harness that starts a session, simulates harvests and shifts, and
asserts the results settle correctly. The unit tests cover the risky *logic*;
nothing covers the *orchestration*, which is where the remaining bugs will be.

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
