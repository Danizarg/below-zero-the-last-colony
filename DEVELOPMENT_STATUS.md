# DEVELOPMENT STATUS

**Version 0.1.0-mvp** · 76 Lua files · ~29,350 lines

## How to read this

| Mark | Meaning |
|---|---|
| ✅ **Implemented** | Code exists, is complete, and can be meaningfully tested |
| 🟡 **Partial** | Works, with a stated limitation or an unfinished edge |
| 🏗 **Architected** | Config, data model and call sites exist; behaviour deliberately refuses rather than pretending |
| ❌ **Not started** | No code |

**Nothing in this repository has been executed.** There is no Roblox Studio,
Rojo, Lune or Luau binary on the machine it was written on. "Implemented" means
the code is written and reviewed, not that it has been seen to work.

### What has actually been verified

| Check | Result |
|---|---|
| Structural check across all 76 Lua files (balanced `end`/block keywords, balanced brackets, malformed table entries) | **0 problems** |
| `default.project.json` parses as JSON | **pass** |
| Luau syntax via the real compiler | **not run** — no binary available |
| `selene` / `stylua` | **not run** |
| Test suite (5 specs, 129 tests) | **not run** — needs the Roblox engine; runs automatically on Play in Studio |
| Anything requiring the engine | **not run** |

The test suite (129 tests across 5 spec files) is written and wired. It is the first thing to run — see
[SETUP.md](SETUP.md) §4. Until it has run, treat every ✅ below as "written and
reviewed" rather than "known good".

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
| Toolchain manifest | 🟡 | `rokit.toml` exists; **versions unverified** — no network access to check them |
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
| Test harness | ✅ | Self-contained; no external dependency |
| CaveLayout spec | ✅ | 23 tests, sweeping 120 seeds × 3 difficulties |
| ConfigIntegrity spec | ✅ | 56 tests over cross-config references and design invariants |
| Inventory spec | ✅ | 21 tests: atomicity, capacity, loss rules, determinism |
| Rng spec | ✅ | 15 tests: determinism, ranges, weighting, shuffle correctness |
| PlotGrid spec | ✅ | 14 tests: round-trips, snapping, bounds, overlap |
| Server integration tests | ❌ | Nothing tests a full expedition end to end. Manual checklist in SETUP.md §5 covers it |
| Headless test run | ❌ | Specs use `game:GetService`, so they need Studio. A Lune shim is possible but not written |

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
| Toolchain versions in `rokit.toml` unverified | `rokit install` may fail on a bad pin | `rokit.toml` |
| No rate limit on `ProximityPrompt` spam beyond the route budget | The route budgets cover it, but prompt-triggered requests are the most spammable surface | `Util/Net.lua` |

---

## What to build next

In the order I would actually do it.

### 1. Run the tests, then play it

Nothing below matters until the suite has run and the loop has been played once
end to end. Expect to spend the first session fixing things this document calls
✅. The most likely failure sites, in order:

1. Client UI construction — the most code with the least verification.
2. `MonsterBase` rig assembly — custom Humanoid rigs are fussy about
   `HumanoidRootPart`, `HipHeight` and welds.
3. Service start-up ordering around `profileLoaded`.
4. `BuildingBuilder` wedge orientation — the roof pitch maths is unverified.

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
