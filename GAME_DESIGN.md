# GAME DESIGN — BELOW ZERO: THE LAST COLONY

This document records what the mechanics are, what the numbers are, and why they
are those numbers. Where a decision was a judgement call between two defensible
options, the reasoning is written down so it can be argued with later.

Every number here lives in `src/shared/Config/`. Nothing in this document is
hard-coded anywhere in the gameplay code.

---

## 1. The central tension

> Your civilisation is permanent. Your expeditions are not.

Everything is arranged around one question the player asks every few minutes:
**do I push deeper, or do I go home now?**

Three systems create that question and nothing else is allowed to dilute it:

1. **A clock.** Preparation, day, dusk, night. Fixed length, visible, announced.
2. **A rearranging maze.** At night the tunnels change. The route you memorised
   on the way in may not exist on the way out.
3. **Asymmetric loss.** What you carry out is permanent. What you are still
   holding when the run ends is mostly gone.

If any one of those three is weak, the game becomes a grind. The maze shift is
the one most likely to be weakened accidentally — by being too gentle, too
unfair, or too buggy to trust — which is why it has the most test coverage in the
project.

---

## 2. The clock

`DifficultyConfig.Modes[*].phaseDurations`

| Phase | Easy | **Medium** | Hard | What changes |
|---|---|---|---|---|
| Preparation | 2:30 | **3:00** | 2:00 | Monsters at ~55% awareness, no shifts |
| Day | 12:00 | **10:00** | 8:00 | Monsters at ~55% awareness, good visibility |
| Dusk | 4:00 | **3:00** | 2:00 | Warnings fire, lighting drops, no geometry changes yet |
| Night | 7:00 | **6:00** | 7:00 | Shifts begin, Stalker can appear, visibility halves |
| **Total** | 25:30 | **22:00** | 19:00 | |

Medium matches the brief's stated 3 / 10 / 3 / 6 exactly, and
`ConfigIntegrity.spec` pins those four numbers so they cannot drift silently.

**Dusk changes no geometry.** This is the most important scheduling decision in
the game. Dusk is pure warning: the horn, the full-screen message, the dimming
light. The first shift lands precisely as night falls. That gives a player a
whole phase — two to four minutes — to act on the warning. Rearranging during
dusk would make the warning cosmetic.

**Hard has a *longer* night than Medium** (7:00 vs 6:00) with a much shorter day.
Hard is not "the same run, faster"; it is a run where you spend proportionally
more of your time in the dangerous part.

### Shift cadence

| | Easy | Medium | Hard |
|---|---|---|---|
| Rooms rearranged per shift | 2 | 3 | 5 |
| Seconds between shifts | 150 | 120 | 80 |
| Shifts in a night | ~3 | ~3 | ~5 |
| Extra loop connections | 3 | 2 | 1 |

Loop connections are the counterweight. Easy rearranges less *and* gives you more
alternative routes; Hard rearranges more *and* gives you fewer. That single pair
of numbers does more for the difficulty curve than any monster stat.

---

## 3. The maze shift

`CaveLayout.shift` — and `tests/CaveLayout.spec.lua`, which is the real
specification.

### Contract

The brief lists requirements for the shift. Each is implemented as an invariant
and covered by a test that sweeps many seeds:

| Requirement | How it is met | Test |
|---|---|---|
| Warn players before rearrangement | Warnings at 30s and 10s, plus a dusk announcement; full-screen red overlay | manual (step 28) |
| Never silently teleport players into invalid geometry | Nothing teleports. Only doorways change | by construction |
| Do not delete rooms occupied by players | Occupied cells are excluded from candidates, and **floors are never rebuilt for any cell** | "a shift never adds or removes a room" |
| Preserve important objectives | Vault, entrance and extraction rooms are frozen, as are all edges touching them | "objective and extraction rooms keep their kind" |
| Validate reachable routes after shifting | `validate()` runs after every shift; a failure rolls the whole shift back | "a shift keeps the layout valid" |
| Introduce alternative paths for trapped players | Any occupied room left with one doorway gains a second where the grid allows | "an occupied room gets a second doorway" |
| Run authoritatively on the server | Layout lives in `CaveService`; the client is told what changed | by construction |

### How a shift actually works

1. Snapshot every cell's doors and kind (cheap — nothing else changes).
2. Pick `shiftCount` candidate cells: not objective-critical, not occupied.
3. For each, reroll every editable edge (both sides rewireable) on a coin flip,
   then guarantee at least one stays open.
4. **Repair pass.** Compute connected components; while there is more than one,
   open a doorway across the cut. This always terminates: the cell set is
   connected under grid adjacency by construction, so any partition has at least
   one adjacent pair across it.
5. **Trapped-room pass.** Every occupied room with fewer than two doorways gains
   one, if it has two or more neighbours.
6. Re-fit room kinds to their new door signatures.
7. Validate. **If validation fails, restore the snapshot.** A static cave is
   much better than a broken one.

Geometry then rebuilds only the changed cells' walls, ceiling and props. The
floor is never touched, which is the mechanical reason a player standing in a
shifting room cannot fall.

Resource nodes are also never touched. If a shift re-rolled nodes, standing in
one room through two shifts would be an infinite resource exploit.

### Soft vs hard constraints

A connectivity repair can leave a frozen room (the vault, say) with three
doorways when its kind "normally" has one or two. That is recorded by
`validate()` as a **warning**, not an error, and logged rather than rolled back.
Keeping the party connected to an exit matters more than a room's cosmetic door
count. The tests check door-rule conformance strictly for filler rooms and
leniently for protected ones, for exactly this reason.

---

## 4. Cave generation

`CaveLayout.generate` — pure, deterministic, seeded.

**Growth, not carving.** Starting from a perimeter cell, the generator
repeatedly picks an active cell and extends into a free neighbour. It picks the
*most recently added* cell 72% of the time and a random active cell the rest.
That mix produces winding tunnels with occasional side branches — a cave, rather
than the uniform lattice a pure maze algorithm gives you.

**Kinds are assigned after topology, not before.** A room's kind must fit its
door signature (a corridor cannot have three doors), so the generator builds the
shape first and then asks `RoomRules.kindsFor(doors)` what will fit. A test
proves every one of the fifteen non-empty door signatures has at least one
eligible filler kind, which is what keeps the generator off its fallback branch.

**Two exits, always.** The entrance is itself an extraction point — you leave the
way you came in. A secondary `ExtractionChamber` is placed far away, in a
different part of the map. This is structural, not generous: with two exits in
different regions, no single shift can corner the party.

**Objectives are placed by depth.** The vault takes the deepest cell with two or
fewer doors (a quiet corner at the end of a journey). Puzzle rooms take mid-depth
cells — far enough in to be a detour worth considering on a timer, close enough
out to be worth taking. A test asserts the vault is at least three rooms deep.

**Room counts** are 10 / 13 / 15 for Easy / Medium / Hard, on a 7×7 grid. The
brief asked for 10–15 and explicitly asked for reliability over scale. A 7×7 grid
gives the growth algorithm room to wander without ever exhausting itself.

---

## 5. Resources and the economy

### Why weight for the bag and units for storage

The expedition bag is measured in **weight**; colony storage in **units**.

That means a crystal (weight 3) costs three times the bag room of stone
(weight 1), so the interesting decision — "I have found crystal, what do I drop?"
— exists underground, where it matters. Storage does not need that friction; it
just needs a cap that upgrades relieve.

### Capacity

| | Value | Reasoning |
|---|---|---|
| Base bag | 180 weight | ~3 full mining chambers. Enough that a short run is worthwhile, tight enough that a long one forces choices |
| Base storage | 200 units | Plus 400 from a level 1 Town Hall = 600 |
| Guardian carry bonus | +20 | The slow tank carries more |
| Cook carry bonus | +25 | Specified; role not implemented |

### Resources

Eight gatherable, plus the Ancient Key.

| Resource | Tier | Weight | Where | Used for |
|---|---|---|---|---|
| Stone | 0 | 1 | everywhere | construction, repairs |
| Fungal Fiber | 0 | 1 | shallow | construction, bandages |
| Cave Mushroom | 0 | 1 | shallow | food, farm stock |
| Glowroot | 0 | 1 | resource + puzzle rooms | medicine |
| Coal | 1 | 1 | mining chambers | fuel, smelting |
| Iron Ore | 1 | 2 | mining + Iron Depths | tools, frames |
| Resonant Crystal | 2 | 3 | Crystal Reach, vaults | research, power |
| Ancient Fragment | 0 | 2 | ruins (one-shot) | research |
| **Ancient Key** | 0 | **0** | vault / revealed by puzzles | the First Gate |

Ancient Keys weigh nothing and are flagged `protectedOnDeath`. Both are
deliberate: a key should never be the thing you drop to fit one more stone in,
and losing a key to a bad run would make the escape objective feel punishing
rather than suspenseful. A test asserts exactly one resource carries that flag
and that it is the key.

### Fractional production

NPC jobs produce fractional amounts per tick (a farmer yields `2.0 × efficiency`
mushrooms, a researcher consumes `0.05` relics). Flooring those would make slow
consumers free and destroy ~28% of a farmer's output every tick.

Instead the fractional part becomes a probability: 1.4 mushrooms means 1 most
ticks and 2 sometimes. Expected value is exact, storage stays integral, and no
accumulator has to be persisted. `NPCService.quantise` and `NodeService.quantise`
are the same three lines.

---

## 6. Colony

### Why plots

The brief asks for a persistent colony per player that friends can visit, with
permissions that stop a visitor stealing or demolishing. Three options:

| Option | Cost |
|---|---|
| One shared colony per server | Not "your" colony; griefing is a permissions nightmare |
| Per-player instance, visit by teleport | Handover complexity, loading screens, hard to test |
| **Nine owned plots in one cavern** | Visiting is a walk; ownership is one integer comparison |

The third was chosen. `ColonyService.canManage` is the single gate, and every
spend reads the **acting** player's own profile — there is no code path anywhere
that takes a target user id for a resource operation, so leadership or visiting
cannot be escalated into theft.

Nine plots at 352 studs with 416 spacing, in a 3×3 grid. Nine exceeds the
eight-player design cap, and a test asserts that.

### Buildings

| Building | Footprint | Levels | Key effect |
|---|---|---|---|
| Town Hall | 5×5 | 4 | Colony level, storage, population, unlocks |
| Shelter | 3×3 | 3 | +2/4/6 population |
| Fungal Farm | 4×4 | 3 | Food, farmer and cook slots, cooking station |
| Workshop | 4×3 | 3 | Tool crafting, builder and miner slots |
| Infirmary | 4×3 | 3 | Healing at home, medic slots, **+5/10/15s revive window** |

The Infirmary's revive-window bonus is the clearest expression of the game's
loop: a colony investment that pays off inside the caves. Building it makes dying
less final, which makes the next run braver, which makes a bigger colony.

Five more (Kitchen, Barracks, Research Laboratory, Watchtower, Generator) are
fully specified with costs, effects and prerequisites, and blocked behind
`MvpContentOnly`.

**Effects are declarative.** `BuildingService.effectsFor` sums every placement's
effects into one table of named keys. No system reads a building id. Adding a
building that grants population or storage needs no change outside config.

**Condition scales contribution.** A damaged building contributes proportionally
less, floored at 35%. Condition matters without ever switching a building off,
which would be a punishment spiral.

**The Town Hall cannot be demolished.** It is the colony's anchor and the thing
that unlocks everything else; removing it would strand the player.

### Colonists

Production is a **simulation tick**, not AI. One pass of arithmetic over the
roster every 10 seconds. A 24-worker colony costs the same CPU as a 3-worker one.

Visible colonists are a presentation layer: at most 10 bodies per plot, moved by
one shared 10 Hz loop with simple interpolation, skipped entirely when nobody is
within 220 studs. No Humanoids, no pathfinding — the plot is a flat open pad, so
there is nothing to path around.

Skill runs 1–10 with a deliberately shallow curve (`0.7 + (skill-1) × 0.13`): a
fresh colonist is immediately useful at 70%, a veteran is worth 1.87×. Steeper
would make early colonists feel worthless.

### Offline production

- Enabled, capped at **8 hours**, scaled to **50% efficiency**.
- Condition decays at 1.5/hour but is **floored at 55**.

The cap and the efficiency penalty together mean logging off is never the optimal
strategy **for resources**. The floor means a colony can never be lost to
absence, which the brief requires explicitly. Starvation costs condition, never
colonists — losing a worker to a missed login is the kind of punishment that
makes people quit.

For **skill** it is not true, and the code is what it is rather than what this
paragraph used to claim: `skillGain` is granted flat per tick and is not touched
by the 50% scale, so half an hour of absence takes a colonist from 1 to the
ceiling. See open question 5.

---

## 7. Survival

| Stat | Value | Reasoning |
|---|---|---|
| Hunger drain | 0.09/s (Medium) | A full bar lasts ~18 minutes, slightly longer than a Medium run. Hunger is a **supply decision made before the run**, not a chore during it |
| Stamina | 100–135 by role | Sprint 13/s, mine 6/swing, attack 9/swing |
| Sprint multiplier | 1.5× | And it makes noise the Stalker can hear |
| Fall damage | above 22 studs, 2.6/stud | Telegraphed by height, and clamped like everything else |
| Revive window | 75 / 45 / 25s | Plus up to +15s from the Infirmary |
| Revive channel | 4s, ÷ role multiplier | A Medic revives in ~1.8s, a Guardian in ~4.4s |

### Nothing kills a standing player outright

`SurvivalService.applyDamage` clamps every damage event so health cannot drop
below 1. The only route from downed to dead is the revive timer expiring, which
is visible and counting down on screen. A `HealthChanged` handler catches
anything that bypasses the clamp and converts it into the downed state.

This is the brief's "avoid unpredictable instant deaths", implemented as a
property of the one function that can reduce health rather than as a habit.

### Players always know why they died

Every damage event carries a source string; the last six are kept per player. The
death screen reads "Killed by Cave Crawler (36), starvation (8)" rather than "you
died".

### A downed player cannot be damaged further

Monsters also lose interest in downed targets. Standing over a downed teammate
denying the revive is not tension, it is a dead end.

---

## 8. Roles

Implemented: **Runner, Medic, Guardian.** Specified and wired, returning honest
`NotImplemented`: **Cook, Engineer, Researcher.**

| | Speed | HP | Damage | Taken | Revive | Carry |
|---|---|---|---|---|---|---|
| Runner | 19 | 85 | 0.85× | 1.10× | 1.0× | +0 |
| Medic | 15 | 100 | 0.80× | 1.00× | **2.2×** | +10 |
| Guardian | 13 | 150 | **1.45×** | **0.75×** | 0.9× | +20 |

### Abilities

- **Runner — Pathfinder** (45s): lights a route from here to the nearest exit.
  The *server* computes it, so a modified client cannot ask for a path it has not
  earned. The Cartographer passive shares it with the whole party, which is what
  makes the Runner worth bringing rather than just fast.
- **Medic — Field Stabilization** (60s, 32 studs): **freezes** downed timers
  nearby and heals those standing. The downed player's overlay says so, turning a
  confusing stopped number into a visible rescue in progress.
- **Guardian — Last Stand** (70s, 28 studs): 55% damage reduction for the
  Guardian and nearby allies. Queried per damage event rather than applied as a
  stat, so it layers correctly with role multipliers.

### No role is mandatory

The brief requires this, especially solo. It holds because:

- Every expedition has **two exits**, so the Runner's route-finding is a
  convenience, not a requirement.
- The **free rescue** covers the Medic's absence.
- The Stalker **cannot be fought at all**, so the Guardian is not a gate.
- Solo drops monster *count* to 50% while keeping per-monster health at 90%, so
  a lone player is never surrounded and fights still read the same.

### Mastery

Earned per expedition, not per XP point: +1 for finishing in a role, +1 more for
extracting. Capped at 20. That makes the progression legible — "two more runs as
Medic" — and stops a long grinding session trivialising the unlock tiers.

`RoleConfig.resolve` folds unlocked upgrades into a flat stat table and clamps
the result. A test runs every role at mastery 999 and asserts nothing escapes its
clamp.

### The Engineer's beacon, and why it is capped

The Emergency Beacon creates a temporary extraction point. An on-demand exit
would defeat the maze shift entirely — the game's defining mechanic. So it is
capped at one use per expedition, takes a 6-second channel, and **cannot be
placed during Night**. Those constraints are in config today, before the ability
is implemented, so the balancing decision is recorded rather than deferred.

---

## 9. Monsters

The brief asks that different enemies require different strategies, and rules out
"monsters that simply have huge health pools". Two monsters, one state machine,
genuinely different problems:

| | Cave Crawler | The Stalker |
|---|---|---|
| Health | 55 | 400, **and unkillable** |
| Sight | 48 | **16** |
| Hearing | 26 | **110** |
| Damage | 12 | 34 |
| Wind-up | 0.55s | 0.80s |
| Staggerable | yes | no |
| Answer | **fight it** | **avoid it** |

The Crawler is a fight: low health, a readable wind-up, staggerable by the
Guardian's Heavy Swing, and the damage only lands if you are *still* in range when
it resolves — so backing off genuinely works.

The Stalker is a problem to solve. Hitting it does not reduce its health, it
reduces its **interest**; a solid hit buys you a retreat, it does not win a fight.
It hunts noise (sprinting, mining, combat, getting hurt) with distance falloff,
and it breaks off when:

- it is standing somewhere lit above 0.55, or
- it finds two or more living players together.

Extraction rooms are lit at 0.70–0.85, which is **above** that threshold — so the
exits are genuinely safe ground and the Stalker cannot camp them. A test asserts
that relationship holds, because it is load-bearing and a lighting tweak could
silently break it.

The Stalker appears only at dusk or night, only after the first maze shift, one
at a time, and always in the room furthest from every player by a multi-source
BFS. It never materialises in someone's face.

`ConfigIntegrity.spec` encodes the "different strategies" requirement directly:
it asserts the Crawler is killable, the Stalker is not, the Stalker hears more
than twice as far, and the Stalker sees less.

### Performance

Monster count is the easiest way to wreck a Roblox server, so ticking is
budgeted:

| Distance to nearest player | Behaviour |
|---|---|
| ≤ 150 studs | tick every 0.15s |
| 150–420 studs | tick every 1.2s |
| > 420 studs | **not ticked at all**, Humanoid parked |

One `Heartbeat` connection drives every monster on the server. Pathfinding is
used *only* when the target is out of line of sight; in sight the monster steers
directly, which costs less and reads better in a tight corridor. `ComputeAsync`
runs off the AI tick, and the monster keeps moving toward its last waypoint while
it thinks rather than stopping dead.

---

## 10. Difficulty

Difficulty is pure data. **No system branches on the difficulty id** — every
system reads a named multiplier from the resolved table. A new difficulty is a
config-only change.

`DifficultyConfig.resolve(id, partySize)` folds party scaling in once, at session
start.

| Party size | Monster count | Monster health | Objectives | Nodes |
|---|---|---|---|---|
| 1 | 0.50× | 0.90× | 1.0× | 0.8× |
| 2 | 0.70× | 0.95× | 1.0× | 0.9× |
| 3 | 0.88× | 1.00× | 1.0× | 1.0× |
| 4 | 1.00× | 1.00× | 1.0× | 1.1× |
| 5–8 | 1.15–1.60× | 1.05–1.20× | 1.2–1.4× | 1.2–1.5× |

Five through eight exist for when the cap rises.

### Loss rules, stated to the player

| | Keep on death | Keep on timeout | Reward |
|---|---|---|---|
| Easy | 75% | 50% | 0.85× |
| Medium | 40% | 25% | 1.00× |
| Hard | 15% | 10% | 1.50× |

These are printed on the difficulty cards in the expedition lobby, before the
player commits. A player should never be surprised by a loss rule. Rounding is in
the player's favour (`ceil`), so a single item is never destroyed by a rounding
rule.

---

## 11. The escape

Keys are found in the caves. Keys open stages of the First Gate.

| Stage | Keys | State | Unlocks |
|---|---|---|---|
| The First Seal | 1 | **implemented** | Deeper expeditions, Iron Depths |
| The Second Seal | 3 | designed | Crystal Reach, research tier 2 |
| The Last Door | 6 | designed | Chapter 2: the route to the surface |

**Escaping never resets the colony.** The brief is explicit and so is the code:
`ObjectiveService.unlockGate` touches `profile.escape` and nothing else. The
dialog tells the player this before they spend a key.

Stages 2 and 3 return an honest `NotImplemented` refusal naming the stage, rather
than unlocking and promising content that does not exist.

Keys can be spent from the bag or from the colony bank, bag first. A key carried
out last run should not have to be carried back in.

---

## 12. Multiplayer

**Solo is a party of one.** `PartyService.ensureParty` means there is exactly one
code path for one player and for four. No separate solo mode to drift.

### What a leader can and cannot do

Can: set the difficulty, mark a location, start the expedition. That is the
complete list.

Cannot: touch anyone's storage, colony, inventory, bag, role or progression. This
is not enforced by checking "is leader" in those systems; it is enforced by those
systems only ever reading the acting player's own profile.

**There is no shared loot pool.** Harvests and drops go straight into the
harvester's or killer's own bag. Nothing to race for, nothing to steal, and
rewards are allocated per player at extraction. Changing the difficulty clears
everyone's readiness — they agreed to the old one.

---

## 13. Death, rescue, and never being stuck

1. Health reaches 1 → **downed**. Visible countdown, movement locked.
2. Teammates may revive (server-channelled; walking away cancels it).
3. Timer expires → **dead**, spectating, cause of death stated.
4. **One free rescue per expedition**, always available: back at the tunnel mouth
   with your bag intact.
5. No rescue left → you return to the colony when the run ends, with the
   difficulty's recovery fraction and **all** your keys.

There is no state from which the only option is to stop playing. A disconnect
mid-run is treated as a death for loot purposes and does not block the party.

---

## 14. Monetization

| Rule | How it is enforced |
|---|---|
| No gambling | There are no crates, rolls, odds or randomised rewards in `ShopConfig`. None |
| No pay-to-win | Exactly one product declares a gameplay effect. A test asserts that, and that it is the rescue |
| The rescue is bounded | Capped per expedition, excluded from ranked, and a **free** rescue always comes first |
| Nothing is simulated | `ProcessReceipt` is the only grant path. No debug grant exists |
| Fulfilment is idempotent | Receipts are recorded in the profile; a known `PurchaseId` is acknowledged without granting again |
| Purchases survive a crash | The profile is **saved before** `PurchaseGranted` is returned. If the save fails, the grant is rolled back and the receipt is retried |
| Read-only sessions defer | A session that cannot persist returns `NotProcessedYet` rather than losing the purchase |
| Cosmetic lanterns stay cosmetic | Only `preview.light` (colour) is read. Range and brightness are never taken from a cosmetic |

`GameConfig.Monetization.Enabled` is `false` and every `productId` is `0`. The
shop renders the catalogue with a plain notice saying nothing can be purchased
and nothing is required to play — which is more honest than hiding it, and means
the flow is reviewable before it is live.

`ConfigIntegrity.spec` contains a test designed to **fail** the day a real product
id is pasted in, as a prompt to verify the purchase flow before shipping it.

---

## 15. Security

`src/shared/Util/Net.lua` is the only client/server boundary. Three remotes carry
everything, routed by name, so rate limiting and payload sanitising are
properties of the transport rather than something each service remembers.

| Protection | Detail |
|---|---|
| Payload sanitising | Max depth 5, max 64 keys per table, max 256-char strings, finite numbers only. Functions, userdata and Instances rejected |
| Rate limiting | Token bucket per player per route. Hot routes have explicit budgets (harvest 6/s, attack 6/s, ability 3/2s, expedition start 2/10s) |
| Identity | Handlers receive the `Player` from the engine. Client-claimed identity is ignored |
| Error isolation | A handler that errors returns a structured failure. An error across a RemoteFunction leaves the client's invoke hanging |
| Range | Every interaction re-measures distance **on the server**, with a 4-stud latency tolerance |
| Atomic spending | `Inventory.pay` is all-or-nothing and is the single chokepoint for every build, upgrade, repair and craft |
| One-shot pickups | A key is marked taken **before** the grant, so two simultaneous requests cannot both succeed |
| Session locking | A profile records the owning JobId. A second server waits, retries, then loads **read-only** rather than stealing |
| Write guard | Every save re-checks the lock inside `UpdateAsync` and aborts if another server took over |
| Seeds | Client-supplied seeds are accepted only while `Debug` is true, so a player cannot scout a layout and replay it |

Suspicious behaviour (40 consecutive rate-limited calls) is **logged, never
auto-punished**. A legitimate player on a bad connection can trip a rate limit,
and banning on that signal alone would be wrong.

---

## 16. UI

One `ScreenGui`, five layers (HUD, Panel, Modal, Toast, Critical), every colour
and size from `Theme.lua`. No component reads a raw value.

**One panel open at a time, on purpose.** A survival HUD with four floating
windows is unreadable, and the brief asks explicitly for an uncluttered screen.
Navigation hides itself entirely during an expedition.

**Three tiers of message**, because they are not the same thing:

- **Toast** (bottom-right, auto-dismissing): routine feedback.
- **Alert** (centre banner): something that changed the run.
- **Warning** (full-screen, red, counting down): the maze shift, and only that.

The shift warning is the loudest element in the game. It has to be: it is the one
thing that can kill you by surprise.

**Touch is a real control scheme**, not a scaled-down desktop HUD: 62px action
buttons in the thumb arc, sprint as a toggle rather than a hold, tap-a-teammate's
row to revive, and every interactive element at least 44px. World interaction
goes through `ProximityPrompt`, which gives keyboard, gamepad and touch for free
and only draws when the player is close enough to care.

---

## 17. Open balance questions

Honest list of things that need play-testing to settle, with the reasoning for
the current value:

1. **Is 180 bag weight right?** Chosen as ~3 mining chambers. If players always
   leave full, it is too small; if they never fill it, the "push or go home"
   question never fires.
2. **Is a 3-room Medium shift enough to feel dangerous?** It is 23% of a 13-room
   cave. Might need to be 4.
3. **Is the Stalker's 0.55 light threshold too generous?** It currently makes
   both extraction rooms and the vault effectively safe. The vault being safe may
   be too kind.
4. **Does the Guardian's 150 HP and 0.75× mitigation make them mandatory on
   Hard?** The design says no role should be required; Hard's 1.5× monster damage
   may quietly contradict that.
5. **Is 50% offline efficiency too high?** If players optimise by logging off, it
   is. And for colonist **skill** the answer is already yes, because the 50%
   does not apply to it: `skillGain` is flat per tick, so an absence trains a
   worker exactly as fast as being there would and the 30-minute curve from
   skill 1 to skill 10 is skipped by one overnight. Scaling `skillGain` by
   `efficiencyScale` is a one-line change in `NPCService:simulate`; it is a
   progression decision rather than a correctness fix, so it has deliberately
   not been made. `Offline.spec` asserts the invariant that holds either way —
   skill stops at the ceiling.
6. **Is the 10-second production tick too coarse?** It makes the resource strip
   jump rather than tick.
