# TWW Prospector Ultimate (v3.0.0)

Autonomous mining assistant for the Roblox game **The Wild West (TWW)**, delivered as one self-contained
Luau file for client executors (target: Xeno 1.2.1).

| File | Purpose |
|---|---|
| `TWW_Prospector_Ultimate.lua` | The whole program. Execute this file. |
| `tests/mock_roblox.lua` | Offline Roblox mock (instances, signals, virtual-time scheduler, pathfinding, humanoid movement). |
| `tests/run_tests.lua` | 24 offline tests that load the **real** script file into the mock and drive it. |

> **Status:** the script has **not** been run inside Roblox or TWW. It was verified offline (syntax, global
> usage, 24 behavioural tests against a mock). Everything game-specific in the
> [verified/unverified table](#5-verified-vs-unverified-game-specific-features) needs a live test.

---

## 1. Quick start

1. Join a TWW server and execute `TWW_Prospector_Ultimate.lua` in your executor.
2. The window appears on the left of the screen. `RightControl` shows or hides it (configurable).
3. **Ore Management**: choose ore types and set priorities.
4. Press **START** (Dashboard or sidebar). You never record routes or place waypoints.
5. If something is not detected, open **Settings → Diagnostics → RUN SELF-TESTS** and read the **Logs** tab.

Re-executing the file at any time first shuts down the running copy completely, including v2.0.

---

## 2. Architecture

A single chunk organised as Lua-table modules (search the file for `==== MODULE:`). Modules talk through
plain function calls. There is one automation thread, guarded by a generation counter.

```
Bootstrap/Util ─ Session (resource registry) ─ Token (cancellation) ─ Log ─ Config ─ Stats
        │
        ├─ Char (character/respawn)  Tools (pickaxe)  Blacklist (back-off)
        ├─ Ores (event-driven deposit registry + remembered sites)
        ├─ Nav (PathfindingService, progressive legs, stuck recovery)  Visual (pooled route dots, Highlight)
        ├─ Probe + Miner (approach, aim, interact, verify progress)
        ├─ Inventory + Wallet (discovered sources, full detection, sale confirmation)
        ├─ Sellers (prompt/store discovery, travel, prompt interaction, verification)
        ├─ Targeting (scoring + path validation)  Auto (finite-state machine)
        └─ UI (7 tabs)  SelfTest  Main (teardown → GUI → subsystems → loops)
```

### Key mechanisms

- **Session registry**: every connection, thread, owned Instance and cleanup step goes through
  `SESSION:connect/spawn/give/onCleanup`. `SESSION:destroy()` disconnects all of them, cancels the threads,
  destroys the instances and restores the camera. Handlers check `session.alive`, so a stale callback from an
  old build does nothing.
- **Cancellation**: every long operation takes a `Token` (parent chain plus optional deadline) and polls it.
  The automation run owns a root token, and each FSM step gets a child token with that state's timeout. Pause,
  stop, death and timeouts all cancel through tokens.
- **Ore discovery** is event-driven. The Mining root is resolved from configurable paths, then a bounded
  heuristic search (depth ≤ 3, ≤ 4000 nodes, only when the path fails). After that, `ChildAdded`/`ChildRemoved`
  watch every container and `OreRemaining.Changed` watches every deposit. Nothing scans Workspace per frame.
- **Remembered sites**: if a deposit disappears while you are far away (more than 150 studs) and still has
  ore, it was most likely streamed out (StreamingEnabled). Its position is remembered. When no loaded deposit
  is available, the bot travels to the nearest remembered site of a selected type.
- **Navigation**: one persistent `Path` per agent configuration, so `Path.Blocked` can be observed.
  Destinations further than `maxLegLength` get **progressive legs**: an intermediate goal toward the target is
  snapped to the ground by raycast, trying lateral offsets and shorter legs. Each waypoint has progress-based
  stuck detection with a recovery ladder (jump → strafe + jump → strafe the other way → give up and replan).
  Recalculation is rate-limited (`pathRecalcMinInterval`).
- **Targeting** scores each deposit as:

  ```
  score = estimatedCost / priorityWeight, then × (1 − min(remaining, 10) × 0.015)
          + 45 × pastFailures
          + 40 if |Δy| > 25
          + 120 if another player is within 10 studs
  ```

  `estimatedCost` is the real path length cached from an earlier computation. Without one, it is
  1.3 × straight-line distance + 2 × |Δy|. The best `validateCandidates` deposits (default 4) are then
  **path-validated**, and the cheapest real route wins. Unreachable deposits are blacklisted with exponential
  back-off (30 s, 60 s, … up to 600 s) and reconsidered automatically when the back-off expires.
- **Mining verification**: the `Probe` watches the target.
  - **Verified yield**: `OreRemaining` decreases, the inventory count rises, or ore items enter the Backpack.
  - **Activity** (resets the no-progress timer, but never counts as success): numeric values or attributes
    under the deposit change, deposit BillboardGui bars resize, a progress-like PlayerGui frame resizes, or the
    deposit gains descendants.

  A deposit counts as *depleted* only when `OreRemaining` reaches 0, or when the model disappears after
  observed progress. If nothing changes within `stallTimeout`, the attempt fails and the deposit is
  blacklisted. The same happens when there is activity but no verified yield for 3 × `stallTimeout`.
  A function call completing without error is never treated as success.

### Finite-state machine

The step timeout is enforced by the step token. On timeout the machine goes to RECOVERING. Handler errors are
caught (`pcall`) and lead to ERROR with exponential back-off. Five consecutive errors pause automation with the
last error shown.

| State | Entered when | Exits to | Timeout |
|---|---|---|---|
| IDLE | not running / Stop | SCANNING (Start) | – |
| SCANNING | start, after selling, after recovery | CHECKING_INVENTORY; stays (sleeps) while the Mining root is missing | 40 s |
| CHECKING_INVENTORY | after scanning or a mined deposit | FINDING_SELLER (needs unloading + auto-sell), PAUSED (needs unloading, auto-sell off), SELECTING_TARGET | 15 s |
| SELECTING_TARGET | need a target | PATHFINDING, EQUIPPING (already at the stand spot), PATHFINDING to a remembered site, SCANNING (nothing reachable, after a wait) | 60 s |
| PATHFINDING | target chosen, leg finished, replan | TRAVELING; SELECTING_TARGET (no route, target blacklisted) | 45 s |
| TRAVELING | leg planned | APPROACHING (arrived), PATHFINDING (next leg / blocked / timeout), RECOVERING (stuck, death), SELECTING_TARGET (target vanished, too many replans) | 240 s |
| APPROACHING | near the deposit | EQUIPPING (at stand range), PATHFINDING (direct approach blocked), SELECTING_TARGET (3 failed approaches) | 30 s |
| EQUIPPING | in range | MINING; PAUSED with auto-resume (no pickaxe) | 12 s |
| MINING | pickaxe equipped | CHECKING_INVENTORY (depleted / needs unloading), APPROACHING (drifted out of range), EQUIPPING (tool lost), SELECTING_TARGET (no verified progress / vanished), RECOVERING (death) | `mineTimeout` + 20 s |
| FINDING_SELLER | inventory needs unloading | TRAVELING_TO_SELLER; PAUSED with auto-resume (no seller after 3 tries) | 75 s |
| TRAVELING_TO_SELLER | seller chosen | SELLING; FINDING_SELLER (unreachable → seller blacklisted) | 600 s |
| SELLING | at the seller | SCANNING (verified, or unverified when allowed), FINDING_SELLER (failed), PAUSED (3 failures, or 3 unverifiable sales within 5 min) | 90 s |
| RECOVERING | stuck, death, timeouts | SCANNING or the interrupted state | 75 s |
| PAUSED | user pause or `Auto.halt(reason, check)` | SCANNING on resume; auto-resumes when `check()` passes (e.g. a pickaxe appears) | – |
| ERROR | a handler threw | RECOVERING after back-off; PAUSED after 5 consecutive errors | 40 s |

### GUI

Dark theme with configurable accent colours, tween transitions, a draggable header, a collapse button, a
hotkey and a `UIScale` that adapts to small viewports. Seven tabs:

- **Dashboard**: state, activity, pause reason, Start/Pause/Stop, and tiles for target, distance, runtime,
  deposits mined, attempts ok/failed, verified ore, inventory, seller and swings.
- **Ore Management**: discovered types (rebuilt when new types appear), select/deselect all, priority 1–5,
  available/known counters, nearest distance, rescan.
- **Navigation**: route status, waypoint progress, legs, replans, stuck/recovery counters, clear blacklist,
  every navigation setting.
- **Inventory & Selling**: capacity bar, detected source (cycle through candidates), auto-sell, threshold,
  "sell every N deposits", seller status and choice, fallback sell point, Sell Now, sale counters.
- **Statistics**: attempts, depletions, verified units per type, time split, efficiency per hour, reliability
  counters, reset.
- **Settings**: interface, mining, performance, and Diagnostics (self-tests, executor capabilities, resource
  counts, copy report).
- **Logs**: filter box, level filter, pooled rows (150 visible), clear, copy.

Only the visible tab refreshes, at `uiRefreshRate` Hz (default 4), and labels are written only when their
text changes.

---

## 3. Changes from v2.0

**Why v2.0 could fail (review findings)**

- If `PlayerGui` was missing after 8 s, the script returned and **no GUI appeared at all**.
- Ore types came from a hard-coded name map, so any other folder name (e.g. a new ore or gem type) was
  silently ignored.
- Deposits without a readable `OreRemaining` were never targeted. During mining, a missing `OreRemaining`
  (`nil`) was counted as **"Depleted" (a false success)**.
- `enumerateOres()` rebuilt the full deposit list with recursive `FindFirstChild` every 2 s and on every
  selection.
- `inventoryFull()` walked **all PlayerGui descendants on every swing**, and the vendor scan walked
  **all Workspace descendants every 15 s** from the status loop.
- Targets were chosen by straight-line distance only.
- Intermediate goals for far targets were **not ground-snapped** (points in the air or inside terrain usually
  give `NoPath`). Any stuck moment aborted travel with no recovery, and `Path.Blocked` was ignored.
- A missing pickaxe stopped automation permanently.
- Selling fell back to pressing **F** through VirtualInputManager (a guessed key). If the inventory UI was
  unidentified, every sale returned "failed", which paused automation.
- Errors inside the mining loop ended automation, with only a console message.
- Reinjection depended on a single global stop handle.

**What v3 changes**

- GUI-first initialisation. No indefinite `WaitForChild` anywhere; every optional dependency has a timeout
  and diagnostics.
- Ore types are discovered dynamically with name normalisation (`CopperOre` → `Copper`, `Iron_Deposits` →
  `Iron`). The deposit registry is event-driven, with cached geometry and per-type counters.
- Full navigation engine: progressive ground-snapped legs, `Path.Blocked`, stuck-recovery ladder, rate-limited
  replanning, cost cache, path-validated scoring, back-off blacklist with automatic reconsideration, and
  remembered streamed-out sites.
- Mining engine: stand spots around the bounding box, oriented-box range checks, facing, optional camera aim,
  selectable interaction method (Tool / Click / Both), and a multi-signal progress probe. A deposit only counts
  as mined on verified depletion.
- Inventory discovery: player attributes/values, ranked PlayerGui `N/M` labels with negative context words
  (ammo, health, …), "inventory full" messages, and ore dropping on the ground nearby. The user can pick the
  source.
- Seller discovery: chunked one-time scan plus event-driven updates; strong/weak classification, path
  validation, manual choice and a fallback point. Sales are confirmed only by money, inventory or ore-item
  changes.
- Central FSM with per-state timeouts, `pcall` isolation, back-off, death handling, and pause with automatic
  resume.
- Session registry for complete teardown on close and on reinjection, including v2.0 and orphaned
  GUIs/visuals.
- Seven-tab dashboard GUI, throttled log, statistics, settings persisted to `getgenv()` and (when available)
  `TWWProspector/settings.json`.
- In-game self-tests plus an offline test suite.

**Kept from v2.0**: `WORKSPACE_Interactables.Mining` + `DepositInfo.OreRemaining` as the primary hierarchy,
`Model:GetPivot()`, `Tool:Activate()` as the default interaction, ProximityPrompt `InputHoldBegin/End` for
selling, optional camera aim, route visualisation, the fallback sell point, and v2 settings (migrated
automatically).

---

## 4. Testing

### Offline (performed)

```
sudo apt-get install luajit lua5.1     # LuaJIT allows yields across pcall, like Luau
luac5.1 -p TWW_Prospector_Ultimate.lua # syntax check (the file uses the Lua 5.1 subset of Luau)
luajit tests/run_tests.lua             # 24 tests; TEST_FILTER=<name part>, TEST_VERBOSE=1 dumps logs on failure
```

The last run passed all 24 tests, and three consecutive full runs were identical. A bytecode listing confirmed
that the script writes **no** globals and reads only Roblox/Luau builtins and feature-detected executor
functions.

The tests cover:

- initialisation and the GUI with all 7 tabs
- the GUI still appearing without the Mining hierarchy, and a late hierarchy being discovered
- event-driven discovery: new categories at runtime, removals, `OreRemaining` changes
- utility parsers and box geometry
- config validation
- log throttling
- blacklist back-off and expiry
- path cost beating straight-line distance
- a full autonomous cycle (travel → equip → mine → deplete → retarget)
- no progress → failure + blacklist, never success
- unreachable deposit → blacklist + alternative target
- stuck detection → recovery → give up
- auto-sell verified by money and inventory
- a sale with no effect → failure, not success
- full inventory detected from ore dropped on the ground
- pause/resume/stop cancelling movement
- death mid-route → respawn → resume
- missing pickaxe → pause → automatic resume
- reinjection teardown, including the v2 handle
- full shutdown (connections, threads and instances at 0, camera restored, no stale callbacks)
- clicking every GUI button and committing every text box
- the diagnostics path test not moving the character
- progressive legs to a deposit 700 studs away
- exploring a remembered streamed-out site

**What the mock cannot prove**: how TWW's real pickaxe, inventory, money and sell prompt behave. In each test
the mock *scripts* those behaviours to match the assumptions in section 5.

### In-game (requires you)

1. Execute the script. Check the Logs tab for `GUI`, `Ore registry: ready` and `Seller discovery: ready`.
2. Go to **Settings → Diagnostics → RUN SELF-TESTS**. Expect PASS for GUI, LocalPlayer, Character, Ore
   hierarchy, Ore discovery, Cancellation and Navigation planning. WARN for inventory, money or sellers means
   that source was not identified yet.
3. **Mining:** stand near one deposit, select only its type, then START. The Logs should show
   `Depleted <type> deposit: N verified unit(s)`.
   If you see `stalled … signals: none`, the TWW pickaxe probably does not react to `Tool:Activate()`.
   Switch **Settings → Interaction method** to `Both` or `Click`.
4. **Navigation:** pick a deposit 100+ studs away. Keep "Show generated route" on and watch the legs and
   replans counters.
5. **Inventory:** open the game's inventory, press RESCAN SOURCES, and use CYCLE SOURCE until the capacity
   shown matches the game.
6. **Selling:** near the General Store, press SCAN SELLERS, then SELL NOW with ore in your inventory. The last
   result must read `sold` with a reason (money +X / inventory A → B).
7. **Reinjection:** execute the file twice. There should be exactly one window, and the log should say
   `Stopped previous session`.

---

## 5. Verified vs unverified game-specific features

Public TWW documentation is sparse. The community wiki pages were not readable from this environment (HTTP
402), and only search-result excerpts were available.

| Feature | Source | Status |
|---|---|---|
| `workspace.WORKSPACE_Interactables.Mining/<Type>/<Deposit>` | your v2.0 script | **Unverified by me.** Configurable paths plus heuristic fallback. |
| `DepositInfo.OreRemaining` (IntValue/NumberValue) | your v2.0 script | **Unverified.** Also accepts attributes, nested values, or none (other progress signals). |
| Mining fills a progress bar; ore goes to the player who lands the final hit; a full inventory drops ore on the ground | community wiki excerpts (thewild-west.fandom.com) | **Unverified in-game.** Used for progress and full-inventory heuristics. |
| Pickaxe is a `Tool` whose name contains "pick" | v2.0 assumption | **Unverified.** Name patterns are configurable. |
| The TWW pickaxe swings on `Tool:Activate()` | v2.0 assumption | **Unverified, highest risk.** Alternative: VirtualInputManager click at the deposit. |
| Ore is sold by holding a sell prompt at General Store / Gun Store NPCs | community forum post | **Unverified.** Prompts with "sell" text are preferred; store NPCs and buildings are weaker candidates. |
| Inventory capacity representation | unknown | **Not found.** Discovered heuristically; reported as unknown otherwise. |
| Money location (leaderstats / attribute / `$` label) | unknown | **Not found.** Optional; sales can also be confirmed by inventory changes. |
| Ore items as Backpack Tools | unknown | **Unverified.** Only one of several yield signals. |
| Roblox APIs used (PathfindingService, Humanoid:MoveTo, GetPivot/GetBoundingBox, Raycast, ProximityPrompt InputHoldBegin/End, Tool:Activate, RequestStreamAroundAsync) | Roblox documentation | Documented engine APIs. Behaviour in TWW not tested live. |

No RemoteEvents are called, guessed or hooked. No anti-cheat, metatable, or namecall hooks are used.

---

## 6. Known limitations

- **No live execution was possible here.** Xeno 1.2.1 compatibility is by design (standard Luau,
  feature-detected optional functions such as `getgenv`, `identifyexecutor`, `setclipboard`, `readfile`,
  `writefile`, `isfile`, `makefolder`, `isfolder`, `fireproximityprompt`, VirtualInputManager), not by test.
- Luau type checking (`luau-analyze`) was not run: downloading the Luau toolchain was blocked in this
  environment. The file sticks to the Lua 5.1 subset. `string.format("%d")` calls were audited for Luau's
  integer rule.
- StreamingEnabled: only replicated deposits and sellers can be discovered. Remembered sites cover deposits
  that were seen earlier. A never-seen region is not explored blindly.
- PathfindingService navmesh limits apply (some caves, doors, ladders; `AgentCanClimb` covers TrussParts
  only). The bot dismounts horses and walks; it does not ride.
- Your own keyboard movement overrides `Humanoid:MoveTo` while automation runs.
- Camera aim switches the camera to Scriptable while mining and restores it afterwards (toggle in Settings).
- A "Click" interaction depends on VirtualInputManager being accessible from your executor. Sell-dialog
  clicking is off by default because the dialog layout is unknown.
- Roblox's idle disconnect (about 20 minutes without real input) is not circumvented.
- Using executors breaks Roblox's Terms of Use and may break TWW's rules. Server-side checks may still flag
  automated play even though only normal interactions are used.
