# BELOW ZERO: THE LAST COLONY

A cooperative underground survival and civilisation-building game for Roblox.

Your colony is permanent. The caves are not. Every expedition is a bet that you
can get back before the tunnels rearrange themselves around you.

> **Status: playable vertical slice, never executed.** Every system described
> below exists as code and has been structurally checked. None of it has been
> run, because there is no Roblox Studio or Luau runtime on the machine it was
> written on. See [SETUP.md](SETUP.md) to get it running, and
> [DEVELOPMENT_STATUS.md](DEVELOPMENT_STATUS.md) for an honest feature-by-feature
> breakdown of what is finished, partial and absent.

---

## The loop

1. You arrive in a dark cavern holding one Town Hall, three colonists and
   enough material for a shelter.
2. You build, assign jobs, and your colonists produce resources whether you are
   watching or not.
3. You pick a difficulty, a role, and some supplies, and walk into the tunnel
   mouth.
4. You mine, fight, explore and look for an Ancient Key.
5. A clock runs: preparation, day, dusk, night. At dusk you are warned. At night
   the caves start rearranging.
6. Everything you carry out becomes permanent. Everything you are still holding
   when the run ends is mostly lost — except the keys.
7. You spend what you brought home on a bigger colony, which makes the next run
   survivable.

The maze shift is the centre of the design. It is the reason a run has a
deadline, the reason the Runner exists, and the thing every other system is
arranged around.

---

## What is in the box

| Area | Summary |
|---|---|
| **Colony** | Nine owned plots in one shared cavern. Friends walk over to visit; visitors are read-only. Buildings persist, upgrade visibly, and feed a declarative effects table. |
| **Construction** | Grid placement with a live ghost, rotation, overlap and bounds validation, upgrades, repairs and a 50% demolition refund. Five buildings implemented, five more specified. |
| **Colonists** | Assignable jobs driving a pure arithmetic production tick — a 24-worker colony costs the same CPU as a 3-worker one. Up to ten visible bodies per plot, moved by one shared loop. Offline production, capped and floored. |
| **Caves** | Deterministic seeded generation over a grid, 10–15 rooms, standardised doorways, biome theming, and a validated night-time rearrangement. |
| **Maze shift** | Warned twice, never deletes an occupied room, freezes objective rooms, re-validates connectivity and hands trapped rooms a second exit. Rolls back rather than shipping a broken cave. |
| **Survival** | Health, stamina, hunger, tool durability, a downed state with a visible timer, server-channelled reviving, spectating and a free rescue. Nothing can kill a standing player outright. |
| **Roles** | Runner, Medic and Guardian implemented end to end with passives, actives and a mastery ladder. Cook, Engineer and Researcher fully specified and wired, returning honest `NotImplemented` refusals. |
| **Monsters** | One shared state machine. The Cave Crawler is a fight with a readable wind-up; the Stalker cannot be killed, hunts by sound, and breaks off in bright light or against a group. Distance-based AI level of detail. |
| **Objectives** | Ancient keys, pillar puzzles with a seeded solution order, and the First Gate with a staged escape ladder. Escaping unlocks content; it never resets your colony. |
| **Multiplayer** | Solo is a party of one, so there is one code path. Private codes, public listing, readiness, leadership, map marks. Per-player loot, so there is nothing to race for. |
| **UI** | One ScreenGui, layered, themed from a single token file. Main menu, colony HUD, expedition HUD, seven panels, toasts, alerts and a full-screen shift warning. Keyboard, mouse, gamepad and touch. |
| **Persistence** | Session-locked profiles, retries with backoff, versioned migration, idempotent purchase receipts, and a read-only fallback that refuses to overwrite a profile another server owns. |
| **Monetization** | Cosmetics only, bar one capped rescue. No gambling, no pay-to-win. Switched hard off, every product id zero, and a test that fails if that changes. |
| **Tests** | 5 spec files, 129 tests, self-contained harness, run automatically in Studio. The cave generator and shift are swept across hundreds of seeds. |

---

## Layout

```
src/
  shared/              ReplicatedStorage.BelowZero — read by both sides
    Config/            all tunable data; no behaviour
    Data/              profile template + forward-only migrations
    Lib/               pure logic: CaveLayout, Inventory, Rng, RoomRules, PlotGrid
    Util/              Net, PartFactory, Signal, Logger, TableUtil
    Enums.lua          persisted string ids
    Routes.lua         every network route name, in one place

  server/              ServerScriptService.BelowZeroServer
    init.server.lua    two-phase bootstrap (init, then start)
    Services/          16 services, each owning one concern
    World/             procedural geometry: colony, buildings, rooms, caves
    AI/                MonsterBase — one state machine for every monster

  client/              StarterPlayerScripts.BelowZeroClient
    init.client.lua    wiring only; no gameplay logic
    Store.lua          the client's read model of server state
    UI/                UIKit, Shell, HUDs, panels
    Controllers/       input, interaction, placement, audio, atmosphere, routes

  tests/               TestRunner + specs; runs in Studio on Play
```

Two architectural choices do most of the work:

**`src/shared/Lib` is pure.** `CaveLayout` and `Inventory` have no Instances, no
services and no Roblox datatypes (`PlotGrid` is the exception — it is geometry).
That is why the maze shift can be swept across hundreds of seeds in a test
instead of being play-tested by hope.

**The client proposes, the server decides.** Every inbound message goes through
one router (`Util/Net.lua`) that rate-limits per route per player and sanitises
payload depth, width and string length before a handler sees it. No gameplay code
reads a quantity, a cost or a damage number out of a payload.

---

## Getting it running

See **[SETUP.md](SETUP.md)**. The short version:

```bash
rokit install      # or: cargo install rojo
rojo plugin install
rojo serve
```

Then connect from Studio's Rojo plugin and press Play. The test suite runs
automatically and prints the generated cave as ASCII art.

---

## Documents

- **[SETUP.md](SETUP.md)** — install, sync, and a 59-step testing checklist
- **[GAME_DESIGN.md](GAME_DESIGN.md)** — mechanics, balance numbers and the
  reasoning behind them
- **[DEVELOPMENT_STATUS.md](DEVELOPMENT_STATUS.md)** — what works, what is
  partial, what is missing, and what to build next

---

## Deliberate limitations

These are choices, not oversights. Each is argued in `GAME_DESIGN.md`.

- **One Place, not two.** Colony and caves coexist at different coordinates and
  the player is moved between them. A `TransportMode = "teleport"` path exists
  and is guarded, but refuses to run rather than half-working, because there is
  no published expedition Place and inventing a `PlaceId` would be worse than
  refusing.
- **Plots, not instances.** Each player owns one of nine plots in a shared
  cavern. Visiting is a walk. Permissions are a single integer comparison.
- **No assets.** Every structure, monster and prop is built from Roblox
  primitives at runtime. No model, image, sound or animation ID appears anywhere,
  invented or otherwise. The audio system is complete and wired, and completely
  silent.
- **Melee only.** One validated attack path is easier to keep honest than
  several, and both MVP monsters are designed around close quarters.
- **Four players, not eight.** The design targets eight; the cap is four and the
  scaling tables already cover five through eight.
