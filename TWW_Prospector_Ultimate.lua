--[[
    TWW PROSPECTOR ULTIMATE  v3.1.0
    Autonomous mining assistant for Roblox "The Wild West" (TWW).
    Single self-contained file for client executors (target: Xeno 1.2.1).

    Design rules
      * Only normal client interactions: Humanoid:MoveTo + PathfindingService for movement,
        Tool:Activate() (or an optional simulated mouse click) for mining, ProximityPrompt
        input for selling. No guessed RemoteEvents, no anti-cheat bypass, no concealment.
      * Nothing is "successful" unless an observable game signal confirms it
        (OreRemaining decreasing, inventory/money changing, deposit removal after progress).
      * Unknown game data is reported as unknown, never invented. Where sources disagree or nothing is
        documented, the script finds out at runtime (see Learn, Tools, Ores, Verify) instead of assuming.
      * Re-executing the script cleanly tears down every previous build first.

    What public sources say about TWW (details and links in README.md):
      * workspace.WORKSPACE_Interactables.Mining exists; older public scripts read deposits from
        Mining.OreDeposits.<group>.<Model> with an ore MeshPart named "CoalOre"/"IronOre"/...
      * Community wiki: a full inventory drops mined ore on the ground; nodes can drop gems instead;
        stores sell loot with a held [F] "Sell Loot" prompt; the backpack has 40 slots (v4.4.0).
      * The game uses its own item framework, so the pickaxe is probably not a Roblox Tool.

    Syntax note: the file deliberately sticks to the Lua 5.1 subset of Luau (no `continue`,
    no compound assignment, no type annotations) so the same file can be exercised by the
    offline mock test-suite with a stock Lua 5.1 interpreter.

    Module map (search for "==== MODULE:")
      Bootstrap/Util  Log  Session  Token  Config  Learned  Stats  Char  Input  Tools  Blacklist
      Ores  Visual  Nav  Probe  Miner  Learn  Inventory  Wallet  Sellers  Targeting  Auto  UI
      Verify  SelfTest  Main
]]

-- ==== MODULE: Bootstrap ==================================================================
local VERSION = "3.1.0"
local APP_NAME = "TWW Prospector Ultimate"
local GUI_NAME = "TWW_Prospector_Ultimate"
local VISUAL_NAME = "TWW_Prospector_Visuals"
local SESSION_KEY = "TWWProspectorSession"
local SETTINGS_KEY = "TWWProspectorUltimateSettings"
local SETTINGS_DIR = "TWWProspector"
local SETTINGS_FILE = "TWWProspector/settings.json"
local LEGACY_GUI_NAMES = {"TWW_Prospector_V1", "TWW_Prospector_V2", GUI_NAME}
local LEGACY_WORLD_NAMES = {"TWW_ProspectorRoute", VISUAL_NAME}

local unpack = table.unpack or unpack

local function getService(name)
    local ok, svc = pcall(function() return game:GetService(name) end)
    if ok and svc then return svc end
    return nil
end

local Players = getService("Players")
local RunService = getService("RunService")
local UserInputService = getService("UserInputService")
local PathfindingService = getService("PathfindingService")
local TweenService = getService("TweenService")
local HttpService = getService("HttpService")
local Workspace = workspace or getService("Workspace")

local env = _G
if type(getgenv) == "function" then
    local ok, g = pcall(getgenv)
    if ok and type(g) == "table" then env = g end
end

-- Optional executor capabilities. Every one of them is feature-detected and optional.
local Exec = {
    name = "Unknown",
    setclipboard = (type(setclipboard) == "function" and setclipboard)
        or (type(toclipboard) == "function" and toclipboard) or nil,
    writefile = type(writefile) == "function" and writefile or nil,
    readfile = type(readfile) == "function" and readfile or nil,
    isfile = type(isfile) == "function" and isfile or nil,
    makefolder = type(makefolder) == "function" and makefolder or nil,
    isfolder = type(isfolder) == "function" and isfolder or nil,
    fireproximityprompt = type(fireproximityprompt) == "function" and fireproximityprompt or nil,
    vim = nil,
}
if type(identifyexecutor) == "function" then
    pcall(function()
        local a, b = identifyexecutor()
        Exec.name = tostring(a) .. (b and (" " .. tostring(b)) or "")
    end)
end
Exec.vim = getService("VirtualInputManager")

-- Forward declarations: these modules reference each other and are assigned further down.
local Probe, Miner, Inventory, Wallet, Sellers, Targeting, Auto, UI, SelfTest, Learn, Verify

-- ==== MODULE: Util =======================================================================
local U = {}
U.now = os.clock

function U.clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

function U.round(x, step)
    step = step or 1
    return math.floor(x / step + 0.5) * step
end

function U.fmtTime(seconds)
    local s = math.max(0, math.floor(seconds or 0))
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    local sec = s % 60
    if h > 0 then return string.format("%dh %02dm %02ds", h, m, sec) end
    if m > 0 then return string.format("%dm %02ds", m, sec) end
    return string.format("%ds", sec)
end

function U.fmtDist(d)
    if not d then return "-" end
    if d == math.huge then return "inf" end
    return tostring(math.floor(d + 0.5)) .. " studs"
end

-- Number for display: integers without decimals, others with one decimal. (Luau's "%d" rejects
-- non-integer numbers, and game values such as weights may be fractional.)
function U.num(x)
    x = tonumber(x)
    if not x then return "?" end
    if x == math.floor(x) then return tostring(math.floor(x)) end
    return string.format("%.1f", x)
end

function U.fmtPct(f)
    if not f then return "-" end
    return tostring(math.floor(f * 100 + 0.5)) .. "%"
end

function U.trim(s)
    local r = string.gsub(tostring(s or ""), "^%s+", "")
    r = string.gsub(r, "%s+$", "")
    return r
end

function U.has(haystack, needle)
    return string.find(haystack, needle, 1, true) ~= nil
end

function U.titleCase(s)
    local r = string.gsub(s, "(%a)(%w*)", function(a, b) return string.upper(a) .. string.lower(b) end)
    return r
end

function U.copy(t)
    local r = {}
    for k, v in pairs(t) do r[k] = v end
    return r
end

function U.count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

function U.splitList(s)
    local out = {}
    for item in string.gmatch(tostring(s or ""), "[^,;]+") do
        local v = string.lower(U.trim(item))
        if v ~= "" then out[#out + 1] = v end
    end
    return out
end

function U.isInstance(x)
    return typeof(x) == "Instance"
end

-- True while the Instance is still parented into the DataModel tree.
function U.alive(inst)
    if typeof(inst) ~= "Instance" then return false end
    local ok, parent = pcall(function() return inst.Parent end)
    return ok and parent ~= nil
end

function U.isA(inst, class)
    if typeof(inst) ~= "Instance" then return false end
    local ok, r = pcall(function() return inst:IsA(class) end)
    return ok and r == true
end

function U.fullName(inst)
    local ok, r = pcall(function() return inst:GetFullName() end)
    if ok then return r end
    return "?"
end

function U.isDescendantOf(inst, ancestor)
    if not inst or not ancestor then return false end
    local ok, r = pcall(function() return inst:IsDescendantOf(ancestor) end)
    return ok and r == true
end

-- Model:GetPivot() is the supported way to read a model's position (WorldPivot is a property,
-- not a child Instance). BaseParts/Attachments use their own positions.
function U.positionOf(inst)
    if not U.alive(inst) then return nil end
    local ok, pos = pcall(function()
        if inst:IsA("BasePart") then return inst.Position end
        if inst:IsA("Attachment") then return inst.WorldPosition end
        if inst:IsA("Model") then return inst:GetPivot().Position end
        return nil
    end)
    if ok then return pos end
    return nil
end

-- Position of an instance or its nearest positioned ancestor (used for prompts).
function U.anchorPosition(inst)
    local node = inst
    for _ = 1, 5 do
        if not node then return nil end
        local p = U.positionOf(node)
        if p then return p end
        local ok, parent = pcall(function() return node.Parent end)
        node = ok and parent or nil
    end
    return nil
end

function U.flatDist(a, b)
    local dx, dz = a.X - b.X, a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

function U.dist(a, b)
    return (a - b).Magnitude
end

function U.vecToTable(v)
    return {x = v.X, y = v.Y, z = v.Z}
end

function U.tableToVec(t)
    if type(t) ~= "table" then return nil end
    local x, y, z = tonumber(t.x), tonumber(t.y), tonumber(t.z)
    if not (x and y and z) then return nil end
    return Vector3.new(x, y, z)
end

function U.fmtVec(v)
    if not v then return "-" end
    return string.format("%d, %d, %d", math.floor(v.X), math.floor(v.Y), math.floor(v.Z))
end

-- Parses "12/40", "12 / 40", "12 of 40" -> 12, 40
function U.parseFraction(text)
    local a, b = string.match(tostring(text or ""), "(%d+)%s*/%s*(%d+)")
    if not a then a, b = string.match(tostring(text or ""), "(%d+)%s+of%s+(%d+)") end
    a, b = tonumber(a), tonumber(b)
    if a and b and b > 0 then return a, b end
    return nil
end

-- Parses "$1,234.50" -> 1234.5
function U.parseMoney(text)
    local s = string.match(tostring(text or ""), "%$%s*([%d,]+%.?%d*)")
    if not s then return nil end
    s = string.gsub(s, ",", "")
    return tonumber(s)
end

-- Shortest distance from a point to an oriented box (CFrame + Size). Used for mining range.
function U.distanceToBox(point, boxCFrame, boxSize)
    local ok, localPoint = pcall(function() return boxCFrame:PointToObjectSpace(point) end)
    if not ok or not localPoint then return U.dist(point, boxCFrame.Position) end
    local hx, hy, hz = boxSize.X / 2, boxSize.Y / 2, boxSize.Z / 2
    local dx = math.max(math.abs(localPoint.X) - hx, 0)
    local dy = math.max(math.abs(localPoint.Y) - hy, 0)
    local dz = math.max(math.abs(localPoint.Z) - hz, 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- ==== MODULE: Log ========================================================================
-- Ring-style event log with per-key throttling so repeated warnings cannot spam the console.
local Log = {
    entries = {},
    max = 400,
    version = 0,
    throttle = {},
    throttleCount = 0,
    debugEnabled = false,
    consoleLevel = 2,
    counts = {DEBUG = 0, INFO = 0, WARN = 0, ERROR = 0},
}
local LOG_LEVELS = {DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4}

function Log.add(level, category, message, key, window)
    if level == "DEBUG" and not Log.debugEnabled then return end
    local now = U.now()
    message = tostring(message)
    if key then
        local t = Log.throttle[key]
        if t and now - t.last < (window or 8) then
            t.suppressed = t.suppressed + 1
            return
        end
        if t and t.suppressed > 0 then
            message = message .. string.format("  (+%d similar suppressed)", t.suppressed)
        end
        if not t then Log.throttleCount = Log.throttleCount + 1 end
        Log.throttle[key] = {last = now, suppressed = 0}
        if Log.throttleCount > 300 then Log.pruneThrottle(now) end
    end
    local stamp = ""
    pcall(function() stamp = os.date("%H:%M:%S") end)
    local entries = Log.entries
    entries[#entries + 1] = {t = now, stamp = stamp, level = level, cat = category, msg = message}
    if #entries > Log.max + 100 then
        local keep = {}
        for i = #entries - Log.max + 1, #entries do keep[#keep + 1] = entries[i] end
        Log.entries = keep
    end
    Log.counts[level] = (Log.counts[level] or 0) + 1
    Log.version = Log.version + 1
    if (LOG_LEVELS[level] or 2) >= Log.consoleLevel then
        local line = string.format("[Prospector][%s][%s] %s", level, category, message)
        if level == "WARN" or level == "ERROR" then warn(line) else print(line) end
    end
end

function Log.pruneThrottle(now)
    local n = 0
    for k, t in pairs(Log.throttle) do
        if now - t.last > 60 then Log.throttle[k] = nil else n = n + 1 end
    end
    Log.throttleCount = n
end

function Log.debug(cat, msg, key, window) Log.add("DEBUG", cat, msg, key, window) end
function Log.info(cat, msg, key, window) Log.add("INFO", cat, msg, key, window) end
function Log.warn(cat, msg, key, window) Log.add("WARN", cat, msg, key, window) end
function Log.error(cat, msg, key, window) Log.add("ERROR", cat, msg, key, window) end

-- ==== MODULE: Session ====================================================================
-- Registry of every connection, thread, instance and cleanup created by this build. Destroying
-- the session is the single place where everything is torn down (used on close and reinjection).
local Session = {}
Session.__index = Session

function Session.new()
    return setmetatable({
        id = tostring(math.random(100000, 999999)) .. "-" .. tostring(math.floor(U.now() * 1000) % 100000),
        alive = true,
        conns = {},
        threads = {},
        instances = {},
        cleanups = {},
        startedAt = U.now(),
    }, Session)
end

-- Connect a signal; the handler is skipped once the session is dead and errors are logged.
function Session:connect(signal, fn, label)
    if not self.alive or signal == nil then return nil end
    local session = self
    local ok, conn = pcall(function()
        return signal:Connect(function(...)
            if not session.alive then return end
            local success, err = pcall(fn, ...)
            if not success then
                Log.error("Event", tostring(label or "callback") .. " failed: " .. tostring(err),
                    "cb:" .. tostring(label), 10)
            end
        end)
    end)
    if ok and conn then
        self.conns[#self.conns + 1] = conn
        return conn
    end
    Log.warn("Session", "Could not connect " .. tostring(label) .. ": " .. tostring(conn), "conn:" .. tostring(label))
    return nil
end

function Session:disconnect(conn)
    if not conn then return end
    pcall(function() conn:Disconnect() end)
    for i = #self.conns, 1, -1 do
        if self.conns[i] == conn then table.remove(self.conns, i) break end
    end
end

-- Spawn a tracked thread. Errors are logged, never silently dropped.
function Session:spawn(label, fn, ...)
    if not self.alive then return nil end
    local session = self
    local args = {...}
    local nargs = select("#", ...)
    local thread
    thread = task.spawn(function()
        local ok, err = pcall(fn, unpack(args, 1, nargs))
        if not ok and session.alive then
            Log.error("Thread", tostring(label) .. " crashed: " .. tostring(err))
        end
        if thread then session.threads[thread] = nil end
    end)
    if thread and coroutine.status(thread) ~= "dead" then
        self.threads[thread] = label or true
    end
    return thread
end

function Session:give(instance)
    if instance then self.instances[#self.instances + 1] = instance end
    return instance
end

function Session:onCleanup(fn)
    self.cleanups[#self.cleanups + 1] = fn
end

function Session:destroy(reason)
    if not self.alive then return end
    self.alive = false
    Log.info("Session", "Shutting down (" .. tostring(reason or "requested") .. ")")
    for i = #self.cleanups, 1, -1 do
        local ok, err = pcall(self.cleanups[i])
        if not ok then Log.warn("Session", "Cleanup step failed: " .. tostring(err)) end
    end
    self.cleanups = {}
    for _, conn in ipairs(self.conns) do pcall(function() conn:Disconnect() end) end
    self.conns = {}
    local current = coroutine.running()
    for thread in pairs(self.threads) do
        if thread ~= current then pcall(task.cancel, thread) end
    end
    self.threads = {}
    for i = #self.instances, 1, -1 do
        pcall(function() self.instances[i]:Destroy() end)
    end
    self.instances = {}
end

function Session:stats()
    local threads = 0
    for _ in pairs(self.threads) do threads = threads + 1 end
    return #self.conns, threads, #self.instances
end

local SESSION = Session.new()

-- ==== MODULE: Token ======================================================================
-- Cooperative cancellation. Every long operation receives a token and polls it.
local Token = {}
Token.__index = Token

function Token.new(parent, timeout)
    return setmetatable({
        parent = parent,
        cancelled = false,
        reason = nil,
        deadline = timeout and (U.now() + timeout) or nil,
    }, Token)
end

function Token:cancel(reason)
    if not self.cancelled then
        self.cancelled = true
        self.reason = reason or "cancelled"
    end
end

function Token:dead()
    if self.cancelled then return true end
    if not SESSION.alive then self:cancel("session_ended") return true end
    if self.deadline and U.now() > self.deadline then self:cancel("timeout") return true end
    local p = self.parent
    if p and p:dead() then self:cancel(p.reason) return true end
    return false
end

-- Sleeps in short slices; returns false as soon as the token is cancelled.
function Token:sleep(seconds)
    local stop = U.now() + (seconds or 0)
    repeat
        if self:dead() then return false end
        local remaining = stop - U.now()
        task.wait(math.min(math.max(remaining, 0), 0.2))
    until U.now() >= stop
    return not self:dead()
end

-- ==== MODULE: Config =====================================================================
-- Every persisted setting is declared here with type and range; loaded values are validated.
local CONFIG_SCHEMA = {
    selected = {"table", {}},
    priorities = {"table", {}},
    autoSell = {"boolean", true},
    sellThreshold = {"number", 0.9, 0.3, 1.0},
    sellAfterDeposits = {"number", 0, 0, 200},
    skipDepleted = {"boolean", true},
    allowUnknownRemaining = {"boolean", true},
    avoidContested = {"boolean", true},
    interactMethod = {"enum", "Auto", nil, nil, {"Auto", "Tool", "Click", "Both"}},
    pickaxeSlot = {"number", 0, 0, 9},
    learned = {"table", {}},
    swingInterval = {"number", 0.85, 0.25, 5},
    stallTimeout = {"number", 15, 5, 90},
    mineTimeout = {"number", 150, 20, 900},
    mineRange = {"number", 8, 3, 20},
    aimCamera = {"boolean", true},
    showRoute = {"boolean", true},
    highlightTarget = {"boolean", true},
    maxLegLength = {"number", 220, 60, 600},
    agentRadius = {"number", 2, 1, 5},
    agentHeight = {"number", 5, 3, 8},
    agentCanJump = {"boolean", true},
    agentCanClimb = {"boolean", false},
    waypointSpacing = {"number", 4, 2, 12},
    stuckTime = {"number", 1.6, 0.6, 6},
    maxReplans = {"number", 6, 1, 20},
    pathRecalcMinInterval = {"number", 0.75, 0.1, 5},
    validateCandidates = {"number", 4, 1, 10},
    rememberSites = {"boolean", true},
    scanInterval = {"number", 4, 1, 30},
    uiRefreshRate = {"number", 4, 1, 15},
    sellerScanInterval = {"number", 25, 5, 300},
    blacklistBase = {"number", 30, 5, 300},
    blacklistMax = {"number", 600, 30, 3600},
    pickaxePatterns = {"string", "pickaxe,pick"},
    preferredPickaxe = {"string", ""},
    sellPoint = {"table", nil},
    sellerChoice = {"string", ""},
    useFirePrompt = {"boolean", false},
    clickSellDialog = {"boolean", false},
    continueAfterUnverifiedSale = {"boolean", true},
    orePaths = {"string", "WORKSPACE_Interactables/Mining"},
    uiScale = {"number", 1, 0.7, 1.5},
    accent = {"enum", "Teal", nil, nil, {"Teal", "Amber", "Azure", "Violet", "Rose"}},
    toggleKey = {"enum", "RightControl", nil, nil, {"RightControl", "RightShift", "Insert", "F6", "F7", "F8"}},
    windowPos = {"table", nil},
    collapsed = {"boolean", false},
    debugLog = {"boolean", false},
    consoleLog = {"boolean", true},
}

local Config = {values = {}, dirty = false, lastSave = 0, listeners = {}, source = "defaults"}

local function validateSetting(key, value)
    local spec = CONFIG_SCHEMA[key]
    if not spec then return false, nil end
    local kind = spec[1]
    if kind == "number" then
        local n = tonumber(value)
        if not n or n ~= n then return false, nil end
        return true, U.clamp(n, spec[3], spec[4])
    elseif kind == "boolean" then
        if type(value) == "boolean" then return true, value end
        return false, nil
    elseif kind == "string" then
        if type(value) == "string" and #value <= 400 then return true, value end
        return false, nil
    elseif kind == "enum" then
        for _, option in ipairs(spec[5]) do
            if option == value then return true, value end
        end
        return false, nil
    elseif kind == "table" then
        if type(value) == "table" then return true, value end
        if value == nil then return true, nil end
        return false, nil
    end
    return false, nil
end

function Config.get(key)
    return Config.values[key]
end

function Config.set(key, value)
    local ok, clean = validateSetting(key, value)
    if not ok then
        Log.warn("Config", "Rejected invalid value for " .. tostring(key) .. ": " .. tostring(value))
        return false
    end
    Config.values[key] = clean
    Config.dirty = true
    for _, fn in ipairs(Config.listeners) do pcall(fn, key, clean) end
    return true
end

function Config.onChange(fn)
    Config.listeners[#Config.listeners + 1] = fn
end

local function applySavedSettings(saved, label)
    if type(saved) ~= "table" then return 0 end
    local applied = 0
    for key, value in pairs(saved) do
        if CONFIG_SCHEMA[key] then
            local ok, clean = validateSetting(key, value)
            if ok then
                Config.values[key] = clean
                applied = applied + 1
            end
        end
    end
    if applied > 0 then Config.source = label end
    return applied
end

function Config.load()
    for key, spec in pairs(CONFIG_SCHEMA) do
        local default = spec[2]
        if type(default) == "table" then default = U.copy(default) end
        Config.values[key] = default
    end
    -- 1) settings from an earlier injection in this game session
    local fromEnv = applySavedSettings(env[SETTINGS_KEY], "previous injection")
    -- 2) settings file (optional executor filesystem API)
    if fromEnv == 0 and Exec.readfile and HttpService then
        local ok, decoded = pcall(function()
            if Exec.isfile and not Exec.isfile(SETTINGS_FILE) then return nil end
            return HttpService:JSONDecode(Exec.readfile(SETTINGS_FILE))
        end)
        if ok and type(decoded) == "table" then applySavedSettings(decoded, "settings file") end
    end
    -- 3) migrate the v2.0 settings table when nothing newer exists
    local legacy = env.TWWProspectorSettings
    if Config.source == "defaults" and type(legacy) == "table" then
        if type(legacy.selected) == "table" then Config.values.selected = U.copy(legacy.selected) end
        if type(legacy.autoSell) == "boolean" then Config.values.autoSell = legacy.autoSell end
        if type(legacy.displayRoute) == "boolean" then Config.values.showRoute = legacy.displayRoute end
        if type(legacy.aimCamera) == "boolean" then Config.values.aimCamera = legacy.aimCamera end
        if typeof(legacy.sellPoint) == "Vector3" then Config.values.sellPoint = U.vecToTable(legacy.sellPoint) end
        Config.source = "migrated v2.0 settings"
    end
    if type(Config.values.selected) ~= "table" then Config.values.selected = {} end
    if type(Config.values.priorities) ~= "table" then Config.values.priorities = {} end
    Log.debugEnabled = Config.values.debugLog
    Log.consoleLevel = Config.values.consoleLog and 2 or 3
end

function Config.save(force)
    if not force and not Config.dirty then return end
    Config.dirty = false
    Config.lastSave = U.now()
    env[SETTINGS_KEY] = U.copy(Config.values)
    if Exec.writefile and HttpService then
        local ok, err = pcall(function()
            if Exec.makefolder and Exec.isfolder and not Exec.isfolder(SETTINGS_DIR) then
                Exec.makefolder(SETTINGS_DIR)
            end
            Exec.writefile(SETTINGS_FILE, HttpService:JSONEncode(Config.values))
        end)
        if not ok then Log.debug("Config", "Settings file not written: " .. tostring(err), "cfgwrite", 60) end
    end
end

-- ==== MODULE: Learned ====================================================================
-- Knowledge the script discovers about the current place at runtime (hotbar slot, working
-- interaction method, inventory counter, money source, movement driver, sellers that did / did not
-- pay). Stored per PlaceId inside the persisted settings, so it survives reinjection and restarts.
local Learned = {}

function Learned.place()
    local key = "place"
    pcall(function() key = tostring(game.PlaceId) end)
    local all = Config.values.learned
    if type(all) ~= "table" then
        all = {}
        Config.values.learned = all
    end
    if type(all[key]) ~= "table" then all[key] = {} end
    return all[key]
end

function Learned.get(key)
    return Learned.place()[key]
end

function Learned.set(key, value)
    local place = Learned.place()
    if place[key] ~= value then
        place[key] = value
        Config.dirty = true
    end
end

function Learned.clear()
    local key = "place"
    pcall(function() key = tostring(game.PlaceId) end)
    if type(Config.values.learned) == "table" then Config.values.learned[key] = {} end
    Config.dirty = true
end

-- ==== MODULE: Stats ======================================================================
local Stats = {}

function Stats.reset()
    Stats.runtime = 0
    Stats.attempts = 0
    Stats.successAttempts = 0
    Stats.failedAttempts = 0
    Stats.depleted = 0
    Stats.yields = 0
    Stats.yieldsByKind = {}
    Stats.swings = 0
    Stats.failedInteractions = 0
    Stats.travelTime = 0
    Stats.miningTime = 0
    Stats.sellingTime = 0
    Stats.otherTime = 0
    Stats.stuckEvents = 0
    Stats.recoveries = 0
    Stats.replans = 0
    Stats.pathsComputed = 0
    Stats.pathFailures = 0
    Stats.unreachable = 0
    Stats.sales = 0
    Stats.salesUnverified = 0
    Stats.salesFailed = 0
    Stats.moneyEarned = 0
    Stats.deaths = 0
    Stats.errors = 0
    Stats.resetAt = U.now()
end
Stats.reset()

local STATE_BUCKET = {
    PATHFINDING = "travelTime", TRAVELING = "travelTime", APPROACHING = "travelTime",
    TRAVELING_TO_SELLER = "travelTime", EQUIPPING = "miningTime", MINING = "miningTime",
    FINDING_SELLER = "sellingTime", SELLING = "sellingTime",
}

function Stats.accumulate(state, dt)
    if dt <= 0 then return end
    local bucket = STATE_BUCKET[state] or "otherTime"
    Stats[bucket] = Stats[bucket] + dt
end

function Stats.recordYield(kind, amount)
    amount = amount or 1
    Stats.yields = Stats.yields + amount
    Stats.yieldsByKind[kind] = (Stats.yieldsByKind[kind] or 0) + amount
end

-- ==== MODULE: Char =======================================================================
-- Tracks the LocalPlayer character across deaths/respawns. Never waits indefinitely.
local LocalPlayer = nil   -- resolved in Main
local PlayerGui = nil     -- resolved in Main (may arrive late)

local Char = {
    character = nil,
    humanoid = nil,
    root = nil,
    lifeId = 0,
    diedConn = nil,
    deaths = 0,
    status = "Waiting for character",
    onDied = {},
    onReady = {},
}

local function fireAll(list, ...)
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then Log.error("Character", "Listener failed: " .. tostring(err), "charlistener", 10) end
    end
end

function Char.bind(character)
    Char.lifeId = Char.lifeId + 1
    local life = Char.lifeId
    Char.character, Char.humanoid, Char.root = character, nil, nil
    if Char.diedConn then SESSION:disconnect(Char.diedConn) Char.diedConn = nil end
    if not character then Char.status = "No character" return end
    Char.status = "Loading character"
    SESSION:spawn("Char.bind", function()
        local deadline = U.now() + 15
        while SESSION.alive and life == Char.lifeId and U.now() < deadline do
            local hum = character:FindFirstChildOfClass("Humanoid")
            local root = character:FindFirstChild("HumanoidRootPart")
                or (hum and hum.RootPart) or character.PrimaryPart
            if hum and root then
                Char.humanoid, Char.root = hum, root
                Char.diedConn = SESSION:connect(hum.Died, function()
                    if life ~= Char.lifeId then return end
                    Char.deaths = Char.deaths + 1
                    Char.status = "Dead - waiting for respawn"
                    Log.warn("Character", "Character died; automation will wait for respawn")
                    fireAll(Char.onDied, life)
                end, "Humanoid.Died")
                Char.status = "Ready"
                Log.info("Character", "Character ready (" .. tostring(root.Name) .. ")", "charready", 2)
                fireAll(Char.onReady, life)
                return
            end
            task.wait(0.2)
        end
        if life == Char.lifeId and SESSION.alive then
            Char.status = "Humanoid/root not found"
            Log.warn("Character", "Humanoid or root part not found within 15s", "charwait", 30)
        end
    end)
end

function Char.init()
    if not LocalPlayer then return end
    SESSION:connect(LocalPlayer.CharacterAdded, function(character) Char.bind(character) end, "CharacterAdded")
    SESSION:connect(LocalPlayer.CharacterRemoving, function(character)
        if character == Char.character then
            Char.lifeId = Char.lifeId + 1
            Char.character, Char.humanoid, Char.root = nil, nil, nil
            Char.status = "Character removed"
        end
    end, "CharacterRemoving")
    if LocalPlayer.Character then Char.bind(LocalPlayer.Character) end
end

-- Returns character, humanoid, root only when all exist and the humanoid is alive.
function Char.get()
    local c, h, r = Char.character, Char.humanoid, Char.root
    if not (c and h and r) then return nil end
    if not U.alive(r) or not U.alive(h) then return nil end
    local ok, health = pcall(function() return h.Health end)
    if not ok or not health or health <= 0 then return nil end
    return c, h, r
end

function Char.position()
    local _, _, r = Char.get()
    return r and r.Position or nil
end

-- "ok" | "seated" | "no_control" | "dead"
function Char.controlState()
    local c, h, r = Char.get()
    if not c then return "dead" end
    local ok, state = pcall(function()
        if h.Sit or h.SeatPart then return "seated" end
        if h.PlatformStand or r.Anchored then return "no_control" end
        if h.WalkSpeed <= 0.05 then return "no_control" end
        return "ok"
    end)
    if ok then return state end
    return "ok"
end

function Char.stopMoving()
    local _, h, r = Char.get()
    if not h then return end
    pcall(function() h:MoveTo(r.Position) end)
    pcall(function() h:Move(Vector3.new(0, 0, 0), false) end)
end

function Char.jump()
    local _, h = Char.get()
    if h then pcall(function() h.Jump = true end) end
end

-- Waits for a living character; returns true when ready.
function Char.waitAlive(token, timeout)
    local deadline = U.now() + (timeout or 30)
    while U.now() < deadline do
        if token and token:dead() then return false end
        if Char.get() then return true end
        task.wait(0.25)
    end
    return Char.get() ~= nil
end

-- ==== MODULE: Input ======================================================================
-- Simulated player input through VirtualInputManager (feature-detected). Used only for things a
-- player does by hand: hotbar number keys, clicking on a deposit, holding a prompt's key.
local Input = {}

function Input.available()
    return Exec.vim ~= nil
end

function Input.key(keyCode, hold, token)
    if not Exec.vim or not keyCode then return false, "VirtualInputManager unavailable" end
    local ok, err = pcall(function() Exec.vim:SendKeyEvent(true, keyCode, false, game) end)
    if not ok then return false, err end
    if token then token:sleep(hold or 0.06) else task.wait(hold or 0.06) end
    pcall(function() Exec.vim:SendKeyEvent(false, keyCode, false, game) end)
    return true
end

-- True when viewport point (x, y) lies on this script's own window (a click there would hit the GUI).
local function overOwnWindow(x, y)
    local w = UI and UI.window
    if not w or not UI.root or not UI.root.Enabled or not w.Visible then return false end
    local ok, inside = pcall(function()
        local inset = Vector2.new(0, 0)
        local gs = getService("GuiService")
        if gs and not UI.root.IgnoreGuiInset then inset = gs:GetGuiInset() end
        local p, s = w.AbsolutePosition + inset, w.AbsoluteSize
        return x >= p.X and x <= p.X + s.X and y >= p.Y and y <= p.Y + s.Y
    end)
    return ok and inside
end

-- Left click at viewport coordinates; the own window is briefly hidden if it covers the point.
function Input.click(x, y)
    if not Exec.vim then return false, "VirtualInputManager unavailable" end
    local hidden = overOwnWindow(x, y)
    if hidden then pcall(function() UI.root.Enabled = false end) end
    local ok, err = pcall(function()
        pcall(function() Exec.vim:SendMouseMoveEvent(x, y, game) end)
        Exec.vim:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(0.05)
        Exec.vim:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
    if hidden then pcall(function() UI.root.Enabled = true end) end
    return ok, err
end

local DIGIT_KEYS = {"One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine"}
function Input.digitKey(n)
    local name = DIGIT_KEYS[n]
    if not name then return nil end
    local ok, key = pcall(function() return Enum.KeyCode[name] end)
    return ok and key or nil
end

-- ==== MODULE: Tools ======================================================================
-- Public TWW scripts show a custom item framework (ReplicatedStorage...Character.Items, equipped via
-- PlayerCharacter:EquipItem), so the pickaxe is probably NOT a Roblox Tool. Equip paths, in order:
--   1. a Roblox Tool matching the name patterns            -> Humanoid:EquipTool
--   2. a game item that is already in hand                 -> pickaxe-named model/part on the character
--      (or on its copy under workspace.WORKSPACE_Entities.Players, also seen in public scripts)
--   3. a hotbar number key (Settings slot, learned slot, slot found in the hotbar UI, else 1-9 tried
--      once every 5 minutes) pressed through VirtualInputManager, confirmed by observing the item
-- Handle: {kind = "tool", tool = Tool} | {kind = "custom", visual = Instance|nil, slot = n, assumed = bool}
local Tools = {status = "Not checked", lastName = nil, lastTrial = -1000}

function Tools.matches(name)
    local lname = string.lower(tostring(name or ""))
    local preferred = string.lower(U.trim(Config.get("preferredPickaxe") or ""))
    if preferred ~= "" and lname == preferred then return true end
    for _, pattern in ipairs(U.splitList(Config.get("pickaxePatterns"))) do
        if U.has(lname, pattern) then return true end
    end
    return false
end

function Tools.score(tool)
    local name = string.lower(tool.Name)
    local preferred = string.lower(U.trim(Config.get("preferredPickaxe") or ""))
    if preferred ~= "" and name == preferred then return 10000 end
    local tip = ""
    pcall(function() tip = string.lower(tool.ToolTip or "") end)
    if not (Tools.matches(name) or (tip ~= "" and Tools.matches(tip))) then return nil end
    local score = 100
    local tier = tonumber(string.match(name, "tier%s*(%d+)") or string.match(name, "(%d+)"))
    if tier then score = score + math.min(tier, 50) * 10 end
    return score
end

-- Best Roblox Tool pickaxe and where it is ("equipped" | "backpack").
function Tools.find()
    local c = Char.get()
    if not c or not LocalPlayer then return nil, "no_character" end
    local best, bestScore, where = nil, nil, nil
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    for _, container in ipairs({c, backpack}) do
        if container then
            for _, child in ipairs(container:GetChildren()) do
                if child:IsA("Tool") then
                    local s = Tools.score(child)
                    if s then
                        if container == c then s = s + 5 end
                        if not bestScore or s > bestScore then
                            best, bestScore, where = child, s, (container == c) and "equipped" or "backpack"
                        end
                    end
                end
            end
        end
    end
    return best, where
end

function Tools.characterModels()
    local list = {}
    if Char.character then list[1] = Char.character end
    local entities = Workspace:FindFirstChild("WORKSPACE_Entities")
    local players = entities and entities:FindFirstChild("Players")
    local rep = LocalPlayer and players and players:FindFirstChild(LocalPlayer.Name)
    if rep and rep ~= Char.character then list[#list + 1] = rep end
    return list
end

-- A pickaxe-named part/model/tool currently attached to the character (custom items included).
function Tools.equippedVisual()
    for _, model in ipairs(Tools.characterModels()) do
        local ok, list = pcall(function() return model:GetDescendants() end)
        if ok then
            for i, d in ipairs(list) do
                if i > 400 then break end
                if (d:IsA("BasePart") or d:IsA("Model") or d:IsA("Tool") or d:IsA("Accessory")) and Tools.matches(d.Name) then
                    return d
                end
            end
        end
    end
    return nil
end

local HOTBAR_WORDS = {"hotbar", "toolbar", "quickbar", "itembar", "slots", "weaponwheel", "backpack"}

-- Hotbar slot number of a pickaxe-labelled element inside a hotbar-like frame, if the UI shows one.
function Tools.hotbarSlotFromUI()
    if not PlayerGui then return nil end
    local ok, list = pcall(function() return PlayerGui:GetDescendants() end)
    if not ok then return nil end
    for i, inst in ipairs(list) do
        if i > 6000 then break end
        if inst:IsA("GuiObject") and not U.isDescendantOf(inst, UI and UI.root) then
            local text = (inst:IsA("TextLabel") or inst:IsA("TextButton")) and (inst.Text or "") or ""
            if Tools.matches(inst.Name) or (text ~= "" and Tools.matches(text)) then
                local node, inBar = inst, false
                for _ = 1, 6 do
                    node = node.Parent
                    if not node or node == PlayerGui then break end
                    local lname = string.lower(node.Name)
                    for _, w in ipairs(HOTBAR_WORDS) do if U.has(lname, w) then inBar = true end end
                end
                if inBar then
                    local slot = inst
                    for _ = 1, 4 do
                        if not slot or slot == PlayerGui then break end
                        local n = tonumber(string.match(slot.Name, "(%d+)%s*$"))
                        if n and n >= 1 and n <= 9 then return n end
                        for _, c in ipairs(slot:GetChildren()) do
                            if c:IsA("TextLabel") then
                                local d = tonumber(string.match(c.Text or "", "^%s*(%d)%s*$"))
                                if d and d >= 1 then return d end
                            end
                        end
                        slot = slot.Parent
                    end
                end
            end
        end
    end
    return nil
end

local function pressSlot(slot, token)
    local key = Input.digitKey(slot)
    if not key then return false end
    Input.key(key, 0.06, token)
    local deadline = U.now() + 1.2
    while U.now() < deadline do
        if token and token:dead() then return false end
        if Tools.equippedVisual() then return true end
        task.wait(0.1)
    end
    return false
end

local function slotSucceeded(slot)
    Learned.set("hotbarSlot", slot)
    local visual = Tools.equippedVisual()
    Tools.status = "Equipped via hotbar key " .. slot .. (visual and (": " .. visual.Name) or "")
    Tools.lastName = visual and visual.Name or ("hotbar " .. slot)
    Log.info("Tools", Tools.status, "hotbar:" .. slot, 30)
    return {kind = "custom", visual = visual, slot = slot}
end

function Tools.isEquipped(handle)
    if not handle then return false end
    if handle.kind == "tool" then
        local c = Char.get()
        return c ~= nil and U.alive(handle.tool) and handle.tool.Parent == c
    end
    if handle.assumed then return true end
    return Tools.equippedVisual() ~= nil
end

-- True when some pickaxe is obtainable (used by auto-resume checks).
function Tools.available()
    return (Tools.find()) ~= nil or Tools.equippedVisual() ~= nil
        or (Input.available() and U.now() - Tools.lastTrial > 300)
end

local function equipRobloxTool(tool, where, token)
    Tools.lastName = tool.Name
    if where == "equipped" then
        Tools.status = "Equipped: " .. tool.Name
        return {kind = "tool", tool = tool}
    end
    local c, h = Char.get()
    if not h then return nil, "no_character" end
    pcall(function() h:UnequipTools() end)
    local ok, err = pcall(function() h:EquipTool(tool) end)
    if not ok then Log.warn("Tools", "EquipTool failed: " .. tostring(err), "equipfail", 10) end
    local deadline = U.now() + 2.5
    while U.now() < deadline do
        if token and token:dead() then return nil, "cancelled" end
        if tool.Parent == c then
            Tools.status = "Equipped: " .. tool.Name
            Log.info("Tools", "Equipped " .. tool.Name, "equipped:" .. tool.Name, 20)
            return {kind = "tool", tool = tool}
        end
        task.wait(0.1)
    end
    Tools.status = "Equip did not take effect"
    return nil, "equip_failed"
end

function Tools.ensureEquipped(token)
    local tool, where = Tools.find()
    if tool then return equipRobloxTool(tool, where, token) end
    local visual = Tools.equippedVisual()
    if visual then
        Tools.status = "In hand (game item): " .. visual.Name
        Tools.lastName = visual.Name
        return {kind = "custom", visual = visual}
    end
    if not Input.available() then
        Tools.status = "Pickaxe is not a Roblox Tool and no input API is available to press its hotbar key"
        return nil, "manual_equip"
    end
    local configured = Config.get("pickaxeSlot")
    local tried = {}
    for _, slot in ipairs({configured > 0 and configured or nil, Learned.get("hotbarSlot"), Tools.hotbarSlotFromUI()}) do
        if slot and not tried[slot] then
            tried[slot] = true
            if pressSlot(slot, token) then return slotSucceeded(slot) end
            if token and token:dead() then return nil, "cancelled" end
        end
    end
    if configured > 0 then
        -- The user named the slot but the item cannot be seen on the character: trust the setting;
        -- mining verification decides whether it actually works.
        Tools.status = "Pressed hotbar key " .. configured .. " (pickaxe not visible on the character)"
        Log.warn("Tools", Tools.status, "assumedslot", 60)
        return {kind = "custom", slot = configured, assumed = true}
    end
    if U.now() - Tools.lastTrial > 300 then
        Tools.lastTrial = U.now()
        Tools.status = "Trying hotbar keys 1-9 to find the pickaxe"
        Log.info("Tools", Tools.status)
        for slot = 1, 9 do
            if token and token:dead() then return nil, "cancelled" end
            if not tried[slot] and pressSlot(slot, token) then return slotSucceeded(slot) end
        end
    end
    Tools.status = "No pickaxe found (no Roblox Tool, none in hand, no hotbar key equipped one)"
    return nil, "no_pickaxe"
end

-- ==== MODULE: Blacklist ==================================================================
-- Temporary exclusion with exponential back-off; expired entries are reconsidered automatically.
local Blacklist = {}
Blacklist.__index = Blacklist

function Blacklist.new(name)
    return setmetatable({name = name, map = setmetatable({}, {__mode = "k"})}, Blacklist)
end

function Blacklist:mark(key, reason, weight)
    if key == nil then return 0 end
    local e = self.map[key] or {failures = 0}
    e.failures = e.failures + (weight or 1)
    local duration = math.min(Config.get("blacklistBase") * 2 ^ (math.max(e.failures, 1) - 1),
        Config.get("blacklistMax"))
    e.untilT = U.now() + duration
    e.reason = reason
    self.map[key] = e
    return duration
end

function Blacklist:blocked(key)
    local e = key ~= nil and self.map[key] or nil
    if e and e.untilT and U.now() < e.untilT then return true, e.untilT - U.now(), e.reason end
    return false
end

function Blacklist:failures(key)
    local e = key ~= nil and self.map[key] or nil
    return e and e.failures or 0
end

function Blacklist:success(key)
    local e = key ~= nil and self.map[key] or nil
    if e then
        e.failures = math.max(0, e.failures - 1)
        e.untilT = nil
    end
end

function Blacklist:clear()
    self.map = setmetatable({}, {__mode = "k"})
end

function Blacklist:activeCount()
    local n, now = 0, U.now()
    for _, e in pairs(self.map) do
        if e.untilT and now < e.untilT then n = n + 1 end
    end
    return n
end

-- ==== MODULE: Ores =======================================================================
-- Event-driven ore registry. Two layouts are supported because two sources disagree:
--   A) Mining/<OreType>/<Deposit model with DepositInfo.OreRemaining>          (your v2.0 script)
--   B) Mining/OreDeposits/<group Folder>/<Deposit Model>{MeshPart "CoalOre"}    (public TWW scripts:
--      LightMildTH/RobloxScripts TheWildWest.lua, yasinert12 ore ESP). In B an exhausted node loses
--      its ore MeshPart, which is how depletion/respawn is tracked when OreRemaining does not exist.
-- The ore type comes from deposit-level evidence first (type attribute, ore mesh name, deposit name)
-- and only then from folder names. The root is resolved from configurable paths, then a folder named
-- like "Mining", then the common ancestor of ore-named parts. Containers are watched with
-- ChildAdded/ChildRemoved and values with .Changed; nothing rescans Workspace per frame.
local Ores = {
    root = nil,
    rootLabel = "Not found",
    rootHow = "-",
    status = "Not scanned",
    kinds = {},
    kindList = {},
    deposits = {},
    depositCount = 0,
    version = 0,
    dataVersion = 0,
    memory = {},
    containers = {},
    rootConns = {},
    lastResolve = -1000,
    lastOreScan = -1000,
    lastStats = 0,
    meshLayout = false,
    kindStrikes = {},
    suspendedKinds = {},
    blacklist = Blacklist.new("deposits"),
    remainingListeners = {},
}

local KIND_NOISE = {
    deposits = true, deposit = true, nodes = true, node = true, ores = true, ore = true,
    rocks = true, rock = true, veins = true, vein = true, spawns = true, spawn = true, folder = true,
}
local GENERIC_NAMES = {
    model = true, part = true, meshpart = true, mesh = true, union = true, group = true, cluster = true,
    mining = true, interactables = true, workspace = true, ["workspace interactables"] = true,
}
-- Ore and gem words (community wiki "Ores and Gems"); used to read types out of instance names.
local ORE_WORDS = {"coal", "copper", "zinc", "iron", "limestone", "silver", "gold", "quartz", "sulfur",
    "sulphur", "nitre", "saltpeter", "nickel", "platinum", "diamond", "ruby", "emerald", "sapphire",
    "amethyst", "topaz", "opal", "jade"}
local GEM_WORDS = {"diamond", "ruby", "emerald", "sapphire", "amethyst", "topaz", "opal", "jade", "gem"}
-- Minimum pickaxe tier per ore according to the community wiki (game version 3.7.5). Informational.
Ores.TIERS = {Coal = 1, Copper = 1, Zinc = 2, Iron = 3, Limestone = 3, Silver = 4, Gold = 5}
local ROOT_FALLBACKS = {"WORKSPACE_Interactables/Mining", "Interactables/Mining", "Mining", "Ores", "OreDeposits"}
local KIND_ATTRS = {"OreType", "Ore", "OreName", "Resource", "Mineral", "Type", "Kind"}
local MAX_CONTAINER_DEPTH = 4

function Ores.oreWordKind(name)
    local lname = string.lower(tostring(name or ""))
    for _, w in ipairs(ORE_WORDS) do
        if U.has(lname, w) then return U.titleCase(w) end
    end
    return nil
end

function Ores.isGemOrOreName(name)
    local lname = string.lower(tostring(name or ""))
    if Ores.oreWordKind(lname) then return true end
    for _, w in ipairs(GEM_WORDS) do if U.has(lname, w) then return true end end
    return string.match(tostring(name or ""), "Ore%d*$") ~= nil or lname == "ore"
end

-- Normalised, non-generic type name or nil: "CopperOre" -> "Copper", "OreDeposits" -> nil, "Node12" -> nil.
function Ores.specificKind(raw)
    local ore = Ores.oreWordKind(raw)
    if ore then return ore end
    local s = string.gsub(tostring(raw or ""), "[_%-%.]", " ")
    s = string.gsub(s, "(%l)(%u)", "%1 %2")
    local words = {}
    for word in string.gmatch(s, "%S+") do
        word = string.gsub(word, "%d+$", "")
        local lw = string.lower(word)
        if word ~= "" and not KIND_NOISE[lw] and not GENERIC_NAMES[lw] then words[#words + 1] = U.titleCase(word) end
    end
    if #words == 0 then return nil end
    local name = table.concat(words, " ")
    if GENERIC_NAMES[string.lower(name)] then return nil end
    return name
end

function Ores.kindName(raw)
    return Ores.specificKind(raw) or tostring(raw)
end

function Ores.isSelected(kind)
    return Config.values.selected[kind] ~= false
end

function Ores.priority(kind)
    return U.clamp(tonumber(Config.values.priorities[kind]) or 3, 1, 5)
end

local function isOreMeshName(name)
    return Ores.oreWordKind(name) ~= nil or string.match(tostring(name), "Ore%d*$") ~= nil
        or string.lower(tostring(name)) == "ore"
end

-- The part that visibly holds the ore (layout B: MeshPart "CoalOre" directly inside the deposit).
function Ores.findOreMesh(node)
    if node:IsA("BasePart") then
        if isOreMeshName(node.Name) then return node end
        return nil
    end
    for _, c in ipairs(node:GetChildren()) do
        if c:IsA("BasePart") and isOreMeshName(c.Name) then return c end
    end
    return nil
end

local function hasDepositInfo(inst)
    return inst:FindFirstChild("DepositInfo") ~= nil or inst:GetAttribute("OreRemaining") ~= nil
end

-- Returns kind, source. Deposit-level evidence wins over folder names.
function Ores.resolveKind(node, containerKind)
    local info = node:FindFirstChild("DepositInfo")
    for _, holder in ipairs({node, info}) do
        if holder then
            for _, attr in ipairs(KIND_ATTRS) do
                local v = holder:GetAttribute(attr)
                if type(v) == "string" and Ores.specificKind(v) then return Ores.specificKind(v), "attribute " .. attr end
                if holder == info then
                    local sv = info:FindFirstChild(attr)
                    if sv and sv:IsA("StringValue") and Ores.specificKind(sv.Value) then
                        return Ores.specificKind(sv.Value), "DepositInfo." .. attr
                    end
                end
            end
        end
    end
    local mesh = Ores.findOreMesh(node)
    if mesh and Ores.specificKind(mesh.Name) then return Ores.specificKind(mesh.Name), "ore mesh name" end
    local own = Ores.oreWordKind(node.Name)
    if own then return own, "deposit name" end
    if containerKind then return containerKind, "folder name" end
    local ownAny = Ores.specificKind(node.Name)
    if ownAny then return ownAny, "deposit name" end
    return "Unknown", "no evidence yet"
end

local function findPath(pathString)
    local node = Workspace
    for segment in string.gmatch(pathString, "[^/%.]+") do
        node = node and node:FindFirstChild(U.trim(segment)) or nil
        if not node then return nil end
    end
    if node == Workspace then return nil end
    return node
end

-- Bounded breadth-first search (depth <= 3, <= 4000 nodes) for a folder named like the Mining root.
local function heuristicRoot()
    local queue, head, visited = {{Workspace, 0}}, 1, 0
    while head <= #queue and visited < 4000 do
        local node, depth = queue[head][1], queue[head][2]
        head = head + 1
        local ok, children = pcall(function() return node:GetChildren() end)
        if ok then
            for _, child in ipairs(children) do
                visited = visited + 1
                local lname = string.lower(child.Name)
                if (lname == "mining" or lname == "ores" or lname == "oredeposits" or lname == "ore_deposits")
                    and (child:IsA("Folder") or child:IsA("Model")) and #child:GetChildren() > 0 then
                    return child
                end
                if depth < 3 and (child:IsA("Folder") or child:IsA("Model")) then
                    queue[#queue + 1] = {child, depth + 1}
                end
            end
        end
    end
    return nil
end

-- Last resort, at most once a minute: the ancestor holding the most ore-named parts ("CoalOre").
local function oreNamedRoot()
    if U.now() - Ores.lastOreScan < 60 then return nil end
    Ores.lastOreScan = U.now()
    local ok, list = pcall(function() return Workspace:GetDescendants() end)
    if not ok then return nil end
    local counts, best, bestN = {}, nil, 0
    for i, inst in ipairs(list) do
        if i > 250000 then break end
        if i % 4000 == 0 then task.wait() end
        if inst:IsA("BasePart") and string.match(inst.Name, "%aOre%d*$") and Ores.oreWordKind(inst.Name) then
            local deposit = inst.Parent
            local anc = deposit and deposit.Parent and deposit.Parent.Parent
            if anc and anc ~= Workspace and not (Char.character and U.isDescendantOf(inst, Char.character)) then
                counts[anc] = (counts[anc] or 0) + 1
                if counts[anc] > bestN then best, bestN = anc, counts[anc] end
            end
        end
    end
    if best and bestN >= 3 then return best end
    return nil
end

function Ores.resolveRoot()
    local paths = {}
    for p in string.gmatch(Config.get("orePaths") or "", "[^;,]+") do paths[#paths + 1] = U.trim(p) end
    for _, p in ipairs(ROOT_FALLBACKS) do paths[#paths + 1] = p end
    for _, p in ipairs(paths) do
        local node = findPath(p)
        if node then return node, p, "path" end
    end
    local found = heuristicRoot()
    if found then return found, U.fullName(found), "folder name" end
    found = oreNamedRoot()
    if found then return found, U.fullName(found), "ore-named parts" end
    return nil
end

local function ensureKind(kind)
    if Ores.kinds[kind] then return Ores.kinds[kind] end
    local record = {name = kind, total = 0, available = 0, depleted = 0, nearest = nil, nearestDist = nil}
    Ores.kinds[kind] = record
    Ores.kindList[#Ores.kindList + 1] = kind
    table.sort(Ores.kindList)
    if Config.values.selected[kind] == nil then Config.values.selected[kind] = true end
    if Config.values.priorities[kind] == nil then Config.values.priorities[kind] = 3 end
    Ores.version = Ores.version + 1
    Log.info("Ores", "Discovered ore type: " .. kind)
    return record
end

function Ores.readRemaining(entry)
    local obj = entry.remainingObj
    if obj then
        local ok, v = pcall(function() return obj.Value end)
        if ok and type(v) == "number" then return v end
        return nil
    end
    local host = entry.remainingAttrHost
    if host then
        local ok, v = pcall(function() return host:GetAttribute("OreRemaining") end)
        if ok and type(v) == "number" then return v end
    end
    return nil
end

local function notifyChange(entry, old)
    entry.lastChange = U.now()
    Ores.dataVersion = Ores.dataVersion + 1
    for _, fn in ipairs(Ores.remainingListeners) do pcall(fn, entry, old, entry.remaining) end
end

local function onRemainingChanged(entry)
    local old = entry.remaining
    entry.remaining = Ores.readRemaining(entry)
    notifyChange(entry, old)
end

function Ores.resolveRemaining(entry)
    local node = entry.node
    entry.resolveAt = U.now()
    local info = node:FindFirstChild("DepositInfo") or node:FindFirstChild("DepositInfo", true)
    local value = info and info:FindFirstChild("OreRemaining") or node:FindFirstChild("OreRemaining", true)
    if value and (value:IsA("IntValue") or value:IsA("NumberValue")) then
        entry.remainingObj = value
        entry.conns[#entry.conns + 1] = SESSION:connect(value.Changed, function() onRemainingChanged(entry) end,
            "OreRemaining.Changed")
    else
        local host = nil
        if node:GetAttribute("OreRemaining") ~= nil then host = node
        elseif info and info:GetAttribute("OreRemaining") ~= nil then host = info end
        if host then
            entry.remainingAttrHost = host
            entry.conns[#entry.conns + 1] = SESSION:connect(host:GetAttributeChangedSignal("OreRemaining"),
                function() onRemainingChanged(entry) end, "OreRemaining attribute")
        end
    end
    entry.remaining = Ores.readRemaining(entry)
end

function Ores.refreshGeometry(entry)
    local node = entry.node
    local ok = pcall(function()
        if node:IsA("BasePart") then
            entry.boxCF, entry.boxSize = node.CFrame, node.Size
        elseif entry.mesh and U.alive(entry.mesh) then
            entry.boxCF, entry.boxSize = entry.mesh.CFrame, entry.mesh.Size
        else
            entry.boxCF, entry.boxSize = node:GetBoundingBox()
        end
    end)
    if not ok or not entry.boxCF then
        local p = U.positionOf(node)
        if p then entry.boxCF, entry.boxSize = CFrame.new(p), Vector3.new(4, 4, 4) end
    end
    if entry.boxCF then
        entry.pos = entry.boxCF.Position
        local s = entry.boxSize
        entry.radius = math.max(1, math.max(s.X, s.Z) / 2)
        entry.height = s.Y
    end
    entry.geoAt = U.now()
end

function Ores.hasOre(entry)
    local mesh = entry.mesh
    return mesh ~= nil and U.alive(mesh) and (mesh == entry.node or mesh.Parent == entry.node)
end

-- Mineable now: alive with a known type, not suspended, and OreRemaining > 0. Without OreRemaining:
-- layout B requires the ore mesh to be present; otherwise "allow unknown remaining" decides (such
-- deposits are still verified by progress signals and blacklisted when mining shows no effect).
function Ores.isAvailable(entry)
    if entry.removed or not U.alive(entry.node) or entry.kind == "Unknown" then return false end
    local until_ = Ores.suspendedKinds[entry.kind]
    if until_ and U.now() < until_ then return false end
    local r = entry.remaining
    if r ~= nil then return r > 0 end
    if Ores.meshLayout then return Ores.hasOre(entry) end
    return Config.get("allowUnknownRemaining")
end

function Ores.setKind(entry, kind, source)
    entry.kindSource = source
    if entry.kind == kind then return end
    entry.kind = kind
    if kind ~= "Unknown" then ensureKind(kind) end
    Ores.dataVersion = Ores.dataVersion + 1
end

local function forgetMemoryNear(pos, radius)
    for i = #Ores.memory, 1, -1 do
        if U.dist(Ores.memory[i].pos, pos) < radius then table.remove(Ores.memory, i) end
    end
end

-- Ore mesh removed (node exhausted) or re-added (respawned) under a deposit model.
local function onDepositChild(entry, child, added)
    if child.Name == "DepositInfo" and added and not entry.remainingObj and not entry.remainingAttrHost then
        Ores.resolveRemaining(entry)
        return
    end
    if not child:IsA("BasePart") then return end
    if added then
        if not Ores.hasOre(entry) and isOreMeshName(child.Name) then
            entry.mesh = child
            if entry.kind == "Unknown" or entry.kindSource == "folder name" then
                local kind, source = Ores.resolveKind(entry.node, entry.containerKind)
                Ores.setKind(entry, kind, source)
            end
            Ores.refreshGeometry(entry)
            notifyChange(entry, entry.remaining)
        end
    elseif child == entry.mesh then
        entry.mesh = Ores.findOreMesh(entry.node)
        notifyChange(entry, entry.remaining)
    end
end

function Ores.addDeposit(node, containerKind, container)
    if Ores.deposits[node] then return Ores.deposits[node] end
    local entry = {node = node, container = container, containerKind = containerKind, conns = {},
        addedAt = U.now(), lastChange = U.now(), attempts = 0}
    Ores.deposits[node] = entry
    Ores.depositCount = Ores.depositCount + 1
    entry.mesh = Ores.findOreMesh(node)
    entry.kind, entry.kindSource = Ores.resolveKind(node, containerKind)
    if entry.kind ~= "Unknown" then ensureKind(entry.kind) end
    Ores.refreshGeometry(entry)
    Ores.resolveRemaining(entry)
    if entry.mesh and entry.mesh ~= node and not entry.remainingObj and not entry.remainingAttrHost
        and not Ores.meshLayout then
        Ores.meshLayout = true
        Log.info("Ores", "Deposits expose no OreRemaining; tracking exhaustion through their ore mesh (" ..
            entry.mesh.Name .. ")")
    end
    if not node:IsA("BasePart") then
        entry.conns[#entry.conns + 1] = SESSION:connect(node.ChildAdded,
            function(child) onDepositChild(entry, child, true) end, "Deposit.ChildAdded")
        entry.conns[#entry.conns + 1] = SESSION:connect(node.ChildRemoved,
            function(child) onDepositChild(entry, child, false) end, "Deposit.ChildRemoved")
    end
    if entry.pos then forgetMemoryNear(entry.pos, 12) end
    Ores.dataVersion = Ores.dataVersion + 1
    return entry
end

function Ores.removeDeposit(node, why)
    local entry = Ores.deposits[node]
    if not entry then return end
    for _, conn in ipairs(entry.conns) do SESSION:disconnect(conn) end
    entry.conns = {}
    entry.removed = true
    Ores.deposits[node] = nil
    Ores.depositCount = Ores.depositCount - 1
    -- A deposit that vanishes far away with ore left was most likely streamed out: remember it.
    local here = Char.position()
    local hadOre = (entry.remaining == nil or entry.remaining > 0) and (not Ores.meshLayout or entry.mesh ~= nil)
    if Config.get("rememberSites") and entry.pos and here and hadOre and entry.kind ~= "Unknown"
        and U.dist(here, entry.pos) > 150 and #Ores.memory < 300 then
        forgetMemoryNear(entry.pos, 12)
        Ores.memory[#Ores.memory + 1] = {pos = entry.pos, kind = entry.kind, at = U.now()}
    end
    Ores.dataVersion = Ores.dataVersion + 1
    Log.debug("Ores", "Deposit removed (" .. tostring(why) .. "): " .. entry.kind)
end

-- Classifies a child of a container: "deposit", "container" or nil.
local function classify(child, depth, containerKind)
    if child:IsA("BasePart") then
        if Ores.findOreMesh(child) or containerKind then return "deposit" end
        return nil
    end
    if child:IsA("Folder") or child:IsA("Configuration") then
        if child.Name == "DepositInfo" then return nil end
        return depth < MAX_CONTAINER_DEPTH and "container" or nil
    end
    if child:IsA("Model") then
        if hasDepositInfo(child) or Ores.findOreMesh(child) then return "deposit" end
        for _, sub in ipairs(child:GetChildren()) do
            if sub:IsA("Model") and (hasDepositInfo(sub) or Ores.findOreMesh(sub)) then
                return depth < MAX_CONTAINER_DEPTH and "container" or nil
            end
        end
        -- No evidence yet: e.g. an exhausted node whose ore mesh is gone. Tracked (unavailable) so a
        -- respawning ore mesh is noticed.
        return "deposit"
    end
    return nil
end

local watchContainer

local function addChild(child, kind, container, depth)
    local class = classify(child, depth, kind)
    if class == "deposit" then
        Ores.addDeposit(child, kind, container)
    elseif class == "container" then
        watchContainer(child, Ores.oreWordKind(child.Name) or kind, depth + 1)
    end
end

watchContainer = function(container, kind, depth)
    if Ores.containers[container] then return end
    local record = {kind = kind, conns = {}}
    Ores.containers[container] = record
    record.conns[1] = SESSION:connect(container.ChildAdded, function(child)
        addChild(child, kind, container, depth)
    end, "Ores.ChildAdded")
    record.conns[2] = SESSION:connect(container.ChildRemoved, function(child)
        if Ores.deposits[child] then Ores.removeDeposit(child, "removed") end
        if Ores.containers[child] then Ores.unwatch(child) end
    end, "Ores.ChildRemoved")
    for _, child in ipairs(container:GetChildren()) do addChild(child, kind, container, depth) end
end

function Ores.unwatch(container)
    local record = Ores.containers[container]
    if not record then return end
    for _, conn in ipairs(record.conns) do SESSION:disconnect(conn) end
    Ores.containers[container] = nil
    for node, entry in pairs(Ores.deposits) do
        if entry.container == container then Ores.removeDeposit(node, "container removed") end
    end
end

local function addCategory(child)
    if (child:IsA("Model") and (hasDepositInfo(child) or Ores.findOreMesh(child))) or
        (child:IsA("BasePart") and Ores.findOreMesh(child)) then
        Ores.addDeposit(child, nil, Ores.root) -- flat layout: deposits directly under the root
    elseif child:IsA("Folder") or child:IsA("Model") or child:IsA("Configuration") then
        -- Type folder ("Copper") or generic grouping folder ("OreDeposits" -> no type).
        watchContainer(child, Ores.specificKind(child.Name), 1)
    end
end

function Ores.detach()
    for _, conn in ipairs(Ores.rootConns) do SESSION:disconnect(conn) end
    Ores.rootConns = {}
    for container in pairs(Ores.containers) do Ores.unwatch(container) end
    for node in pairs(Ores.deposits) do Ores.removeDeposit(node, "detach") end
    Ores.root = nil
    Ores.rootLabel = "Not found"
end

function Ores.attach(root, label, how)
    Ores.detach()
    Ores.root = root
    Ores.rootHow = how
    Ores.rootLabel = label .. (how ~= "path" and (" (found by " .. how .. ")") or "")
    Ores.rootConns[1] = SESSION:connect(root.ChildAdded, function(child) addCategory(child) end, "Mining.ChildAdded")
    Ores.rootConns[2] = SESSION:connect(root.ChildRemoved, function(child)
        if Ores.containers[child] then Ores.unwatch(child) end
        if Ores.deposits[child] then Ores.removeDeposit(child, "removed") end
    end, "Mining.ChildRemoved")
    Ores.rootConns[3] = SESSION:connect(root.AncestryChanged, function()
        if not U.alive(root) then
            Log.warn("Ores", "Mining root left the DataModel; will re-resolve")
            Ores.detach()
        end
    end, "Mining.AncestryChanged")
    for _, child in ipairs(root:GetChildren()) do addCategory(child) end
    Ores.status = string.format("Watching %s: %d types, %d deposits", Ores.rootLabel, #Ores.kindList, Ores.depositCount)
    Log.info("Ores", Ores.status)
end

-- Periodic, cheap maintenance (called every scanInterval seconds).
function Ores.maintain(force)
    local now = U.now()
    if not Ores.root or not U.alive(Ores.root) then
        if force or now - Ores.lastResolve > Config.get("scanInterval") then
            Ores.lastResolve = now
            local root, label, how = Ores.resolveRoot()
            if root then
                Ores.attach(root, label, how)
            else
                Ores.status = "Mining folder not found (not replicated yet?)"
                Log.warn("Ores", "Mining root not found; checked configured paths, folder names and ore-named parts",
                    "noroot", 60)
            end
        end
        return
    end
    for _, entry in pairs(Ores.deposits) do
        if not entry.remainingObj and not entry.remainingAttrHost and now - (entry.resolveAt or 0) > 10 then
            Ores.resolveRemaining(entry)
        end
        if now - (entry.geoAt or 0) > 30 then Ores.refreshGeometry(entry) end
    end
    for i = #Ores.memory, 1, -1 do
        if now - Ores.memory[i].at > 900 then table.remove(Ores.memory, i) end
    end
    Ores.status = string.format("Watching %s: %d types, %d deposits", Ores.rootLabel, #Ores.kindList, Ores.depositCount)
end

-- Kind-level learning: a type whose deposits show no reaction at all three times in a row is skipped
-- for 10 minutes (most likely the pickaxe tier is too low for it).
function Ores.kindResult(kind, reacted)
    if reacted then
        Ores.kindStrikes[kind] = 0
        return
    end
    local n = (Ores.kindStrikes[kind] or 0) + 1
    Ores.kindStrikes[kind] = n
    if n >= 3 then
        Ores.kindStrikes[kind] = 0
        Ores.suspendedKinds[kind] = U.now() + 600
        local tier = Ores.TIERS[kind]
        Log.warn("Ores", string.format("%s deposits did not react to mining 3 times in a row; skipping %s for 10 minutes.%s",
            kind, kind, tier and (" The community wiki lists pickaxe tier " .. tier .. " as the minimum for " .. kind .. ".") or ""))
    end
end

-- Per-kind counters for the GUI (throttled).
function Ores.refreshStats(force)
    local now = U.now()
    if not force and now - Ores.lastStats < 0.5 then return end
    Ores.lastStats = now
    local here = Char.position()
    local hideDepleted = Config.get("skipDepleted")
    for _, record in pairs(Ores.kinds) do
        record.available, record.nearestDist, record.total, record.depleted = 0, nil, 0, 0
    end
    for _, entry in pairs(Ores.deposits) do
        local record = Ores.kinds[entry.kind]
        if record then
            local depleted = (entry.remaining ~= nil and entry.remaining <= 0)
                or (entry.remaining == nil and Ores.meshLayout and not Ores.hasOre(entry))
            if depleted then record.depleted = record.depleted + 1 end
            if not (depleted and hideDepleted) then record.total = record.total + 1 end
            if Ores.isAvailable(entry) then
                record.available = record.available + 1
                if here and entry.pos then
                    local d = U.dist(here, entry.pos)
                    if not record.nearestDist or d < record.nearestDist then record.nearestDist = d end
                end
            end
        end
    end
end

function Ores.totals()
    local total, available, selected = 0, 0, 0
    for kind, record in pairs(Ores.kinds) do
        total = total + record.total
        available = available + record.available
        if Ores.isSelected(kind) then selected = selected + record.available end
    end
    return total, available, selected
end

-- ==== MODULE: Visual =====================================================================
-- Pooled route markers and one reusable Highlight. Nothing is recreated per route.
local Visual = {folder = nil, dots = {}, used = 0, maxDots = 140, highlight = nil, accent = Color3.fromRGB(62, 207, 174)}

function Visual.ensureFolder()
    if Visual.folder and U.alive(Visual.folder) then return Visual.folder end
    local folder = Instance.new("Folder")
    folder.Name = VISUAL_NAME
    folder.Parent = Workspace
    SESSION:give(folder)
    Visual.folder = folder
    Visual.dots = {}
    Visual.highlight = nil
    return folder
end

function Visual.showRoute(points)
    if not Config.get("showRoute") or #points < 2 then Visual.clearRoute() return end
    local folder = Visual.ensureFolder()
    local stride = math.max(1, math.ceil(#points / Visual.maxDots))
    local used = 0
    for i = 1, #points, stride do
        used = used + 1
        local dot = Visual.dots[used]
        if not dot or not U.alive(dot) then
            dot = Instance.new("Part")
            dot.Name = "RouteDot"
            dot.Shape = Enum.PartType.Ball
            dot.Size = Vector3.new(0.6, 0.6, 0.6)
            dot.Material = Enum.Material.Neon
            dot.Anchored = true
            dot.CanCollide = false
            dot.CanTouch = false
            dot.CanQuery = false
            dot.CastShadow = false
            dot.Parent = folder
            Visual.dots[used] = dot
        end
        dot.Color = Visual.accent
        dot.Position = points[i] + Vector3.new(0, 0.5, 0)
        dot.Transparency = 0.2
    end
    for i = used + 1, #Visual.dots do
        if Visual.dots[i] then Visual.dots[i].Transparency = 1 end
    end
    Visual.used = used
end

function Visual.clearRoute()
    for i = 1, #Visual.dots do
        if Visual.dots[i] then Visual.dots[i].Transparency = 1 end
    end
    Visual.used = 0
end

function Visual.highlightTarget(inst)
    if not Config.get("highlightTarget") or not U.alive(inst) then
        if Visual.highlight then pcall(function() Visual.highlight.Adornee = nil end) end
        return
    end
    local folder = Visual.ensureFolder()
    if not Visual.highlight or not U.alive(Visual.highlight) then
        local ok, h = pcall(function()
            local hl = Instance.new("Highlight")
            hl.Name = "TargetHighlight"
            hl.FillTransparency = 0.8
            hl.OutlineTransparency = 0.1
            hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
            hl.Parent = folder
            return hl
        end)
        if not ok then return end
        Visual.highlight = h
    end
    pcall(function()
        Visual.highlight.FillColor = Visual.accent
        Visual.highlight.OutlineColor = Visual.accent
        Visual.highlight.Adornee = inst
    end)
end

-- ==== MODULE: Nav ========================================================================
-- PathfindingService navigation. Long trips are split into progressive legs toward ground-snapped
-- intermediate goals. Each waypoint has progress-based stuck detection with a recovery ladder.
local Nav = {
    path = nil,
    pathKey = nil,
    blockedConn = nil,
    blockedIndex = nil,
    lastCompute = 0,
    costCache = setmetatable({}, {__mode = "k"}),
    status = {
        dest = "None", destPos = nil, route = "Idle", wpIndex = 0, wpCount = 0, legs = 0,
        replans = 0, stuck = 0, recoveries = 0, lastFailure = "-", lastComputeMs = 0, length = 0,
    },
}

function Nav.agentParams()
    return {
        AgentRadius = Config.get("agentRadius"),
        AgentHeight = Config.get("agentHeight"),
        AgentCanJump = Config.get("agentCanJump"),
        AgentCanClimb = Config.get("agentCanClimb"),
        WaypointSpacing = Config.get("waypointSpacing"),
        Costs = {Water = 6},
    }
end

local function newPath()
    local ok, path = pcall(function() return PathfindingService:CreatePath(Nav.agentParams()) end)
    if ok and path then return path end
    Log.error("Nav", "CreatePath failed: " .. tostring(path), "createpath", 30)
    return nil
end

-- The followed route uses one persistent Path object so Path.Blocked can be observed.
function Nav.followPath()
    local key = table.concat({Config.get("agentRadius"), Config.get("agentHeight"),
        tostring(Config.get("agentCanJump")), tostring(Config.get("agentCanClimb")), Config.get("waypointSpacing")}, "|")
    if Nav.path and Nav.pathKey == key then return Nav.path end
    if Nav.blockedConn then SESSION:disconnect(Nav.blockedConn) Nav.blockedConn = nil end
    Nav.path = newPath()
    Nav.pathKey = key
    if Nav.path then
        Nav.blockedConn = SESSION:connect(Nav.path.Blocked, function(index)
            Nav.blockedIndex = index
        end, "Path.Blocked")
    end
    return Nav.path
end

function Nav.length(waypoints)
    local total = 0
    for i = 2, #waypoints do total = total + U.dist(waypoints[i - 1].Position, waypoints[i].Position) end
    return total
end

function Nav.rayParams()
    local params = RaycastParams.new()
    local exclude = {}
    if Char.character then exclude[#exclude + 1] = Char.character end
    if Visual.folder then exclude[#exclude + 1] = Visual.folder end
    pcall(function() params.FilterType = Enum.RaycastFilterType.Exclude end)
    params.FilterDescendantsInstances = exclude
    params.IgnoreWater = true
    return params
end

-- Snap a point to walkable ground: first a short ray (caves/overhangs), then a tall one.
function Nav.groundAt(pos)
    local params = Nav.rayParams()
    local ok, hit = pcall(function()
        return Workspace:Raycast(pos + Vector3.new(0, 8, 0), Vector3.new(0, -70, 0), params)
            or Workspace:Raycast(pos + Vector3.new(0, 120, 0), Vector3.new(0, -300, 0), params)
    end)
    if ok and hit then return hit.Position + Vector3.new(0, 2.5, 0) end
    return nil
end

function Nav.throttle(token)
    local wait = Config.get("pathRecalcMinInterval") - (U.now() - Nav.lastCompute)
    if wait > 0 and token then return token:sleep(wait) end
    if wait > 0 then task.wait(wait) end
    return true
end

-- Computes a path. forFollow=true uses the persistent Path (Blocked tracking); probes use a fresh one.
function Nav.compute(from, to, forFollow, token)
    if not PathfindingService then return nil, "PathfindingService unavailable" end
    if token and not Nav.throttle(token) then return nil, "cancelled" end
    local path = forFollow and Nav.followPath() or newPath()
    if not path then return nil, "no path object" end
    local started = U.now()
    local ok, err = pcall(function() path:ComputeAsync(from, to) end)
    Nav.lastCompute = U.now()
    Nav.status.lastComputeMs = math.floor((Nav.lastCompute - started) * 1000)
    Stats.pathsComputed = Stats.pathsComputed + 1
    if not ok then
        Stats.pathFailures = Stats.pathFailures + 1
        return nil, "compute error: " .. tostring(err)
    end
    if path.Status ~= Enum.PathStatus.Success then
        Stats.pathFailures = Stats.pathFailures + 1
        return nil, tostring(path.Status)
    end
    local waypoints = path:GetWaypoints()
    if #waypoints == 0 then return nil, "empty path" end
    if forFollow then Nav.blockedIndex = nil end
    return waypoints, "Success", Nav.length(waypoints)
end

-- Estimated travel cost; uses a cached real path length when the player has not moved much.
function Nav.estimate(key, from, to)
    local cached = key and Nav.costCache[key]
    if cached and U.now() - cached.at < 90 and U.dist(cached.from, from) < 25 then
        return cached.cost + U.dist(cached.from, from), true
    end
    local straight = U.dist(from, to)
    return straight * 1.3 + math.abs(to.Y - from.Y) * 2, false
end

function Nav.remember(key, from, cost)
    if key then Nav.costCache[key] = {cost = cost, from = from, at = U.now()} end
end

local function requestStream(pos)
    if LocalPlayer then
        pcall(function() LocalPlayer:RequestStreamAroundAsync(pos, 5) end)
    end
end

-- Plans one leg toward goal. Returns {waypoints, goal, final, length} or nil, reason.
function Nav.planLeg(goal, token, extraGoals)
    local _, _, root = Char.get()
    if not root then return nil, "character_lost" end
    local from = root.Position
    local dist = U.dist(from, goal)
    local maxLeg = Config.get("maxLegLength")
    Nav.status.route = "Computing path"
    if dist <= maxLeg then
        local candidates = {goal}
        for _, g in ipairs(extraGoals or {}) do candidates[#candidates + 1] = g end
        local lastWhy = "no candidates"
        for _, g in ipairs(candidates) do
            local waypoints, why, len = Nav.compute(from, g, true, token)
            if waypoints then return {waypoints = waypoints, goal = g, final = true, length = len} end
            lastWhy = why
            if token:dead() then return nil, "cancelled" end
        end
        return nil, "no path (" .. tostring(lastWhy) .. ")"
    end
    if dist > 400 then requestStream(goal) end
    local flat = Vector3.new(goal.X - from.X, 0, goal.Z - from.Z)
    local unit = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(1, 0, 0)
    local lateral = Vector3.new(-unit.Z, 0, unit.X)
    for _, fraction in ipairs({1, 0.7, 0.45}) do
        local stepLen = maxLeg * fraction
        local yGuess = from.Y + (goal.Y - from.Y) * math.min(1, stepLen / dist)
        local base = Vector3.new(from.X, yGuess, from.Z) + unit * stepLen
        for _, side in ipairs({0, 1, -1, 2, -2}) do
            if token:dead() then return nil, "cancelled" end
            local ground = Nav.groundAt(base + lateral * (side * 24))
            if ground then
                local waypoints, _, len = Nav.compute(from, ground, true, token)
                if waypoints then
                    return {waypoints = waypoints, goal = ground, final = false, length = len}
                end
            end
        end
    end
    return nil, "no progressive path"
end

local function strafe(hum, pos, toward, sign)
    local flat = Vector3.new(toward.X - pos.X, 0, toward.Z - pos.Z)
    local unit = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(1, 0, 0)
    local side = Vector3.new(-unit.Z, 0, unit.X) * sign
    pcall(function() hum:MoveTo(pos + side * 4 - unit * 1.5) end)
end

-- Movement drivers. "MoveTo" (Humanoid:MoveTo) is the default. TWW uses its own character
-- controller (public scripts show a PlayerCharacter module), so if the character does not move at
-- all on two consecutive waypoints the driver switches to "Move": Humanoid:Move toward the waypoint
-- every frame, bound after the game's controller. The driver that produced movement is remembered.
local DRIVER_BIND = "TWWProspectorMoveDriver"
Nav.driver, Nav.driverVerified, Nav.zeroMoves = "MoveTo", false, 0
SESSION:onCleanup(function()
    if RunService then pcall(function() RunService:UnbindFromRenderStep(DRIVER_BIND) end) end
end)

function Nav.startDriver(target)
    if Nav.driver ~= "Move" or not RunService then return function() end end
    local function step()
        local _, h, r = Char.get()
        if not h then return end
        local d = Vector3.new(target.X - r.Position.X, 0, target.Z - r.Position.Z)
        if d.Magnitude > 0.5 then pcall(function() h:Move(d.Unit, false) end) end
    end
    local bound = pcall(function()
        RunService:BindToRenderStep(DRIVER_BIND, Enum.RenderPriority.Character.Value + 1, step)
    end)
    local conn = nil
    if not bound then conn = SESSION:connect(RunService.Heartbeat, step, "MoveDriver") end
    return function()
        if bound then pcall(function() RunService:UnbindFromRenderStep(DRIVER_BIND) end) end
        if conn then SESSION:disconnect(conn) end
        local _, h = Char.get()
        if h then pcall(function() h:Move(Vector3.new(0, 0, 0), false) end) end
    end
end

function Nav.noteDisplacement(moved, result)
    if moved >= 1.5 then
        Nav.zeroMoves = 0
        if not Nav.driverVerified then
            Nav.driverVerified = true
            Learned.set("moveDriver", Nav.driver)
        end
        return
    end
    if Nav.driverVerified or result == "reached" or result == "arrived_early" or result == "cancelled"
        or result == "character_lost" or Char.controlState() ~= "ok" then
        return
    end
    Nav.zeroMoves = Nav.zeroMoves + 1
    if Nav.zeroMoves >= 2 then
        Nav.zeroMoves = 0
        local old = Nav.driver
        Nav.driver = old == "MoveTo" and "Move" or "MoveTo"
        Log.warn("Nav", "The character did not move with " .. old .. "; switching movement driver to " .. Nav.driver)
    end
end

local walkToInner

-- Walks to a single waypoint. Returns "reached" | "arrived_early" | "stuck" | "timeout" |
-- "character_lost" | "no_control" | "target_invalid" | "cancelled".
function Nav.walkTo(target, jump, token, opts, isLast)
    local _, _, root = Char.get()
    local startPos = root and root.Position
    local stopDriver = Nav.startDriver(target)
    local ok, result = pcall(walkToInner, target, jump, token, opts, isLast)
    stopDriver()
    if not ok then error(result, 0) end
    local _, _, after = Char.get()
    if startPos and after then Nav.noteDisplacement(U.flatDist(startPos, after.Position), result) end
    return result
end

walkToInner = function(target, jump, token, opts, isLast)
    local _, hum, root = Char.get()
    if not hum then return "character_lost" end
    local control = Char.controlState()
    if control == "seated" then
        Char.jump()
        pcall(function() hum.Sit = false end)
        if not token:sleep(0.4) then return "cancelled" end
    elseif control == "no_control" then
        local deadline = U.now() + 8
        while Char.controlState() == "no_control" and U.now() < deadline do
            if not token:sleep(0.25) then return "cancelled" end
        end
        if Char.controlState() == "no_control" then return "no_control" end
    end
    if jump then pcall(function() hum.Jump = true end) end
    pcall(function() hum:MoveTo(target) end)
    local started = U.now()
    local lastIssue, lastValid = started, started
    local best, bestAt = U.flatDist(root.Position, target), started
    local speed = 16
    pcall(function() speed = math.max(hum.WalkSpeed, 4) end)
    local timeout = math.max(4, best / speed * 2.5 + 2.5)
    local recoveries = 0
    while true do
        if token:dead() then return "cancelled" end
        local _, h, r = Char.get()
        if not r then return "character_lost" end
        local pos = r.Position
        local flat = U.flatDist(pos, target)
        if flat < (isLast and 1.8 or 2.8) and math.abs(pos.Y - target.Y) < 6 then return "reached" end
        if opts.arrivedCheck and opts.arrivedCheck(pos) then return "arrived_early" end
        local now = U.now()
        if flat < best - 0.5 then best, bestAt = flat, now end
        if now - lastIssue > 2.5 then
            pcall(function() h:MoveTo(target) end)
            lastIssue = now
        end
        if now - bestAt > Config.get("stuckTime") then
            recoveries = recoveries + 1
            Stats.stuckEvents = Stats.stuckEvents + 1
            Nav.status.stuck = Nav.status.stuck + 1
            if recoveries > 3 then return "stuck" end
            Nav.status.recoveries = Nav.status.recoveries + 1
            Stats.recoveries = Stats.recoveries + 1
            Log.debug("Nav", "Stuck near " .. U.fmtVec(pos) .. "; recovery step " .. recoveries)
            if recoveries == 1 then
                pcall(function() h.Jump = true end)
            else
                strafe(h, pos, target, recoveries == 2 and 1 or -1)
                pcall(function() h.Jump = true end)
                if not token:sleep(0.55) then return "cancelled" end
            end
            pcall(function() h:MoveTo(target) end)
            lastIssue = U.now()
            bestAt = U.now()
            best = U.flatDist(r.Position, target)
        end
        if now - started > timeout then return "timeout" end
        if opts.isValid and now - lastValid > 0.5 then
            lastValid = now
            if not opts.isValid() then return "target_invalid" end
        end
        task.wait(0.1)
    end
end

-- Follows one planned leg. Returns "arrived" | "leg_done" | "blocked" | other walkTo failure.
function Nav.followLeg(leg, token, opts)
    opts = opts or {}
    local waypoints = leg.waypoints
    local points = {}
    for i, wp in ipairs(waypoints) do points[i] = wp.Position end
    Visual.showRoute(points)
    Nav.status.wpCount = #waypoints
    Nav.status.length = math.floor(leg.length or 0)
    Nav.status.route = leg.final and "Following final leg" or "Following intermediate leg"
    Nav.blockedIndex = nil
    for i = (#waypoints > 1 and 2 or 1), #waypoints do
        Nav.status.wpIndex = i
        if Nav.blockedIndex and Nav.blockedIndex >= i - 1 then
            Nav.blockedIndex = nil
            Nav.status.route = "Path blocked"
            return "blocked"
        end
        local wp = waypoints[i]
        local result = Nav.walkTo(wp.Position, wp.Action == Enum.PathWaypointAction.Jump, token, opts, i == #waypoints)
        if result == "arrived_early" then return "arrived" end
        if result ~= "reached" then
            Nav.status.route = "Leg failed: " .. result
            Nav.status.lastFailure = result
            return result
        end
    end
    return leg.final and "arrived" or "leg_done"
end

-- Complete trip helper (used for sellers and fallback points): plan/follow/replan until arrival.
function Nav.travel(goal, token, opts)
    opts = opts or {}
    Nav.status.dest = opts.label or U.fmtVec(goal)
    Nav.status.destPos = goal
    local arriveRadius = opts.arriveRadius or 3
    local replans, legs = 0, 0
    while true do
        if token:dead() then return false, token.reason or "cancelled" end
        local pos = Char.position()
        if not pos then return false, "character_lost" end
        if U.dist(pos, goal) <= arriveRadius or (opts.arrivedCheck and opts.arrivedCheck(pos)) then
            Nav.status.route = "Arrived"
            return true, "arrived"
        end
        local leg, why = Nav.planLeg(goal, token, opts.extraGoals)
        if not leg then
            Nav.status.route = "No route"
            Nav.status.lastFailure = why
            return false, why
        end
        legs = legs + 1
        Nav.status.legs = Nav.status.legs + 1
        if legs > 40 then return false, "leg limit reached" end
        local result = Nav.followLeg(leg, token, opts)
        if result == "arrived" then
            Nav.status.route = "Arrived"
            return true, "arrived"
        elseif result == "leg_done" then
            -- continue with the next progressive leg
        elseif result == "blocked" or result == "stuck" or result == "timeout" then
            replans = replans + 1
            Nav.status.replans = Nav.status.replans + 1
            Stats.replans = Stats.replans + 1
            if replans > Config.get("maxReplans") then return false, result end
        else
            return false, result
        end
    end
end

function Nav.stop()
    Char.stopMoving()
    Visual.clearRoute()
    Nav.status.route = "Idle"
    Nav.status.wpIndex, Nav.status.wpCount = 0, 0
end

-- ==== MODULE: Probe ======================================================================
-- Observes a deposit for real progress while it is being mined.
--   Verified yield: OreRemaining decreases, inventory count rises, or ore items enter the Backpack.
--   Activity (resets the stall timer, never counted as success): numeric values / attributes under
--   the deposit change, deposit BillboardGui bars resize, a progress-like frame in PlayerGui resizes.
Probe = {}
Probe.__index = Probe

local BAR_WORDS = {"progress", "bar", "fill", "damage", "mining", "health", "hp"}

local function looksLikeBar(inst)
    if not inst:IsA("Frame") then return false end
    local name = string.lower(inst.Name)
    for _, word in ipairs(BAR_WORDS) do
        if U.has(name, word) then return true end
    end
    return false
end

function Probe.attach(entry)
    local self = setmetatable({entry = entry, conns = {}, activity = 0, lastActivity = U.now(),
        lastRemaining = Ores.readRemaining(entry), remainingYields = 0, signals = {}}, Probe)
    local function hit(kind)
        self.activity = self.activity + 1
        self.lastActivity = U.now()
        self.signals[kind] = (self.signals[kind] or 0) + 1
    end
    local watched = 0
    local ok, descendants = pcall(function() return entry.node:GetDescendants() end)
    if ok then
        for _, d in ipairs(descendants) do
            if watched >= 60 then break end
            if (d:IsA("IntValue") or d:IsA("NumberValue")) and d ~= entry.remainingObj then
                self.conns[#self.conns + 1] = SESSION:connect(d.Changed, function() hit("value") end, "Probe.value")
                watched = watched + 1
            elseif looksLikeBar(d) then
                self.conns[#self.conns + 1] = SESSION:connect(d:GetPropertyChangedSignal("Size"),
                    function() hit("deposit bar") end, "Probe.bar")
                watched = watched + 1
            end
        end
    end
    self.conns[#self.conns + 1] = SESSION:connect(entry.node.AttributeChanged, function() hit("attribute") end,
        "Probe.attr")
    self.conns[#self.conns + 1] = SESSION:connect(entry.node.DescendantAdded, function() hit("child") end,
        "Probe.child")
    -- Screen progress bars (the wiki describes a damage bar at the top of the screen).
    if PlayerGui then
        local bars = 0
        local okGui, guiDesc = pcall(function() return PlayerGui:GetDescendants() end)
        if okGui then
            for _, d in ipairs(guiDesc) do
                if bars >= 40 then break end
                if looksLikeBar(d) and not U.isDescendantOf(d, UI and UI.root) then
                    self.conns[#self.conns + 1] = SESSION:connect(d:GetPropertyChangedSignal("Size"),
                        function() hit("screen bar") end, "Probe.screenbar")
                    bars = bars + 1
                end
            end
        end
    end
    return self
end

-- Returns the number of newly verified units from OreRemaining since the last poll.
function Probe:pollRemaining()
    local now = Ores.readRemaining(self.entry)
    local gained = 0
    if now and self.lastRemaining and now < self.lastRemaining then
        gained = self.lastRemaining - now
        self.remainingYields = self.remainingYields + gained
        self.lastActivity = U.now()
    end
    if now then self.lastRemaining = now end
    return gained, now
end

function Probe:detach()
    for _, conn in ipairs(self.conns) do SESSION:disconnect(conn) end
    self.conns = {}
end

function Probe:signalSummary()
    local parts = {}
    for kind, n in pairs(self.signals) do parts[#parts + 1] = kind .. "=" .. n end
    if #parts == 0 then return "none" end
    return table.concat(parts, ", ")
end

-- ==== MODULE: Miner ======================================================================
Miner = {handle = nil, autoMethod = nil, noReaction = 0, status = "Idle", lastOutcome = "-", cameraSaved = false, cameraType = nil}
local SWING_HOLD = 0.12

-- Candidate standing spots in a ring just outside the deposit footprint, nearest side first.
function Miner.standSpots(entry, fromPos)
    local center = entry.pos
    local radius = (entry.radius or 2) + 2.2
    local base = math.atan2(fromPos.Z - center.Z, fromPos.X - center.X)
    local spots = {}
    for _, step in ipairs({0, 1, -1, 2, -2, 3, -3, 4}) do
        local a = base + step * (math.pi / 4)
        local p = center + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
        local ground = Nav.groundAt(p)
        if ground and math.abs(ground.Y - center.Y) < (entry.height or 4) + 8 then
            spots[#spots + 1] = ground
        end
    end
    if #spots == 0 then
        local flat = Vector3.new(fromPos.X - center.X, 0, fromPos.Z - center.Z)
        local unit = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(1, 0, 0)
        spots[1] = center + unit * radius
    end
    return spots
end

function Miner.rangeTo(entry, pos)
    if not entry.boxCF then Ores.refreshGeometry(entry) end
    if not entry.boxCF then return math.huge end
    return U.distanceToBox(pos, entry.boxCF, entry.boxSize)
end

-- Maximum distance at which mining continues (drift detection).
function Miner.inRange(entry, pos)
    return Miner.rangeTo(entry, pos) <= Config.get("mineRange")
end

-- Distance the approach aims for before swinging: a stand spot right next to the deposit.
-- Stopping at the edge of the maximum range would risk swings that never reach the deposit.
local APPROACH_RANGE = 3.5
function Miner.atStandRange(entry, pos)
    return Miner.rangeTo(entry, pos) <= math.min(Config.get("mineRange"), APPROACH_RANGE)
end

function Miner.face(entry)
    local _, _, root = Char.get()
    if not root or not entry.pos then return end
    local look = Vector3.new(entry.pos.X, root.Position.Y, entry.pos.Z)
    if U.dist(look, root.Position) > 0.3 then
        pcall(function() root.CFrame = CFrame.lookAt(root.Position, look) end)
    end
end

function Miner.aim(entry)
    if not Config.get("aimCamera") then return end
    local cam = Workspace.CurrentCamera
    local _, _, root = Char.get()
    if not cam or not root or not entry.pos then return end
    if not Miner.cameraSaved then
        Miner.cameraSaved = true
        Miner.cameraType = cam.CameraType
        pcall(function() cam.CameraType = Enum.CameraType.Scriptable end)
    end
    local head = root.Position + Vector3.new(0, 1.5, 0)
    local back = Vector3.new(head.X - entry.pos.X, 0, head.Z - entry.pos.Z)
    local unit = back.Magnitude > 0.2 and back.Unit or Vector3.new(0, 0, 1)
    local eye = head + unit * 4 + Vector3.new(0, 1.5, 0)
    pcall(function() cam.CFrame = CFrame.lookAt(eye, entry.pos) end)
end

function Miner.restoreCamera()
    if not Miner.cameraSaved then return end
    Miner.cameraSaved = false
    local cam = Workspace.CurrentCamera
    if cam then
        pcall(function() cam.CameraType = Miner.cameraType or Enum.CameraType.Custom end)
    end
end
SESSION:onCleanup(Miner.restoreCamera)

-- Simulated mouse click on the deposit's ore mesh (or box centre) at its current screen position.
function Miner.click(entry)
    local cam = Workspace.CurrentCamera
    if not cam then return false, "no camera" end
    local target = (Ores.hasOre(entry) and entry.mesh.Position) or entry.pos
    local ok, point, onScreen = pcall(function()
        local v, visible = cam:WorldToViewportPoint(target)
        return v, visible
    end)
    if not ok or not onScreen then return false, "deposit not on screen" end
    return Input.click(point.X, point.Y)
end

-- "Auto" picks Tool:Activate for a Roblox Tool and a mouse click for a game item, prefers whatever
-- worked before in this place, and is switched inside Miner.mine when a method gets no reaction.
function Miner.effectiveMethod(handle)
    local m = Config.get("interactMethod")
    if m ~= "Auto" then return m end
    local preferred = Miner.autoMethod or Learned.get("interact")
    if preferred == "Tool" and handle.kind == "tool" then return "Tool" end
    if preferred == "Click" and Input.available() then return "Click" end
    if handle.kind == "tool" then return "Tool" end
    return "Click"
end

function Miner.activate(handle, entry, method)
    local anyOk, lastErr = false, nil
    if (method == "Tool" or method == "Both") then
        if handle.kind == "tool" then
            local ok, err = pcall(function() handle.tool:Activate() end)
            anyOk = anyOk or ok
            if not ok then lastErr = err end
        else
            lastErr = "pickaxe is a game item, not a Roblox Tool"
        end
    end
    if method == "Click" or method == "Both" then
        local ok, err = Miner.click(entry)
        anyOk = anyOk or ok
        if not ok then lastErr = err end
    end
    return anyOk, lastErr
end

local function deactivate(handle)
    if handle and handle.kind == "tool" then pcall(function() handle.tool:Deactivate() end) end
end

-- Mines one deposit until it is depleted or a stop condition occurs. Returns a result table:
--   outcome: depleted | stalled | no_yield | out_of_range | tool_lost | inventory_full |
--            target_gone | character_lost | timeout | cancelled
--   yields: verified ore units observed, activity: weak progress signals observed.
function Miner.mine(entry, token)
    local probe = Probe.attach(entry)
    local handle = Miner.handle
    local started = U.now()
    local lastProgress = started
    local result = {outcome = nil, yields = 0, activity = 0, swings = 0, startRemaining = probe.lastRemaining}
    local interval = Config.get("swingInterval")
    local stallTimeout = Config.get("stallTimeout")
    local method = Miner.effectiveMethod(handle)
    local quietSwings, lastActivity = 0, 0
    Inventory.watchDrops(true)
    Miner.status = "Mining " .. entry.kind .. " (" .. method .. ")"

    local function finish(outcome)
        probe:detach()
        Inventory.watchDrops(false)
        deactivate(handle)
        result.outcome = outcome
        result.activity = probe.activity
        result.signals = probe:signalSummary()
        result.elapsed = U.now() - started
        result.method = method
        Miner.lastOutcome = outcome
        Miner.status = "Last: " .. outcome
        return result
    end

    local function verified(n)
        result.yields = result.yields + n
        Stats.recordYield(entry.kind, n)
        lastProgress = U.now()
        Inventory.lastYieldAt = U.now()
        Learn.onEvent("yield", n)
        if Config.get("interactMethod") == "Auto" then Learned.set("interact", method) end
    end

    local lastInv = Inventory.snapshot()
    while true do
        if token:dead() then
            return finish(token.reason == "timeout" and "timeout" or "cancelled")
        end
        if entry.removed or not U.alive(entry.node) then
            if result.yields > 0 or probe.activity > 0 then return finish("depleted") end
            return finish("target_gone")
        end
        local gained, remaining = probe:pollRemaining()
        if gained > 0 then verified(gained) end
        if remaining ~= nil and remaining <= 0 then return finish("depleted") end
        if remaining == nil and Ores.meshLayout and not Ores.hasOre(entry) then
            -- Layout B: the game removed the ore mesh, i.e. the node is exhausted.
            if result.yields > 0 or probe.activity > 0 then
                if result.yields == 0 then Learn.onEvent("yield", 1) end
                return finish("depleted")
            end
            return finish("target_gone")
        end
        local _, _, root = Char.get()
        if not root then return finish("character_lost") end
        if not Miner.inRange(entry, root.Position) then return finish("out_of_range") end
        if not Tools.isEquipped(handle) then return finish("tool_lost") end
        local sell, why = Inventory.shouldSell()
        if sell then
            result.sellReason = why
            return finish("inventory_full")
        end

        Learn.tick()
        Miner.face(entry)
        Miner.aim(entry)
        local ok, err = Miner.activate(handle, entry, method)
        Stats.swings = Stats.swings + 1
        result.swings = result.swings + 1
        if not ok then
            Stats.failedInteractions = Stats.failedInteractions + 1
            Log.warn("Miner", "Interaction failed (" .. method .. "): " .. tostring(err), "swingerr", 15)
        end
        if not token:sleep(SWING_HOLD) then return finish("cancelled") end
        deactivate(handle)
        if not token:sleep(math.max(0.05, interval - SWING_HOLD)) then
            return finish(token.reason == "timeout" and "timeout" or "cancelled")
        end

        -- Inventory-side verification (only counted when OreRemaining did not already account for it).
        local inv = Inventory.snapshot()
        local invGain = Inventory.gainBetween(lastInv, inv)
        lastInv = inv
        local remGain = probe:pollRemaining()
        if remGain > 0 then
            verified(remGain)
        elseif invGain > 0 then
            verified(invGain)
        end
        if probe.activity > lastActivity then
            lastActivity = probe.activity
            quietSwings = 0
            if Config.get("interactMethod") == "Auto" then Learned.set("interact", method) end
        elseif remGain == 0 and invGain == 0 then
            quietSwings = quietSwings + 1
        else
            quietSwings = 0
        end
        if probe.lastActivity > lastProgress then lastProgress = probe.lastActivity end

        -- Auto mode: no reaction at all after 6 swings -> try the other interaction method once.
        if Config.get("interactMethod") == "Auto" and quietSwings >= 6 and not result.switched then
            local alt = nil
            if method == "Tool" and Input.available() then alt = "Click"
            elseif method == "Click" and handle.kind == "tool" then alt = "Tool" end
            if alt then
                Log.info("Miner", "No reaction to " .. method .. " interaction after 6 swings; trying " .. alt)
                method, Miner.autoMethod, result.switched = alt, alt, true
                quietSwings, lastProgress = 0, U.now()
                Miner.status = "Mining " .. entry.kind .. " (" .. method .. ")"
            end
        end

        local now = U.now()
        if now - lastProgress > stallTimeout then
            Stats.failedInteractions = Stats.failedInteractions + 1
            return finish("stalled")
        end
        if result.yields == 0 and now - started > stallTimeout * 3 then
            return finish("no_yield")
        end
        if now - started > Config.get("mineTimeout") then return finish("timeout") end
    end
end

-- ==== MODULE: Learn ======================================================================
-- Differential discovery of the inventory counter and money display WITHOUT assuming names.
-- Numbers shown in PlayerGui ("12/40", "$1,250", "x17", "17") and numeric values/attributes under the
-- player are sampled. A candidate that was stable across two snapshots before an event and moved in
-- the expected direction right after it gains evidence:
--   verified ore yield -> the inventory counter rises;  verified sale -> money rises, inventory falls.
-- Two consistent observations promote a candidate. Results are stored per place (Learned) and feed
-- Inventory (capacity, full detection by "ore mined but counter unchanged") and Wallet (sale checks).
Learn = {candidates = {}, lastCollect = -1000, lastTick = 0, ring = {}, invEvidence = {},
    moneyEvidence = {}, inv = nil, money = nil, noGain = 0}

local function readGuiNumber(label)
    local text = label.Text or ""
    local a, b = U.parseFraction(text)
    if a then return a, b, "fraction" end
    local money = U.parseMoney(text)
    if money then return money, nil, "money" end
    local n = string.match(text, "^%s*[xX]?%s*([%d,]+%.?%d*)%s*$")
    if n then return tonumber((string.gsub(n, ",", ""))), nil, "number" end
    return nil
end

local function guiPath(inst)
    local names, node = {}, inst
    while node and node ~= PlayerGui do
        table.insert(names, 1, node.Name)
        node = node.Parent
    end
    if node ~= PlayerGui then return nil end
    return table.concat(names, "/")
end

local LEARN_MONEY_HINTS = {"money", "cash", "dollar", "bank", "wallet", "balance", "bucks", "coins", "funds"}

local function looksLikeMoney(c)
    if c.mode == "money" then return true end
    local lp = string.lower(c.path or "")
    for _, w in ipairs(LEARN_MONEY_HINTS) do if U.has(lp, w) then return true end end
    return false
end

-- Candidate: {key, kind = "gui" | "value" | "attr", inst, holder, attr, path, mode}
function Learn.collect(force)
    if not force and U.now() - Learn.lastCollect < 20 then return end
    Learn.lastCollect = U.now()
    local list = {}
    if PlayerGui then
        local ok, desc = pcall(function() return PlayerGui:GetDescendants() end)
        if ok then
            for _, inst in ipairs(desc) do
                if #list >= 700 then break end
                if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and not U.isDescendantOf(inst, UI and UI.root) then
                    local v, _, mode = readGuiNumber(inst)
                    if v then list[#list + 1] = {key = inst, kind = "gui", inst = inst, mode = mode, path = guiPath(inst)} end
                end
            end
        end
    end
    if LocalPlayer then
        local ok, desc = pcall(function() return LocalPlayer:GetDescendants() end)
        if ok then
            local n = 0
            for _, inst in ipairs(desc) do
                if n >= 300 then break end
                if (inst:IsA("IntValue") or inst:IsA("NumberValue")) and not (PlayerGui and inst:IsDescendantOf(PlayerGui)) then
                    n = n + 1
                    list[#list + 1] = {key = inst, kind = "value", inst = inst, mode = "number",
                        path = "value " .. U.fullName(inst)}
                end
            end
        end
        for _, holder in ipairs({LocalPlayer, Char.character}) do
            local okAttrs, attrs = pcall(function() return holder:GetAttributes() end)
            if okAttrs then
                local label = holder == LocalPlayer and "Player" or "Character"
                for name, value in pairs(attrs) do
                    if type(value) == "number" then
                        list[#list + 1] = {key = label .. "@" .. name, kind = "attr", holder = holder, attr = name,
                            mode = "number", path = label .. "@" .. name}
                    end
                end
            end
        end
    end
    Learn.candidates = list
end

function Learn.read(c)
    if c.kind == "gui" then
        if not U.alive(c.inst) then return nil end
        local v, cap = readGuiNumber(c.inst)
        return v, cap
    elseif c.kind == "value" then
        if not U.alive(c.inst) then return nil end
        local ok, v = pcall(function() return c.inst.Value end)
        return ok and tonumber(v) or nil
    end
    local ok, v = pcall(function() return c.holder:GetAttribute(c.attr) end)
    return ok and tonumber(v) or nil
end

function Learn.snapshot()
    local snap = {t = U.now(), values = {}}
    for _, c in ipairs(Learn.candidates) do
        local v = Learn.read(c)
        if v then snap.values[c.key] = v end
    end
    return snap
end

-- Called every swing: keeps the last three snapshots as the pre-event baseline.
function Learn.tick()
    Learn.collect(false)
    local now = U.now()
    if now - Learn.lastTick < 0.7 then return end
    Learn.lastTick = now
    local ring = Learn.ring
    ring[#ring + 1] = Learn.snapshot()
    if #ring > 3 then table.remove(ring, 1) end
end

-- Candidates stable across both baselines whose value moved afterwards: list of {c, delta}.
local function stableChanges(b1, b2, after)
    local out = {}
    for _, c in ipairs(Learn.candidates) do
        local v1, v2, v3 = b1.values[c.key], b2.values[c.key], after.values[c.key]
        if v1 and v2 and v3 and v1 == v2 and v3 ~= v2 then out[#out + 1] = {c = c, delta = v3 - v2} end
    end
    return out
end

local function promote(which, c)
    if which == "inv" then
        Learn.inv = c
        Learned.set("inventoryPath", c.path)
        Log.info("Learn", "Learned the inventory counter by observation: " .. tostring(c.path))
        Inventory.scan(true)
    else
        Learn.money = c
        Learned.set("moneyPath", c.path)
        Wallet.source, Wallet.label = function() return (Learn.read(c)) end, "Learned: " .. tostring(c.path)
        Log.info("Learn", "Learned the money display from a sale: " .. tostring(c.path))
    end
end

-- Evaluates a verified yield one and a half seconds later, against the pre-yield baseline.
function Learn.onEvent(kind, amount)
    local ring = Learn.ring
    if kind ~= "yield" or #ring < 2 then return end
    local b1, b2 = ring[#ring - 1], ring[#ring]
    SESSION:spawn("Learn.yield", function()
        task.wait(1.5)
        local after = Learn.snapshot()
        local invRose = false
        for _, ch in ipairs(stableChanges(b1, b2, after)) do
            if ch.delta > 0 and not looksLikeMoney(ch.c) then
                local e = (Learn.invEvidence[ch.c.key] or 0) + 1
                Learn.invEvidence[ch.c.key] = e
                if Learn.inv == ch.c then invRose = true end
                if not Learn.inv and e >= 2 and ch.c.mode == "fraction" then promote("inv", ch.c) end
            end
        end
        -- Correlation check: ore was verifiably mined but the learned counter did not move.
        if Learn.inv and U.alive(Learn.inv.inst or Learn.inv.holder) then
            if invRose then
                Learn.noGain = 0
            else
                Learn.noGain = Learn.noGain + 1
                if Learn.noGain >= 2 then
                    Learn.noGain = 0
                    Inventory.markFull("ore was mined twice but the inventory counter did not change")
                end
            end
        end
    end)
end

-- Sale evaluation against baselines taken right before the interaction. commit=true records evidence
-- and may promote candidates; returns a verification text when money rose or inventory fell.
function Learn.evaluateSale(b1, b2, after, commit, countMoney)
    local verdict = nil
    for _, ch in ipairs(stableChanges(b1, b2, after)) do
        local c = ch.c
        if ch.delta > 0 and looksLikeMoney(c) then
            verdict = verdict or ("money display " .. tostring(c.path) .. " rose by " .. U.num(ch.delta))
            if commit then
                if countMoney then Stats.moneyEarned = Stats.moneyEarned + ch.delta end
                Learn.moneyEvidence[c.key] = (Learn.moneyEvidence[c.key] or 0) + 2
                if not Learn.money then promote("money", c) end
            end
        elseif ch.delta > 0 then
            if commit then
                local e = (Learn.moneyEvidence[c.key] or 0) + 1
                Learn.moneyEvidence[c.key] = e
                if e >= 2 and not Learn.money then promote("money", c) end
            end
        elseif ch.delta < 0 and (c == Learn.inv or c.mode == "fraction") then
            verdict = verdict or ("inventory counter " .. tostring(c.path) .. " fell by " .. U.num(-ch.delta))
        end
    end
    return verdict
end

-- True when some money-like or "N/M" display exists, i.e. a sale could be observed at all.
function Learn.canObserveSale()
    for _, c in ipairs(Learn.candidates) do
        if looksLikeMoney(c) or c.mode == "fraction" then return true end
    end
    return false
end

-- Re-binds counters learned in an earlier session (paths stored per place).
function Learn.restore()
    Learn.collect(true)
    local invPath, moneyPath = Learned.get("inventoryPath"), Learned.get("moneyPath")
    for _, c in ipairs(Learn.candidates) do
        if invPath and c.path == invPath and not Learn.inv then Learn.inv = c end
        if moneyPath and c.path == moneyPath and not Learn.money then
            Learn.money = c
            Wallet.source, Wallet.label = function() return (Learn.read(c)) end, "Learned: " .. tostring(c.path)
        end
    end
end

-- ==== MODULE: Inventory ==================================================================
-- TWW's inventory internals are not publicly documented, so this module DISCOVERS candidate
-- sources (player attributes/values and PlayerGui "N/M" labels in inventory-like containers),
-- ranks them, and lets the user override the choice. Unknown stays unknown: no capacity is assumed.
-- Full-inventory evidence also comes from "inventory full"-style messages and from ore that drops on
-- the ground next to the player while mining (community wiki: a full inventory drops mined ore).
Inventory = {
    state = {known = false, used = nil, capacity = nil, fraction = nil, source = "Not detected",
        fullFlag = false, fullReason = nil, fullAt = 0, oreItems = 0, lastRead = 0},
    candidates = {},
    choice = 0,
    messageLabels = {},
    lastScan = -1000,
    dropConn = nil,
    guiConn = nil,
    depositsSinceSell = 0,
    dropsObserved = 0,
    lastYieldAt = -1000,
}

local INV_WORDS = {inventory = 4, backpack = 3, capacity = 4, bag = 3, bags = 3, slots = 3, slot = 2,
    storage = 3, weight = 2, carry = 3, items = 1, item = 1, pack = 1, satchel = 3, load = 1}
local INV_NEGATIVE = {"ammo", "health", "stamina", "hunger", "thirst", "xp", "exp", "level", "bullet",
    "round", "clip", "mag", "horse", "bounty", "players", "server"}
local FULL_PHRASES = {"inventory full", "inventory is full", "backpack full", "backpack is full", "bag is full",
    "bags are full", "no room", "not enough space", "no space", "too heavy", "can't carry", "cannot carry",
    "carrying too much", "inventory space"}
local MESSAGE_WORDS = {"notif", "message", "alert", "toast", "popup", "hint", "announce", "warning", "error", "feed"}

local function contextScore(inst)
    local score, text = 0, ""
    local node = inst
    for _ = 1, 5 do
        if not node or node == PlayerGui then break end
        text = text .. " " .. string.lower(node.Name)
        node = node.Parent
    end
    for word, weight in pairs(INV_WORDS) do
        if U.has(text, word) then score = score + weight end
    end
    for _, word in ipairs(INV_NEGATIVE) do
        if U.has(text, word) then score = score - 6 end
    end
    return score, text
end

local function isOurs(inst)
    return UI and UI.root and U.isDescendantOf(inst, UI.root)
end

local function attributeCandidates(holder, prefix, out)
    local ok, attrs = pcall(function() return holder:GetAttributes() end)
    if not ok then return end
    for name, value in pairs(attrs) do
        if type(value) == "number" then
            local lname = string.lower(name)
            local relevant = false
            for word in pairs(INV_WORDS) do if U.has(lname, word) then relevant = true break end end
            if relevant and not U.has(lname, "max") then
                for _, maxName in ipairs({"Max" .. name, name .. "Max", (string.gsub(name, "Current", "Max"))}) do
                    local maxValue = attrs[maxName]
                    if maxName ~= name and type(maxValue) == "number" and maxValue > 0 then
                        out[#out + 1] = {kind = "attribute", score = 8, label = prefix .. "@" .. name .. "/" .. maxName,
                            read = function()
                                local a, b = holder:GetAttribute(name), holder:GetAttribute(maxName)
                                if type(a) == "number" and type(b) == "number" and b > 0 then return a, b end
                                return nil
                            end}
                        break
                    end
                end
            end
        end
    end
end

local function valueCandidates(root, out)
    local ok, list = pcall(function() return root:GetDescendants() end)
    if not ok then return end
    local byName, checked = {}, 0
    for _, v in ipairs(list) do
        checked = checked + 1
        if checked > 400 then break end
        if (v:IsA("IntValue") or v:IsA("NumberValue")) and not (PlayerGui and v:IsDescendantOf(PlayerGui)) then
            byName[string.lower(v.Name)] = v
        end
    end
    for lname, v in pairs(byName) do
        local relevant = false
        for word in pairs(INV_WORDS) do if U.has(lname, word) then relevant = true break end end
        if relevant and not U.has(lname, "max") then
            local maxV = byName["max" .. lname] or byName[lname .. "max"] or byName[(string.gsub(lname, "current", "max"))]
            if maxV and maxV ~= v then
                out[#out + 1] = {kind = "value", score = 7, label = U.fullName(v) .. " / " .. maxV.Name,
                    read = function()
                        if not U.alive(v) or not U.alive(maxV) or maxV.Value <= 0 then return nil end
                        return v.Value, maxV.Value
                    end}
            end
        end
    end
end

-- Heavy discovery pass; throttled (15 s) unless forced.
function Inventory.scan(force)
    local now = U.now()
    if not force and now - Inventory.lastScan < 15 then return end
    Inventory.lastScan = now
    local candidates, messages = {}, {}
    if LocalPlayer then
        attributeCandidates(LocalPlayer, "Player", candidates)
        if Char.character then attributeCandidates(Char.character, "Character", candidates) end
        valueCandidates(LocalPlayer, candidates)
    end
    if PlayerGui then
        local ok, list = pcall(function() return PlayerGui:GetDescendants() end)
        if ok then
            for _, inst in ipairs(list) do
                if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and not isOurs(inst) then
                    local text = inst.Text or ""
                    local used, cap = U.parseFraction(text)
                    if used then
                        local score, ctx = contextScore(inst)
                        if score >= 2 then
                            local label = inst
                            candidates[#candidates + 1] = {kind = "gui", score = score, inst = inst,
                                label = "GUI " .. U.fullName(inst):gsub("^.-PlayerGui%.", "") .. "  [" .. text .. "]",
                                read = function()
                                    if not U.alive(label) then return nil end
                                    return U.parseFraction(label.Text)
                                end}
                        end
                    end
                    if #messages < 80 then
                        local _, ctx = contextScore(inst)
                        for _, word in ipairs(MESSAGE_WORDS) do
                            if U.has(ctx, word) then messages[#messages + 1] = inst break end
                        end
                    end
                end
            end
        end
    end
    table.sort(candidates, function(a, b) return a.score > b.score end)
    local learned = Learn.inv
    if learned and U.alive(learned.inst or learned.holder) then
        table.insert(candidates, 1, {kind = "learned", score = 1000, label = "Learned " .. tostring(learned.path),
            read = function()
                local v, cap = Learn.read(learned)
                if v and cap then return v, cap end
                return nil
            end})
    end
    Inventory.candidates = candidates
    Inventory.messageLabels = messages
    if Inventory.choice > #candidates then Inventory.choice = 0 end
    Log.debug("Inventory", string.format("Scan: %d capacity candidates, %d message labels", #candidates, #messages))
end

function Inventory.current()
    if Inventory.choice > 0 then return Inventory.candidates[Inventory.choice] end
    return Inventory.candidates[1]
end

function Inventory.cycleChoice()
    Inventory.scan(true)
    local n = #Inventory.candidates
    if n == 0 then Inventory.choice = 0 return end
    Inventory.choice = (Inventory.choice + 1) % (n + 1)
end

local function textIsFull(text)
    local lower = string.lower(text or "")
    for _, phrase in ipairs(FULL_PHRASES) do
        if U.has(lower, phrase) then return phrase end
    end
    return nil
end

local function visibleChain(inst)
    local node = inst
    for _ = 1, 12 do
        if not node or node == PlayerGui then return true end
        local ok, visible = pcall(function()
            if node:IsA("GuiObject") then return node.Visible end
            if node:IsA("LayerCollector") then return node.Enabled end
            return true
        end)
        if ok and visible == false then return false end
        node = node.Parent
    end
    return true
end

function Inventory.markFull(reason)
    local s = Inventory.state
    if not s.fullFlag then Log.warn("Inventory", "Inventory reported full: " .. tostring(reason)) end
    s.fullFlag, s.fullReason, s.fullAt = true, reason, U.now()
end

function Inventory.oreItemCount()
    if not LocalPlayer then return 0 end
    local total = 0
    local containers = {LocalPlayer:FindFirstChildOfClass("Backpack"), Char.character}
    for _, container in ipairs(containers) do
        if container then
            for _, item in ipairs(container:GetChildren()) do
                if item:IsA("Tool") and not Tools.score(item) then
                    local lname = string.lower(item.Name)
                    local isOre = U.has(lname, "ore")
                    if not isOre then
                        for _, kind in ipairs(Ores.kindList) do
                            if U.has(lname, string.lower(kind)) then isOre = true break end
                        end
                    end
                    if isOre then
                        local qty = item:GetAttribute("Quantity") or item:GetAttribute("Amount") or item:GetAttribute("Count")
                        local qv = item:FindFirstChild("Quantity") or item:FindFirstChild("Amount")
                        if type(qty) ~= "number" and qv and qv:IsA("ValueBase") then qty = tonumber(qv.Value) end
                        total = total + ((type(qty) == "number" and qty > 0) and qty or 1)
                    end
                end
            end
        end
    end
    return total
end

-- Cheap periodic read of the chosen source plus message labels.
function Inventory.read()
    local s = Inventory.state
    s.lastRead = U.now()
    Inventory.scan(false)
    local src = Inventory.current()
    local used, cap = nil, nil
    if src then
        local ok, a, b = pcall(src.read)
        if ok then used, cap = a, b end
    end
    if used and cap then
        s.known, s.used, s.capacity, s.fraction = true, used, cap, used / cap
        s.source = src.label
        if s.fullFlag and s.fraction < Config.get("sellThreshold") and U.now() - s.fullAt > 5 then
            s.fullFlag, s.fullReason = false, nil
        end
    else
        s.known, s.used, s.capacity, s.fraction = false, nil, nil, nil
        s.source = src and ("Unreadable: " .. src.label) or "Not detected (no inventory counter found)"
    end
    for _, label in ipairs(Inventory.messageLabels) do
        if U.alive(label) then
            local phrase = textIsFull(label.Text)
            if phrase and visibleChain(label) then Inventory.markFull("UI message \"" .. phrase .. "\"") break end
        end
    end
    s.oreItems = Inventory.oreItemCount()
    return s
end

-- True when mining should stop because inventory needs unloading.
-- With auto-sell enabled, the configured threshold also applies.
function Inventory.shouldSell()
    local s = Inventory.state
    if s.fullFlag then return true, s.fullReason end
    if s.known and s.fraction then
        if s.fraction >= 1 then return true, "inventory " .. U.num(s.used) .. "/" .. U.num(s.capacity) end
        if Config.get("autoSell") and s.fraction >= Config.get("sellThreshold") then
            return true, string.format("inventory %s/%s reached threshold %s", U.num(s.used), U.num(s.capacity),
                U.fmtPct(Config.get("sellThreshold")))
        end
    end
    local every = Config.get("sellAfterDeposits")
    if Config.get("autoSell") and every > 0 and Inventory.depositsSinceSell >= every then
        return true, "sell-after-" .. every .. "-deposits rule"
    end
    return false, nil
end

function Inventory.snapshot()
    local s = Inventory.state
    return {used = s.known and s.used or nil, oreItems = Inventory.oreItemCount(), money = Wallet.read()}
end

function Inventory.gainBetween(a, b)
    local gain = 0
    if a.used and b.used and b.used > a.used then gain = b.used - a.used end
    if b.oreItems > a.oreItems then gain = math.max(gain, b.oreItems - a.oreItems) end
    return gain
end

function Inventory.resetAfterSale()
    local s = Inventory.state
    s.fullFlag, s.fullReason = false, nil
    Inventory.depositsSinceSell = 0
end

-- Ground-drop detection, only active while mining.
-- Community wiki (Ores and Gems, v3.7.5): "If your inventory is full, the ore will drop to the ground
-- instead" and nodes can drop gems instead of ore. A new ore- or gem-named object appearing next to the
-- player while mining (outside the Mining tree and outside any character) is treated as "inventory full".
local function checkDroppedItem(inst)
    if not U.alive(inst) then return end
    if Ores.root and inst:IsDescendantOf(Ores.root) then return end
    if Visual.folder and inst:IsDescendantOf(Visual.folder) then return end
    for _, model in ipairs(Tools.characterModels()) do
        if inst:IsDescendantOf(model) then return end
    end
    local entities = Workspace:FindFirstChild("WORKSPACE_Entities")
    local playerModels = entities and entities:FindFirstChild("Players")
    if playerModels and inst:IsDescendantOf(playerModels) then return end
    if Players then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character and inst:IsDescendantOf(plr.Character) then return end
        end
    end
    local named = Ores.isGemOrOreName(inst.Name)
    if not named then
        local lname = string.lower(inst.Name)
        for _, kind in ipairs(Ores.kindList) do
            if U.has(lname, string.lower(kind)) then named = true break end
        end
    end
    if not named then return end
    local p, here = U.positionOf(inst), Char.position()
    if not (p and here) then return end
    local d = U.dist(p, here)
    local recentYield = U.now() - (Inventory.lastYieldAt or -1000) < 6
    if d < 20 or (recentYield and d < 35) then
        Inventory.dropsObserved = Inventory.dropsObserved + 1
        Inventory.markFull("mined ore/gem dropped on the ground (" .. inst.Name .. ")")
    end
end

-- Cheap class filter now; name/parent/position are checked one step later because a dropped item
-- may be parented before it is named and positioned.
function Inventory.onWorldAdded(inst)
    if inst:IsA("Tool") or inst:IsA("Model") or inst:IsA("BasePart") then
        task.defer(checkDroppedItem, inst)
    end
end

function Inventory.watchDrops(on)
    if on and not Inventory.dropConn then
        Inventory.dropConn = SESSION:connect(Workspace.DescendantAdded, Inventory.onWorldAdded, "DropWatcher")
    elseif not on and Inventory.dropConn then
        SESSION:disconnect(Inventory.dropConn)
        Inventory.dropConn = nil
    end
end

function Inventory.init()
    if PlayerGui then
        -- New notification labels are checked immediately instead of waiting for the next scan.
        Inventory.guiConn = SESSION:connect(PlayerGui.DescendantAdded, function(inst)
            if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and not isOurs(inst) then
                task.defer(function()
                    if U.alive(inst) and textIsFull(inst.Text) and visibleChain(inst) then
                        Inventory.markFull("UI message \"" .. textIsFull(inst.Text) .. "\"")
                    end
                end)
            end
        end, "Inventory.GuiAdded")
    end
    Inventory.scan(true)
    Inventory.read()
end

-- ==== MODULE: Wallet =====================================================================
-- Optional money tracker used to CONFIRM sales. Sources: leaderstats, player attributes/values,
-- or a "$1,234" label in PlayerGui. If none is found, sale confirmation relies on inventory only.
Wallet = {source = nil, label = "Not detected", lastValue = nil, lastDiscover = -1000}
local MONEY_WORDS = {"money", "cash", "dollar", "bank", "wallet", "balance", "bucks", "coins", "funds"}

local function moneyName(name)
    local lname = string.lower(name)
    for _, w in ipairs(MONEY_WORDS) do if U.has(lname, w) then return true end end
    return false
end

function Wallet.discover(force)
    if not force and U.now() - Wallet.lastDiscover < 20 then return end
    Wallet.lastDiscover = U.now()
    if Learn.money and Learn.read(Learn.money) then
        Wallet.source = function() return (Learn.read(Learn.money)) end
        Wallet.label = "Learned: " .. tostring(Learn.money.path)
        return
    end
    Wallet.source, Wallet.label = nil, "Not detected"
    if not LocalPlayer then return end
    local stats = LocalPlayer:FindFirstChild("leaderstats")
    if stats then
        for _, v in ipairs(stats:GetChildren()) do
            if (v:IsA("IntValue") or v:IsA("NumberValue")) and moneyName(v.Name) then
                Wallet.source = function() return v.Value end
                Wallet.label = "leaderstats." .. v.Name
                return
            end
        end
    end
    local okAttrs, attrs = pcall(function() return LocalPlayer:GetAttributes() end)
    if okAttrs then
        for name, value in pairs(attrs) do
            if type(value) == "number" and moneyName(name) then
                Wallet.source = function() return LocalPlayer:GetAttribute(name) end
                Wallet.label = "Player@" .. name
                return
            end
        end
    end
    for _, v in ipairs(LocalPlayer:GetChildren()) do
        if (v:IsA("IntValue") or v:IsA("NumberValue")) and moneyName(v.Name) then
            Wallet.source = function() return v.Value end
            Wallet.label = "Player." .. v.Name
            return
        end
    end
    if PlayerGui then
        local best, bestScore = nil, 0
        local ok, list = pcall(function() return PlayerGui:GetDescendants() end)
        if ok then
            for _, inst in ipairs(list) do
                if inst:IsA("TextLabel") and not isOurs(inst) and string.match(inst.Text or "", "^%s*%$%s*[%d,]+%.?%d*%s*$") then
                    local score = 1
                    local node = inst
                    for _ = 1, 4 do
                        if not node then break end
                        if moneyName(node.Name) then score = score + 3 end
                        node = node.Parent
                    end
                    if score > bestScore then best, bestScore = inst, score end
                end
            end
        end
        if best then
            Wallet.source = function() return U.alive(best) and U.parseMoney(best.Text) or nil end
            Wallet.label = "GUI " .. U.fullName(best):gsub("^.-PlayerGui%.", "")
        end
    end
end

function Wallet.read()
    if not Wallet.source then return nil end
    local ok, v = pcall(Wallet.source)
    if ok and type(v) == "number" then
        Wallet.lastValue = v
        return v
    end
    return nil
end

-- ==== MODULE: Sellers ====================================================================
-- Seller discovery. A community forum report says ore is sold by holding the sell prompt at the
-- General Store / Gun Store NPCs; this module therefore looks for ProximityPrompts whose text says
-- "sell" (strong), prompts on store/merchant NPCs (weak), and store buildings (position hints).
-- Discovery is one chunked initial scan, then event-driven (DescendantAdded/Removing).
Sellers = {
    prompts = {},
    buildings = {},
    list = {},
    status = "Not scanned",
    scanning = false,
    scanned = false,
    lastScan = -1000,
    blacklist = Blacklist.new("sellers"),
    current = nil,
    lastResult = "-",
    lastDetail = "",
    manualIndex = 0,
}

local STORE_WORDS_STRONG = {"general store", "generalstore", "general_store", "gun store", "gunstore",
    "gun_store", "gunsmith", "merchant", "shopkeeper", "shopkeep", "clerk", "vendor", "trader", "assay"}
local STORE_WORDS_WEAK = {"store", "shop"}
local INTERACT_WORDS = {"talk", "shop", "trade", "open", "buy", "interact", "speak"}

local function ancestryText(inst, levels)
    local text, node = "", inst
    for _ = 1, levels do
        if not node or node == Workspace then break end
        text = text .. " " .. string.lower(node.Name)
        node = node.Parent
    end
    return text
end

local function storeBonus(text)
    for _, w in ipairs(STORE_WORDS_STRONG) do if U.has(text, w) then return 30 end end
    for _, w in ipairs(STORE_WORDS_WEAK) do if U.has(text, w) then return 15 end end
    return 0
end

local function inExcludedTree(inst)
    if Ores.root and U.isDescendantOf(inst, Ores.root) then return true end
    if Players then
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr.Character and U.isDescendantOf(inst, plr.Character) then return true end
        end
    end
    return false
end

function Sellers.classifyPrompt(prompt)
    local ok, text = pcall(function()
        return string.lower((prompt.ActionText or "") .. " " .. (prompt.ObjectText or "") .. " " .. prompt.Name)
    end)
    if not ok then return nil end
    if inExcludedTree(prompt) then return nil end
    local bonus = storeBonus(ancestryText(prompt.Parent, 5) .. " " .. text)
    local score = 0
    if U.has(text, "sell") then
        score = 100 + bonus
    elseif bonus > 0 then
        for _, w in ipairs(INTERACT_WORDS) do
            if U.has(text, w) then score = 40 + bonus break end
        end
    end
    if score == 0 then return nil end
    local objectText, actionText = "", ""
    pcall(function() objectText, actionText = prompt.ObjectText, prompt.ActionText end)
    local owner = prompt.Parent and prompt.Parent.Name or "?"
    if prompt.Parent and prompt.Parent.Parent and prompt.Parent:IsA("BasePart") then owner = prompt.Parent.Parent.Name end
    local label = string.format("%s - \"%s\"", objectText ~= "" and objectText or owner, actionText ~= "" and actionText or prompt.Name)
    return score, label
end

local function considerPrompt(prompt)
    local score, label = Sellers.classifyPrompt(prompt)
    if score then
        Sellers.prompts[prompt] = {key = prompt, kind = "prompt", prompt = prompt, score = score, label = label}
    end
end

local function considerBuilding(inst)
    local lname = string.lower(inst.Name)
    for _, w in ipairs(STORE_WORDS_STRONG) do
        if U.has(lname, w) then
            if not inExcludedTree(inst) then
                Sellers.buildings[inst] = {key = inst, kind = "building", building = inst, score = 20,
                    label = "Building: " .. inst.Name}
            end
            return
        end
    end
end

local function onDescendantAdded(inst)
    local class = inst.ClassName
    if class == "ProximityPrompt" then
        task.defer(function() if U.alive(inst) then considerPrompt(inst) end end)
    elseif class == "Model" or class == "Folder" then
        considerBuilding(inst)
    end
end

local function onDescendantRemoving(inst)
    if Sellers.prompts[inst] then Sellers.prompts[inst] = nil end
    if Sellers.buildings[inst] then Sellers.buildings[inst] = nil end
end

-- Initial chunked scan (yields every 1500 instances to avoid frame spikes).
function Sellers.scan(force)
    if Sellers.scanning then return end
    if Sellers.scanned and not force then return end
    Sellers.scanning = true
    Sellers.status = "Scanning world for sellers..."
    SESSION:spawn("Sellers.scan", function()
        local ok, list = pcall(function() return Workspace:GetDescendants() end)
        if ok then
            for i, inst in ipairs(list) do
                if not SESSION.alive then return end
                local class = inst.ClassName
                if class == "ProximityPrompt" then considerPrompt(inst)
                elseif class == "Model" or class == "Folder" then considerBuilding(inst) end
                if i % 1500 == 0 then task.wait() end
            end
        end
        Sellers.scanning = false
        Sellers.scanned = true
        Sellers.lastScan = U.now()
        local p, b = U.count(Sellers.prompts), U.count(Sellers.buildings)
        Sellers.status = string.format("%d sell prompt(s), %d store building(s) known", p, b)
        Log.info("Sellers", Sellers.status)
    end)
end

function Sellers.init()
    SESSION:connect(Workspace.DescendantAdded, onDescendantAdded, "Sellers.Added")
    SESSION:connect(Workspace.DescendantRemoving, onDescendantRemoving, "Sellers.Removing")
    Sellers.scan(true)
end

function Sellers.position(c)
    if c.kind == "prompt" then return U.alive(c.prompt) and U.anchorPosition(c.prompt.Parent) or nil end
    if c.kind == "building" then return U.positionOf(c.building) end
    if c.kind == "point" then return c.pos end
    return nil
end

-- Ranked candidate list (prompts first, then buildings, then the optional fallback point).
function Sellers.rank()
    local here = Char.position()
    local list = {}
    local function add(c)
        local pos = Sellers.position(c)
        if pos then
            c.pos = pos
            c.dist = here and U.dist(here, pos) or math.huge
            c.cost = c.dist - c.score * 4 + Sellers.memoryAdjust(c)
            c.blocked = Sellers.blacklist:blocked(c.key)
            list[#list + 1] = c
        end
    end
    for _, c in pairs(Sellers.prompts) do add(c) end
    for _, c in pairs(Sellers.buildings) do add(c) end
    local point = U.tableToVec(Config.get("sellPoint"))
    if point then
        add({key = "fallback-point", kind = "point", pos = point, score = 10, label = "Fallback sell point (user set)"})
    end
    table.sort(list, function(a, b)
        if a.blocked ~= b.blocked then return not a.blocked end
        return a.cost < b.cost
    end)
    Sellers.list = list
    return list
end

local function nearAny(list, pos, radius)
    for _, t in ipairs(type(list) == "table" and list or {}) do
        local v = U.tableToVec(t)
        if v and U.dist(v, pos) < radius then return true end
    end
    return false
end

-- Per-place memory: sellers that paid are preferred, sellers that did not are tried last. A forum
-- report says the Howling Peak merchant and the Hunter Shack did not buy loot, so those rank lower too.
function Sellers.memoryAdjust(c)
    c.knownGood = nearAny(Learned.get("goodSellers"), c.pos, 15)
    c.knownBad = not c.knownGood and nearAny(Learned.get("badSellers"), c.pos, 15)
    local adjust = (c.knownGood and -300 or 0) + (c.knownBad and 400 or 0)
    local owner = c.prompt or c.building
    if owner then
        local text = ancestryText(owner, 6)
        if U.has(text, "howling") or U.has(text, "hunter") then adjust = adjust + 250 end
    end
    return adjust
end

function Sellers.remember(c, good)
    if not c or not c.pos then return end
    local keep, drop = good and "goodSellers" or "badSellers", good and "badSellers" or "goodSellers"
    local list = Learned.get(keep)
    if type(list) ~= "table" then list = {} end
    if not nearAny(list, c.pos, 15) then
        list[#list + 1] = U.vecToTable(c.pos)
        while #list > 20 do table.remove(list, 1) end
    end
    Learned.set(keep, list)
    local other = Learned.get(drop)
    if type(other) == "table" then
        for i = #other, 1, -1 do
            local v = U.tableToVec(other[i])
            if v and U.dist(v, c.pos) < 15 then table.remove(other, i) end
        end
    end
    Config.dirty = true
end

function Sellers.cycleManual()
    local list = Sellers.rank()
    if #list == 0 then Sellers.manualIndex = 0 return nil end
    Sellers.manualIndex = (Sellers.manualIndex + 1) % (#list + 1)
    return Sellers.manualIndex > 0 and list[Sellers.manualIndex] or nil
end

-- Picks a seller; reachable candidates (validated path) win. Returns candidate or nil, reason.
function Sellers.choose(token)
    local list = Sellers.rank()
    if Sellers.manualIndex > 0 and list[Sellers.manualIndex] then
        return list[Sellers.manualIndex], "manual selection"
    end
    local here = Char.position()
    if not here then return nil, "character unavailable" end
    local checked = 0
    for _, c in ipairs(list) do
        if not c.blocked then
            if c.dist > Config.get("maxLegLength") or checked >= 3 then return c, "nearest (progressive route)" end
            checked = checked + 1
            local waypoints, why = Nav.compute(here, c.pos, false, token)
            if waypoints then return c, "path validated" end
            Sellers.blacklist:mark(c.key, "no path: " .. tostring(why))
            Log.warn("Sellers", "Seller unreachable, skipping for now: " .. c.label, "sellerunreach:" .. c.label, 30)
            if token:dead() then return nil, "cancelled" end
        end
    end
    if #list == 0 then
        return nil, "No seller discovered yet (StreamingEnabled may hide distant stores). Set a fallback sell point."
    end
    return nil, "All known sellers are temporarily unreachable"
end

-- Nearest prompt candidate with a minimum score within radius of a position.
function Sellers.findNear(pos, radius, minScore)
    local best, bestD = nil, nil
    for _, c in pairs(Sellers.prompts) do
        if c.score >= (minScore or 100) and U.alive(c.prompt) then
            local p = U.anchorPosition(c.prompt.Parent)
            if p then
                local d = U.dist(p, pos)
                if d <= radius and (not bestD or d < bestD) then best, bestD = c, d end
            end
        end
    end
    return best
end

local function promptRange(prompt)
    local range = 10
    pcall(function() range = prompt.MaxActivationDistance end)
    return math.max(3, range)
end

-- 1) optional executor fireproximityprompt, 2) ProximityPrompt:InputHoldBegin/End honouring
-- HoldDuration, 3) if the prompt did not report Triggered: hold the prompt's own key (the wiki says
-- "Sell Loot" is held with [F]) through VirtualInputManager, exactly as a player would.
local function triggerPrompt(prompt, token, wasTriggered)
    if Config.get("useFirePrompt") and Exec.fireproximityprompt then
        local ok, err = pcall(Exec.fireproximityprompt, prompt)
        return ok, err, "fireproximityprompt"
    end
    local hold = 0
    pcall(function() hold = prompt.HoldDuration end)
    local ok, err = pcall(function() prompt:InputHoldBegin() end)
    if ok then
        token:sleep(hold + 0.2)
        pcall(function() prompt:InputHoldEnd() end)
        token:sleep(0.4)
        if wasTriggered() then return true, nil, "InputHoldBegin/End" end
    end
    if Input.available() then
        local key = nil
        pcall(function() key = prompt.KeyboardKeyCode end)
        if key then
            Input.key(key, hold + 0.3, token)
            token:sleep(0.4)
            local keyName = tostring(key):gsub("^Enum%.KeyCode%.", "")
            return true, nil, "holding key " .. keyName
        end
    end
    if not ok then return false, err, "InputHoldBegin" end
    return true, nil, "InputHoldBegin/End (no Triggered event)"
end

local SELL_BUTTON_PATTERNS = {"^%s*sell%s*all", "^%s*sell%s*ores?", "^%s*sell%s*everything", "^%s*sell%s*$"}

local function findSellButton()
    if not PlayerGui then return nil end
    local ok, list = pcall(function() return PlayerGui:GetDescendants() end)
    if not ok then return nil end
    for _, inst in ipairs(list) do
        if inst:IsA("TextButton") and not U.isDescendantOf(inst, UI and UI.root) then
            local text = string.lower(inst.Text or "")
            for _, pattern in ipairs(SELL_BUTTON_PATTERNS) do
                if string.match(text, pattern) then
                    local visible = true
                    local node = inst
                    for _ = 1, 12 do
                        if not node or node == PlayerGui then break end
                        if node:IsA("GuiObject") and not node.Visible then visible = false break end
                        if node:IsA("LayerCollector") and not node.Enabled then visible = false break end
                        node = node.Parent
                    end
                    if visible then return inst end
                end
            end
        end
    end
    return nil
end

local function clickGuiButton(button)
    if not Exec.vim then return false, "VirtualInputManager unavailable" end
    return pcall(function()
        local inset = Vector2.new(0, 0)
        local gs = getService("GuiService")
        if gs then inset = gs:GetGuiInset() end
        local p = button.AbsolutePosition + button.AbsoluteSize / 2 + inset
        Exec.vim:SendMouseButtonEvent(p.X, p.Y, 0, true, game, 0)
        task.wait(0.06)
        Exec.vim:SendMouseButtonEvent(p.X, p.Y, 0, false, game, 0)
    end)
end

-- Walks to the candidate, triggers the normal prompt interaction and verifies the result.
-- Returns outcome ("sold" | "unverified" | "failed" | "unreachable" | "cancelled"), detail.
function Sellers.sell(c, token, onPhase)
    Sellers.current = c
    local phase = onPhase or function() end
    if c.kind ~= "prompt" then
        phase("Traveling to " .. c.label)
        local ok, why = Nav.travel(c.pos, token, {label = c.label, arriveRadius = 10})
        if not ok then return token:dead() and "cancelled" or "unreachable", "route failed: " .. tostring(why) end
        phase("Looking for a sell prompt nearby")
        local found
        for _ = 1, 10 do
            found = Sellers.findNear(c.pos, 70, 100)
            if found then break end
            if not token:sleep(0.5) then return "cancelled", "cancelled" end
        end
        if not found then return "failed", "no sell prompt found near " .. c.label end
        c = found
        Sellers.current = c
    end
    local prompt = c.prompt
    if not U.alive(prompt) then return "failed", "prompt disappeared" end
    local anchor = U.anchorPosition(prompt.Parent)
    if not anchor then return "failed", "prompt has no position" end
    local range = promptRange(prompt)
    local here = Char.position()
    if not here then return "cancelled", "character lost" end
    if U.dist(here, anchor) > range - 1 then
        phase("Traveling to " .. c.label)
        local flat = Vector3.new(here.X - anchor.X, 0, here.Z - anchor.Z)
        local unit = flat.Magnitude > 0.1 and flat.Unit or Vector3.new(1, 0, 0)
        local stand = Nav.groundAt(anchor + unit * math.min(range * 0.5, 5)) or anchor
        local ok, why = Nav.travel(stand, token, {label = c.label, arriveRadius = 2,
            arrivedCheck = function(pos) return U.dist(pos, anchor) <= range - 1.5 end,
            extraGoals = {anchor}})
        if not ok then return token:dead() and "cancelled" or "unreachable", "route failed: " .. tostring(why) end
    end
    Nav.stop()
    local _, _, root = Char.get()
    if root then
        pcall(function() root.CFrame = CFrame.lookAt(root.Position, Vector3.new(anchor.X, root.Position.Y, anchor.Z)) end)
    end
    local enabled = true
    pcall(function() enabled = prompt.Enabled end)
    if not enabled then return "failed", "sell prompt is disabled" end

    Inventory.read()
    local before = Inventory.snapshot()
    Learn.collect(true)
    local base1 = Learn.snapshot()
    token:sleep(0.8)
    local base2 = Learn.snapshot()
    local triggered = false
    local trigConn = SESSION:connect(prompt.Triggered, function() triggered = true end, "SellPrompt.Triggered")
    phase("Holding sell prompt")
    local ok, err, method = triggerPrompt(prompt, token, function() return triggered end)
    if not ok then
        SESSION:disconnect(trigConn)
        return "failed", "prompt interaction error (" .. tostring(method) .. "): " .. tostring(err)
    end
    -- Optional: a sell dialog may open. It is reported, and clicked only when explicitly enabled.
    local dialogNote = ""
    for _ = 1, 6 do
        local button = findSellButton()
        if button then
            dialogNote = " | sell dialog seen: " .. U.fullName(button):gsub("^.-PlayerGui%.", "")
            if Config.get("clickSellDialog") then
                local clicked, cerr = clickGuiButton(button)
                dialogNote = dialogNote .. (clicked and " (clicked)" or (" (click failed: " .. tostring(cerr) .. ")"))
            end
            break
        end
        if not token:sleep(0.4) then break end
    end
    phase("Verifying sale")
    local verdict, detail = nil, ""
    for _ = 1, 16 do
        if token:dead() then break end
        Inventory.read()
        local after = Inventory.snapshot()
        if before.money and after.money and after.money > before.money then
            Stats.moneyEarned = Stats.moneyEarned + (after.money - before.money)
            verdict, detail = "sold", string.format("money +%s", tostring(after.money - before.money))
        elseif before.used and after.used and after.used < before.used then
            verdict, detail = "sold", "inventory " .. U.num(before.used) .. " -> " .. U.num(after.used)
        elseif before.oreItems > 0 and after.oreItems < before.oreItems then
            verdict, detail = "sold", "ore items " .. U.num(before.oreItems) .. " -> " .. U.num(after.oreItems)
        end
        local observed = Learn.evaluateSale(base1, base2, Learn.snapshot(), false)
        if observed and not verdict then verdict, detail = "sold", observed end
        if verdict then break end
        task.wait(0.4)
    end
    Learn.evaluateSale(base1, base2, Learn.snapshot(), verdict == "sold", before.money == nil)
    SESSION:disconnect(trigConn)
    local trigNote = triggered and " | prompt reported Triggered" or " | no Triggered event observed"
    if verdict == "sold" then
        Inventory.resetAfterSale()
        Sellers.blacklist:success(c.key)
        return "sold", detail .. " via " .. method .. trigNote .. dialogNote
    end
    if not before.money and not before.used and before.oreItems == 0 and not Learn.canObserveSale() then
        return "unverified", "no money/inventory signal available to confirm the sale" .. trigNote .. dialogNote
    end
    return "failed", "no money or inventory change after interaction" .. trigNote .. dialogNote
end

-- ==== MODULE: Targeting ==================================================================
-- Scores deposits by estimated travel cost (real path length when known), priority, remaining
-- ore, past failures, verticality and contention, then path-validates the best few candidates.
Targeting = {lastList = {}, info = "-", lastReason = "-"}
local PRIORITY_WEIGHT = {0.45, 0.7, 1, 1.5, 2.4}

function Targeting.valid(entry)
    return entry ~= nil and Ores.isAvailable(entry) and Ores.isSelected(entry.kind)
end

function Targeting.contested(entry)
    if not Players then return false end
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and plr.Character then
            local root = plr.Character:FindFirstChild("HumanoidRootPart")
            if root and U.dist(root.Position, entry.pos) < 10 then return true end
        end
    end
    return false
end

function Targeting.score(entry, here)
    local cost, real = Nav.estimate(entry.node, here, entry.pos)
    local score = cost / PRIORITY_WEIGHT[Ores.priority(entry.kind)]
    local r = entry.remaining
    if r and r > 0 then score = score * (1 - math.min(r, 10) * 0.015) end
    score = score + Ores.blacklist:failures(entry.node) * 45
    if math.abs(entry.pos.Y - here.Y) > 25 then score = score + 40 end
    if Config.get("avoidContested") and Targeting.contested(entry) then score = score + 120 end
    return score, real
end

function Targeting.candidates(here)
    local list = {}
    for node, entry in pairs(Ores.deposits) do
        if entry.pos and Targeting.valid(entry) and not Ores.blacklist:blocked(node) then
            local score, real = Targeting.score(entry, here)
            list[#list + 1] = {entry = entry, score = score, real = real}
        end
    end
    table.sort(list, function(a, b) return a.score < b.score end)
    return list
end

-- Returns the best reachable deposit or nil, reason.
function Targeting.select(token)
    local here = Char.position()
    if not here then return nil, "character unavailable" end
    local list = Targeting.candidates(here)
    Targeting.lastList = list
    if #list == 0 then return nil, "no available deposits of the selected types" end
    local best, bestScore, bestInfo = nil, nil, nil
    local limit = math.min(#list, Config.get("validateCandidates"))
    for i = 1, limit do
        if token:dead() then return nil, "cancelled" end
        local entry = list[i].entry
        if Miner.atStandRange(entry, here) then return entry, "already in range" end
        if U.dist(here, entry.pos) > Config.get("maxLegLength") then
            if not best or list[i].score < bestScore then
                best, bestScore, bestInfo = entry, list[i].score, "far target, progressive route"
            end
        else
            local spots = Miner.standSpots(entry, here)
            local waypoints, why, len = Nav.compute(here, spots[1], false, token)
            if not waypoints and spots[2] then waypoints, why, len = Nav.compute(here, spots[2], false, token) end
            if waypoints then
                Nav.remember(entry.node, here, len)
                local score = Targeting.score(entry, here)
                if not best or score < bestScore then
                    best, bestScore, bestInfo = entry, score, string.format("path %d studs", math.floor(len))
                end
            elseif not token:dead() then
                local duration = Ores.blacklist:mark(entry.node, "no path: " .. tostring(why))
                Stats.unreachable = Stats.unreachable + 1
                Log.info("Targeting", string.format("%s deposit unreachable (%s); retry in %ds",
                    entry.kind, tostring(why), math.floor(duration)), "unreach:" .. entry.kind, 5)
            end
        end
    end
    if not best then return nil, "best candidates were unreachable" end
    return best, bestInfo
end

-- Nearest remembered (streamed-out) site of a selected ore type.
function Targeting.exploreSite()
    local here = Char.position()
    if not here or not Config.get("rememberSites") then return nil end
    local best, bestD = nil, nil
    for _, site in ipairs(Ores.memory) do
        if Ores.isSelected(site.kind) and not Ores.blacklist:blocked(site) then
            local d = U.dist(here, site.pos)
            if not bestD or d < bestD then best, bestD = site, d end
        end
    end
    return best
end

local function forgetSite(site)
    for i = #Ores.memory, 1, -1 do
        if Ores.memory[i] == site then table.remove(Ores.memory, i) end
    end
end

-- ==== MODULE: Auto (finite-state machine) ================================================
-- One driver thread per run (guarded by a generation counter), one handler per state, a per-state
-- timeout enforced through the step token, and pcall isolation. Handlers return nextState, activity.
Auto = {
    state = "IDLE", stateSince = U.now(), activity = "Idle", running = false, paused = false,
    pauseReason = nil, resumeCheck = nil, generation = 0, runToken = nil, stepToken = nil,
    ctx = {}, history = {}, consecutiveErrors = 0, lastError = nil, lastAccrue = U.now(),
}

local STATE_TIMEOUT = {
    SCANNING = 40, SELECTING_TARGET = 60, PATHFINDING = 45, TRAVELING = 240, APPROACHING = 30,
    EQUIPPING = 12, CHECKING_INVENTORY = 15, FINDING_SELLER = 75, TRAVELING_TO_SELLER = 600,
    SELLING = 90, RECOVERING = 75, ERROR = 40,
}

function Auto.timeoutFor(state)
    if state == "MINING" then return Config.get("mineTimeout") + 20 end
    return STATE_TIMEOUT[state] or 60
end

function Auto.accrue()
    local now = U.now()
    if Auto.running and not Auto.paused then
        Stats.accumulate(Auto.state, now - Auto.stateSince)
        Stats.runtime = Stats.runtime + (now - Auto.lastAccrue)
    end
    Auto.stateSince = now
    Auto.lastAccrue = now
end

function Auto.setState(new, activity)
    Auto.accrue()
    if new ~= Auto.state then
        local h = Auto.history
        h[#h + 1] = {from = Auto.state, to = new, t = U.now()}
        if #h > 40 then table.remove(h, 1) end
        Log.debug("FSM", Auto.state .. " -> " .. new .. (activity and (" | " .. activity) or ""))
    end
    Auto.state = new
    if activity then Auto.activity = activity end
end

function Auto.act(text)
    Auto.activity = text
end

-- Pause with a reason; optional check() auto-resumes when the blocking condition clears.
function Auto.halt(reason, check)
    Auto.paused = true
    Auto.pauseReason = reason
    Auto.resumeCheck = check
    Log.warn("FSM", "Automation paused: " .. tostring(reason))
end

local function finishAttempt(ctx, success)
    if not ctx.attemptCounted then return end
    ctx.attemptCounted = false
    if success then Stats.successAttempts = Stats.successAttempts + 1
    else Stats.failedAttempts = Stats.failedAttempts + 1 end
end

local H = {}
Auto.handlers = H

H.SCANNING = function(ctx, token)
    if not Char.get() then return "RECOVERING", "Waiting for character" end
    Ores.maintain(true)
    if not Ores.root then
        Auto.act("Mining folder not found; waiting for it to replicate")
        token:sleep(Config.get("scanInterval"))
        return "SCANNING"
    end
    return "CHECKING_INVENTORY", "Checking inventory"
end

H.CHECKING_INVENTORY = function(ctx, token)
    Inventory.read()
    local need, why = Inventory.shouldSell()
    if need then
        if Config.get("autoSell") then
            ctx.sellReason = why
            return "FINDING_SELLER", "Unloading: " .. tostring(why)
        end
        Auto.halt("Inventory needs unloading (" .. tostring(why) .. ") and auto-sell is off",
            function() Inventory.read() return not Inventory.shouldSell() end)
        return "PAUSED"
    end
    return "SELECTING_TARGET", "Choosing next deposit"
end

H.SELECTING_TARGET = function(ctx, token)
    Visual.highlightTarget(nil)
    ctx.target, ctx.site, ctx.leg = nil, nil, nil
    local entry, info = Targeting.select(token)
    if entry then
        ctx.target = entry
        ctx.legs, ctx.replans, ctx.approachTries, ctx.rangeReturns, ctx.equipFails = 0, 0, 0, 0, 0
        Targeting.info = info
        Visual.highlightTarget(entry.node)
        Nav.status.dest = entry.kind .. " deposit"
        Nav.status.destPos = entry.pos
        local here = Char.position()
        if here and Miner.atStandRange(entry, here) then return "EQUIPPING", entry.kind .. " deposit in range" end
        return "PATHFINDING", "Target " .. entry.kind .. " (" .. tostring(info) .. ")"
    end
    if token:dead() then return "SELECTING_TARGET" end
    Targeting.lastReason = info
    local site = Targeting.exploreSite()
    if site then
        ctx.site = site
        ctx.legs, ctx.replans = 0, 0
        Nav.status.dest = "Remembered " .. site.kind .. " site"
        Nav.status.destPos = site.pos
        return "PATHFINDING", "Exploring remembered " .. site.kind .. " site"
    end
    Auto.act("No reachable deposits (" .. tostring(info) .. "); waiting for respawns")
    token:sleep(math.max(3, Config.get("scanInterval")))
    return "SCANNING"
end

H.PATHFINDING = function(ctx, token)
    local goal, extra
    local here = Char.position()
    if not here then return "RECOVERING", "Character unavailable" end
    if ctx.target then
        if not Targeting.valid(ctx.target) then return "SELECTING_TARGET", "Target no longer available" end
        local spots = Miner.standSpots(ctx.target, here)
        goal, extra = spots[1], {spots[2], spots[3]}
    elseif ctx.site then
        goal = ctx.site.pos
    else
        return "SELECTING_TARGET"
    end
    local leg, why = Nav.planLeg(goal, token, extra)
    if not leg then
        if token:dead() then return "PATHFINDING" end
        if ctx.target then
            local duration = Ores.blacklist:mark(ctx.target.node, "no route: " .. tostring(why))
            Stats.unreachable = Stats.unreachable + 1
            Log.info("Nav", string.format("No route to %s deposit (%s); retry in %ds", ctx.target.kind,
                tostring(why), math.floor(duration)), "noroute", 5)
        elseif ctx.site then
            Ores.blacklist:mark(ctx.site, "no route")
            forgetSite(ctx.site)
        end
        Nav.status.lastFailure = tostring(why)
        return "SELECTING_TARGET", "Route failed: " .. tostring(why)
    end
    ctx.leg = leg
    return "TRAVELING", leg.final and "Traveling to target" or "Traveling (progressive leg)"
end

H.TRAVELING = function(ctx, token)
    local leg = ctx.leg
    if not leg then return "PATHFINDING" end
    ctx.leg = nil
    Nav.status.legs = Nav.status.legs + 1
    local target = ctx.target
    local opts = {}
    if target then
        opts.isValid = function() return Targeting.valid(target) end
        opts.arrivedCheck = function(pos) return Miner.atStandRange(target, pos) end
    end
    local result = Nav.followLeg(leg, token, opts)
    if result == "arrived" then
        Auto.consecutiveErrors = 0
        if target then return "APPROACHING", "Arrived near deposit" end
        if ctx.site then forgetSite(ctx.site) ctx.site = nil end
        return "SCANNING", "Arrived at remembered site"
    elseif result == "leg_done" then
        ctx.legs = (ctx.legs or 0) + 1
        if ctx.legs > 40 then
            if target then Ores.blacklist:mark(target.node, "leg limit") end
            return "SELECTING_TARGET", "Too many legs; choosing another target"
        end
        return "PATHFINDING", "Planning next leg"
    elseif result == "target_invalid" then
        return "SELECTING_TARGET", "Target vanished or depleted; retargeting"
    elseif result == "cancelled" then
        return "TRAVELING"
    elseif result == "character_lost" or result == "no_control" then
        return "RECOVERING", "Movement unavailable (" .. result .. ")"
    end
    ctx.replans = (ctx.replans or 0) + 1
    Stats.replans = Stats.replans + 1
    Nav.status.replans = Nav.status.replans + 1
    if ctx.replans > Config.get("maxReplans") then
        if target then
            local duration = Ores.blacklist:mark(target.node, "repeatedly " .. result)
            Log.info("Nav", string.format("Giving up on %s deposit after %d replans; retry in %ds", target.kind,
                ctx.replans, math.floor(duration)))
        end
        return "SELECTING_TARGET", "Route keeps failing; choosing another target"
    end
    if result == "stuck" then
        ctx.recoverTo = "PATHFINDING"
        return "RECOVERING", "Stuck; recovering then replanning"
    end
    return "PATHFINDING", "Replanning (" .. result .. ")"
end

H.APPROACHING = function(ctx, token)
    local target = ctx.target
    if not Targeting.valid(target) then return "SELECTING_TARGET", "Target no longer available" end
    ctx.approachTries = (ctx.approachTries or 0) + 1
    if ctx.approachTries > 3 then
        Ores.blacklist:mark(target.node, "could not reach mining range")
        return "SELECTING_TARGET", "Could not get into mining range"
    end
    local here = Char.position()
    if not here then return "RECOVERING", "Character unavailable" end
    local function ready()
        Nav.stop()
        Miner.face(target)
        return "EQUIPPING", "In mining range"
    end
    if Miner.atStandRange(target, here) then return ready() end
    local spots = Miner.standSpots(target, here)
    for i = 1, math.min(3, #spots) do
        local r = Nav.walkTo(spots[i], false, token,
            {arrivedCheck = function(pos) return Miner.atStandRange(target, pos) end}, true)
        local pos = Char.position()
        if pos and Miner.atStandRange(target, pos) then return ready() end
        if r == "cancelled" then return "APPROACHING" end
        if r == "character_lost" then return "RECOVERING", "Character lost" end
    end
    return "PATHFINDING", "Direct approach blocked; computing a path"
end

H.EQUIPPING = function(ctx, token)
    if not Targeting.valid(ctx.target) then return "SELECTING_TARGET", "Target no longer available" end
    local handle, why = Tools.ensureEquipped(token)
    if handle then
        Miner.handle = handle
        return "MINING", "Mining " .. ctx.target.kind .. " with " .. tostring(Tools.lastName or "pickaxe")
    end
    if why == "cancelled" then return "EQUIPPING" end
    if why == "manual_equip" then
        Auto.halt("The pickaxe is a game item and this executor offers no input API to press its hotbar key. " ..
            "Equip it by hand; automation resumes as soon as it is in your hand.",
            function() return Tools.equippedVisual() ~= nil or (Tools.find()) ~= nil end)
        return "PAUSED"
    end
    if why == "no_pickaxe" then
        Auto.halt("No pickaxe found: no Roblox Tool matching '" .. tostring(Config.get("pickaxePatterns")) ..
            "', none in hand, and hotbar keys 1-9 did not equip one. Equip it or set Settings > Pickaxe hotbar slot; " ..
            "automation resumes automatically.", Tools.available)
        return "PAUSED"
    end
    ctx.equipFails = (ctx.equipFails or 0) + 1
    if ctx.equipFails > 3 then
        Auto.halt("Pickaxe could not be equipped (" .. tostring(why) .. ")", Tools.available)
        return "PAUSED"
    end
    token:sleep(0.5)
    return "EQUIPPING", "Retrying equip (" .. tostring(why) .. ")"
end

H.MINING = function(ctx, token)
    local target = ctx.target
    if not Targeting.valid(target) then
        finishAttempt(ctx, (ctx.attemptYields or 0) > 0)
        return "SELECTING_TARGET", "Target no longer available"
    end
    if not ctx.attemptCounted then
        ctx.attemptCounted = true
        ctx.attemptYields = 0
        Stats.attempts = Stats.attempts + 1
    end
    local result = Miner.mine(target, token)
    ctx.attemptYields = ctx.attemptYields + result.yields
    local outcome = result.outcome
    if outcome ~= "cancelled" then Miner.restoreCamera() end
    if outcome == "depleted" then
        finishAttempt(ctx, true)
        Ores.kindResult(target.kind, true)
        Miner.noReaction = 0
        Stats.depleted = Stats.depleted + 1
        Ores.blacklist:success(target.node)
        Inventory.depositsSinceSell = Inventory.depositsSinceSell + 1
        Auto.consecutiveErrors = 0
        Log.info("Miner", string.format("Depleted %s deposit: %s verified unit(s), %d swing(s), %s",
            target.kind, U.num(ctx.attemptYields), result.swings, U.fmtTime(result.elapsed)))
        return "CHECKING_INVENTORY", "Deposit depleted"
    elseif outcome == "inventory_full" then
        finishAttempt(ctx, ctx.attemptYields > 0)
        return "CHECKING_INVENTORY", "Inventory needs unloading (" .. tostring(result.sellReason) .. ")"
    elseif outcome == "out_of_range" then
        ctx.rangeReturns = (ctx.rangeReturns or 0) + 1
        if ctx.rangeReturns > 3 then
            finishAttempt(ctx, ctx.attemptYields > 0)
            Ores.blacklist:mark(target.node, "kept leaving range")
            return "SELECTING_TARGET", "Kept drifting out of range"
        end
        ctx.approachTries = 0
        return "APPROACHING", "Out of range; re-approaching"
    elseif outcome == "tool_lost" then
        return "EQUIPPING", "Pickaxe was unequipped; re-equipping"
    elseif outcome == "stalled" or outcome == "no_yield" or outcome == "timeout" then
        finishAttempt(ctx, ctx.attemptYields > 0)
        local duration = Ores.blacklist:mark(target.node, outcome)
        Log.warn("Miner", string.format("%s on %s deposit (verified units %s, signals: %s, method %s); retry in %ds",
            outcome, target.kind, U.num(ctx.attemptYields), tostring(result.signals), tostring(result.method),
            math.floor(duration)))
        local reacted = (result.activity or 0) > 0 or ctx.attemptYields > 0
        Ores.kindResult(target.kind, reacted)
        Miner.noReaction = reacted and 0 or (Miner.noReaction + 1)
        if Miner.noReaction >= 5 then
            Miner.noReaction = 0
            Auto.halt("5 deposits in a row showed no reaction at all to mining (method " .. tostring(result.method) ..
                "). The interaction probably does not reach the game: check Settings > Interaction method and " ..
                "Pickaxe hotbar slot, then resume.")
            return "PAUSED"
        end
        return "SELECTING_TARGET", "No verified progress (" .. outcome .. ")"
    elseif outcome == "target_gone" then
        finishAttempt(ctx, ctx.attemptYields > 0)
        return "SELECTING_TARGET", "Deposit disappeared"
    elseif outcome == "character_lost" then
        return "RECOVERING", "Character lost while mining"
    end
    return "MINING"
end

H.FINDING_SELLER = function(ctx, token)
    Nav.stop()
    Visual.highlightTarget(nil)
    if not Sellers.scanned then
        Sellers.scan()
        local deadline = U.now() + 15
        while not Sellers.scanned and U.now() < deadline do
            if not token:sleep(0.25) then return "FINDING_SELLER" end
        end
    end
    local c, why = Sellers.choose(token)
    if not c then
        if token:dead() then return "FINDING_SELLER" end
        Sellers.lastResult = why
        ctx.sellerWaits = (ctx.sellerWaits or 0) + 1
        if ctx.sellerWaits >= 3 then
            ctx.sellerWaits = 0
            Auto.halt("Cannot sell: " .. tostring(why), function()
                for _, cand in ipairs(Sellers.rank()) do if not cand.blocked then return true end end
                return false
            end)
            return "PAUSED"
        end
        token:sleep(5)
        return "FINDING_SELLER", "No seller yet: " .. tostring(why)
    end
    ctx.seller = c
    ctx.sellerWaits = 0
    Sellers.current = c
    return "TRAVELING_TO_SELLER", "Seller: " .. c.label .. " (" .. tostring(why) .. ")"
end

H.TRAVELING_TO_SELLER = function(ctx, token)
    local c = ctx.seller
    if not c then return "FINDING_SELLER" end
    local pos = Sellers.position(c)
    if not pos then return "FINDING_SELLER", "Seller disappeared" end
    local opts = {label = c.label, arriveRadius = 10, extraGoals = {pos}}
    if c.kind == "prompt" then
        local range = 10
        pcall(function() range = c.prompt.MaxActivationDistance end)
        opts.arriveRadius = 2
        opts.arrivedCheck = function(p) return U.dist(p, pos) <= math.max(3, range) - 1.5 end
    end
    local ok, why = Nav.travel(pos, token, opts)
    if ok then
        Auto.consecutiveErrors = 0
        return "SELLING", "At seller"
    end
    if token:dead() then return "TRAVELING_TO_SELLER" end
    if why == "character_lost" then return "RECOVERING", "Character lost en route to seller" end
    Sellers.blacklist:mark(c.key, "route failed: " .. tostring(why))
    Log.warn("Sellers", "Could not reach " .. c.label .. ": " .. tostring(why))
    ctx.seller = nil
    return "FINDING_SELLER", "Seller unreachable; trying another"
end

H.SELLING = function(ctx, token)
    local c = ctx.seller
    if not c then return "FINDING_SELLER" end
    local outcome, detail = Sellers.sell(c, token, function(phase) Auto.act(phase) end)
    Sellers.lastResult = outcome
    Sellers.lastDetail = detail
    if outcome == "sold" then
        Sellers.remember(Sellers.current or c, true)
        Stats.sales = Stats.sales + 1
        ctx.sellFailures, ctx.seller = 0, nil
        Log.info("Sellers", "Sale verified: " .. detail)
        return "SCANNING", "Sold (" .. detail .. ")"
    elseif outcome == "cancelled" then
        return "SELLING"
    elseif outcome == "unverified" then
        Stats.salesUnverified = Stats.salesUnverified + 1
        Log.warn("Sellers", "Sale could NOT be verified: " .. detail)
        ctx.unverified = ctx.unverified or {}
        local now = U.now()
        local recent = {}
        for _, t in ipairs(ctx.unverified) do if now - t < 300 then recent[#recent + 1] = t end end
        recent[#recent + 1] = now
        ctx.unverified = recent
        if not Config.get("continueAfterUnverifiedSale") or #recent >= 3 then
            Auto.halt("Selling cannot be verified (" .. detail .. "). Check the sell location, then resume.")
            return "PAUSED"
        end
        Inventory.resetAfterSale()
        ctx.seller = nil
        return "SCANNING", "Sale unverified; resuming mining"
    end
    Stats.salesFailed = Stats.salesFailed + 1
    if outcome == "failed" then Sellers.remember(Sellers.current or c, false) end
    Sellers.blacklist:mark(c.key, outcome .. ": " .. tostring(detail))
    Log.warn("Sellers", "Sale " .. outcome .. " at " .. c.label .. ": " .. tostring(detail))
    ctx.sellFailures = (ctx.sellFailures or 0) + 1
    ctx.seller = nil
    if ctx.sellFailures >= 3 then
        ctx.sellFailures = 0
        Auto.halt("Selling failed 3 times (" .. tostring(detail) .. ")")
        return "PAUSED"
    end
    return "FINDING_SELLER", "Retrying sale elsewhere"
end

H.RECOVERING = function(ctx, token)
    Stats.fsmRecoveries = (Stats.fsmRecoveries or 0) + 1
    Nav.stop()
    Miner.restoreCamera()
    ctx.leg = nil
    if not Char.get() then
        Auto.act("Waiting for character respawn")
        if not Char.waitAlive(token, 60) then return "RECOVERING" end
        token:sleep(2)
        return "SCANNING", "Character respawned; rescanning"
    end
    local control = Char.controlState()
    if control == "seated" then
        Char.jump()
        token:sleep(0.6)
    elseif control == "no_control" then
        Auto.act("Waiting for movement control")
        local deadline = U.now() + 12
        while Char.controlState() == "no_control" and U.now() < deadline do
            if not token:sleep(0.3) then return "RECOVERING" end
        end
        if Char.controlState() == "no_control" then return "RECOVERING", "Still no movement control" end
    end
    Char.jump()
    token:sleep(0.4)
    local resume = ctx.recoverTo
    ctx.recoverTo = nil
    if resume and Targeting.valid(ctx.target) then return resume, "Recovered; resuming" end
    return "SCANNING", "Recovered"
end

H.ERROR = function(ctx, token)
    if Auto.consecutiveErrors >= 5 then
        Auto.halt("Too many consecutive errors. Last: " .. tostring(Auto.lastError))
        return "PAUSED"
    end
    Nav.stop()
    Miner.restoreCamera()
    local backoff = math.min(2 ^ Auto.consecutiveErrors, 20)
    Auto.act(string.format("Error; retrying in %ds", backoff))
    token:sleep(backoff)
    return "RECOVERING", "Recovering after error"
end

function Auto.loop(gen, runToken)
    while SESSION.alive and Auto.running and gen == Auto.generation and not runToken:dead() do
        if Auto.paused then
            if Auto.state ~= "PAUSED" then
                Nav.stop()
                Miner.restoreCamera()
                Auto.setState("PAUSED", Auto.pauseReason or "Paused")
            end
            if Auto.resumeCheck and (not Auto.nextResumeCheck or U.now() >= Auto.nextResumeCheck) then
                Auto.nextResumeCheck = U.now() + 2
                local ok, ready = pcall(Auto.resumeCheck)
                if ok and ready then
                    Log.info("FSM", "Blocking condition cleared; resuming automatically")
                    Auto.resume()
                end
            end
            task.wait(0.25)
        else
            local state = Auto.state
            local handler = H[state]
            if not handler then
                Auto.lastError = "no handler for state " .. tostring(state)
                Auto.setState("ERROR", Auto.lastError)
                handler = H.ERROR
                state = "ERROR"
            end
            local timeout = Auto.timeoutFor(state)
            local step = Token.new(runToken, timeout)
            Auto.stepToken = step
            local ok, nextState, activity = pcall(handler, Auto.ctx, step)
            Auto.stepToken = nil
            if gen ~= Auto.generation or not Auto.running or not SESSION.alive then break end
            if not ok then
                Stats.errors = Stats.errors + 1
                Auto.consecutiveErrors = Auto.consecutiveErrors + 1
                Auto.lastError = tostring(nextState)
                Log.error("FSM", state .. " failed: " .. Auto.lastError)
                Auto.setState("ERROR", "Error in " .. state)
            elseif Auto.paused then
                -- the next iteration enters the paused branch
            elseif step.reason == "character_lost" then
                Auto.setState("RECOVERING", "Character lost; waiting for respawn")
            elseif step.reason == "timeout" then
                Log.warn("FSM", string.format("%s exceeded its %ds timeout; recovering", state, math.floor(timeout)))
                Auto.setState("RECOVERING", "Recovering from " .. state .. " timeout")
            else
                Auto.setState(nextState or "SCANNING", activity)
            end
            task.wait(0.05)
        end
    end
end

function Auto.start()
    if Auto.running then
        if Auto.paused then Auto.resume() end
        return
    end
    Auto.generation = Auto.generation + 1
    Auto.running, Auto.paused = true, false
    Auto.pauseReason, Auto.resumeCheck = nil, nil
    Auto.runToken = Token.new(nil)
    Auto.ctx = {}
    Auto.consecutiveErrors = 0
    Auto.lastAccrue = U.now()
    Auto.stateSince = U.now()
    Auto.setState("SCANNING", "Starting automation")
    Log.info("FSM", "Automation started")
    SESSION:spawn("Automation", Auto.loop, Auto.generation, Auto.runToken)
end

function Auto.pause(reason)
    if not Auto.running or Auto.paused then return end
    Auto.paused = true
    Auto.pauseReason = reason or "Paused by user"
    Auto.resumeCheck = nil
    if Auto.stepToken then Auto.stepToken:cancel("paused") end
    Nav.stop()
    Miner.restoreCamera()
    Log.info("FSM", "Paused: " .. Auto.pauseReason)
end

function Auto.resume()
    if not Auto.running then return Auto.start() end
    Auto.paused = false
    Auto.pauseReason, Auto.resumeCheck = nil, nil
    Auto.ctx = {}
    Auto.consecutiveErrors = 0
    Auto.setState("SCANNING", "Resumed")
    Log.info("FSM", "Resumed")
end

function Auto.stop(reason)
    if not Auto.running and Auto.state == "IDLE" then return end
    Auto.generation = Auto.generation + 1
    if Auto.runToken then Auto.runToken:cancel("stopped") end
    if Auto.stepToken then Auto.stepToken:cancel("stopped") end
    Auto.accrue()
    Auto.running, Auto.paused = false, false
    Auto.pauseReason, Auto.resumeCheck = nil, nil
    Nav.stop()
    Miner.restoreCamera()
    Visual.highlightTarget(nil)
    Auto.setState("IDLE", reason or "Stopped")
    Log.info("FSM", "Automation stopped (" .. tostring(reason or "user") .. ")")
end

-- Death/respawn: cancel only the current step; the driver moves to RECOVERING.
Char.onDied[#Char.onDied + 1] = function()
    Stats.deaths = Stats.deaths + 1
    if Auto.stepToken then Auto.stepToken:cancel("character_lost") end
end

-- ==== MODULE: UI (theme, components, window) =============================================
UI = {
    root = nil, window = nil, body = nil, scale = nil, pages = {}, tabs = {}, order = {},
    current = "Dashboard", pageRefresh = {}, textCache = setmetatable({}, {__mode = "k"}),
    accentTargets = {}, collapsed = false, visible = true, built = false, lastRefresh = 0,
}

local ACCENTS = {
    Teal = Color3.fromRGB(62, 207, 174), Amber = Color3.fromRGB(242, 184, 75),
    Azure = Color3.fromRGB(77, 163, 255), Violet = Color3.fromRGB(160, 124, 255),
    Rose = Color3.fromRGB(240, 98, 146),
}
local T = {
    bg = Color3.fromRGB(13, 16, 22), panel = Color3.fromRGB(19, 23, 31), surface = Color3.fromRGB(25, 30, 41),
    surface2 = Color3.fromRGB(33, 39, 53), hover = Color3.fromRGB(41, 48, 65), stroke = Color3.fromRGB(44, 52, 70),
    text = Color3.fromRGB(232, 236, 243), muted = Color3.fromRGB(143, 155, 178), faint = Color3.fromRGB(98, 108, 130),
    success = Color3.fromRGB(76, 195, 138), warning = Color3.fromRGB(242, 184, 75), danger = Color3.fromRGB(229, 83, 75),
    onAccent = Color3.fromRGB(12, 18, 22), accent = ACCENTS.Teal,
    font = Enum.Font.Gotham, medium = Enum.Font.GothamMedium, bold = Enum.Font.GothamBold, mono = Enum.Font.Code,
}
UI.theme = T

local STATE_COLORS = {
    IDLE = "muted", PAUSED = "warning", ERROR = "danger", RECOVERING = "warning", MINING = "success",
    SELLING = "success",
}

function UI.stateColor(state)
    return T[STATE_COLORS[state] or "accent"]
end

local function make(class, props, parent)
    local inst = Instance.new(class)
    for k, v in pairs(props or {}) do inst[k] = v end
    if parent then inst.Parent = parent end
    return inst
end
UI.make = make

local function corner(inst, r) return make("UICorner", {CornerRadius = UDim.new(0, r or 8)}, inst) end
local function stroke(inst, color, thickness)
    return make("UIStroke", {Color = color or T.stroke, Thickness = thickness or 1,
        ApplyStrokeMode = Enum.ApplyStrokeMode.Border}, inst)
end
local function pad(inst, l, r, t, b)
    return make("UIPadding", {PaddingLeft = UDim.new(0, l or 0), PaddingRight = UDim.new(0, r or l or 0),
        PaddingTop = UDim.new(0, t or l or 0), PaddingBottom = UDim.new(0, b or t or l or 0)}, inst)
end
local function vlist(inst, gap)
    return make("UIListLayout", {Padding = UDim.new(0, gap or 6), SortOrder = Enum.SortOrder.LayoutOrder,
        FillDirection = Enum.FillDirection.Vertical}, inst)
end
local function hlist(inst, gap, align)
    return make("UIListLayout", {Padding = UDim.new(0, gap or 6), SortOrder = Enum.SortOrder.LayoutOrder,
        FillDirection = Enum.FillDirection.Horizontal, VerticalAlignment = Enum.VerticalAlignment.Center,
        HorizontalAlignment = align or Enum.HorizontalAlignment.Left}, inst)
end
UI.corner, UI.stroke, UI.pad, UI.vlist, UI.hlist = corner, stroke, pad, vlist, hlist

function UI.tween(inst, props, duration)
    local ok = false
    if TweenService then
        ok = pcall(function()
            TweenService:Create(inst, TweenInfo.new(duration or 0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                props):Play()
        end)
    end
    if not ok then
        for k, v in pairs(props) do pcall(function() inst[k] = v end) end
    end
end

-- Only writes when the text actually changed (cheap refreshes).
function UI.setText(label, text)
    text = tostring(text)
    if UI.textCache[label] ~= text then
        UI.textCache[label] = text
        label.Text = text
    end
end

function UI.setColor(inst, prop, color)
    if inst[prop] ~= color then inst[prop] = color end
end

function UI.accentify(inst, prop)
    UI.accentTargets[#UI.accentTargets + 1] = {inst, prop}
    inst[prop] = T.accent
    return inst
end

function UI.applyAccent(name)
    T.accent = ACCENTS[name] or ACCENTS.Teal
    Visual.accent = T.accent
    for _, target in ipairs(UI.accentTargets) do
        pcall(function() target[1][target[2]] = T.accent end)
    end
end

local order = 0
local function nextOrder()
    order = order + 1
    return order
end

function UI.label(parent, text, props)
    local l = make("TextLabel", {BackgroundTransparency = 1, Font = T.font, TextSize = 13, TextColor3 = T.text,
        Text = text or "", TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center,
        Size = UDim2.new(1, 0, 0, 18), LayoutOrder = nextOrder(), TextTruncate = Enum.TextTruncate.AtEnd}, parent)
    for k, v in pairs(props or {}) do l[k] = v end
    return l
end

-- Card with title; returns content frame (vertical list, auto height).
function UI.section(page, title, subtitle)
    local card = make("Frame", {BackgroundColor3 = T.surface, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder()}, page)
    corner(card, 8)
    stroke(card, T.stroke, 1)
    pad(card, 12, 12, 10, 12)
    vlist(card, 6)
    UI.label(card, string.upper(title), {Font = T.bold, TextSize = 11, TextColor3 = T.muted, Size = UDim2.new(1, 0, 0, 14)})
    if subtitle then
        UI.label(card, subtitle, {TextSize = 11, TextColor3 = T.faint, TextWrapped = true,
            AutomaticSize = Enum.AutomaticSize.Y, TextTruncate = Enum.TextTruncate.None})
    end
    return card
end

function UI.row(parent, height)
    return make("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, height or 26),
        LayoutOrder = nextOrder()}, parent)
end

-- Key/value line; returns the value label.
function UI.kv(parent, key)
    local row = UI.row(parent, 18)
    make("TextLabel", {BackgroundTransparency = 1, Font = T.font, TextSize = 12, TextColor3 = T.muted, Text = key,
        TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(0.42, 0, 1, 0)}, row)
    return make("TextLabel", {BackgroundTransparency = 1, Font = T.medium, TextSize = 12, TextColor3 = T.text, Text = "-",
        TextXAlignment = Enum.TextXAlignment.Right, Position = UDim2.new(0.42, 0, 0, 0), Size = UDim2.new(0.58, 0, 1, 0),
        TextTruncate = Enum.TextTruncate.AtEnd}, row)
end

local BUTTON_STYLES = {
    primary = function() return T.accent, T.onAccent end,
    danger = function() return Color3.fromRGB(120, 44, 48), T.text end,
    warning = function() return Color3.fromRGB(122, 92, 34), T.text end,
    ghost = function() return T.surface2, T.text end,
}

function UI.button(parent, text, style, callback, size)
    local bg, fg = BUTTON_STYLES[style or "ghost"]()
    local b = make("TextButton", {Text = text, Font = T.medium, TextSize = 12, TextColor3 = fg, BackgroundColor3 = bg,
        AutoButtonColor = false, BorderSizePixel = 0, Size = size or UDim2.new(1, 0, 0, 30),
        LayoutOrder = nextOrder()}, parent)
    corner(b, 6)
    if style == "primary" then UI.accentify(b, "BackgroundColor3") end
    SESSION:connect(b.MouseEnter, function()
        if style ~= "primary" then UI.tween(b, {BackgroundColor3 = T.hover}, 0.12) end
    end, "btn.enter")
    SESSION:connect(b.MouseLeave, function()
        local base = BUTTON_STYLES[style or "ghost"]()
        UI.tween(b, {BackgroundColor3 = base}, 0.12)
    end, "btn.leave")
    SESSION:connect(b.MouseButton1Click, function()
        if callback then callback(b) end
    end, "button:" .. text)
    return b
end

-- Horizontal button bar; returns the frame.
function UI.buttonBar(parent, specs, height)
    local bar = UI.row(parent, height or 30)
    local n = #specs
    local gap = 6
    local buttons = {}
    for i, spec in ipairs(specs) do
        local b = UI.button(bar, spec[1], spec[2], spec[3],
            UDim2.new(1 / n, -gap * (n - 1) / n, 1, 0))
        b.Position = UDim2.new((i - 1) / n, gap * (i - 1) / n, 0, 0)
        buttons[i] = b
    end
    return bar, buttons
end

-- Toggle switch bound to a config key (or custom getter/setter).
function UI.toggle(parent, text, key, hint, getter, setter)
    local row = UI.row(parent, hint and 34 or 24)
    make("TextLabel", {BackgroundTransparency = 1, Font = T.font, TextSize = 13, TextColor3 = T.text, Text = text,
        TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -54, 0, 18)}, row)
    if hint then
        make("TextLabel", {BackgroundTransparency = 1, Font = T.font, TextSize = 11, TextColor3 = T.faint, Text = hint,
            TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 0, 0, 17),
            Size = UDim2.new(1, -54, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd}, row)
    end
    local track = make("TextButton", {Text = "", AutoButtonColor = false, BorderSizePixel = 0,
        BackgroundColor3 = T.surface2, Size = UDim2.new(0, 38, 0, 20), Position = UDim2.new(1, -40, 0, 0)}, row)
    corner(track, 10)
    local knob = make("Frame", {BackgroundColor3 = T.text, BorderSizePixel = 0, Size = UDim2.new(0, 14, 0, 14),
        Position = UDim2.new(0, 3, 0, 3)}, track)
    corner(knob, 7)
    getter = getter or function() return Config.get(key) end
    setter = setter or function(v) Config.set(key, v) end
    local function render(animate)
        local on = getter() and true or false
        local pos = on and UDim2.new(0, 21, 0, 3) or UDim2.new(0, 3, 0, 3)
        local color = on and T.accent or T.surface2
        if animate then
            UI.tween(knob, {Position = pos}, 0.15)
            UI.tween(track, {BackgroundColor3 = color}, 0.15)
        else
            knob.Position = pos
            track.BackgroundColor3 = color
        end
    end
    SESSION:connect(track.MouseButton1Click, function()
        setter(not getter())
        render(true)
    end, "toggle:" .. text)
    render(false)
    return render
end

local function fmtNumber(v, step)
    if step and step < 1 then return string.format("%.2f", v) end
    return tostring(math.floor(v + 0.5))
end

-- Numeric stepper with direct text entry.
function UI.stepper(parent, text, key, step, fmt, getter, setter)
    local spec = CONFIG_SCHEMA[key] or {}
    local lo, hi = spec[3] or -math.huge, spec[4] or math.huge
    getter = getter or function() return Config.get(key) end
    setter = setter or function(v) Config.set(key, v) end
    fmt = fmt or function(v) return fmtNumber(v, step) end
    local row = UI.row(parent, 26)
    make("TextLabel", {BackgroundTransparency = 1, Font = T.font, TextSize = 13, TextColor3 = T.text, Text = text,
        TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -132, 1, 0),
        TextTruncate = Enum.TextTruncate.AtEnd}, row)
    local minus = make("TextButton", {Text = "-", Font = T.bold, TextSize = 14, TextColor3 = T.text,
        BackgroundColor3 = T.surface2, AutoButtonColor = false, BorderSizePixel = 0,
        Size = UDim2.new(0, 26, 0, 24), Position = UDim2.new(1, -128, 0, 1)}, row)
    corner(minus, 6)
    local box = make("TextBox", {Text = fmt(getter()), Font = T.medium, TextSize = 12, TextColor3 = T.text,
        BackgroundColor3 = T.bg, BorderSizePixel = 0, ClearTextOnFocus = false,
        Size = UDim2.new(0, 68, 0, 24), Position = UDim2.new(1, -98, 0, 1)}, row)
    corner(box, 6)
    local plus = make("TextButton", {Text = "+", Font = T.bold, TextSize = 14, TextColor3 = T.text,
        BackgroundColor3 = T.surface2, AutoButtonColor = false, BorderSizePixel = 0,
        Size = UDim2.new(0, 26, 0, 24), Position = UDim2.new(1, -26, 0, 1)}, row)
    corner(plus, 6)
    local function render() box.Text = fmt(getter()) end
    local function apply(v)
        v = U.clamp(v, lo, hi)
        if step and step >= 1 then v = math.floor(v + 0.5) end
        setter(v)
        render()
    end
    SESSION:connect(minus.MouseButton1Click, function() apply(getter() - step) end, "stepper-")
    SESSION:connect(plus.MouseButton1Click, function() apply(getter() + step) end, "stepper+")
    SESSION:connect(box.FocusLost, function()
        local n = tonumber((string.gsub(box.Text, "[^%d%.%-]", "")))
        if n then apply(n) else render() end
    end, "stepper.box")
    return render
end

-- Option cycler bound to an enum config key (or custom options).
function UI.cycle(parent, text, key, options, getter, setter)
    options = options or (CONFIG_SCHEMA[key] and CONFIG_SCHEMA[key][5]) or {}
    getter = getter or function() return Config.get(key) end
    setter = setter or function(v) Config.set(key, v) end
    local row = UI.row(parent, 26)
    make("TextLabel", {BackgroundTransparency = 1, Font = T.font, TextSize = 13, TextColor3 = T.text, Text = text,
        TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -150, 1, 0)}, row)
    local b = make("TextButton", {Text = tostring(getter()), Font = T.medium, TextSize = 12, TextColor3 = T.text,
        BackgroundColor3 = T.surface2, AutoButtonColor = false, BorderSizePixel = 0,
        Size = UDim2.new(0, 146, 0, 24), Position = UDim2.new(1, -146, 0, 1)}, row)
    corner(b, 6)
    local function render() b.Text = tostring(getter()) .. "  >" end
    SESSION:connect(b.MouseButton1Click, function()
        local current, idx = getter(), 0
        for i, o in ipairs(options) do if o == current then idx = i end end
        setter(options[(idx % #options) + 1])
        render()
    end, "cycle:" .. text)
    render()
    return render
end

-- Free-text setting bound to a string config key.
function UI.textField(parent, text, key, placeholder)
    local row = UI.row(parent, 44)
    make("TextLabel", {BackgroundTransparency = 1, Font = T.font, TextSize = 12, TextColor3 = T.muted, Text = text,
        TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 16)}, row)
    local box = make("TextBox", {Text = tostring(Config.get(key) or ""), PlaceholderText = placeholder or "",
        Font = T.medium, TextSize = 12, TextColor3 = T.text, PlaceholderColor3 = T.faint,
        BackgroundColor3 = T.bg, BorderSizePixel = 0, ClearTextOnFocus = false,
        TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 24),
        Position = UDim2.new(0, 0, 0, 18)}, row)
    corner(box, 6)
    pad(box, 8, 8, 0, 0)
    SESSION:connect(box.FocusLost, function()
        if Config.set(key, box.Text) then Log.info("Config", text .. " set to \"" .. box.Text .. "\"") end
        box.Text = tostring(Config.get(key) or "")
    end, "text:" .. key)
    return box
end

function UI.progress(parent, height)
    local trackFrame = make("Frame", {BackgroundColor3 = T.bg, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, height or 8), LayoutOrder = nextOrder()}, parent)
    corner(trackFrame, 4)
    local fill = make("Frame", {BackgroundColor3 = T.accent, BorderSizePixel = 0, Size = UDim2.new(0, 0, 1, 0)}, trackFrame)
    corner(fill, 4)
    local last = -1
    return function(fraction, color)
        fraction = fraction and U.clamp(fraction, 0, 1) or 0
        if math.abs(fraction - last) > 0.002 then
            last = fraction
            UI.tween(fill, {Size = UDim2.new(fraction, 0, 1, 0)}, 0.25)
        end
        UI.setColor(fill, "BackgroundColor3", color or T.accent)
    end
end

-- Stat tile for grid layouts; returns value label and subtitle label.
function UI.tile(parent, title)
    local tile = make("Frame", {BackgroundColor3 = T.surface, BorderSizePixel = 0, LayoutOrder = nextOrder()}, parent)
    corner(tile, 8)
    stroke(tile, T.stroke, 1)
    pad(tile, 10, 10, 8, 8)
    make("TextLabel", {BackgroundTransparency = 1, Font = T.bold, TextSize = 10, TextColor3 = T.muted,
        Text = string.upper(title), TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 12)}, tile)
    local value = make("TextLabel", {BackgroundTransparency = 1, Font = T.bold, TextSize = 17, TextColor3 = T.text,
        Text = "-", TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 0, 0, 15),
        Size = UDim2.new(1, 0, 0, 22), TextTruncate = Enum.TextTruncate.AtEnd}, tile)
    local sub = make("TextLabel", {BackgroundTransparency = 1, Font = T.font, TextSize = 11, TextColor3 = T.faint,
        Text = "", TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 0, 0, 37),
        Size = UDim2.new(1, 0, 0, 14), TextTruncate = Enum.TextTruncate.AtEnd}, tile)
    return value, sub
end

function UI.grid(parent, columns, cellHeight)
    local frame = make("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = nextOrder()}, parent)
    make("UIGridLayout", {CellPadding = UDim2.new(0, 8, 0, 8),
        CellSize = UDim2.new(1 / columns, -8 * (columns - 1) / columns, 0, cellHeight or 62),
        SortOrder = Enum.SortOrder.LayoutOrder}, frame)
    return frame
end

function UI.newPage(name)
    local page = make("ScrollingFrame", {Name = name, BackgroundTransparency = 1, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 1, 0), CanvasSize = UDim2.new(0, 0, 0, 0), AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ScrollBarThickness = 4, ScrollBarImageColor3 = T.stroke, Visible = false,
        ScrollingDirection = Enum.ScrollingDirection.Y}, UI.body)
    pad(page, 2, 10, 2, 10)
    vlist(page, 10)
    UI.pages[name] = page
    return page
end

function UI.selectTab(name)
    if not UI.pages[name] then return end
    UI.current = name
    for tabName, tab in pairs(UI.tabs) do
        local active = tabName == name
        UI.pages[tabName].Visible = active
        UI.tween(tab.button, {BackgroundColor3 = active and T.surface2 or T.panel}, 0.12)
        tab.label.TextColor3 = active and T.text or T.muted
        tab.bar.Visible = active
    end
    UI.refresh(true)
end

-- Builds the window shell: header (drag/collapse/close), sidebar tabs, body and run controls.
function UI.buildShell(parent)
    local root = make("ScreenGui", {Name = GUI_NAME, ResetOnSpawn = false, DisplayOrder = 50,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling, IgnoreGuiInset = false}, nil)
    UI.root = root
    SESSION:give(root)
    local window = make("Frame", {Name = "Window", BackgroundColor3 = T.bg, BorderSizePixel = 0,
        Size = UDim2.new(0, 680, 0, 460), Position = UDim2.new(0, 40, 0.5, -230), ClipsDescendants = true}, root)
    corner(window, 12)
    stroke(window, T.stroke, 1)
    UI.window = window
    UI.scale = make("UIScale", {Scale = 1}, window)
    local saved = Config.get("windowPos")
    if type(saved) == "table" and tonumber(saved.xs) then
        window.Position = UDim2.new(saved.xs, saved.xo or 0, saved.ys or 0, saved.yo or 0)
    end

    local header = make("Frame", {Name = "Header", BackgroundColor3 = T.panel, BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 46)}, window)
    UI.header = header
    local accentLine = make("Frame", {BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 2),
        Position = UDim2.new(0, 0, 1, -2)}, header)
    UI.accentify(accentLine, "BackgroundColor3")
    accentLine.BackgroundTransparency = 0.55
    make("TextLabel", {BackgroundTransparency = 1, Font = T.bold, TextSize = 15, TextColor3 = T.text,
        Text = "TWW PROSPECTOR", TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.new(0, 16, 0, 7), Size = UDim2.new(0, 220, 0, 18)}, header)
    local sub = make("TextLabel", {BackgroundTransparency = 1, Font = T.medium, TextSize = 11,
        Text = "ULTIMATE  v" .. VERSION, TextXAlignment = Enum.TextXAlignment.Left,
        Position = UDim2.new(0, 16, 0, 25), Size = UDim2.new(0, 220, 0, 14)}, header)
    UI.accentify(sub, "TextColor3")
    local pill = make("Frame", {BackgroundColor3 = T.surface2, BorderSizePixel = 0,
        Size = UDim2.new(0, 190, 0, 26), Position = UDim2.new(1, -278, 0, 10)}, header)
    corner(pill, 13)
    local dot = make("Frame", {BorderSizePixel = 0, BackgroundColor3 = T.muted, Size = UDim2.new(0, 8, 0, 8),
        Position = UDim2.new(0, 11, 0.5, -4)}, pill)
    corner(dot, 4)
    local pillText = make("TextLabel", {BackgroundTransparency = 1, Font = T.bold, TextSize = 11, TextColor3 = T.text,
        Text = "IDLE", TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 26, 0, 0),
        Size = UDim2.new(1, -32, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd}, pill)
    UI.pillDot, UI.pillText = dot, pillText
    local collapse = make("TextButton", {Text = "-", Font = T.bold, TextSize = 18, TextColor3 = T.muted,
        BackgroundColor3 = T.surface2, AutoButtonColor = false, BorderSizePixel = 0,
        Size = UDim2.new(0, 30, 0, 26), Position = UDim2.new(1, -78, 0, 10)}, header)
    corner(collapse, 6)
    local close = make("TextButton", {Text = "X", Font = T.bold, TextSize = 13, TextColor3 = T.muted,
        BackgroundColor3 = T.surface2, AutoButtonColor = false, BorderSizePixel = 0,
        Size = UDim2.new(0, 30, 0, 26), Position = UDim2.new(1, -42, 0, 10)}, header)
    corner(close, 6)
    UI.collapseButton, UI.closeButton = collapse, close

    local sidebar = make("Frame", {Name = "Sidebar", BackgroundColor3 = T.panel, BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 0, 46), Size = UDim2.new(0, 150, 1, -46)}, window)
    UI.sidebar = sidebar
    local tabList = make("Frame", {BackgroundTransparency = 1, Position = UDim2.new(0, 8, 0, 10),
        Size = UDim2.new(1, -16, 1, -120)}, sidebar)
    vlist(tabList, 4)
    UI.tabList = tabList
    local controls = make("Frame", {BackgroundTransparency = 1, Position = UDim2.new(0, 10, 1, -104),
        Size = UDim2.new(1, -20, 0, 96)}, sidebar)
    vlist(controls, 6)
    UI.controls = controls

    local body = make("Frame", {Name = "Body", BackgroundTransparency = 1, Position = UDim2.new(0, 162, 0, 56),
        Size = UDim2.new(1, -170, 1, -64)}, window)
    UI.body = body

    make("Frame", {BackgroundColor3 = T.stroke, BorderSizePixel = 0, Position = UDim2.new(0, 150, 0, 46),
        Size = UDim2.new(0, 1, 1, -46)}, window)

    UI.bindWindowBehaviour(header, collapse, close)
    root.Parent = parent
    return root
end

function UI.addTab(name, title)
    local button = make("TextButton", {Text = "", AutoButtonColor = false, BorderSizePixel = 0,
        BackgroundColor3 = T.panel, Size = UDim2.new(1, 0, 0, 32), LayoutOrder = #UI.order + 1}, UI.tabList)
    corner(button, 6)
    local bar = make("Frame", {BorderSizePixel = 0, Size = UDim2.new(0, 3, 0, 16), Position = UDim2.new(0, 0, 0.5, -8),
        Visible = false}, button)
    corner(bar, 2)
    UI.accentify(bar, "BackgroundColor3")
    local label = make("TextLabel", {BackgroundTransparency = 1, Font = T.medium, TextSize = 13, TextColor3 = T.muted,
        Text = title, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 14, 0, 0),
        Size = UDim2.new(1, -18, 1, 0)}, button)
    UI.tabs[name] = {button = button, label = label, bar = bar}
    UI.order[#UI.order + 1] = name
    SESSION:connect(button.MouseButton1Click, function() UI.selectTab(name) end, "tab:" .. name)
    return UI.newPage(name)
end

function UI.applyScale()
    if not UI.scale then return end
    local scale = Config.get("uiScale")
    local cam = Workspace.CurrentCamera
    if cam then
        local ok, size = pcall(function() return cam.ViewportSize end)
        if ok and size and size.X > 0 then
            -- keep the window usable on small viewports
            scale = math.min(scale, (size.X - 20) / 680, (size.Y - 20) / 460)
        end
    end
    UI.scale.Scale = math.max(0.5, scale)
end

function UI.setCollapsed(collapsed)
    UI.collapsed = collapsed
    Config.set("collapsed", collapsed)
    UI.collapseButton.Text = collapsed and "+" or "-"
    UI.tween(UI.window, {Size = collapsed and UDim2.new(0, 680, 0, 46) or UDim2.new(0, 680, 0, 460)}, 0.2)
end

function UI.bindWindowBehaviour(header, collapse, close)
    local dragging, dragStart, startPos = false, nil, nil
    SESSION:connect(header.InputBegan, function(input)
        local t = input.UserInputType
        if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
            dragging, dragStart, startPos = true, input.Position, UI.window.Position
        end
    end, "drag.begin")
    if UserInputService then
        SESSION:connect(UserInputService.InputChanged, function(input)
            if not dragging then return end
            local t = input.UserInputType
            if t == Enum.UserInputType.MouseMovement or t == Enum.UserInputType.Touch then
                local delta = input.Position - dragStart
                UI.window.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
                    startPos.Y.Scale, startPos.Y.Offset + delta.Y)
            end
        end, "drag.move")
        SESSION:connect(UserInputService.InputEnded, function(input)
            local t = input.UserInputType
            if dragging and (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch) then
                dragging = false
                local p = UI.window.Position
                Config.set("windowPos", {xs = p.X.Scale, xo = p.X.Offset, ys = p.Y.Scale, yo = p.Y.Offset})
            end
        end, "drag.end")
        SESSION:connect(UserInputService.InputBegan, function(input, processed)
            if processed then return end
            local okFocus, focused = pcall(function() return UserInputService:GetFocusedTextBox() end)
            if okFocus and focused then return end
            local key = Config.get("toggleKey")
            if input.KeyCode == Enum.KeyCode[key] then
                UI.visible = not UI.visible
                UI.window.Visible = UI.visible
            end
        end, "hotkey")
    end
    SESSION:connect(collapse.MouseButton1Click, function() UI.setCollapsed(not UI.collapsed) end, "collapse")
    SESSION:connect(close.MouseButton1Click, function()
        if UI.onClose then UI.onClose() end
    end, "close")
end

-- ==== MODULE: UI pages ===================================================================
local Pages = {}

function Pages.Dashboard(page)
    local T = UI.theme
    local w = {}
    local hero = UI.section(page, "Automation")
    w.state = UI.label(hero, "IDLE", {Font = T.bold, TextSize = 22, Size = UDim2.new(1, 0, 0, 26)})
    w.activity = UI.label(hero, "", {TextColor3 = T.muted, TextWrapped = true, TextTruncate = Enum.TextTruncate.None,
        TextYAlignment = Enum.TextYAlignment.Top, Size = UDim2.new(1, 0, 0, 30)})
    w.banner = UI.label(hero, "", {TextColor3 = T.warning, TextWrapped = true, Visible = false,
        TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y})
    local _, buttons = UI.buttonBar(hero, {
        {"START", "primary", function() Auto.start() end},
        {"PAUSE", "warning", function() if Auto.paused then Auto.resume() else Auto.pause("Paused by user") end end},
        {"STOP", "danger", function() Auto.stop("user") end},
    }, 34)
    w.buttons = buttons
    local grid = UI.grid(page, 3, 62)
    w.target, w.targetSub = UI.tile(grid, "Current target")
    w.dist, w.distSub = UI.tile(grid, "Distance")
    w.runtime, w.runtimeSub = UI.tile(grid, "Running time")
    w.mined, w.minedSub = UI.tile(grid, "Deposits mined")
    w.attempts, w.attemptsSub = UI.tile(grid, "Attempts ok / failed")
    w.yields, w.yieldsSub = UI.tile(grid, "Verified ore")
    w.inv, w.invSub = UI.tile(grid, "Inventory")
    w.seller, w.sellerSub = UI.tile(grid, "Seller")
    w.swings, w.swingsSub = UI.tile(grid, "Swings")

    UI.pageRefresh.Dashboard = function()
        local set = UI.setText
        set(w.state, Auto.state)
        UI.setColor(w.state, "TextColor3", UI.stateColor(Auto.state))
        set(w.activity, Auto.activity or "")
        w.banner.Visible = Auto.paused and Auto.pauseReason ~= nil
        if Auto.paused then set(w.banner, "Paused: " .. tostring(Auto.pauseReason)) end
        set(w.buttons[1], Auto.running and (Auto.paused and "RESUME" or "RUNNING") or "START")
        set(w.buttons[2], Auto.paused and "RESUME" or "PAUSE")
        local target = Auto.ctx and Auto.ctx.target
        local here = Char.position()
        if target and Targeting.valid(target) then
            set(w.target, target.kind)
            set(w.targetSub, target.remaining and ("ore remaining " .. target.remaining) or "remaining unknown")
            if here and target.pos then
                set(w.dist, U.fmtDist(U.dist(here, target.pos)))
                set(w.distSub, Miner.inRange(target, here) and "in mining range" or Nav.status.route)
            end
        else
            set(w.target, Auto.ctx and Auto.ctx.site and "Exploring" or "None")
            set(w.targetSub, Targeting.lastReason or "-")
            set(w.dist, "-")
            set(w.distSub, Nav.status.route)
        end
        set(w.runtime, U.fmtTime(Stats.runtime))
        set(w.runtimeSub, "session " .. U.fmtTime(U.now() - SESSION.startedAt))
        set(w.mined, Stats.depleted)
        set(w.minedSub, Ores.blacklist:activeCount() .. " deposit(s) on cooldown")
        set(w.attempts, Stats.successAttempts .. " / " .. Stats.failedAttempts)
        set(w.attemptsSub, Stats.attempts .. " total attempt(s)")
        set(w.yields, Stats.yields)
        set(w.yieldsSub, "units confirmed by game data")
        local s = Inventory.state
        set(w.inv, s.known and (U.num(s.used) .. " / " .. U.num(s.capacity)) or "Unknown")
        set(w.invSub, s.fullFlag and "FULL - " .. tostring(s.fullReason) or (s.known and U.fmtPct(s.fraction) or "no counter found"))
        set(w.seller, Sellers.current and Sellers.current.label or "-")
        set(w.sellerSub, "last: " .. tostring(Sellers.lastResult))
        set(w.swings, Stats.swings)
        set(w.swingsSub, Stats.failedInteractions .. " failed interaction(s)")
    end
end

function Pages.Ores(page)
    local T = UI.theme
    local w = {rows = {}, version = -1}
    local head = UI.section(page, "Ore discovery")
    w.root = UI.kv(head, "Mining root")
    w.totals = UI.kv(head, "Selected available / all known")
    w.memory = UI.kv(head, "Remembered streamed-out sites")
    w.cooldown = UI.kv(head, "Deposits on cooldown")
    UI.buttonBar(head, {
        {"SELECT ALL", "ghost", function()
            for _, kind in ipairs(Ores.kindList) do Config.values.selected[kind] = true end
            Config.dirty = true
        end},
        {"DESELECT ALL", "ghost", function()
            for _, kind in ipairs(Ores.kindList) do Config.values.selected[kind] = false end
            Config.dirty = true
        end},
        {"RESCAN", "ghost", function()
            Ores.detach()
            Ores.maintain(true)
        end},
    })
    UI.toggle(head, "Hide depleted deposits from totals", "skipDepleted")
    UI.toggle(head, "Mine deposits without OreRemaining", "allowUnknownRemaining",
        "Still verified by other progress signals; blacklisted if nothing changes")

    local list = UI.section(page, "Ore types", "Click a type to include/exclude it. Priority 1 (low) to 5 (high).")
    local headerRow = UI.row(list, 16)
    local cols = {{"TYPE", 0, 0.38}, {"AVAILABLE", 0.38, 0.2}, {"NEAREST", 0.58, 0.18}, {"PRIORITY", 0.76, 0.24}}
    for _, c in ipairs(cols) do
        UI.make("TextLabel", {BackgroundTransparency = 1, Font = T.bold, TextSize = 10, TextColor3 = T.faint,
            Text = c[1], TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(c[2], 6, 0, 0),
            Size = UDim2.new(c[3], -6, 1, 0)}, headerRow)
    end
    w.empty = UI.label(list, "No ore types discovered yet. The Mining folder may not be replicated; it is re-checked automatically.",
        {TextColor3 = T.faint, TextWrapped = true, TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y})
    w.holder = UI.make("Frame", {BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 100000}, list)
    UI.vlist(w.holder, 4)

    local function makeRow(kind, index)
        local row = UI.make("TextButton", {Text = "", AutoButtonColor = false, BorderSizePixel = 0,
            BackgroundColor3 = T.surface2, Size = UDim2.new(1, 0, 0, 30), LayoutOrder = index}, w.holder)
        UI.corner(row, 6)
        local check = UI.make("Frame", {BorderSizePixel = 0, Size = UDim2.new(0, 14, 0, 14),
            Position = UDim2.new(0, 8, 0.5, -7), BackgroundColor3 = T.bg}, row)
        UI.corner(check, 4)
        local name = UI.make("TextLabel", {BackgroundTransparency = 1, Font = T.medium, TextSize = 13, TextColor3 = T.text,
            Text = kind, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0, 30, 0, 0),
            Size = UDim2.new(0.38, -30, 1, 0), TextTruncate = Enum.TextTruncate.AtEnd}, row)
        local avail = UI.make("TextLabel", {BackgroundTransparency = 1, Font = T.font, TextSize = 12, TextColor3 = T.text,
            Text = "-", TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0.38, 6, 0, 0),
            Size = UDim2.new(0.2, -6, 1, 0)}, row)
        local nearest = UI.make("TextLabel", {BackgroundTransparency = 1, Font = T.font, TextSize = 12, TextColor3 = T.muted,
            Text = "-", TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(0.58, 6, 0, 0),
            Size = UDim2.new(0.18, -6, 1, 0)}, row)
        local minus = UI.make("TextButton", {Text = "-", Font = T.bold, TextSize = 13, TextColor3 = T.text,
            BackgroundColor3 = T.bg, AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.new(0, 22, 0, 20),
            Position = UDim2.new(0.76, 4, 0.5, -10)}, row)
        UI.corner(minus, 5)
        local prio = UI.make("TextLabel", {BackgroundTransparency = 1, Font = T.bold, TextSize = 12, TextColor3 = T.text,
            Text = "3", Position = UDim2.new(0.76, 28, 0, 0), Size = UDim2.new(0, 20, 1, 0)}, row)
        local plus = UI.make("TextButton", {Text = "+", Font = T.bold, TextSize = 13, TextColor3 = T.text,
            BackgroundColor3 = T.bg, AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.new(0, 22, 0, 20),
            Position = UDim2.new(0.76, 50, 0.5, -10)}, row)
        UI.corner(plus, 5)
        local function bump(delta)
            Config.values.priorities[kind] = U.clamp(Ores.priority(kind) + delta, 1, 5)
            Config.dirty = true
            UI.refresh(true)
        end
        SESSION:connect(minus.MouseButton1Click, function() bump(-1) end, "prio-")
        SESSION:connect(plus.MouseButton1Click, function() bump(1) end, "prio+")
        SESSION:connect(row.MouseButton1Click, function()
            Config.values.selected[kind] = not Ores.isSelected(kind)
            Config.dirty = true
            Log.info("Ores", kind .. (Ores.isSelected(kind) and " selected" or " deselected"))
            UI.refresh(true)
        end, "ore:" .. kind)
        return {frame = row, check = check, name = name, avail = avail, nearest = nearest, prio = prio}
    end

    UI.pageRefresh.Ores = function()
        local set = UI.setText
        if w.version ~= Ores.version then
            w.version = Ores.version
            for i, kind in ipairs(Ores.kindList) do
                if not w.rows[kind] then w.rows[kind] = makeRow(kind, i) end
                w.rows[kind].frame.LayoutOrder = i
            end
        end
        Ores.refreshStats()
        w.empty.Visible = #Ores.kindList == 0
        set(w.root, Ores.root and Ores.rootLabel or Ores.status)
        local total, _, selected = Ores.totals()
        set(w.totals, selected .. " / " .. total)
        set(w.memory, #Ores.memory)
        set(w.cooldown, Ores.blacklist:activeCount())
        for kind, row in pairs(w.rows) do
            local record = Ores.kinds[kind]
            local on = Ores.isSelected(kind)
            UI.setColor(row.check, "BackgroundColor3", on and T.accent or T.bg)
            UI.setColor(row.name, "TextColor3", on and T.text or T.faint)
            local tier = Ores.TIERS[kind]
            set(row.name, kind .. (tier and ("  T" .. tier) or ""))
            local suspended = Ores.suspendedKinds[kind] and U.now() < Ores.suspendedKinds[kind]
            if suspended then
                set(row.avail, "skipped")
            elseif record then
                set(row.avail, record.available .. " / " .. record.total)
                UI.setColor(row.avail, "TextColor3", record.available > 0 and T.success or T.faint)
                set(row.nearest, record.nearestDist and U.fmtDist(record.nearestDist) or "-")
            end
            set(row.prio, Ores.priority(kind))
        end
    end
end

function Pages.Navigation(page)
    local w = {}
    local status = UI.section(page, "Route status")
    w.dest = UI.kv(status, "Destination")
    w.destPos = UI.kv(status, "Destination position")
    w.route = UI.kv(status, "Route")
    w.wp = UI.kv(status, "Waypoint")
    w.length = UI.kv(status, "Leg path length")
    w.legs = UI.kv(status, "Legs travelled")
    w.replans = UI.kv(status, "Replans")
    w.stuck = UI.kv(status, "Stuck events / recoveries")
    w.compute = UI.kv(status, "Last path compute")
    w.fail = UI.kv(status, "Last failure")
    w.paths = UI.kv(status, "Paths computed / failed")
    w.unreach = UI.kv(status, "Unreachable deposits (total)")
    UI.buttonBar(status, {
        {"CLEAR DEPOSIT BLACKLIST", "ghost", function()
            Ores.blacklist:clear()
            Log.info("Nav", "Deposit blacklist cleared; all deposits will be reconsidered")
        end},
        {"RESET COUNTERS", "ghost", function()
            local s = Nav.status
            s.legs, s.replans, s.stuck, s.recoveries = 0, 0, 0, 0
        end},
    })
    local settings = UI.section(page, "Navigation settings")
    local renders = {}
    renders[#renders + 1] = UI.toggle(settings, "Show generated route", "showRoute")
    renders[#renders + 1] = UI.toggle(settings, "Highlight current target", "highlightTarget")
    renders[#renders + 1] = UI.toggle(settings, "Avoid deposits other players are mining", "avoidContested")
    renders[#renders + 1] = UI.toggle(settings, "Remember streamed-out deposit sites", "rememberSites")
    renders[#renders + 1] = UI.toggle(settings, "Agent can jump", "agentCanJump")
    renders[#renders + 1] = UI.toggle(settings, "Agent can climb (TrussParts)", "agentCanClimb")
    renders[#renders + 1] = UI.stepper(settings, "Max leg length (studs)", "maxLegLength", 20)
    renders[#renders + 1] = UI.stepper(settings, "Agent radius", "agentRadius", 0.5, nil)
    renders[#renders + 1] = UI.stepper(settings, "Agent height", "agentHeight", 0.5, nil)
    renders[#renders + 1] = UI.stepper(settings, "Waypoint spacing", "waypointSpacing", 1)
    renders[#renders + 1] = UI.stepper(settings, "Stuck detection (s)", "stuckTime", 0.2)
    renders[#renders + 1] = UI.stepper(settings, "Max replans per target", "maxReplans", 1)
    renders[#renders + 1] = UI.stepper(settings, "Min path recompute interval (s)", "pathRecalcMinInterval", 0.25)
    renders[#renders + 1] = UI.stepper(settings, "Candidates path-validated", "validateCandidates", 1)

    UI.pageRefresh.Navigation = function()
        local set, s = UI.setText, Nav.status
        set(w.dest, s.dest)
        set(w.destPos, U.fmtVec(s.destPos))
        set(w.route, s.route)
        set(w.wp, s.wpCount > 0 and (s.wpIndex .. " / " .. s.wpCount) or "-")
        set(w.length, s.length > 0 and U.fmtDist(s.length) or "-")
        set(w.legs, s.legs)
        set(w.replans, s.replans)
        set(w.stuck, s.stuck .. " / " .. s.recoveries)
        set(w.compute, s.lastComputeMs .. " ms")
        set(w.fail, s.lastFailure)
        set(w.paths, Stats.pathsComputed .. " / " .. Stats.pathFailures)
        set(w.unreach, Stats.unreachable)
    end
end

function Pages.Inventory(page)
    local T = UI.theme
    local w = {}
    local inv = UI.section(page, "Inventory", "Capacity is read from game data or UI when it can be identified; otherwise it is reported as unknown.")
    w.capacity = UI.label(inv, "Unknown", {Font = T.bold, TextSize = 16, Size = UDim2.new(1, 0, 0, 20)})
    w.bar = UI.progress(inv, 8)
    w.source = UI.kv(inv, "Source")
    w.items = UI.kv(inv, "Ore items in Backpack")
    w.full = UI.kv(inv, "Full signal")
    w.candidates = UI.kv(inv, "Capacity candidates found")
    w.learnInv = UI.kv(inv, "Learned inventory counter")
    w.drops = UI.kv(inv, "Ground drops observed")
    UI.buttonBar(inv, {
        {"RESCAN SOURCES", "ghost", function() Inventory.scan(true) Inventory.read() end},
        {"CYCLE SOURCE", "ghost", function()
            Inventory.cycleChoice()
            Log.info("Inventory", "Source: " .. (Inventory.choice == 0 and "automatic" or ("#" .. Inventory.choice)))
        end},
        {"CLEAR FULL FLAG", "ghost", function() Inventory.resetAfterSale() end},
    })
    local sell = UI.section(page, "Selling")
    local renders = {}
    renders[#renders + 1] = UI.toggle(sell, "Auto-sell when inventory needs unloading", "autoSell")
    renders[#renders + 1] = UI.stepper(sell, "Sell threshold", "sellThreshold", 0.05, U.fmtPct)
    renders[#renders + 1] = UI.stepper(sell, "Also sell every N deposits (0 = off)", "sellAfterDeposits", 1)
    renders[#renders + 1] = UI.toggle(sell, "Continue after an unverifiable sale", "continueAfterUnverifiedSale",
        "Pauses anyway after 3 unverifiable sales within 5 minutes")
    renders[#renders + 1] = UI.toggle(sell, "Use executor fireproximityprompt", "useFirePrompt",
        Exec.fireproximityprompt and "Available in this executor" or "Not available in this executor")
    renders[#renders + 1] = UI.toggle(sell, "Click a detected \"Sell\" dialog button", "clickSellDialog",
        "Uses VirtualInputManager; off by default (dialog layout unverified)")
    w.status = UI.kv(sell, "Discovery")
    w.current = UI.kv(sell, "Current seller")
    w.result = UI.kv(sell, "Last result")
    w.detail = UI.label(sell, "", {TextColor3 = T.faint, TextSize = 11, TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y})
    w.manual = UI.kv(sell, "Seller choice")
    w.fallback = UI.kv(sell, "Fallback sell point")
    w.wallet = UI.kv(sell, "Money source")
    w.sales = UI.kv(sell, "Sales verified / unverified / failed")
    UI.buttonBar(sell, {
        {"SCAN SELLERS", "ghost", function() Sellers.scan(true) end},
        {"CYCLE SELLER", "ghost", function()
            local c = Sellers.cycleManual()
            Log.info("Sellers", "Seller choice: " .. (c and c.label or "automatic"))
        end},
        {"SELL NOW", "primary", function()
            Inventory.markFull("manual sell request")
            if not Auto.running then Auto.start() elseif Auto.paused then Auto.resume() end
        end},
    })
    UI.buttonBar(sell, {
        {"SET FALLBACK POINT HERE", "ghost", function()
            local p = Char.position()
            if p then
                Config.set("sellPoint", U.vecToTable(p))
                Log.info("Sellers", "Fallback sell point set at " .. U.fmtVec(p))
            end
        end},
        {"CLEAR FALLBACK", "ghost", function()
            Config.set("sellPoint", nil)
            Log.info("Sellers", "Fallback sell point cleared")
        end},
    })

    UI.pageRefresh.Inventory = function()
        local set, s = UI.setText, Inventory.state
        if s.known then
            set(w.capacity, U.num(s.used) .. " / " .. U.num(s.capacity) .. "  (" .. U.fmtPct(s.fraction) .. ")")
            local color = s.fraction >= Config.get("sellThreshold") and T.warning or T.accent
            w.bar(s.fraction, color)
        else
            set(w.capacity, "Unknown")
            w.bar(0)
        end
        set(w.source, s.source)
        set(w.items, s.oreItems)
        set(w.full, s.fullFlag and tostring(s.fullReason) or "none")
        set(w.candidates, #Inventory.candidates .. (Inventory.choice > 0 and (" (manual #" .. Inventory.choice .. ")") or " (auto)"))
        set(w.learnInv, Learn.inv and tostring(Learn.inv.path) or "not yet (learned from mined ore)")
        set(w.drops, Inventory.dropsObserved)
        set(w.status, Sellers.scanning and "Scanning..." or Sellers.status)
        set(w.current, Sellers.current and Sellers.current.label or "-")
        set(w.result, Sellers.lastResult)
        set(w.detail, Sellers.lastDetail or "")
        local manual = Sellers.manualIndex > 0 and Sellers.list[Sellers.manualIndex]
        set(w.manual, manual and ("Manual: " .. manual.label) or "Automatic (nearest reachable)")
        local point = U.tableToVec(Config.get("sellPoint"))
        set(w.fallback, point and U.fmtVec(point) or "not set")
        set(w.wallet, Wallet.label .. (Wallet.lastValue and (" = " .. tostring(Wallet.lastValue)) or ""))
        set(w.sales, Stats.sales .. " / " .. Stats.salesUnverified .. " / " .. Stats.salesFailed)
    end
end

function Pages.Statistics(page)
    local w = {}
    local mining = UI.section(page, "Mining")
    w.attempts = UI.kv(mining, "Mining attempts")
    w.success = UI.kv(mining, "Successful / failed attempts")
    w.depleted = UI.kv(mining, "Deposits depleted")
    w.yields = UI.kv(mining, "Verified ore units")
    w.byKind = UI.kv(mining, "Units by type")
    w.swings = UI.kv(mining, "Swings / failed interactions")
    local time = UI.section(page, "Time")
    w.runtime = UI.kv(time, "Automation running time")
    w.travel = UI.kv(time, "Traveling")
    w.mining = UI.kv(time, "Mining")
    w.selling = UI.kv(time, "Selling")
    w.other = UI.kv(time, "Scanning / recovering / other")
    local eff = UI.section(page, "Efficiency")
    w.perHour = UI.kv(eff, "Deposits per hour")
    w.unitsHour = UI.kv(eff, "Verified units per hour")
    w.rate = UI.kv(eff, "Attempt success rate")
    w.minePct = UI.kv(eff, "Share of time mining")
    w.money = UI.kv(eff, "Money earned (verified)")
    local rel = UI.section(page, "Reliability")
    w.sales = UI.kv(rel, "Sales verified / unverified / failed")
    w.stuck = UI.kv(rel, "Stuck events / nav recoveries")
    w.fsm = UI.kv(rel, "FSM recoveries / errors")
    w.deaths = UI.kv(rel, "Deaths handled")
    UI.buttonBar(rel, {{"RESET STATISTICS", "danger", function() Stats.reset() Log.info("Stats", "Statistics reset") end}})

    UI.pageRefresh.Statistics = function()
        local set = UI.setText
        set(w.attempts, Stats.attempts)
        set(w.success, Stats.successAttempts .. " / " .. Stats.failedAttempts)
        set(w.depleted, Stats.depleted)
        set(w.yields, Stats.yields)
        local parts = {}
        for kind, n in pairs(Stats.yieldsByKind) do parts[#parts + 1] = kind .. " " .. n end
        table.sort(parts)
        set(w.byKind, #parts > 0 and table.concat(parts, ", ") or "-")
        set(w.swings, Stats.swings .. " / " .. Stats.failedInteractions)
        local rt = math.max(Stats.runtime, 1e-6)
        set(w.runtime, U.fmtTime(Stats.runtime))
        set(w.travel, U.fmtTime(Stats.travelTime) .. "  (" .. U.fmtPct(Stats.travelTime / rt) .. ")")
        set(w.mining, U.fmtTime(Stats.miningTime) .. "  (" .. U.fmtPct(Stats.miningTime / rt) .. ")")
        set(w.selling, U.fmtTime(Stats.sellingTime) .. "  (" .. U.fmtPct(Stats.sellingTime / rt) .. ")")
        set(w.other, U.fmtTime(Stats.otherTime) .. "  (" .. U.fmtPct(Stats.otherTime / rt) .. ")")
        local hours = Stats.runtime / 3600
        set(w.perHour, hours > 0.005 and string.format("%.1f", Stats.depleted / hours) or "-")
        set(w.unitsHour, hours > 0.005 and string.format("%.1f", Stats.yields / hours) or "-")
        set(w.rate, Stats.attempts > 0 and U.fmtPct(Stats.successAttempts / Stats.attempts) or "-")
        set(w.minePct, Stats.runtime > 0 and U.fmtPct(Stats.miningTime / rt) or "-")
        set(w.money, Wallet.source and tostring(Stats.moneyEarned) or "unknown (no money source)")
        set(w.sales, Stats.sales .. " / " .. Stats.salesUnverified .. " / " .. Stats.salesFailed)
        set(w.stuck, Stats.stuckEvents .. " / " .. Stats.recoveries)
        set(w.fsm, (Stats.fsmRecoveries or 0) .. " / " .. Stats.errors)
        set(w.deaths, Stats.deaths)
    end
end

function Pages.Settings(page)
    local T = UI.theme
    local w = {}
    local iface = UI.section(page, "Interface")
    UI.stepper(iface, "Interface scale", "uiScale", 0.05, nil, nil, function(v) Config.set("uiScale", v) UI.applyScale() end)
    UI.cycle(iface, "Accent color", "accent", nil, nil, function(v) Config.set("accent", v) UI.applyAccent(v) end)
    UI.cycle(iface, "Show/hide hotkey", "toggleKey")
    UI.toggle(iface, "Debug logging", "debugLog", nil, nil, function(v) Config.set("debugLog", v) Log.debugEnabled = v end)
    UI.toggle(iface, "Mirror log to console", "consoleLog", nil, nil, function(v)
        Config.set("consoleLog", v)
        Log.consoleLevel = v and 2 or 3
    end)
    local mine = UI.section(page, "Mining")
    UI.cycle(mine, "Interaction method", "interactMethod")
    UI.stepper(mine, "Swing interval (s)", "swingInterval", 0.05)
    UI.stepper(mine, "No-progress timeout (s)", "stallTimeout", 1)
    UI.stepper(mine, "Max time per deposit (s)", "mineTimeout", 10)
    UI.stepper(mine, "Mining range (studs)", "mineRange", 0.5)
    UI.toggle(mine, "Aim camera at deposit while mining", "aimCamera")
    UI.stepper(mine, "Pickaxe hotbar slot (0 = find automatically)", "pickaxeSlot", 1)
    UI.textField(mine, "Pickaxe name patterns (comma separated)", "pickaxePatterns", "pickaxe,pick")
    UI.textField(mine, "Preferred pickaxe (exact tool name, optional)", "preferredPickaxe", "")
    UI.textField(mine, "Ore root path(s) under Workspace (; separated)", "orePaths", "WORKSPACE_Interactables/Mining")
    UI.buttonBar(mine, {{"CLEAR LEARNED DATA FOR THIS PLACE", "ghost", function()
        Learned.clear()
        Learn.inv, Learn.money, Miner.autoMethod = nil, nil, nil
        Nav.driverVerified, Nav.driver = false, "MoveTo"
        Wallet.discover(true)
        Log.info("Learn", "Learned data for this place cleared")
    end}})
    local perf = UI.section(page, "Performance")
    UI.stepper(perf, "Ore root re-check interval (s)", "scanInterval", 1)
    UI.stepper(perf, "Interface refresh rate (Hz)", "uiRefreshRate", 1)
    UI.stepper(perf, "Seller rescan interval (s)", "sellerScanInterval", 5)
    UI.stepper(perf, "Blacklist base duration (s)", "blacklistBase", 5)
    UI.stepper(perf, "Blacklist max duration (s)", "blacklistMax", 30)
    local diag = UI.section(page, "Diagnostics")
    w.caps = UI.label(diag, "", {TextColor3 = T.muted, TextSize = 11, TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y})
    w.res = UI.label(diag, "", {TextColor3 = T.muted, TextSize = 11, TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y})
    w.results = UI.label(diag, "Self-tests have not run yet.", {Font = T.mono, TextSize = 11, TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y,
        TextYAlignment = Enum.TextYAlignment.Top})
    local verifyCard = UI.section(page, "Game assumptions",
        "Checks each assumption about TWW against this server and shows the evidence. SAVE WORLD REPORT writes " ..
        "the structure it found to TWWProspector/world_report.txt and the clipboard.")
    w.verify = UI.label(verifyCard, "", {Font = T.mono, TextSize = 11, TextWrapped = true,
        TextTruncate = Enum.TextTruncate.None, AutomaticSize = Enum.AutomaticSize.Y,
        TextYAlignment = Enum.TextYAlignment.Top})
    UI.buttonBar(verifyCard, {
        {"VERIFY ASSUMPTIONS", "primary", function() SESSION:spawn("Verify", Verify.run) end},
        {"SAVE WORLD REPORT", "ghost", function() SESSION:spawn("WorldReport", Verify.saveReport) end},
    })
    UI.buttonBar(diag, {
        {"RUN SELF-TESTS", "primary", function() SESSION:spawn("SelfTest", SelfTest.run, true) end},
        {"COPY REPORT", "ghost", function()
            if Exec.setclipboard then
                pcall(Exec.setclipboard, SelfTest.report())
                Log.info("Diagnostics", "Report copied to clipboard")
            else
                Log.warn("Diagnostics", "setclipboard is not available in this executor")
            end
        end},
    })
    UI.pageRefresh.Settings = function()
        local set = UI.setText
        set(w.caps, string.format("Executor: %s | getgenv %s | file API %s | clipboard %s | VirtualInputManager %s | fireproximityprompt %s",
            Exec.name, env ~= _G and "yes" or "no", Exec.writefile and "yes" or "no", Exec.setclipboard and "yes" or "no",
            Exec.vim and "yes" or "no", Exec.fireproximityprompt and "yes" or "no"))
        local c, t, i = SESSION:stats()
        set(w.res, string.format("Session %s | connections %d | threads %d | owned instances %d | log entries %d | settings: %s",
            SESSION.id, c, t, i, #Log.entries, Config.source))
        set(w.results, SelfTest.summaryText())
        set(w.verify, Verify.text())
    end
end

function Pages.Logs(page)
    local T = UI.theme
    local w = {rows = {}, version = -1, filter = "", level = "ALL"}
    local top = UI.section(page, "Event log")
    local controls = UI.row(top, 28)
    local box = UI.make("TextBox", {Text = "", PlaceholderText = "Filter text...", Font = T.font, TextSize = 12,
        TextColor3 = T.text, PlaceholderColor3 = T.faint, BackgroundColor3 = T.bg, BorderSizePixel = 0,
        ClearTextOnFocus = false, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -228, 1, 0)}, controls)
    UI.corner(box, 6)
    UI.pad(box, 8, 8, 0, 0)
    local levels = {"ALL", "INFO", "WARN", "ERROR", "DEBUG"}
    local levelButton = UI.make("TextButton", {Text = "ALL", Font = T.medium, TextSize = 12, TextColor3 = T.text,
        BackgroundColor3 = T.surface2, AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.new(0, 70, 1, 0),
        Position = UDim2.new(1, -220, 0, 0)}, controls)
    UI.corner(levelButton, 6)
    local clear = UI.make("TextButton", {Text = "CLEAR", Font = T.medium, TextSize = 12, TextColor3 = T.text,
        BackgroundColor3 = T.surface2, AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.new(0, 70, 1, 0),
        Position = UDim2.new(1, -146, 0, 0)}, controls)
    UI.corner(clear, 6)
    local copy = UI.make("TextButton", {Text = "COPY", Font = T.medium, TextSize = 12, TextColor3 = T.text,
        BackgroundColor3 = T.surface2, AutoButtonColor = false, BorderSizePixel = 0, Size = UDim2.new(0, 70, 1, 0),
        Position = UDim2.new(1, -72, 0, 0)}, controls)
    UI.corner(copy, 6)
    w.count = UI.label(top, "", {TextColor3 = T.faint, TextSize = 11})
    local holder = UI.make("Frame", {BackgroundColor3 = T.bg, BorderSizePixel = 0, Size = UDim2.new(1, 0, 0, 0),
        AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 100000}, top)
    UI.corner(holder, 6)
    UI.pad(holder, 8, 8, 6, 6)
    UI.vlist(holder, 1)
    local LEVEL_COLOR = {DEBUG = T.faint, INFO = T.text, WARN = T.warning, ERROR = T.danger}
    local MAX_ROWS = 150
    SESSION:connect(box:GetPropertyChangedSignal("Text"), function()
        w.filter = string.lower(box.Text)
        w.version = -1
    end, "log.filter")
    SESSION:connect(levelButton.MouseButton1Click, function()
        local idx = 1
        for i, l in ipairs(levels) do if l == w.level then idx = i end end
        w.level = levels[(idx % #levels) + 1]
        levelButton.Text = w.level
        w.version = -1
    end, "log.level")
    SESSION:connect(clear.MouseButton1Click, function()
        Log.entries = {}
        Log.version = Log.version + 1
    end, "log.clear")
    SESSION:connect(copy.MouseButton1Click, function()
        if not Exec.setclipboard then Log.warn("Logs", "setclipboard is not available in this executor") return end
        local lines = {}
        for _, e in ipairs(Log.entries) do lines[#lines + 1] = string.format("%s [%s][%s] %s", e.stamp, e.level, e.cat, e.msg) end
        pcall(Exec.setclipboard, table.concat(lines, "\n"))
    end, "log.copy")

    UI.pageRefresh.Logs = function()
        if w.version == Log.version then return end
        w.version = Log.version
        local shown = {}
        local entries = Log.entries
        for i = #entries, 1, -1 do
            local e = entries[i]
            local levelOk = w.level == "ALL" or e.level == w.level
            if levelOk and (w.filter == "" or U.has(string.lower(e.msg .. " " .. e.cat), w.filter)) then
                shown[#shown + 1] = e
                if #shown >= MAX_ROWS then break end
            end
        end
        for i = 1, MAX_ROWS do
            local e = shown[i]
            local row = w.rows[i]
            if e and not row then
                row = UI.make("TextLabel", {BackgroundTransparency = 1, Font = T.mono, TextSize = 11, TextWrapped = true,
                    TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
                    Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = i}, holder)
                w.rows[i] = row
            end
            if row then
                row.Visible = e ~= nil
                if e then
                    UI.setText(row, string.format("%s %-5s %-9s %s", e.stamp, e.level, e.cat, e.msg))
                    UI.setColor(row, "TextColor3", LEVEL_COLOR[e.level] or T.text)
                end
            end
        end
        UI.setText(w.count, string.format("Showing %d of %d entries | warnings %d | errors %d", #shown, #entries,
            Log.counts.WARN or 0, Log.counts.ERROR or 0))
    end
end

function UI.refresh(force)
    if not UI.built or not SESSION.alive then return end
    local now = U.now()
    if not force and now - UI.lastRefresh < 1 / Config.get("uiRefreshRate") then return end
    UI.lastRefresh = now
    UI.setText(UI.pillText, Auto.state == "MINING" and Auto.ctx and Auto.ctx.target
        and ("MINING " .. string.upper(Auto.ctx.target.kind)) or Auto.state)
    UI.setColor(UI.pillDot, "BackgroundColor3", UI.stateColor(Auto.state))
    if UI.sideStart then
        UI.setText(UI.sideStart, Auto.running and (Auto.paused and "RESUME" or "PAUSE") or "START")
    end
    if UI.collapsed or not UI.visible then return end
    local fn = UI.pageRefresh[UI.current]
    if fn then
        local ok, err = pcall(fn)
        if not ok then Log.error("UI", UI.current .. " refresh failed: " .. tostring(err), "uirefresh:" .. UI.current, 15) end
    end
end

function UI.build(parent)
    UI.buildShell(parent)
    local tabs = {
        {"Dashboard", "Dashboard"}, {"Ores", "Ore Management"}, {"Navigation", "Navigation"},
        {"Inventory", "Inventory & Selling"}, {"Statistics", "Statistics"}, {"Settings", "Settings"}, {"Logs", "Logs"},
    }
    for _, spec in ipairs(tabs) do
        local page = UI.addTab(spec[1], spec[2])
        local ok, err = pcall(Pages[spec[1]], page)
        if not ok then
            Log.error("UI", "Building tab " .. spec[1] .. " failed: " .. tostring(err))
            UI.label(page, "This tab failed to build: " .. tostring(err), {TextColor3 = UI.theme.danger, TextWrapped = true})
        end
    end
    local _, buttons = UI.buttonBar(UI.controls, {
        {"START", "primary", function()
            if not Auto.running then Auto.start()
            elseif Auto.paused then Auto.resume()
            else Auto.pause("Paused by user") end
        end},
    }, 32)
    UI.sideStart = buttons[1]
    UI.buttonBar(UI.controls, {{"STOP", "danger", function() Auto.stop("user") end}}, 32)
    UI.applyAccent(Config.get("accent"))
    UI.applyScale()
    UI.built = true
    UI.selectTab("Dashboard")
    if Config.get("collapsed") then UI.setCollapsed(true) end
end

-- ==== MODULE: Verify =====================================================================
-- Confirms every game-specific assumption against the live game, with evidence, and writes a
-- world-structure report (file + clipboard) that can be shared to confirm details offline.
-- Statuses: CONFIRMED | DIFFERENT (works, but not as assumed) | CONTRADICTED | NOT FOUND |
--           PENDING (needs an in-game event first, e.g. a full inventory) | LEARNED (found by observation)
Verify = {results = {}, ranAt = nil, running = false}

local function vadd(R, claim, status, evidence)
    R[#R + 1] = {claim = claim, status = status, evidence = tostring(evidence or "")}
end

local function promptSummary(prompt)
    local action, object, key, hold, range = "?", "?", "?", "?", "?"
    pcall(function()
        action, object = prompt.ActionText, prompt.ObjectText
        key = tostring(prompt.KeyboardKeyCode):gsub("^Enum%.KeyCode%.", "")
        hold, range = prompt.HoldDuration, prompt.MaxActivationDistance
    end)
    return string.format("\"%s\" / \"%s\" key %s hold %ss range %s at %s", tostring(action), tostring(object),
        tostring(key), tostring(hold), tostring(range), U.fullName(prompt.Parent))
end

function Verify.run()
    if Verify.running then return Verify.results end
    Verify.running = true
    Ores.maintain(true)
    local R = {}

    -- 1. Mining root location
    if Ores.root then
        local full = U.fullName(Ores.root)
        vadd(R, "Deposits live under workspace.WORKSPACE_Interactables.Mining",
            full == "Workspace.WORKSPACE_Interactables.Mining" and "CONFIRMED" or "DIFFERENT",
            full .. " (found by " .. tostring(Ores.rootHow) .. ")")
    else
        vadd(R, "Deposits live under workspace.WORKSPACE_Interactables.Mining", "NOT FOUND", Ores.status)
    end

    -- 2-4. Deposit layout, OreRemaining, ore type source
    local total, withInfo, withValue, withMesh, inOreDeposits = 0, 0, 0, 0, 0
    local sources, samples, sampleValue = {}, {}, nil
    for _, e in pairs(Ores.deposits) do
        total = total + 1
        if e.node:FindFirstChild("DepositInfo") then withInfo = withInfo + 1 end
        if e.remainingObj or e.remainingAttrHost then
            withValue = withValue + 1
            if not sampleValue then
                sampleValue = (e.remainingObj and (e.remainingObj.ClassName .. " " .. U.fullName(e.remainingObj)) or
                    ("attribute on " .. U.fullName(e.remainingAttrHost))) .. " = " .. tostring(e.remaining)
            end
        end
        if e.mesh then withMesh = withMesh + 1 end
        if U.has(U.fullName(e.node), ".OreDeposits.") then inOreDeposits = inOreDeposits + 1 end
        sources[e.kindSource or "?"] = (sources[e.kindSource or "?"] or 0) + 1
        if #samples < 3 then samples[#samples + 1] = U.fullName(e.node) end
    end
    local typeFolders = total - inOreDeposits
    local function share(n)
        if total == 0 then return "NOT FOUND" end
        if n == total then return "CONFIRMED" end
        if n > 0 then return "PARTLY" end
        return "CONTRADICTED"
    end
    vadd(R, "Layout Mining/<OreType>/<Deposit> (v2.0 assumption)", share(typeFolders),
        string.format("%d of %d deposits; samples: %s", typeFolders, total, total > 0 and table.concat(samples, " | ") or "-"))
    vadd(R, "Layout Mining/OreDeposits/<group>/<Deposit> (public scripts)", inOreDeposits > 0 and "CONFIRMED" or
        (total > 0 and "NOT PRESENT" or "NOT FOUND"), inOreDeposits .. " of " .. total .. " deposits")
    vadd(R, "Deposits expose DepositInfo.OreRemaining", share(withValue),
        string.format("%d/%d have DepositInfo, %d/%d a readable OreRemaining%s; %d/%d have an ore mesh%s",
            withInfo, total, withValue, total, sampleValue and (" (e.g. " .. sampleValue .. ")") or "", withMesh, total,
            (withValue < total and withMesh > 0) and " -> exhaustion tracked through the ore mesh" or ""))
    local parts = {}
    for source, n in pairs(sources) do parts[#parts + 1] = source .. " " .. n end
    table.sort(parts)
    vadd(R, "Ore type can be read for each deposit", (sources["no evidence yet"] or 0) == 0 and share(total) or "PARTLY",
        #parts > 0 and table.concat(parts, ", ") or "no deposits")

    -- 5-6. Pickaxe and interaction
    local tool, where = Tools.find()
    local visual = Tools.equippedVisual()
    local slot = Learned.get("hotbarSlot")
    local uiSlot = Tools.hotbarSlotFromUI()
    if tool then
        vadd(R, "Pickaxe is a Roblox Tool (v2.0 assumption)", "CONFIRMED", tool.Name .. " in " .. tostring(where))
    else
        vadd(R, "Pickaxe is a Roblox Tool (v2.0 assumption)", (visual or slot) and "CONTRADICTED" or "NOT FOUND",
            (visual and ("game item in hand: " .. U.fullName(visual)) or "no pickaxe in hand") ..
            (slot and ("; learned hotbar slot " .. slot) or "") .. (uiSlot and ("; hotbar UI shows it in slot " .. uiSlot) or "") ..
            (Input.available() and "" or "; VirtualInputManager unavailable"))
    end
    local interact = Learned.get("interact")
    vadd(R, "Mining interaction that produces progress", interact and "LEARNED" or "PENDING",
        interact and (interact .. " (remembered for this place)") or "not observed yet - mine one deposit")

    -- 7. Full inventory -> ground drop
    vadd(R, "Full inventory drops mined ore on the ground (wiki)",
        Inventory.dropsObserved > 0 and "CONFIRMED" or "PENDING",
        Inventory.dropsObserved > 0 and (Inventory.dropsObserved .. " drop(s) observed this session")
            or "only observable when the inventory is actually full")

    -- 8. Sell prompts
    local sellLines, sellLoot = {}, false
    for prompt, c in pairs(Sellers.prompts) do
        if c.score >= 100 and #sellLines < 6 then
            sellLines[#sellLines + 1] = promptSummary(prompt)
            local ok, action = pcall(function() return string.lower(prompt.ActionText or "") end)
            if ok and U.has(action, "sell loot") then sellLoot = true end
        end
    end
    local sellStatus = sellLoot and "CONFIRMED" or (#sellLines > 0 and "PARTLY" or "NOT FOUND")
    vadd(R, "Ore is sold by holding the \"Sell Loot\" prompt at stores (wiki/forum)", sellStatus,
        (#sellLines > 0 and table.concat(sellLines, " || ") or "no sell prompt replicated (stand near a General Store)") ..
        string.format(" | verified sales this session: %d", Stats.sales))

    -- 9-10. Inventory capacity and money
    local s = Inventory.state
    if Learn.inv then
        vadd(R, "Inventory capacity is readable", "LEARNED", tostring(Learn.inv.path) .. (s.known and
            (" = " .. U.num(s.used) .. "/" .. U.num(s.capacity)) or ""))
    elseif s.known then
        vadd(R, "Inventory capacity is readable", "CONFIRMED", s.source .. " = " .. U.num(s.used) .. "/" .. U.num(s.capacity))
    else
        vadd(R, "Inventory capacity is readable", "PENDING",
            "no counter identified yet; it is learned from the first mined ore (wiki: backpack holds 40 slots)")
    end
    Wallet.discover(true)
    vadd(R, "Money is readable", Learn.money and "LEARNED" or (Wallet.source and "CONFIRMED" or "PENDING"),
        Wallet.source and (Wallet.label .. " = " .. tostring(Wallet.read())) or "not identified yet; learned from the first sale")

    -- 11. Movement
    vadd(R, "Character moves with Humanoid:MoveTo", Nav.driverVerified and (Nav.driver == "MoveTo" and "CONFIRMED" or
        "CONTRADICTED") or "PENDING", Nav.driverVerified and ("working driver: " .. Nav.driver) or "not observed yet - travel once")

    Verify.results = R
    Verify.ranAt = U.now()
    Verify.running = false
    local counts = {}
    for _, r in ipairs(R) do counts[r.status] = (counts[r.status] or 0) + 1 end
    local summary = {}
    for status, n in pairs(counts) do summary[#summary + 1] = status .. " " .. n end
    table.sort(summary)
    Log.info("Verify", "Assumption check: " .. table.concat(summary, ", "))
    for _, r in ipairs(R) do Log.info("Verify", "[" .. r.status .. "] " .. r.claim .. ": " .. r.evidence) end
    return R
end

function Verify.text()
    if not Verify.ranAt then return "Not run yet. Press VERIFY ASSUMPTIONS while in a TWW server." end
    local lines = {}
    for _, r in ipairs(Verify.results) do
        lines[#lines + 1] = "[" .. r.status .. "] " .. r.claim .. "\n    " .. r.evidence
    end
    return table.concat(lines, "\n")
end

local MAX_REPORT_LINES = 1600

local function attrText(inst)
    local ok, attrs = pcall(function() return inst:GetAttributes() end)
    if not ok then return "" end
    local parts = {}
    for k, v in pairs(attrs) do
        if #parts >= 6 then break end
        parts[#parts + 1] = k .. "=" .. tostring(v)
    end
    if #parts == 0 then return "" end
    table.sort(parts)
    return "  {" .. table.concat(parts, ", ") .. "}"
end

local function dumpTree(inst, depth, maxDepth, lines, maxChildren, skip)
    if #lines >= MAX_REPORT_LINES then return end
    local info = inst.ClassName
    pcall(function()
        if inst:IsA("ValueBase") then info = info .. " = " .. tostring(inst.Value) end
        if inst:IsA("TextLabel") or inst:IsA("TextButton") then info = info .. " \"" .. tostring(inst.Text) .. "\"" end
    end)
    lines[#lines + 1] = string.rep("  ", depth) .. inst.Name .. "  [" .. info .. "]" .. attrText(inst)
    local children = inst:GetChildren()
    if depth >= maxDepth then
        if #children > 0 then lines[#lines + 1] = string.rep("  ", depth + 1) .. "... " .. #children .. " child(ren)" end
        return
    end
    for i, c in ipairs(children) do
        if i > maxChildren then
            lines[#lines + 1] = string.rep("  ", depth + 1) .. "... +" .. (#children - maxChildren) .. " more"
            break
        end
        if not (skip and skip[c]) then dumpTree(c, depth + 1, maxDepth, lines, maxChildren, skip) end
    end
end

function Verify.worldReport()
    if not Verify.ranAt then Verify.run() end
    local lines = {}
    local placeId, jobId = "?", "?"
    pcall(function() placeId, jobId = tostring(game.PlaceId), tostring(game.JobId) end)
    lines[#lines + 1] = APP_NAME .. " v" .. VERSION .. " world report"
    lines[#lines + 1] = "PlaceId " .. placeId .. "  JobId " .. jobId .. "  executor " .. Exec.name
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Verification =="
    lines[#lines + 1] = Verify.text()
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Mining root =="
    if Ores.root then dumpTree(Ores.root, 0, 3, lines, 8) else lines[#lines + 1] = "not found" end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Sample deposits (full subtree) =="
    local n = 0
    for node in pairs(Ores.deposits) do
        n = n + 1
        if n > 3 then break end
        lines[#lines + 1] = U.fullName(node)
        dumpTree(node, 1, 4, lines, 30)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Workspace top level =="
    for _, c in ipairs(Workspace:GetChildren()) do
        lines[#lines + 1] = c.Name .. "  [" .. c.ClassName .. "]  " .. #c:GetChildren() .. " child(ren)"
        if string.sub(c.Name, 1, 10) == "WORKSPACE_" then dumpTree(c, 1, 2, lines, 25) end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Sell-like prompts =="
    for prompt, c in pairs(Sellers.prompts) do
        lines[#lines + 1] = string.format("score %d  %s", c.score, promptSummary(prompt))
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Player (without PlayerGui) =="
    if LocalPlayer then
        local skip = {}
        if PlayerGui then skip[PlayerGui] = true end
        dumpTree(LocalPlayer, 0, 3, lines, 40, skip)
        lines[#lines + 1] = "attributes:" .. attrText(LocalPlayer)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Character models =="
    for _, model in ipairs(Tools.characterModels()) do
        lines[#lines + 1] = U.fullName(model)
        dumpTree(model, 1, 2, lines, 60)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== PlayerGui: screens, N/M labels, money labels =="
    if PlayerGui then
        for _, gui in ipairs(PlayerGui:GetChildren()) do
            if gui ~= UI.root then lines[#lines + 1] = "screen " .. gui.Name .. "  [" .. gui.ClassName .. "]" end
        end
        local fractions, money = 0, 0
        for _, inst in ipairs(PlayerGui:GetDescendants()) do
            if (inst:IsA("TextLabel") or inst:IsA("TextButton")) and not U.isDescendantOf(inst, UI.root) then
                local text = inst.Text or ""
                if U.parseFraction(text) and fractions < 25 then
                    fractions = fractions + 1
                    lines[#lines + 1] = "N/M  " .. U.fullName(inst) .. " = \"" .. text .. "\""
                elseif U.parseMoney(text) and money < 10 then
                    money = money + 1
                    lines[#lines + 1] = "$    " .. U.fullName(inst) .. " = \"" .. text .. "\""
                end
            end
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "== Learned for this place =="
    for k, v in pairs(Learned.place()) do
        lines[#lines + 1] = k .. " = " .. (type(v) == "table" and (#v .. " entr(ies)") or tostring(v))
    end
    if #lines >= MAX_REPORT_LINES then lines[#lines + 1] = "(report truncated)" end
    return table.concat(lines, "\n")
end

function Verify.saveReport()
    local text = Verify.worldReport()
    local saved, copied = false, false
    if Exec.writefile then
        saved = pcall(function()
            if Exec.makefolder and Exec.isfolder and not Exec.isfolder(SETTINGS_DIR) then Exec.makefolder(SETTINGS_DIR) end
            Exec.writefile(SETTINGS_DIR .. "/world_report.txt", text)
        end)
    end
    if Exec.setclipboard then copied = pcall(Exec.setclipboard, text) end
    local count = select(2, string.gsub(text, "\n", "\n")) + 1
    Log.info("Verify", string.format("World report: %d lines%s%s", count,
        saved and (", saved to " .. SETTINGS_DIR .. "/world_report.txt") or "", copied and ", copied to clipboard" or ""))
    if not saved and not copied then
        Log.warn("Verify", "Neither writefile nor setclipboard is available; the report is only in the Logs tab")
        for line in string.gmatch(text, "[^\n]+") do Log.info("Report", line) end
    end
    return text, saved, copied
end

-- ==== MODULE: SelfTest ===================================================================
-- Non-destructive in-game checks. Nothing here moves the character or interacts with the game.
SelfTest = {results = {}, ranAt = nil, running = false}

function SelfTest.run(includePath)
    if SelfTest.running then return end
    SelfTest.running = true
    local R = {}
    local function add(name, status, detail) R[#R + 1] = {name = name, status = status, detail = tostring(detail or "")} end

    add("Initialization", SESSION.alive and "PASS" or "FAIL",
        "session " .. SESSION.id .. ", settings from " .. Config.source)
    local guiOk = UI.built and U.alive(UI.root)
    add("GUI creation", guiOk and "PASS" or "FAIL", guiOk and U.fullName(UI.root) or "GUI is not parented")
    add("LocalPlayer", LocalPlayer and "PASS" or "FAIL", LocalPlayer and LocalPlayer.Name or "unavailable")
    local _, _, root = Char.get()
    add("Character / root", root and "PASS" or "WARN",
        root and (root.Name .. " at " .. U.fmtVec(root.Position)) or Char.status)

    Ores.maintain(true)
    add("Ore hierarchy", Ores.root and "PASS" or "FAIL", Ores.root and Ores.rootLabel or Ores.status)
    local withValue, without = 0, 0
    for _, e in pairs(Ores.deposits) do
        if e.remainingObj or e.remainingAttrHost then withValue = withValue + 1 else without = without + 1 end
    end
    local discovery = "FAIL"
    if Ores.depositCount > 0 then discovery = withValue > 0 and "PASS" or "WARN" end
    add("Ore discovery", discovery, string.format("%d type(s), %d deposit(s): %d with OreRemaining, %d without",
        #Ores.kindList, Ores.depositCount, withValue, without))

    local tool, where = Tools.find()
    local visual = Tools.equippedVisual()
    local slot = Learned.get("hotbarSlot")
    local pickDetail = (tool and (tool.Name .. " (Roblox Tool, " .. where .. ")"))
        or (visual and ("game item in hand: " .. visual.Name))
        or (slot and ("game item, learned hotbar slot " .. slot))
        or ("not a Roblox Tool and not in hand; hotbar keys are tried when mining starts" ..
            (Input.available() and "" or " (VirtualInputManager unavailable: equip it by hand)"))
    add("Pickaxe", (tool or visual or slot) and "PASS" or "WARN", pickDetail)

    if not PathfindingService then
        add("Navigation planning", "FAIL", "PathfindingService unavailable")
    elseif includePath and root then
        local here = root.Position
        local list = Targeting.candidates(here)
        local first = list[1] and list[1].entry
        if first then
            local spot = Miner.standSpots(first, here)[1]
            local started = U.now()
            local waypoints, why, len = Nav.compute(here, spot, false, nil)
            local ms = math.floor((U.now() - started) * 1000)
            if waypoints then
                add("Navigation planning", "PASS", string.format("%s deposit: %d waypoints, %d studs, %d ms",
                    first.kind, #waypoints, math.floor(len), ms))
            else
                add("Navigation planning", "WARN", string.format("%s deposit: no path (%s) - progressive legs or another target will be used",
                    first.kind, tostring(why)))
            end
        else
            add("Navigation planning", "SKIP", "no available deposit to plan a test path to")
        end
    else
        add("Navigation planning", "SKIP", "run from Settings > Diagnostics to compute a test path")
    end

    local token = Token.new(nil)
    local child = Token.new(token)
    token:cancel("selftest")
    local expired = Token.new(nil, -1)
    local tokensOk = token:dead() and child:dead() and child.reason == "selftest" and expired:dead()
    local probe = Session.new()
    local finished = false
    local fired = false
    local bindable = Instance.new("BindableEvent")
    probe:connect(bindable.Event, function() fired = true end, "selftest.bindable")
    probe:spawn("selftest.thread", function() task.wait(0.3) finished = true end)
    probe:destroy("self-test probe")
    pcall(function() bindable:Fire() end)
    task.wait(0.45)
    pcall(function() bindable:Destroy() end)
    local cleanupOk = not finished and not fired and #probe.conns == 0
    add("Cancellation & cleanup", (tokensOk and cleanupOk) and "PASS" or "FAIL",
        string.format("tokens %s, thread cancelled %s, connection cut %s", tostring(tokensOk), tostring(not finished),
            tostring(not fired)))

    Inventory.scan(true)
    local s = Inventory.read()
    add("Inventory availability", s.known and "PASS" or "WARN",
        s.known and (U.num(s.used) .. "/" .. U.num(s.capacity) .. " via " .. s.source) or s.source)
    local list = Sellers.rank()
    local prompts, others = 0, 0
    for _, c in ipairs(list) do if c.kind == "prompt" then prompts = prompts + 1 else others = others + 1 end end
    local sellStatus = prompts > 0 and "PASS" or "WARN"
    add("Selling subsystem", sellStatus, string.format("%d prompt candidate(s), %d building/fallback candidate(s)%s",
        prompts, others, Sellers.scanned and "" or " (initial scan still running)"))
    Wallet.discover(true)
    add("Money source", Wallet.source and "PASS" or "WARN", Wallet.label)

    SelfTest.results = R
    SelfTest.ranAt = U.now()
    SelfTest.running = false
    local counts = {PASS = 0, WARN = 0, FAIL = 0, SKIP = 0}
    for _, r in ipairs(R) do counts[r.status] = (counts[r.status] or 0) + 1 end
    local line = string.format("Self-test: %d pass, %d warn, %d fail, %d skipped", counts.PASS, counts.WARN, counts.FAIL, counts.SKIP)
    if counts.FAIL > 0 then Log.warn("SelfTest", line) else Log.info("SelfTest", line) end
    for _, r in ipairs(R) do
        if r.status ~= "PASS" then Log.info("SelfTest", "[" .. r.status .. "] " .. r.name .. ": " .. r.detail) end
    end
    return R
end

function SelfTest.summaryText()
    if not SelfTest.ranAt then return "Self-tests have not run yet." end
    local lines = {}
    for _, r in ipairs(SelfTest.results) do
        lines[#lines + 1] = string.format("[%s] %s - %s", r.status, r.name, r.detail)
    end
    return table.concat(lines, "\n")
end

function SelfTest.report()
    local lines = {APP_NAME .. " v" .. VERSION .. " diagnostics", "Executor: " .. Exec.name, "", SelfTest.summaryText(), "",
        "Recent warnings/errors:"}
    local n = 0
    for i = #Log.entries, 1, -1 do
        local e = Log.entries[i]
        if e.level == "WARN" or e.level == "ERROR" then
            lines[#lines + 1] = string.format("%s [%s][%s] %s", e.stamp, e.level, e.cat, e.msg)
            n = n + 1
            if n >= 25 then break end
        end
    end
    return table.concat(lines, "\n")
end

-- ==== MODULE: Main =======================================================================
local handle = {version = VERSION, id = SESSION.id}

local function shutdown(reason)
    if not SESSION.alive then return end
    pcall(Auto.stop, "shutdown")
    pcall(Config.save, true)
    SESSION:destroy(reason or "closed")
    if env[SESSION_KEY] == handle then env[SESSION_KEY] = nil end
    if env.TWWProspector == handle then env.TWWProspector = nil end
end
handle.stop = shutdown
handle.modules = {
    U = U, Log = Log, Session = Session, Token = Token, Config = Config, Stats = Stats, Char = Char, Tools = Tools,
    Blacklist = Blacklist, Ores = Ores, Nav = Nav, Visual = Visual, Probe = Probe, Miner = Miner,
    Inventory = Inventory, Wallet = Wallet, Sellers = Sellers, Targeting = Targeting, Auto = Auto, UI = UI,
    SelfTest = SelfTest, SESSION = SESSION, Exec = Exec, Learn = Learn, Learned = Learned, Verify = Verify,
    Input = Input,
}

local function waitFor(getter, seconds)
    local deadline = U.now() + seconds
    local value = getter()
    while not value and U.now() < deadline do
        task.wait(0.1)
        value = getter()
    end
    return value
end

-- Stops every earlier build: the v3 session handle, the v2.0 handle, then orphaned GUIs/visuals.
local function teardownPrevious()
    local prev = env[SESSION_KEY]
    if type(prev) == "table" and type(prev.stop) == "function" then
        local ok, err = pcall(prev.stop, "replaced by a new injection")
        if ok then Log.info("Main", "Stopped previous session " .. tostring(prev.id))
        else Log.warn("Main", "Previous session stop failed: " .. tostring(err)) end
    end
    local legacy = env.TWWProspector
    if type(legacy) == "table" and legacy ~= prev and type(legacy.stop) == "function" then
        local ok = pcall(legacy.stop)
        Log.info("Main", ok and "Stopped legacy v2.0 instance" or "Legacy v2.0 stop failed")
    end
    local removed = 0
    if PlayerGui then
        for _, child in ipairs(PlayerGui:GetChildren()) do
            for _, name in ipairs(LEGACY_GUI_NAMES) do
                if child.Name == name and child ~= UI.root then
                    if pcall(function() child:Destroy() end) then removed = removed + 1 end
                end
            end
        end
    end
    for _, child in ipairs(Workspace:GetChildren()) do
        for _, name in ipairs(LEGACY_WORLD_NAMES) do
            if child.Name == name and child ~= Visual.folder then
                if pcall(function() child:Destroy() end) then removed = removed + 1 end
            end
        end
    end
    if removed > 0 then Log.info("Main", "Removed " .. removed .. " orphaned GUI/visual object(s)") end
end

local function initStep(name, fn)
    local ok, err = pcall(fn)
    if ok then Log.info("Main", name .. ": ready")
    else Log.error("Main", name .. " failed to initialise: " .. tostring(err)) end
    return ok
end

local function buildGui(parent)
    local ok, err = pcall(UI.build, parent)
    if not ok then
        Log.error("Main", "GUI build failed: " .. tostring(err))
        warn("[Prospector] GUI build failed: " .. tostring(err))
    end
end

local function main()
    Config.load()
    Nav.driver = Learned.get("moveDriver") == "Move" and "Move" or "MoveTo"
    Nav.driverVerified = Learned.get("moveDriver") ~= nil
    Log.info("Main", APP_NAME .. " v" .. VERSION .. " starting (executor: " .. Exec.name .. ", settings: " .. Config.source .. ")")
    if not Players or not Workspace then
        warn("[Prospector] Players/Workspace services unavailable; aborting")
        return
    end
    LocalPlayer = waitFor(function() return Players.LocalPlayer end, 10)
    if not LocalPlayer then
        warn("[Prospector] LocalPlayer unavailable after 10s - this script must run on the client")
        return
    end
    PlayerGui = waitFor(function() return LocalPlayer:FindFirstChildOfClass("PlayerGui") end, 10)
    teardownPrevious()
    env[SESSION_KEY] = handle
    env.TWWProspector = handle
    UI.onClose = function() shutdown("closed from GUI") end

    -- Priority 1: the GUI appears even if later subsystems fail.
    if PlayerGui then
        buildGui(PlayerGui)
    else
        Log.error("Main", "PlayerGui not available after 10s; the GUI will be created when it appears")
        SESSION:spawn("LateGui", function()
            while SESSION.alive and not PlayerGui do
                PlayerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
                if PlayerGui then buildGui(PlayerGui) break end
                task.wait(1)
            end
        end)
    end

    initStep("Character tracking", Char.init)
    initStep("Ore registry", function() Ores.maintain(true) end)
    initStep("Inventory monitor", Inventory.init)
    initStep("Learned counters", Learn.restore)
    initStep("Money tracker", function() Wallet.discover(true) end)
    initStep("Seller discovery", Sellers.init)

    Config.onChange(function(key, value)
        if key == "showRoute" and not value then Visual.clearRoute() end
        if key == "highlightTarget" and not value then Visual.highlightTarget(nil) end
        if key == "orePaths" then Ores.detach() Ores.maintain(true) end
    end)
    local cam = Workspace.CurrentCamera
    if cam then
        SESSION:connect(cam:GetPropertyChangedSignal("ViewportSize"), function() UI.applyScale() end, "Viewport")
    end

    SESSION:spawn("Maintenance", function()
        local tick = 0
        local function maintain()
            Ores.maintain(false)
            Auto.accrue()
            if Auto.running or tick % 3 == 0 then Inventory.read() end
            if not Wallet.source then Wallet.discover(false) end
            if U.count(Sellers.prompts) == 0 and not Sellers.scanning
                and U.now() - Sellers.lastScan > Config.get("sellerScanInterval") then
                Sellers.scan(true)
            end
            if tick % 2 == 0 then Config.save(false) end
            if tick % 30 == 0 then Log.pruneThrottle(U.now()) end
        end
        while SESSION.alive do
            tick = tick + 1
            local okStep, stepErr = pcall(maintain)
            if not okStep then Log.error("Main", "Maintenance step failed: " .. tostring(stepErr), "maint", 30) end
            task.wait(1)
        end
    end)
    SESSION:spawn("UI refresh", function()
        while SESSION.alive do
            local okRefresh, refreshErr = pcall(UI.refresh, false)
            if not okRefresh then Log.error("UI", "Refresh failed: " .. tostring(refreshErr), "uiloop", 15) end
            task.wait(1 / Config.get("uiRefreshRate"))
        end
    end)
    SESSION:spawn("Startup self-test", function()
        task.wait(2)
        -- A full run the user started from Diagnostics in the meantime must not be overwritten.
        if not SelfTest.ranAt and not SelfTest.running then SelfTest.run(false) end
    end)
    Log.info("Main", "Ready. Choose ore types and press START. Hotkey " .. Config.get("toggleKey") .. " shows/hides the window.")
end

local ok, err = pcall(main)
if not ok then
    warn("[Prospector] Fatal initialisation error: " .. tostring(err))
    Log.error("Main", "Fatal initialisation error: " .. tostring(err))
end

return handle
