# SETUP — getting BELOW ZERO running and tested

This gets you from a clone to a running game, and then tells you exactly what to
look at.

**What has been verified**, by actually running it:

| Check | Result |
|---|---|
| `rojo build -o build/BelowZero.rbxlx` | pass, 1,213 KB |
| `selene src` | 0 errors, 0 warnings, **0 parse errors** across 84 files |
| `stylua --check src tools` | clean |
| `lune run tools/run-tests` | **129 passed, 0 failed** in 0.7s |
| `lune run tools/run-integration` | **116 passed, 0 failed** in 10s |
| `lune run tools/load-check` | **67 of 67 modules load** |

**What has not been verified**: anything the Roblox engine owns. UI actually
rendering and laying out, Instances assembling correctly, monster pathfinding,
real DataStore persistence, real multiplayer. The integration suite narrowed
this — it exercises service orchestration, the phase clock, the maze shift, the
session-lock protocol and the disconnect paths against a simulated DataModel —
but a simulation is not the engine. That is what §5 below is for, and it is the
reason the checklist is 59 steps long rather than 5.

If you only want to know whether the logic still holds, you do not need Studio
at all:

```bash
lune run tools/run-tests
```

---

## 1. Install the toolchain

You need two things: the **Rojo CLI** (to turn `src/` into something Studio can
open) and the **Rojo Studio plugin** (to receive the sync). Pick one install
route.

### Option A — Rokit (recommended; `rokit.toml` is already in the repo)

Install [Rokit](https://github.com/rojo-rbx/rokit), then:

```bash
rokit install
```

That reads `rokit.toml` and installs Rojo 7.4.4, StyLua 0.20.0, Selene 0.27.1
and Lune 0.8.9. Those exact pins are known good — all four install and run.

> **Rokit will tell you to restart your computer. You do not need to.** Its
> shims go in `~/.rokit/bin` (`%USERPROFILE%\.rokit\bin` on Windows) and it adds
> that to your user `PATH`. An already-open terminal does not pick up a `PATH`
> change, which is the whole problem — so just **open a new terminal**.
>
> If you want it working in the terminal you already have:
>
> ```bash
> set PATH=%PATH%;%USERPROFILE%\.rokit\bin
> ```
>
> Or skip `PATH` entirely and call the shim directly:
>
> ```bash
> "%USERPROFILE%\.rokit\bin\rojo.exe" plugin install
> ```
>
> One more wrinkle: Rokit's shims resolve a tool from the nearest project
> manifest, so run them **from the repository root**. Running `lune` from
> somewhere else gives you `Failed to find tool 'lune' in any project manifest
> file`.

### Option B — Aftman

Aftman reads the same `[tools]` table. Copy `rokit.toml` to `aftman.toml` and run
`aftman install`.

### Option C — Cargo

```bash
cargo install rojo
```

### Option D — Prebuilt binary

Download `rojo.exe` from the [Rojo releases
page](https://github.com/rojo-rbx/rojo/releases) and put it on your `PATH`.

### Then install the Studio plugin

```bash
rojo plugin install
```

If that subcommand is unavailable in your version, install **Rojo** from the
Roblox Creator Store inside Studio instead (Toolbox → Creator Store → search
"Rojo"). Either way you want the Rojo button to appear in Studio's Plugins tab.

---

## 2. Get it into Studio

There are two ways. The first is better for development; the second is faster for
a single look.

### Live sync (recommended)

```bash
rojo serve
```

Then in Studio: **new baseplate → Plugins tab → Rojo → Connect**. The tree
appears immediately and re-syncs on every file save.

### Build a place file

```bash
rojo build -o BelowZero.rbxlx
```

Open `BelowZero.rbxlx` in Studio. No live reload, but nothing to keep running.

### What you should see in the Explorer

```
ReplicatedStorage
  BelowZero/              Config, Data, Lib, Util, Enums, Routes
ServerScriptService
  BelowZeroServer         (a Script, with Services/World/AI beneath it)
  BelowZeroTests          (TestRunner + specs + RunTests)
StarterPlayer
  StarterPlayerScripts
    BelowZeroClient       (a LocalScript, with UI/Controllers beneath it)
```

If `BelowZeroServer` is a Folder rather than a Script, the `init.server.lua` file
did not sync — check you opened the project from the repository root.

---

## 3. Turn on DataStores (do this before testing persistence)

**Game Settings → Security → Enable Studio Access to API Services → Save.**

Without it, `DataService` detects the failure, falls back to an **in-memory**
store, and says so once in the Output:

```
[BZ/DataService] WARN falling back to IN-MEMORY profiles; nothing will persist across sessions.
[BZ/DataService] WARN in Studio, enable Game Settings > Security > Enable Studio Access to API Services to test real saving
```

The game is fully playable in that mode — you just will not keep your colony
between sessions. That is the correct behaviour, not a bug, but it does mean
**persistence is the one feature you cannot test until you flip this switch.**

---

## 4. Press Play

Hit **Play** (F5). Expected Output, roughly in this order:

```
[BZ/Net] server transport ready
[BZ/DataService] ready (jobId=..., store=BelowZero_Profiles_v1)
[BZ/ColonyService] colony cavern built with 9 plots
...
[BZ/Bootstrap] started 16 services, N request routes, M event routes in 0.XXs
[BZ/Test] running 5 spec files
[BZ/Test] PASS  CaveLayout             23 passed, 0 failed, 0 skipped
[BZ/Test] PASS  ConfigIntegrity        ...
[BZ/Test] ───── N passed, 0 failed, 0 skipped in X.XXs ─────
[BZ/Test] ✓ all tests passed
```

**The tests run automatically** in Studio whenever `GameConfig.Debug` is true.
They are the fastest way to find out whether anything is broken, and they are
where you should look first if the game misbehaves. They never run on a published
server.

To re-run them without restarting, open the Command Bar during a running session:

```lua
require(game.ServerScriptService.BelowZeroTests.TestRunner).runAll()
```

You will also see the generated cave printed as ASCII art, which is the quickest
way to sanity-check a seed:

```
[BZ/CaveBuilder] layout seed 123456
   │
  ─┼──M
   │  │
   E  .
```

`E` entrance · `V` ancient vault · `X` extraction chamber · `P` puzzle room ·
`M` mining · `R` resource · `N` nest · `┼` junction · `.` dead end · `─`/`┐`
corridors.

---

## 5. Testing checklist

Work down this list. Each item says what to do and what should happen. Anything
marked **⚠** is a known gap, documented in `DEVELOPMENT_STATUS.md`.

### Colony (first 5 minutes)

| # | Do | Expect |
|---|---|---|
| 1 | Play solo | You spawn on a lit plot in a dark cavern, with a Town Hall already built |
| 2 | Look at the HUD | Colony name top-left, resource strip top-centre, a "NEXT" objective top-right |
| 3 | Press `B` | Construction panel opens, listing Shelter and Fungal Farm as buildable |
| 4 | Pick Shelter, move the mouse | A green translucent footprint follows the cursor, snapped to the grid |
| 5 | Move it off your plot | The footprint turns red and the banner says "outside your plot" |
| 6 | Press `R` | The footprint rotates; the amber facing marker moves |
| 7 | Click on a valid spot | A shelter is built, resources drop, the HUD updates |
| 8 | Try to place a second building overlapping the first | Refused, red footprint, "overlaps Shelter" |
| 9 | Press `C` → Colonists | Three unassigned colonists listed |
| 10 | Build a Farm, then assign a colonist as Farmer | Job button highlights; after ~10s mushrooms start appearing in storage |
| 11 | Wait ~30s watching the resource strip | Counts rise from NPC production |
| 12 | Press `C` → Crafting | Recipes listed; Stone Pick greyed out with "Needs a workshop" |
| 13 | Upgrade the Town Hall to level 2 (`B` → Manage) | Workshop unlocks; the Town Hall visibly gains a storey and a brighter beacon |
| 14 | Build a Workshop, craft a Stone Pick | Tool appears in Inventory (`Tab`) and auto-equips |

### Expedition (the main loop)

| # | Do | Expect |
|---|---|---|
| 15 | Walk to the cave entrance arch and press `E` | Expedition panel opens |
| 16 | Read the difficulty cards | Each states run length, room count, shift cadence, revive window and **how much of your haul you keep if you die** |
| 17 | Pick Easy, press ENTER THE CAVES | Screen content swaps to the expedition HUD; you are in a lit tunnel mouth |
| 18 | Check the Output | `[BZ/ExpeditionService] session 1 started: easy, 1 players, seed N, 10 rooms` plus the ASCII map |
| 19 | Look at the HUD | Phase clock top-centre, HP/ST/FD bottom-left, bag and tool bottom-right, objectives right |
| 20 | Walk into the next room | The objectives card gains "Explored 2 / 10 rooms" |
| 21 | Find a stone outcrop, press `E` repeatedly | `+3` toasts, stamina drains, the node fades out when empty |
| 22 | Try to harvest an iron seam with bare hands | Refused: "You need a Stone Pick for this" |
| 23 | Hold `Shift` and run | Stamina drains faster; releasing it recovers |
| 24 | Find a Cave Crawler and click it | It winds up visibly before hitting; your HP drops and the screen edges flash red |
| 25 | Keep fighting until it dies | Kill toast, fiber may drop into your bag |
| 26 | Press `Q` | Your role ability fires (Runner lights a route out; Guardian/Medic apply an aura) |
| 27 | Let the prep phase end | Phase changes to DAY, then DUSK with a full-screen **"WARNING: THE CAVES ARE SHIFTING / RETURN TO THE COLONY"** |
| 28 | Watch the shift countdown | A "SHIFT IN 0:30" line appears, turning red under 30s, with warnings at 30s and 10s |
| 29 | Stay put through a shift | Screen shakes, a cold flash, **"THE CAVES HAVE SHIFTED"**, and walls around you have changed — but you are still standing on solid floor |
| 30 | Try to leave the room you were in | There is always a way out (the generator guarantees it; the tests prove it) |
| 31 | Find the Ancient Vault (`V` on the ASCII map) | Key on a plinth, plus the First Gate |
| 32 | Take the key | Party-wide alert, key enters your bag |
| 33 | Examine the gate | A dialog states keys required vs held, what opening it unlocks, and that your colony is **not** reset |
| 34 | Open it with a key | "THE FIRST SEAL OPENS", the slab sinks, gate stages increments |
| 35 | Find a puzzle room, touch the pillars in the wrong order | Runes dim, "Wrong order" — no other penalty |
| 36 | Solve it | Relics awarded, and a key's location is revealed on your map |
| 37 | Return to the tunnel mouth and hold `E` | Extraction: your bag empties into colony storage, results screen appears |
| 38 | Read the results screen | Outcome, resources brought home, XP breakdown, level, role mastery |
| 39 | Check storage back home | The haul is there, permanently |

### Failure paths (these matter most)

| # | Do | Expect |
|---|---|---|
| 40 | Let a Crawler reduce you to zero HP | You go **down**, not dead: red overlay, a counting-down timer, "Hold on" |
| 41 | Let the timer expire | "YOU DIED" with the **actual cause** listed ("Killed by Cave Crawler (36)"), and a free-rescue button |
| 42 | Use the free rescue | You respawn at the tunnel mouth with your bag intact |
| 43 | Die again | The rescue button is greyed out with an explanation; you are told you will still get part of your haul |
| 44 | Wait for night to end | Results screen: "CAUGHT BY THE SHIFT", partial recovery, **keys kept in full** |
| 45 | Check storage | Partial haul deposited; ancient keys all present |
| 46 | Fall a long way on purpose | Fall damage scaled to height, and it can down you but **never** kill you outright |
| 47 | Let hunger run out (Hard, long run) | Slow HP drain with a visible warning, not a sudden death |

### Multiplayer

**Test tab → Clients and Servers → 2 Players → Start.**

| # | Do | Expect |
|---|---|---|
| 48 | Look at both clients | Two adjacent claimed plots, each with its own nameplate and warmer ground |
| 49 | Walk player 1 onto player 2's plot and press `B` | You can open the panel but every placement is refused: it is not your colony |
| 50 | Player 1: `X` → note the party code. Player 2: `X` → Open Parties → join | Both see a 2-person roster with roles |
| 51 | Player 2 toggles ready, player 1 starts | Both enter the same cave, team card appears on the HUD |
| 52 | Separate, then have one player go down | The other sees "X IS DOWN" with a countdown |
| 53 | Walk over and hold `E` on them | A server-channelled revive; walking away mid-channel cancels it with "Revive interrupted" |
| 54 | Play a Medic and stand near a downed ally | Their timer **stops**, and their overlay says "Someone is stabilising you" |
| 55 | Both harvest the same room | Each gets their own drops; there is no shared loot pool to race for |
| 56 | One extracts, the other stays | The leaver gets their results; the other keeps playing until night ends |

### Regressions — bugs found by review and fixed without being observed

These thirteen were found by a semantic review, not by running the game, so the
fixes are reasoned rather than seen working. Nine are in engine paths the
headless harness cannot reach. **Check these specifically.**

| # | Do | Expect |
|---|---|---|
| R1 | Extract cleanly carrying an Ancient Key, then examine the gate | Keys held shows **1 banked**. Before the fix, keys landed in colony storage where no gate code reads them, so extracting well made a key unusable while *failing* banked it |
| R2 | Let the downed timer run all the way out | You die **once**: "YOU DIED", spectate, rescue offered. Before the fix, the `HealthChanged` net re-downed you and the cycle repeated forever, so death never completed |
| R3 | Extract, then (with a teammate still below) try to leave the expedition again | Refused with `already_settled`. Before the fix this re-granted the whole run's XP and +1 mastery per call |
| R4 | Watch the phase clock and "SHIFT IN" countdown for 30s | Both count **down smoothly and correctly**. Before the fix the server sent its own `os.clock()`, which is process-relative, so the client computed garbage |
| R5 | Die, then use the free rescue **within 2 seconds** | You get a fresh living body at the tunnel mouth. Before the fix you were revived into the corpse, which a pending destroy then removed |
| R6 | Die, use the rescue, then look at the screen | The full-screen "YOU DIED" sheet is **gone**. Before the fix it only cleared on returning to the colony |
| R7 | Use your role ability and watch the button | The cooldown shade **drains**. Before the fix it froze at full width until the next push |
| R8 | Disconnect mid-expedition holding resources, rejoin, check storage | The difficulty's recovery fraction is there. Before the fix `InventoryService` cleared the bag first and you lost the lot |
| R9 | Disconnect during the join (quit the instant you spawn), then rejoin | You load normally. Before the fix the lock stayed held by nobody and you got a read-only session for two minutes |
| R10 | Disconnect mid-run, rejoin, start a **new** expedition before the old one times out | The new run is unaffected. Before the fix `endSession` nilled your session binding and ripped you out of it |
| R11 | Spam a nonsense route name from the console | Logs are rate-limited, not one line per message |

For the DataStore-degradation fix (a transient error used to latch the server
into in-memory mode forever while reporting saves as successful), the cheapest
check is to start a session **without** API services enabled and confirm the HUD
shows "Saving is currently unavailable" and the output says
`DID NOT PERSIST` rather than `saves complete`.

### Persistence (needs DataStores on — step 3)

| # | Do | Expect |
|---|---|---|
| 57 | Build things, then stop the session | `[BZ/DataService] saved and released <name>` |
| 58 | Play again | Your buildings, colonists, storage, level and keys are all back |
| 59 | Start a session, then start a **second** Studio session with the same account | The second gets `could not acquire the profile lock ... starting a READ-ONLY session`, a red warning in the HUD, and writes nothing |

---

## 6. Useful knobs while testing

All in [`src/shared/Config/GameConfig.lua`](src/shared/Config/GameConfig.lua):

| Setting | Why you would change it |
|---|---|
| `Debug = false` | Silences `[BZ/...]` logging **and** stops the test suite running |
| `MvpContentOnly = false` | Unlocks the three architected roles and five architected buildings — they are **not implemented**, so expect `NotImplemented` refusals |
| `UseDataStore = false` | Forces in-memory saves without touching Game Settings |
| `TransportMode` | `"local"` is the only implemented mode; `"teleport"` refuses to start with a clear message |

To shorten a run while testing the shift, edit the Easy or Medium
`phaseDurations` in
[`src/shared/Config/DifficultyConfig.lua`](src/shared/Config/DifficultyConfig.lua)
— e.g. `{ prep = 10, day = 20, dusk = 15, night = 60 }` gets you to a maze shift
in under a minute.

To replay an exact cave, note the seed from the Output or the results screen and
pass it back. While `Debug` is true the client may supply a seed:

```lua
-- Studio Command Bar, client context
local Routes = require(game.ReplicatedStorage.BelowZero.Routes)
local Net = require(game.ReplicatedStorage.BelowZero.Util.Net)
Net.request(Routes.Request.StartExpedition, { difficultyId = "medium", seed = 123456 })
```

Client-supplied seeds are ignored when `Debug` is false, so a player cannot scout
a layout and replay it.

---

## 7. The checks you can run without Studio

Six checks, all run from the repository root, all currently green. Run them
before a commit; the Lune ones exit non-zero on failure, so they work in CI.

```bash
lune run tools/run-tests && lune run tools/run-integration && lune run tools/load-check && lune run tools/ref-check && lune run tools/call-check && selene src && stylua --check src tools
```

### `lune run tools/run-tests`

All 129 unit specs, headless, in under a second.

```
[BZ/Test] PASS  CaveLayout             23 passed, 0 failed, 0 skipped
[BZ/Test] PASS  ConfigIntegrity        56 passed, 0 failed, 0 skipped
[BZ/Test] PASS  Inventory              21 passed, 0 failed, 0 skipped
[BZ/Test] PASS  PlotGrid               14 passed, 0 failed, 0 skipped
[BZ/Test] PASS  Rng                    15 passed, 0 failed, 0 skipped
[harness] OK: 129 tests passed in 0.67s
```

This works because `src/shared` needs Roblox *datatypes* but no DataModel, and
Lune provides the datatypes. `tools/harness.luau` builds a fake instance tree
over the real files so each module gets a `script` and a `require` that resolve
exactly as they would after a Rojo sync. It is the same TestRunner and the same
specs Studio runs.

### `lune run tools/run-integration`

All 116 integration specs: a fresh server booted per test, then real gameplay
driven through it.

```
[integration] booting a simulated server per test
[integration] loaded 8 spec file(s)
[BZ/Test] PASS  Clock                  14 passed, 0 failed, 0 skipped
[BZ/Test] PASS  Colony                 16 passed, 0 failed, 0 skipped
[BZ/Test] PASS  Death                  13 passed, 0 failed, 0 skipped
[BZ/Test] PASS  Disconnect             12 passed, 0 failed, 0 skipped
[BZ/Test] PASS  Expedition             16 passed, 0 failed, 0 skipped
[BZ/Test] PASS  Monsters               16 passed, 0 failed, 0 skipped
[BZ/Test] PASS  Offline                14 passed, 0 failed, 0 skipped
[BZ/Test] PASS  Persistence            15 passed, 0 failed, 0 skipped
[integration] OK: 116 tests passed in 9.9s
```

`tools/sim.luau` is what makes this possible, and it had to model the Instance
tree by hand: Lune's `@lune/roblox` exists to manipulate place *files*, so it
has no signals at all — `Instance.new("BindableEvent")` has no `.Event` — and
it cannot derive `Position` from `CFrame`. Both matter here, because one of the
bugs under test is about `HealthChanged` ordering and the services set
`root.CFrame` then read `root.Position`. Datatypes still come from Lune, where
they are exact.

Time is virtual: `os.clock`, `os.time` and the whole `task` library run on a
discrete-event scheduler, so a 25-minute expedition plays out in milliseconds.
That is what makes the phase clock, the shift schedule, node respawns, autosave
intervals and the 2-second corpse-destroy delay testable at all.

There is a second clock, and it moves on its own. `advanceWallClock(seconds)`
pushes `os.time()` forward while `os.clock()` stays put and no timer fires at
all — hours passing with the server doing nothing. That is the only honest way
to reach offline production, which exists precisely BECAUSE nothing ran:
advancing the simulation instead would fire thousands of ONLINE production
ticks and test the opposite code. The two clocks part company on a real rejoin
too, where a returning player usually lands on a different server whose
`os.clock()` started over while epoch time moved on. `rejoin(player)` is the
other half: the same account back with a new Player object, which is what the
engine hands you and what a profile is keyed by. The DataStore
is a real in-memory store with genuine `UpdateAsync` read-modify-write
semantics, because the session-lock protocol is where several bugs lived.

**Honest scope.** This proves service logic and orchestration, not engine
fidelity. `workspace:Raycast` returns nil, nothing renders, and
`PathfindingService` is a stub. Every spec header names what it could not reach;
§5 is still the checklist for the rest.

The integration specs are Lune-only. `TestRunner.loadSpecs` walks
`GetChildren()` and matches `*.spec`, so the `integration` folder — a Folder,
not a ModuleScript — is skipped on Play. They do ship inside the place file
(about 230 KB of it) because `src/tests` is mapped whole; they are inert there,
and keeping the Rojo tree simple was judged worth the bytes.

### `lune run tools/load-check`

Requires all 67 ModuleScripts and reports each one.

Worth running separately because Selene proves code *parses*, not that it
*loads*. A typo in a require path, a nil index while building a config table, or
a service captured at require time that does not exist all parse perfectly and
then fail the instant Studio touches them — and since the server bootstrap
requires everything at startup, one of those takes the whole game down.

### `lune run tools/ref-check`

Scans all 76 files for dotted constant references — `Enums.Reject.TooFar`,
`Routes.Push.ObjectiveSync`, `Theme.Color.Accent` — and looks each one up in the
real loaded module. **3,820 references, all resolve.**

Luau is dynamically typed, so `Routes.Push.ObjectiveSyncc` is not an error: it is
`nil`. The packet gets sent under a nil route name, the client never receives it,
and nothing warns. In a codebase this config-heavy that is the likeliest silent
bug there is.

### `lune run tools/call-check`

Loads all 16 services and resolves every `self.context.X:method(...)` call site
against the real service. **313 calls, all name a real method**, none passing
more arguments than the method declares.

Services reach each other through a dynamic registry, so a typo there is a
runtime `attempt to call a nil value` that only fires when that exact line runs
— possibly minutes into an expedition.

### `selene src`

0 errors, 0 warnings, 0 parse errors. Deliberately-unused parameters are
underscore-prefixed (`_biome`, `_rng`), which is how Selene and Luau convention
mark "intentional" — that keeps the lint at zero so a *real* unused variable is
visible when it appears.

### `stylua --check src`

Clean. `stylua.toml` targets Unix line endings, and `.gitattributes` enforces LF
in the repository, so Git and StyLua do not fight on a Windows checkout.

### Rebuilding the place file

```bash
rojo build -o build/BelowZero.rbxlx
```

Useful as a check in its own right: Rojo validates every `$properties` name and
type against its reflection database, so a typo in `default.project.json` fails
here rather than silently doing nothing in Studio. (`build/` is gitignored.)

---

## 8. If something goes wrong

| Symptom | Likely cause |
|---|---|
| Nothing happens, no `[BZ/...]` output | `init.server.lua` did not sync; `BelowZeroServer` is a Folder instead of a Script |
| `[BZ/Net] remote folder never appeared` on the client | The server bootstrap errored. Scroll up for the first `FAULT` line |
| Characters never spawn | `Players.CharacterAutoLoads` is false by design; if `ColonyService` failed to claim a plot it will not call `LoadCharacter`. Look for `no free colony plot` |
| Test failures mentioning a seed | Reproduce it directly: `CaveLayout.generate({ seed = <n>, ... })` and `CaveLayout.render(layout)` |
| Shop products all say "Purchases are off in this build" | Correct. `GameConfig.Monetization.Enabled` is `false` and every product id is `0` |
| Everything is silent | Correct. No sound asset IDs ship with this project; see the `[BZ/Audio]` startup line |
