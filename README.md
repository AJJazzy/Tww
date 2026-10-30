# TWW Prospector Ultimate (v3.1.0)

Autonomous mining assistant for the Roblox game **The Wild West (TWW)**, delivered as one self-contained
Luau file for client executors (target: Xeno 1.2.1).

| File | Purpose |
|---|---|
| `TWW_Prospector_Ultimate.lua` | The whole program. Execute this file. |
| `tests/mock_roblox.lua` | Offline Roblox mock (instances, signals, virtual-time scheduler, pathfinding, humanoid movement). |
| `tests/run_tests.lua` | 31 offline tests that load the **real** script file into the mock and drive it. |

> **Status:** the script has **not** been run inside Roblox or TWW. It was verified offline (syntax, global
> usage, 31 behavioural tests against a mock). Section [0](#0-what-was-checked-and-what-v31-changed) lists
> what public sources confirm about the game. The script's **VERIFY ASSUMPTIONS** button checks each point
> in your live server and reports the evidence.

---

## 0. What was checked and what v3.1 changed

I can't run TWW from here, so "confirming" meant two things:

1. Finding independent public evidence: two published TWW scripts, and the community wiki's text recovered
   from search excerpts and a verbatim copy on Pastebin.
2. Making the script check every assumption itself at runtime, and adapt when an assumption is wrong.

| Assumption | What the evidence says | Verdict | What the script does now |
|---|---|---|---|
| Deposits are under `workspace.WORKSPACE_Interactables.Mining` | Two independent public scripts read `WORKSPACE_Interactables.Mining` ([LightMildTH/RobloxScripts](https://github.com/LightMildTH/RobloxScripts/blob/master/TheWildWest.lua), [yasinert12](https://github.com/yasinert12/yasinert12)) | **Confirmed** (path) | Uses it first; falls back to a folder named like "Mining", then the common ancestor of ore-named parts |
| Deposits are `Mining/<OreType>/<Model>` with `DepositInfo.OreRemaining` | Both public scripts use **`Mining.OreDeposits.<group Folder>.<Model>`**, where each node holds a **MeshPart named `CoalOre`/`IronOre`/…**. Neither mentions `DepositInfo` or `OreRemaining`. The wiki says nodes are mined a fixed number of times (coal 3, zinc 2, gold 1), which fits a counter but doesn't prove one exists. | **Partly contradicted / unconfirmed** | Supports **both** layouts. The ore type comes from deposit evidence first (type attribute → ore-mesh name → deposit name → folder). Without `OreRemaining`, exhaustion is tracked by the ore mesh disappearing and respawning. |
| A full inventory drops mined ore on the ground | Wiki, Ores and Gems (copy of v3.7.5): *"If your inventory is full, the ore will drop to the ground instead. Ore nodes have a chance to drop Gems in the place of their ores."* | **Confirmed** (wiki text) | Drop detection now also matches gems and accepts any parent folder. Second method: if ore is mined but the learned inventory counter doesn't rise twice, the inventory counts as full. |
| Ore is sold by holding a prompt at General/Gun Store NPCs | Wiki, General Store: *"Players may 'Sell Loot' by holding the [F] key or access the 'General Store' by pressing the [E] key at every location."* A forum post agrees; the same thread says the Howling Peak merchant and the Hunter Shack did not buy. | **Confirmed** (wiki text) | Prefers "sell" prompts. If the prompt API doesn't trigger, it holds the prompt's own key (F). Sellers that paid or didn't pay are remembered per place; Howling Peak and Hunter Shack rank lower. |
| Inventory capacity is readable from UI/data | Wiki, Backpack (v4.4.0): up to **40 slots**; stackable items count as one slot. Nothing public says where the client stores it. | **Unknown location** | **Learns by observation.** A `N/M` on-screen counter that was stable and then rose right after verified mining is promoted after two observations, then saved per place. |
| Money is readable | Nothing public | **Unknown** | **Learns by observation.** A `$` or numeric display that rises right after a sale is promoted and saved; `$` labels and leaderstats are also checked. |
| Pickaxe is a Roblox `Tool` swung by `Tool:Activate()` (v2.0) | The public script uses the game's own item framework (`…Character.Items`, `PlayerCharacter:EquipItem`); the wiki describes a hotbar | **Probably false** | Finds a Roblox Tool **or** the game item in hand (on the character or its `WORKSPACE_Entities.Players` copy). Equips via the hotbar key: Settings slot, learned slot, hotbar UI, or trying 1–9. **Auto** interaction switches between `Tool:Activate()` and a simulated click on the deposit and remembers what works. |
| The character walks with `Humanoid:MoveTo` | The game has its own character controller (`PlayerCharacter` module) | **Unverified** | If the character doesn't move on two waypoints, switches to a per-frame `Humanoid:Move` driver and remembers it |

Also from the wiki: minimum pickaxe tier per ore (Coal/Copper 1, Zinc 2, Iron/Limestone 3, Silver 4, Gold 5).
If one ore type shows **no reaction at all** on three deposits in a row, that type is skipped for 10 minutes,
with this hint in the log.

Sources: [TWW wiki: Ores and Gems](https://thewild-west.fandom.com/wiki/Ores_and_Gems) (verbatim copy:
[pastebin ASZbAM8Q](https://pastebin.com/ASZbAM8Q)) · [TWW wiki: General Store](https://thewild-west.fandom.com/wiki/General_Store) ·
[TWW wiki: Backpack](https://thewild-west.fandom.com/wiki/Backpack) · [TWW wiki forum: Ore](https://thewild-west.fandom.com/f/p/4400000000000071105) ·
[LightMildTH/RobloxScripts TheWildWest.lua](https://github.com/LightMildTH/RobloxScripts/blob/master/TheWildWest.lua) ·
[yasinert12 script](https://github.com/yasinert12/yasinert12). The wiki pages themselves were behind a
Cloudflare check, and web.archive.org is blocked from this environment, so wiki statements come from search
excerpts and the Pastebin copy. The public scripts are older than the current 4.x game, so the layout may have
changed again. That is why the script checks the layout at runtime.

**In game:** open **Settings → Game assumptions**.
- **VERIFY ASSUMPTIONS** prints CONFIRMED / DIFFERENT / CONTRADICTED / NOT FOUND / PENDING / LEARNED for
  every row above, with the evidence it found.
- **SAVE WORLD REPORT** writes `TWWProspector/world_report.txt` and copies it to the clipboard. It contains
  the Mining tree, sample deposits, the sell prompts, the player, character and PlayerGui counters, and what
  was learned. Send that file back and every remaining unknown can be settled.

---

## 1. Quick start

1. Join a TWW server and execute `TWW_Prospector_Ultimate.lua` in your executor.
2. The window appears on the left of the screen. `RightControl` shows or hides it (configurable).
3. **Ore Management**: choose ore types and set priorities.
4. Press **START** (Dashboard or sidebar). You never record routes or place waypoints.
5. If something is not detected, open **Settings → Game assumptions → VERIFY ASSUMPTIONS** and
   **Settings → Diagnostics → RUN SELF-TESTS**, and read the **Logs** tab.
6. If the pickaxe isn't found automatically, set **Settings → Pickaxe hotbar slot**.

Re-executing the file at any time first shuts down the running copy completely, including v2.0.

---

## 2. Architecture

A single chunk organised as Lua-table modules (search the file for `==== MODULE:`). Modules talk through
plain function calls. There is one automation thread, guarded by a generation counter.

```
Bootstrap/Util ─ Session (resource registry) ─ Token (cancellation) ─ Log ─ Config ─ Stats
        │
        ├─ Learned (per-place knowledge, persisted)
        ├─ Char (character/respawn)  Input (simulated keys/clicks)  Tools (Tool or game item, hotbar)
        ├─ Blacklist (back-off)  Ores (two layouts, ore-mesh exhaustion, remembered sites, type pausing)
        ├─ Nav (PathfindingService, progressive legs, stuck recovery, driver fallback)  Visual
        ├─ Probe + Miner (approach, aim, Auto interaction, verify progress)
        ├─ Learn (observation-based counters) + Inventory + Wallet (sources, full detection, sale checks)
        ├─ Sellers (prompt/store discovery, travel, prompt interaction, verification)
        ├─ Targeting (scoring + path validation)  Auto (finite-state machine)
        └─ UI (7 tabs)  Verify (assumption check + world report)  SelfTest  Main
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

### v3.1 additions

- **Ores:** both deposit layouts; ore type from deposit-level evidence; exhaustion and respawn through the ore
  mesh when `OreRemaining` doesn't exist; root discovery from ore-named parts; ore types that never react are
  paused (with the wiki tier hint); five non-reacting deposits in a row pause automation with a reason.
- **Pickaxe:** Roblox Tool **or** game item. The game item is found on the character or its
  `WORKSPACE_Entities` copy and equipped with its hotbar key (configured, learned, read from the hotbar UI, or
  tried 1–9). The Auto interaction picks Tool or Click, switches after 6 swings without reaction, and remembers
  what worked.
- **Learn:** the inventory counter and money display are identified by observing which on-screen numbers or
  player values change right after verified mining or a sale, then saved per PlaceId.
- **Full inventory:** wider ground-drop detection (gems, any folder), plus "mined but counter unchanged twice".
- **Selling:** falls back to holding the prompt's own key; remembers paying and non-paying sellers per place;
  ranks Howling Peak and Hunter Shack lower.
- **Movement:** falls back from `MoveTo` to a per-frame `Humanoid:Move` driver, and remembers the one that works.
- **Verify:** the assumption check and world report described in section 0.
- **New settings:** Pickaxe hotbar slot, interaction method `Auto` (new default), and Clear Learned Data.

---

## 4. Testing

### Offline (performed)

```
sudo apt-get install luajit lua5.1     # LuaJIT allows yields across pcall, like Luau
luac5.1 -p TWW_Prospector_Ultimate.lua # syntax check (the file uses the Lua 5.1 subset of Luau)
luajit tests/run_tests.lua             # 31 tests; TEST_FILTER=<name part>, TEST_VERBOSE=1 dumps logs on failure
```

The last run passed all 31 tests, and three consecutive full runs were identical. A bytecode listing confirmed
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
- **v3.1:** the public-script layout (OreDeposits groups, ore MeshParts, no `OreRemaining`): types read from
  mesh names, exhaustion by mesh removal, respawn noticed
- **v3.1:** a game-item pickaxe: hotbar slot found by trying keys, mining by simulated clicks, both remembered
- **v3.1:** inventory counter and money display learned from observation, with no telling names, while an
  unrelated number on screen keeps changing
- **v3.1:** a sell prompt that ignores the prompt API, triggered by holding its key (F); the paying seller is
  remembered
- **v3.1:** an ore type that never reacts is paused with the tier hint, and other types continue
- **v3.1:** the movement driver switching when `MoveTo` does nothing
- **v3.1:** VERIFY ASSUMPTIONS verdicts for both layouts, and the world report

**What the mock cannot prove**: how TWW's real pickaxe, inventory, money and sell prompt behave. In each test
the mock *scripts* those behaviours to match the assumptions in section 5.

### In-game (requires you)

1. Execute the script. Check the Logs tab for `GUI`, `Ore registry: ready` and `Seller discovery: ready`.
2. Go to **Settings → Game assumptions → VERIFY ASSUMPTIONS**, then **SAVE WORLD REPORT** (send me the file
   if anything shows NOT FOUND, DIFFERENT or CONTRADICTED). Then **Settings → Diagnostics → RUN SELF-TESTS**. Expect PASS for GUI, LocalPlayer, Character, Ore
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

See [section 0](#0-what-was-checked-and-what-v31-changed) for the evidence. In short:

| Feature | Public evidence | Runtime handling |
|---|---|---|
| `WORKSPACE_Interactables.Mining` root | Confirmed by two public scripts | Verified in game by VERIFY ASSUMPTIONS; fallbacks if moved |
| Deposit layout / `DepositInfo.OreRemaining` | Public scripts show `OreDeposits` + ore MeshParts, no `OreRemaining` | Both layouts supported; mesh-based exhaustion |
| Full inventory → ore on the ground | Confirmed by wiki text | Drop detection plus a counter-correlation check |
| "Sell Loot" prompt held with F at stores | Confirmed by wiki text and a forum post | Prompt API, then the prompt's key; per-place seller memory |
| Inventory capacity | 40 backpack slots (wiki v4.4.0); location unknown | Learned by observation, or a heuristic UI source, or reported unknown |
| Money | Unknown | Learned by observation, or `$` labels/leaderstats |
| Pickaxe type and swing input | Game item framework, so probably not a Roblox Tool | Tool or game item; hotbar key; Auto Tool/Click |
| Movement via `Humanoid:MoveTo` | Custom controller, unverified | Automatic fallback to `Humanoid:Move` |

No RemoteEvents are called, guessed or hooked. No game modules are `require`d. No anti-cheat, metatable, or
namecall hooks are used. All input is either a documented engine API or a simulated key/mouse event of the
kind a player produces.

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
- Learning needs events: the inventory counter is learned only after ore has been mined twice, and money only
  after a sale. Until then those sources show as PENDING or unknown.
- Trying hotbar keys 1–9 briefly equips whatever is in those slots. Set the pickaxe slot in Settings to avoid it.
- The game-item pickaxe and mouse clicks need VirtualInputManager. Without it, the script asks you to equip the
  pickaxe by hand and stays paused until you do.
- Using executors breaks Roblox's Terms of Use and may break TWW's rules. Server-side checks may still flag
  automated play even though only normal interactions are used.
