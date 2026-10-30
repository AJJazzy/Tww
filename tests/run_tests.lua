-- Offline test-suite for TWW_Prospector_Ultimate.lua.
-- Run from the repository root:   luajit tests/run_tests.lua
-- Every test loads the REAL script file into a fresh mock world (tests/mock_roblox.lua) and drives it
-- with virtual time. Game-specific behaviour (how a pickaxe hit changes OreRemaining, how a sell
-- prompt pays out) is scripted by the test to match the assumptions documented in README.md.

package.path = "./tests/?.lua;" .. package.path
local M = require("mock_roblox")
M.reset() -- install globals (Vector3, Enum, ...) before fixtures build values
local SCRIPT = "TWW_Prospector_Ultimate.lua"

local tests, results = {}, {}
local function test(name, fn) tests[#tests + 1] = {name = name, fn = fn} end
local function check(cond, msg) if not cond then error(msg or "assertion failed", 2) end end
local function eq(a, b, msg)
    if a ~= b then error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

---------------------------------------------------------------------------------- fixtures
local V = function(x, y, z) return Vector3.new(x, y, z) end

local function world(opts)
    opts = opts or {}
    M.reset()
    M.makeCharacter(opts.start or V(0, 3, 0))
    if opts.noHierarchy then return nil end
    local interact = M.new("Folder", M.workspace)
    interact.Name = "WORKSPACE_Interactables"
    local mining = M.new("Folder", interact)
    mining.Name = "Mining"
    for _, spec in ipairs(opts.deposits or {{"Coal", V(30, 2, 0)}}) do
        local folder = mining:FindFirstChild(spec[1]) or M.new("Folder", mining)
        folder.Name = spec[1]
        M.makeDeposit(folder, spec[1] .. "Deposit", spec[2], spec[3] or opts.remaining or 3, spec[4])
    end
    M.mining = mining
    return mining
end

-- Pickaxe whose hits behave like the community-documented loop: every 2nd hit on a deposit within
-- 9 studs yields one ore (OreRemaining - 1). A full inventory drops the ore on the ground.
local function givePickaxe(mode)
    local tool = M.new("Tool", M.backpack)
    tool.Name = "Pickaxe"
    local hits = 0
    tool.Activated:Connect(function()
        M.swings = (M.swings or 0) + 1
        if mode == "noop" then return end
        local root = M.root()
        if not root or tool.Parent ~= M.character then return end
        local best, bestD
        for _, d in ipairs(M.mining:GetDescendants()) do
            if d.Name == "OreRemaining" then
                local model = d.Parent.Parent
                local dist = (model.PrimaryPart.Position - root.Position).Magnitude
                if dist < 9 and (not bestD or dist < bestD) then best, bestD = d, dist end
            end
        end
        if not best then M.missed = (M.missed or 0) + 1 return end
        hits = hits + 1
        if hits % 2 == 0 and best.Value > 0 then
            local inv = M.inventory
            if inv and inv.count >= inv.cap then
                local drop = M.new("Part", M.workspace)
                drop.Name = "Coal Ore"
                drop.Position = root.Position + V(2, 0, 0)
            elseif inv then
                inv.count = inv.count + 1
                inv.label.Text = inv.count .. "/" .. inv.cap
            end
            best.Value = best.Value - 1
            if best.Value == 0 then
                local model = best.Parent.Parent
                task.delay(0.3, function() model:Destroy() end)
            end
        end
    end)
    return tool
end

local function giveInventoryGui(count, cap)
    local gui = M.new("ScreenGui", M.playerGui)
    gui.Name = "MainHUD"
    local frame = M.new("Frame", gui)
    frame.Name = "InventoryFrame"
    local label = M.new("TextLabel", frame)
    label.Name = "CapacityLabel"
    label.Text = count .. "/" .. cap
    M.inventory = {count = count, cap = cap, label = label}
    return label
end

local function giveMoney(amount)
    local stats = M.new("Folder", M.player)
    stats.Name = "leaderstats"
    local money = M.new("IntValue", stats)
    money.Name = "Money"
    money.Value = amount
    M.money = money
    return money
end

local function giveSeller(pos, pays)
    local npc = M.new("Model", M.workspace)
    npc.Name = "GeneralStoreClerk"
    local torso = M.new("Part", npc)
    torso.Name = "Torso"
    torso.Position = pos
    npc.PrimaryPart = torso
    local prompt = M.new("ProximityPrompt", torso)
    prompt.ActionText = "Sell"
    prompt.ObjectText = "General Store"
    prompt.HoldDuration = 0.5
    prompt.MaxActivationDistance = 10
    if pays ~= false then
        M.onPromptTriggered = function()
            if M.inventory then
                if M.money then M.money.Value = M.money.Value + M.inventory.count * 20 end
                M.inventory.count = 0
                M.inventory.label.Text = "0/" .. M.inventory.cap
            end
        end
    end
    return prompt
end

local function inject()
    local getResult = M.loadScript(SCRIPT)
    M.run(0.5)
    local handle = M.genv.TWWProspectorSession
    check(handle, "session handle registered in getgenv")
    M.lastMods = handle.modules
    return handle, handle.modules, getResult
end

local function errorsLogged(mods)
    local list = {}
    for _, e in ipairs(mods.Log.entries) do
        if e.level == "ERROR" then list[#list + 1] = e.cat .. ": " .. e.msg end
    end
    return list
end

local function noErrors(mods)
    local errs = errorsLogged(mods)
    check(#errs == 0, "unexpected ERROR log entries:\n  " .. table.concat(errs, "\n  "))
    check(#M.S.errors == 0, "uncaught thread errors:\n" .. table.concat(M.S.errors, "\n"))
end

---------------------------------------------------------------------------------- tests
test("initialises and builds the GUI with all tabs", function()
    world()
    givePickaxe()
    local handle, mods = inject()
    local gui = M.playerGui:FindFirstChild("TWW_Prospector_Ultimate")
    check(gui, "ScreenGui parented to PlayerGui")
    check(mods.UI.built, "UI.built")
    local tabs = 0
    for _ in pairs(mods.UI.tabs) do tabs = tabs + 1 end
    eq(tabs, 7, "tab count")
    for _, name in ipairs({"Dashboard", "Ores", "Navigation", "Inventory", "Statistics", "Settings", "Logs"}) do
        check(mods.UI.pages[name], "page " .. name)
        mods.UI.selectTab(name)
    end
    M.run(3)
    check(mods.SelfTest.ranAt, "startup self-test ran")
    local byName = {}
    for _, r in ipairs(mods.SelfTest.results) do byName[r.name] = r.status end
    eq(byName["GUI creation"], "PASS", "self-test GUI")
    eq(byName["LocalPlayer"], "PASS", "self-test LocalPlayer")
    eq(byName["Character / root"], "PASS", "self-test character")
    eq(byName["Ore hierarchy"], "PASS", "self-test hierarchy")
    eq(byName["Ore discovery"], "PASS", "self-test discovery")
    eq(byName["Cancellation & cleanup"], "PASS", "self-test cancellation")
    eq(byName["Pickaxe"], "PASS", "self-test pickaxe")
    noErrors(mods)
end)

test("GUI still appears when the Mining hierarchy is missing, then late folder is discovered", function()
    world({noHierarchy = true})
    local _, mods = inject()
    check(M.playerGui:FindFirstChild("TWW_Prospector_Ultimate"), "GUI exists without ore hierarchy")
    check(mods.Ores.root == nil, "no root yet")
    M.run(3)
    local status
    for _, r in ipairs(mods.SelfTest.results) do if r.name == "Ore hierarchy" then status = r.status end end
    eq(status, "FAIL", "self-test reports missing hierarchy")
    local interact = M.new("Folder", M.workspace)
    interact.Name = "WORKSPACE_Interactables"
    local mining = M.new("Folder", interact)
    mining.Name = "Mining"
    local iron = M.new("Folder", mining)
    iron.Name = "IronOre"
    M.makeDeposit(iron, "IronDeposit", V(20, 2, 0), 4)
    M.run(mods.Config.get("scanInterval") + 2)
    check(mods.Ores.root == mining, "root discovered after it replicated")
    check(mods.Ores.kinds["Iron"], "IronOre normalised to Iron")
    eq(mods.Ores.depositCount, 1, "deposit count")
    noErrors(mods)
end)

test("ore discovery is event-driven (new categories, removals, OreRemaining changes)", function()
    local mining = world({deposits = {{"Coal", V(30, 2, 0)}, {"CopperOre", V(-30, 2, 0)}, {"Copper", V(-35, 2, 5)}}})
    local _, mods = inject()
    local Ores = mods.Ores
    check(Ores.kinds.Coal and Ores.kinds.Copper, "Coal and Copper kinds")
    eq(#Ores.kindList, 2, "CopperOre and Copper folders merge into one kind")
    eq(Ores.depositCount, 3, "three deposits")
    local goldFolder = M.new("Folder")
    goldFolder.Name = "Gold_Deposits"
    goldFolder.Parent = mining
    local gold = M.makeDeposit(goldFolder, "GoldDeposit", V(0, 2, 40), 2)
    M.run(0.2)
    check(Ores.kinds.Gold, "Gold kind discovered at runtime")
    eq(Ores.depositCount, 4, "gold deposit added")
    mods.UI.selectTab("Ores")
    M.run(0.5)
    check(mods.UI.pages.Ores and Ores.version >= 3, "ore tab rebuilt for new kind")
    local entry = Ores.deposits[gold]
    eq(entry.remaining, 2, "OreRemaining read")
    gold.DepositInfo.OreRemaining.Value = 0
    M.run(0.1)
    eq(entry.remaining, 0, "OreRemaining change observed via .Changed")
    check(not Ores.isAvailable(entry), "depleted deposit unavailable")
    gold:Destroy()
    M.run(0.1)
    eq(Ores.depositCount, 3, "removal observed")
    noErrors(mods)
end)

test("utility parsers and geometry", function()
    world()
    local _, mods = inject()
    local U, Ores = mods.U, mods.Ores
    eq(Ores.kindName("CopperOre"), "Copper")
    eq(Ores.kindName("Iron_Deposits"), "Iron")
    eq(Ores.kindName("SilverOreNodes"), "Silver")
    eq(Ores.kindName("Gold"), "Gold")
    local a, b = U.parseFraction("Inventory 12 / 40")
    eq(a, 12) eq(b, 40)
    check(U.parseFraction("no numbers") == nil, "fraction nil")
    eq(U.parseMoney("$1,234.50"), 1234.5)
    eq(U.fmtTime(3725), "1h 02m 05s")
    local d = U.distanceToBox(V(10, 0, 0), CFrame.new(0, 0, 0), V(4, 4, 4))
    check(math.abs(d - 8) < 1e-9, "distance to box")
end)

test("config validation clamps and rejects", function()
    world()
    local _, mods = inject()
    local Config = mods.Config
    check(Config.set("sellThreshold", 5), "numeric accepted")
    eq(Config.get("sellThreshold"), 1, "clamped to max")
    check(not Config.set("interactMethod", "Bogus"), "invalid enum rejected")
    eq(Config.get("interactMethod"), "Tool")
    check(not Config.set("unknownKey", 1), "unknown key rejected")
end)

test("log throttling suppresses repeats", function()
    world()
    local _, mods = inject()
    local Log = mods.Log
    local before = #Log.entries
    for _ = 1, 10 do Log.warn("Test", "repeated", "same-key", 5) end
    eq(#Log.entries - before, 1, "only first message stored")
    M.run(6)
    Log.warn("Test", "repeated", "same-key", 5)
    local last = Log.entries[#Log.entries].msg
    check(last:find("+9 similar suppressed", 1, true), "suppressed count reported: " .. last)
end)

test("blacklist uses exponential back-off and expires", function()
    world()
    local _, mods = inject()
    local bl = mods.Blacklist.new("t")
    local key = {}
    eq(bl:mark(key, "x"), 30, "first duration")
    eq(bl:mark(key, "x"), 60, "second duration doubles")
    check(bl:blocked(key), "blocked now")
    M.run(61)
    check(not bl:blocked(key), "expired and reconsidered")
    eq(bl:failures(key), 2, "failure history kept for scoring")
end)

test("target selection uses real path cost, not straight-line distance", function()
    local mining = world({deposits = {{"Coal", V(20, 2, 0)}, {"Iron", V(0, 2, 45)}}})
    givePickaxe()
    local near = mining.Coal.CoalDeposit
    -- The coal deposit is closer in a straight line but behind a wall: the path detours 300 studs.
    M.pathfinder = function(from, to)
        if (to - near.PrimaryPart.Position).Magnitude < 8 then
            local via = V(150, 3, 150)
            local pts = M.straightPath(from, via)
            for _, p in ipairs(M.straightPath(via, to)) do pts[#pts + 1] = p end
            return pts
        end
        return M.straightPath(from, to)
    end
    local _, mods = inject()
    local token = mods.Token.new(nil)
    local chosen, info
    task.spawn(function() chosen, info = mods.Targeting.select(token) end)
    M.runUntil(function() return chosen ~= nil end, 20)
    check(chosen, "a target was chosen")
    eq(chosen.kind, "Iron", "path-validated cheaper target wins (" .. tostring(info) .. ")")
    noErrors(mods)
end)

test("full autonomous cycle: navigate, equip, mine with verified progress, deplete, retarget", function()
    world({deposits = {{"Coal", V(30, 2, 0)}, {"Coal", V(30, 2, 30)}}})
    givePickaxe()
    local _, mods = inject()
    local Stats = mods.Stats
    mods.Auto.start()
    local done = M.runUntil(function() return Stats.depleted >= 2 end, 120)
    check(done, "two deposits depleted (state " .. mods.Auto.state .. ", activity " .. tostring(mods.Auto.activity) .. ")")
    eq(Stats.yields, 6, "verified units equal OreRemaining consumed")
    check(Stats.successAttempts >= 2, "successful attempts counted")
    eq(Stats.failedAttempts, 0, "no failed attempts")
    check(Stats.travelTime > 0 and Stats.miningTime > 0, "time buckets accumulate")
    eq(mods.Ores.depositCount, 0, "depleted deposits removed from registry")
    M.run(5)
    check(mods.Auto.state == "SELECTING_TARGET" or mods.Auto.state == "SCANNING"
        or mods.Auto.state == "CHECKING_INVENTORY", "keeps scanning without targets: " .. mods.Auto.state)
    mods.Auto.stop("test")
    noErrors(mods)
end)

test("no observable progress is a failure, never a success, and the deposit is blacklisted", function()
    local mining = world({deposits = {{"Coal", V(25, 2, 0)}}})
    givePickaxe("noop")
    local _, mods = inject()
    mods.Config.set("stallTimeout", 6)
    mods.Auto.start()
    local entry = mods.Ores.deposits[mining.Coal.CoalDeposit]
    local blocked = M.runUntil(function() return mods.Ores.blacklist:blocked(entry.node) end, 90)
    check(blocked, "deposit blacklisted after no progress")
    check(M.swings and M.swings > 3, "the tool was actually activated")
    eq(mods.Stats.successAttempts, 0, "no false success")
    eq(mods.Stats.depleted, 0, "nothing reported depleted")
    check(mods.Stats.failedAttempts >= 1, "failed attempt recorded")
    mods.Auto.stop("test")
    noErrors(mods)
end)

test("unreachable deposits are blacklisted and another target is chosen", function()
    local mining = world({deposits = {{"Coal", V(15, 2, 0)}, {"Iron", V(0, 2, 30)}}})
    givePickaxe()
    local blockedPos = mining.Coal.CoalDeposit.PrimaryPart.Position
    M.pathfinder = function(from, to)
        if (to - blockedPos).Magnitude < 10 then return nil end
        return M.straightPath(from, to)
    end
    local _, mods = inject()
    mods.Auto.start()
    local ok = M.runUntil(function() return mods.Stats.depleted >= 1 end, 90)
    check(ok, "reachable deposit mined")
    check(mods.Stats.unreachable >= 1, "unreachable counted")
    check(mods.Ores.blacklist:blocked(mining.Coal.CoalDeposit), "unreachable deposit blacklisted")
    mods.Auto.stop("test")
    noErrors(mods)
end)

test("stuck detection triggers recovery and eventually gives up on the target", function()
    world({deposits = {{"Coal", V(40, 2, 0)}}})
    givePickaxe()
    local _, mods = inject()
    M.humanoid._frozen = true
    mods.Auto.start()
    local gaveUp = M.runUntil(function() return mods.Ores.blacklist:activeCount() >= 1 end, 120)
    check(mods.Stats.stuckEvents >= 1, "stuck events detected")
    check(mods.Stats.recoveries >= 1, "recovery steps attempted")
    check(gaveUp, "target blacklisted after repeated stuck failures")
    check(mods.Auto.running, "automation still running")
    mods.Auto.stop("test")
    noErrors(mods)
end)

test("auto-sell: threshold reached, seller discovered, sale verified by money and inventory", function()
    world({deposits = {{"Coal", V(25, 2, 0), 10}}})
    givePickaxe()
    giveInventoryGui(8, 10)
    giveMoney(100)
    giveSeller(V(-40, 3, 0))
    local _, mods = inject()
    mods.Config.set("sellThreshold", 0.9)
    mods.Auto.start()
    local sold = M.runUntil(function() return mods.Stats.sales >= 1 end, 120)
    check(sold, "sale verified (state " .. mods.Auto.state .. ", seller " .. tostring(mods.Sellers.lastResult) ..
        ", detail " .. tostring(mods.Sellers.lastDetail) .. ")")
    check(M.money.Value > 100, "money increased")
    check(mods.Stats.moneyEarned > 0, "money earned recorded")
    eq(mods.Stats.salesUnverified, 0, "no unverified sales")
    local back = M.runUntil(function() return mods.Auto.state == "MINING" end, 60)
    check(back, "returned to mining after selling")
    mods.Auto.stop("test")
    noErrors(mods)
end)

test("a sale with no observable effect is never reported as sold", function()
    world({deposits = {{"Coal", V(25, 2, 0), 10}}})
    givePickaxe()
    giveInventoryGui(9, 10)
    giveSeller(V(-30, 3, 0), false)
    local _, mods = inject()
    mods.Config.set("sellThreshold", 0.9)
    mods.Auto.start()
    local handled = M.runUntil(function() return mods.Stats.salesFailed >= 1 end, 90)
    check(handled, "failed sale detected (last " .. tostring(mods.Sellers.lastResult) .. ")")
    eq(mods.Stats.sales, 0, "no sale claimed")
    check(M.promptTriggers >= 1, "the prompt interaction really happened")
    mods.Auto.stop("test")
    noErrors(mods)
end)

test("full inventory detected from ore dropping on the ground", function()
    world({deposits = {{"Coal", V(25, 2, 0), 10}}})
    givePickaxe()
    giveInventoryGui(10, 10)
    M.inventory.label.Parent = nil -- no readable counter: only the drop reveals fullness
    local _, mods = inject()
    mods.Config.set("autoSell", false)
    mods.Auto.start()
    local paused = M.runUntil(function() return mods.Auto.paused end, 90)
    check(paused, "automation paused instead of wasting ore")
    check(mods.Inventory.state.fullFlag, "full flag set")
    check(tostring(mods.Inventory.state.fullReason):find("dropped", 1, true), "reason mentions drop")
    mods.Auto.stop("test")
    noErrors(mods)
end)

test("stop cancels movement immediately; pause/resume works", function()
    world({deposits = {{"Coal", V(120, 2, 0)}}})
    givePickaxe()
    local _, mods = inject()
    mods.Auto.start()
    M.runUntil(function() return mods.Auto.state == "TRAVELING" end, 20)
    M.run(1)
    mods.Auto.pause("test")
    M.run(0.5)
    eq(mods.Auto.state, "PAUSED", "paused state")
    local x1 = M.root().Position.X
    M.run(2)
    check(math.abs(M.root().Position.X - x1) < 0.6, "no movement while paused")
    mods.Auto.resume()
    M.runUntil(function() return mods.Auto.state == "TRAVELING" end, 20)
    mods.Auto.stop("test")
    M.run(0.3)
    eq(mods.Auto.state, "IDLE", "idle after stop")
    local x2 = M.root().Position.X
    M.run(2)
    check(math.abs(M.root().Position.X - x2) < 0.6, "no movement after stop")
    local _, threads = mods.SESSION:stats()
    for thread, label in pairs(mods.SESSION.threads) do
        check(label ~= "Automation", "automation thread finished")
    end
    check(threads >= 1, "background threads still alive")
    noErrors(mods)
end)

test("death mid-route: waits for respawn and resumes automatically", function()
    world({deposits = {{"Coal", V(80, 2, 0)}}})
    givePickaxe()
    local _, mods = inject()
    mods.Auto.start()
    M.runUntil(function() return mods.Auto.state == "TRAVELING" end, 20)
    M.run(1)
    M.kill()
    M.run(1)
    eq(mods.Auto.state, "RECOVERING", "recovering after death")
    M.run(3)
    M.makeCharacter(V(0, 3, 0))
    local tool = M.backpack:FindFirstChild("Pickaxe")
    check(tool, "pickaxe still in backpack")
    local mined = M.runUntil(function() return mods.Stats.depleted >= 1 end, 120)
    check(mined, "resumed and mined after respawn (state " .. mods.Auto.state .. ")")
    eq(mods.Stats.deaths, 1, "death counted")
    mods.Auto.stop("test")
    noErrors(mods)
end)

test("missing pickaxe pauses with a reason and auto-resumes when one appears", function()
    world({deposits = {{"Coal", V(10, 2, 0)}}})
    local _, mods = inject()
    mods.Auto.start()
    local paused = M.runUntil(function() return mods.Auto.paused end, 30)
    check(paused, "paused without pickaxe")
    check(tostring(mods.Auto.pauseReason):find("pickaxe", 1, true), "reason mentions pickaxe")
    givePickaxe()
    local resumed = M.runUntil(function() return mods.Auto.state == "MINING" end, 30)
    check(resumed, "auto-resumed once a pickaxe exists")
    mods.Auto.stop("test")
    noErrors(mods)
end)

test("reinjection tears down the previous build completely (incl. legacy v2 handle)", function()
    world()
    givePickaxe()
    local legacyStopped = false
    M.genv.TWWProspector = {stop = function() legacyStopped = true end}
    local first, firstMods = inject()
    check(legacyStopped, "legacy v2 stop() called")
    firstMods.Auto.start()
    M.run(2)
    local wsConnsSingle = M.connectionCount(M.workspace)
    local second, secondMods = inject()
    check(first ~= second, "new handle")
    check(not firstMods.SESSION.alive, "old session dead")
    eq(#firstMods.SESSION.conns, 0, "old connections released")
    local guis = 0
    for _, c in ipairs(M.playerGui:GetChildren()) do if c.Name == "TWW_Prospector_Ultimate" then guis = guis + 1 end end
    eq(guis, 1, "exactly one GUI")
    check(not firstMods.Auto.running, "old automation stopped")
    M.run(3)
    check(M.connectionCount(M.workspace) <= wsConnsSingle, "no accumulated workspace connections after reinjection")
    noErrors(secondMods)
end)

test("shutdown releases every connection, thread, instance and restores the camera", function()
    world({deposits = {{"Coal", V(6, 2, 0)}}})
    givePickaxe()
    local handle, mods = inject()
    mods.Auto.start()
    M.runUntil(function() return mods.Auto.state == "MINING" end, 30)
    M.run(1)
    eq(M.workspace.CurrentCamera.CameraType, Enum.CameraType.Scriptable, "camera aimed while mining")
    handle.stop("test")
    M.run(1)
    check(not mods.SESSION.alive, "session dead")
    local c, t, i = mods.SESSION:stats()
    eq(c, 0, "connections") eq(t, 0, "threads") eq(i, 0, "instances")
    check(not M.playerGui:FindFirstChild("TWW_Prospector_Ultimate"), "GUI destroyed")
    check(not M.workspace:FindFirstChild("TWW_Prospector_Visuals"), "visuals destroyed")
    eq(M.workspace.CurrentCamera.CameraType, Enum.CameraType.Custom, "camera restored")
    check(M.genv.TWWProspectorSession == nil, "global handle cleared")
    local swings = M.swings
    M.run(5)
    eq(M.swings, swings, "no stale callbacks or loops after shutdown")
end)

test("every GUI button and text box can be used without errors; close button shuts down", function()
    world({deposits = {{"Coal", V(20, 2, 0)}}})
    givePickaxe()
    giveSeller(V(-30, 3, 0))
    local _, mods = inject()
    local gui = M.playerGui:FindFirstChild("TWW_Prospector_Ultimate")
    local closeButton
    for _, name in ipairs(mods.UI.order) do
        mods.UI.selectTab(name)
        M.run(0.3)
        for _, inst in ipairs(gui:GetDescendants()) do
            if inst:IsA("TextButton") then
                if inst == mods.UI.closeButton then closeButton = inst
                else inst.MouseButton1Click:Fire() end
            elseif inst:IsA("TextBox") then
                inst.Text = inst.Text
                inst.FocusLost:Fire(true)
            end
        end
        M.run(0.5)
    end
    M.run(5)
    noErrors(mods)
    check(closeButton, "close button found")
    closeButton.MouseButton1Click:Fire()
    M.run(0.5)
    check(not mods.SESSION.alive, "close button shut the session down")
    check(not M.playerGui:FindFirstChild("TWW_Prospector_Ultimate"), "GUI removed")
end)

test("diagnostics self-test computes a real test path without moving the character", function()
    world({deposits = {{"Coal", V(30, 2, 0)}}})
    givePickaxe()
    local _, mods = inject()
    local before = M.root().Position
    local calls = M.pathCalls
    task.spawn(function() mods.SelfTest.run(true) end)
    M.run(3)
    local status
    for _, r in ipairs(mods.SelfTest.results) do if r.name == "Navigation planning" then status = r.status end end
    eq(status, "PASS", "path planning self-test")
    check(M.pathCalls > calls, "PathfindingService was used")
    check((M.root().Position - before).Magnitude < 0.01, "character did not move")
    noErrors(mods)
end)

test("distant deposit is reached through progressive path legs", function()
    world({deposits = {{"Iron", V(700, 2, 0)}}})
    givePickaxe()
    local _, mods = inject()
    mods.Auto.start()
    local mined = M.runUntil(function() return mods.Stats.depleted >= 1 end, 200)
    check(mined, "far deposit mined (state " .. mods.Auto.state .. ", route " .. mods.Nav.status.route .. ")")
    check(mods.Nav.status.legs >= 3, "multiple legs used: " .. mods.Nav.status.legs)
    mods.Auto.stop("test")
    noErrors(mods)
end)

test("streamed-out deposit is remembered and its site explored until it streams back in", function()
    local mining = world({deposits = {{"Gold", V(500, 2, 0)}}})
    givePickaxe()
    local _, mods = inject()
    mining.Gold.GoldDeposit:Destroy()  -- simulates StreamingEnabled removing a distant model
    M.run(0.2)
    eq(#mods.Ores.memory, 1, "site remembered")
    eq(mods.Ores.depositCount, 0, "no loaded deposits")
    mods.Auto.start()
    local streamedIn = false
    local mined = M.runUntil(function()
        local root = M.root()
        if not streamedIn and root and (root.Position - V(500, 3, 0)).Magnitude < 180 then
            streamedIn = true
            M.makeDeposit(mining.Gold, "GoldDeposit", V(500, 2, 0), 2)
        end
        return mods.Stats.depleted >= 1
    end, 200)
    check(streamedIn, "bot travelled toward the remembered site")
    check(mined, "deposit mined after streaming back in (state " .. mods.Auto.state .. ")")
    eq(#mods.Ores.memory, 0, "memory entry consumed")
    mods.Auto.stop("test")
    noErrors(mods)
end)

---------------------------------------------------------------------------------- runner
local passed, failed = 0, 0
local filter = os.getenv("TEST_FILTER")
local verbose = os.getenv("TEST_VERBOSE")
for _, t in ipairs(tests) do
    if filter and not t.name:find(filter, 1, true) then goto continue end
    M.lastMods = nil
    local ok, err = pcall(t.fn)
    if ok then
        passed = passed + 1
        io.write("PASS  ", t.name, "\n")
    else
        failed = failed + 1
        io.write("FAIL  ", t.name, "\n      ", tostring(err), "\n")
        if verbose and M.lastMods then
            local entries = M.lastMods.Log.entries
            for i = math.max(1, #entries - 40), #entries do
                local e = entries[i]
                io.write(string.format("        %7.2f %-5s %-10s %s\n", e.t, e.level, e.cat, e.msg))
            end
        end
    end
    ::continue::
end
io.write(string.format("\n%d passed, %d failed, %d total\n", passed, failed, #tests))
os.exit(failed == 0 and 0 or 1)
