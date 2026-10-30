-- Minimal Roblox client mock for offline testing of TWW_Prospector_Ultimate.lua under LuaJIT.
-- It models only what the script touches: Instances/signals, a virtual-time task scheduler,
-- datatypes (Vector3, CFrame, UDim2, Color3, Enum), Humanoid movement, PathfindingService,
-- Raycast against a flat ground plane, ProximityPrompts and Tools.
-- It is NOT a Roblox emulator; game-specific behaviour is scripted per test.

local M = {}

-------------------------------------------------------------------------------- scheduler
local S = {now = 0, sleeping = {}, deferred = {}, cancelled = setmetatable({}, {__mode = "k"}), errors = {}}
M.S = S

local function resume(co, ...)
    if S.cancelled[co] then return end
    if coroutine.status(co) ~= "suspended" then return end
    local ok, err = coroutine.resume(co, ...)
    if not ok then
        local msg = tostring(err) .. "\n" .. debug.traceback(co)
        S.errors[#S.errors + 1] = msg
        io.stderr:write("[mock] thread error: " .. msg .. "\n")
    end
end

local task = {}
function task.spawn(fn, ...)
    local co = type(fn) == "thread" and fn or coroutine.create(fn)
    resume(co, ...)
    return co
end
function task.defer(fn, ...)
    local co = type(fn) == "thread" and fn or coroutine.create(fn)
    S.deferred[#S.deferred + 1] = {co = co, args = {...}, n = select("#", ...)}
    return co
end
function task.delay(t, fn, ...)
    local co = coroutine.create(fn)
    S.sleeping[#S.sleeping + 1] = {co = co, wake = S.now + (t or 0), args = {...}, n = select("#", ...)}
    return co
end
function task.wait(t)
    local co, isMain = coroutine.running()
    if co == nil or isMain then error("task.wait called outside a coroutine") end
    local start = S.now
    S.sleeping[#S.sleeping + 1] = {co = co, wake = S.now + math.max(t or 0, 1 / 60), args = {}, n = 0}
    coroutine.yield()
    return S.now - start
end
function task.cancel(co)
    S.cancelled[co] = true
    for i = #S.sleeping, 1, -1 do
        if S.sleeping[i].co == co then table.remove(S.sleeping, i) end
    end
end
M.task = task

-------------------------------------------------------------------------------- datatypes
local V3 = {}
V3.__index = function(v, k)
    if k == "X" then return rawget(v, 1) elseif k == "Y" then return rawget(v, 2) elseif k == "Z" then return rawget(v, 3)
    elseif k == "Magnitude" then return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
    elseif k == "Unit" then
        local m = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
        if m == 0 then return V3.new(0, 0, 0) end
        return V3.new(v[1] / m, v[2] / m, v[3] / m)
    elseif k == "Dot" then return function(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
    end
    return nil
end
function V3.new(x, y, z) return setmetatable({x or 0, y or 0, z or 0}, V3) end
V3.__add = function(a, b) return V3.new(a[1] + b[1], a[2] + b[2], a[3] + b[3]) end
V3.__sub = function(a, b) return V3.new(a[1] - b[1], a[2] - b[2], a[3] - b[3]) end
V3.__mul = function(a, b)
    if type(a) == "number" then return V3.new(b[1] * a, b[2] * a, b[3] * a) end
    if type(b) == "number" then return V3.new(a[1] * b, a[2] * b, a[3] * b) end
    return V3.new(a[1] * b[1], a[2] * b[2], a[3] * b[3])
end
V3.__div = function(a, b)
    if type(b) == "number" then return V3.new(a[1] / b, a[2] / b, a[3] / b) end
    return V3.new(a[1] / b[1], a[2] / b[2], a[3] / b[3])
end
V3.__unm = function(a) return V3.new(-a[1], -a[2], -a[3]) end
V3.__eq = function(a, b) return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] end
V3.__tostring = function(v) return string.format("%g, %g, %g", v[1], v[2], v[3]) end
local Vector3 = {new = V3.new, zero = V3.new(0, 0, 0), one = V3.new(1, 1, 1)}

local V2 = {}
V2.__index = function(v, k)
    if k == "X" then return rawget(v, 1) elseif k == "Y" then return rawget(v, 2)
    elseif k == "Magnitude" then return math.sqrt(v[1] * v[1] + v[2] * v[2]) end
    return nil
end
function V2.new(x, y) return setmetatable({x or 0, y or 0}, V2) end
V2.__add = function(a, b) return V2.new(a[1] + b[1], a[2] + b[2]) end
V2.__sub = function(a, b) return V2.new(a[1] - b[1], a[2] - b[2]) end
V2.__div = function(a, b) return V2.new(a[1] / b, a[2] / b) end
V2.__mul = function(a, b) return V2.new(a[1] * b, a[2] * b) end
local Vector2 = {new = V2.new, zero = V2.new(0, 0)}

local CF = {}
CF.__index = function(c, k)
    if k == "Position" or k == "p" then return rawget(c, "pos") end
    if k == "LookVector" then return rawget(c, "look") end
    if k == "X" then return rawget(c, "pos").X end
    if k == "Y" then return rawget(c, "pos").Y end
    if k == "Z" then return rawget(c, "pos").Z end
    if k == "PointToObjectSpace" then return function(self, p) return p - rawget(self, "pos") end end
    return nil
end
local CFrame = {}
function CFrame.new(a, b, c)
    local pos
    if type(a) == "number" then pos = V3.new(a, b, c) else pos = a or V3.new(0, 0, 0) end
    return setmetatable({pos = pos, look = V3.new(0, 0, -1)}, CF)
end
function CFrame.lookAt(a, b)
    local d = b - a
    return setmetatable({pos = a, look = d.Magnitude > 0 and d.Unit or V3.new(0, 0, -1)}, CF)
end

local C3 = {}
C3.__index = C3
C3.__eq = function(a, b) return a.R == b.R and a.G == b.G and a.B == b.B end
local Color3 = {}
function Color3.new(r, g, b) return setmetatable({R = r or 0, G = g or 0, B = b or 0}, C3) end
function Color3.fromRGB(r, g, b) return Color3.new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end

local UD = {}
UD.__index = UD
UD.__eq = function(a, b) return a.Scale == b.Scale and a.Offset == b.Offset end
local UDim = {new = function(s, o) return setmetatable({Scale = s or 0, Offset = o or 0}, UD) end}
local UD2 = {}
UD2.__index = UD2
UD2.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
local UDim2 = {}
function UDim2.new(xs, xo, ys, yo) return setmetatable({X = UDim.new(xs, xo), Y = UDim.new(ys, yo)}, UD2) end
function UDim2.fromOffset(x, y) return UDim2.new(0, x, 0, y) end
function UDim2.fromScale(x, y) return UDim2.new(x, 0, y, 0) end

local TweenInfo = {new = function(...) return {...} end}
local RaycastParams = {new = function() return {} end}

local enumCache = {}
local EnumItemMT = {__tostring = function(e) return "Enum." .. e.EnumType .. "." .. e.Name end}
local Enum = setmetatable({}, {__index = function(_, enumName)
    local items = enumCache[enumName]
    if not items then
        items = setmetatable({}, {__index = function(t, itemName)
            local item = setmetatable({Name = itemName, EnumType = enumName}, EnumItemMT)
            rawset(t, itemName, item)
            return item
        end})
        enumCache[enumName] = items
    end
    return items
end})

-------------------------------------------------------------------------------- signals
local Signal = {}
Signal.__index = Signal
function Signal.new() return setmetatable({conns = {}}, Signal) end
function Signal:Connect(fn)
    local conn = {Connected = true, fn = fn}
    function conn.Disconnect(c) c.Connected = false end
    self.conns[#self.conns + 1] = conn
    return conn
end
function Signal:Fire(...)
    local list = {}
    for _, c in ipairs(self.conns) do if c.Connected then list[#list + 1] = c end end
    for _, c in ipairs(list) do
        if c.Connected then task.spawn(c.fn, ...) end
    end
end
function Signal:DisconnectAll()
    for _, c in ipairs(self.conns) do c.Connected = false end
end
function Signal:connectedCount()
    local n = 0
    for _, c in ipairs(self.conns) do if c.Connected then n = n + 1 end end
    return n
end
M.Signal = Signal

-------------------------------------------------------------------------------- instances
local registry = setmetatable({}, {__mode = "k"})
M.registry = registry
local SUPER = {
    Part = "BasePart", MeshPart = "BasePart", BasePart = "PVInstance", Model = "PVInstance", PVInstance = "Instance",
    Workspace = "Model", IntValue = "ValueBase", NumberValue = "ValueBase", StringValue = "ValueBase",
    BoolValue = "ValueBase", ObjectValue = "ValueBase", ValueBase = "Instance",
    Frame = "GuiObject", TextLabel = "GuiObject", TextButton = "GuiButton", ImageButton = "GuiButton",
    GuiButton = "GuiObject", TextBox = "GuiObject", ScrollingFrame = "GuiObject", ImageLabel = "GuiObject",
    GuiObject = "GuiBase2d", GuiBase2d = "Instance", ScreenGui = "LayerCollector", BillboardGui = "LayerCollector",
    SurfaceGui = "LayerCollector", LayerCollector = "GuiBase2d", Tool = "BackpackItem", BackpackItem = "Instance",
}
local SIGNALS = {
    Changed = true, ChildAdded = true, ChildRemoved = true, DescendantAdded = true, DescendantRemoving = true,
    AncestryChanged = true, AttributeChanged = true, Destroying = true, MouseButton1Click = true, MouseEnter = true,
    MouseLeave = true, Activated = true, Deactivated = true, InputBegan = true, InputChanged = true, InputEnded = true,
    FocusLost = true, Died = true, Equipped = true, Unequipped = true, Blocked = true, CharacterAdded = true,
    CharacterRemoving = true, Heartbeat = true, RenderStepped = true, Triggered = true, MoveToFinished = true,
    Event = true, PlayerAdded = true, PlayerRemoving = true,
}

local Methods = {}
local InstMT = {}

local function data(obj) return registry[obj] end

local function signalOf(d, name)
    d.signals[name] = d.signals[name] or Signal.new()
    return d.signals[name]
end

InstMT.__index = function(obj, key)
    local d = registry[obj]
    if key == "Parent" then return d.Parent end
    local m = Methods[key]
    if m then return m end
    if SIGNALS[key] then return signalOf(d, key) end
    local v = d.props[key]
    if v ~= nil then return v end
    for _, child in ipairs(d.children) do
        if registry[child].props.Name == key then return child end
    end
    return nil
end

local function isA(class, target)
    while class do
        if class == target then return true end
        class = SUPER[class]
    end
    return target == "Instance"
end

local function ancestors(obj)
    local list, p = {}, registry[obj].Parent
    while p do list[#list + 1] = p p = registry[p].Parent end
    return list
end

local function subtree(obj, out)
    out = out or {}
    for _, c in ipairs(registry[obj].children) do
        out[#out + 1] = c
        subtree(c, out)
    end
    return out
end

local function setParent(obj, newParent)
    local d = registry[obj]
    if d.destroyed and newParent ~= nil then error("The Parent property of " .. d.props.Name .. " is locked") end
    local old = d.Parent
    if old == newParent then return end
    local moved = {obj}
    subtree(obj, moved)
    if old then
        for _, a in ipairs({old, unpack(ancestors(old))}) do
            for _, m in ipairs(moved) do signalOf(registry[a], "DescendantRemoving"):Fire(m) end
        end
        local od = registry[old]
        for i, c in ipairs(od.children) do if c == obj then table.remove(od.children, i) break end end
        signalOf(od, "ChildRemoved"):Fire(obj)
    end
    d.Parent = newParent
    if newParent then
        local nd = registry[newParent]
        nd.children[#nd.children + 1] = obj
        signalOf(nd, "ChildAdded"):Fire(obj)
        for _, a in ipairs({newParent, unpack(ancestors(newParent))}) do
            for _, m in ipairs(moved) do signalOf(registry[a], "DescendantAdded"):Fire(m) end
        end
    end
    for _, m in ipairs(moved) do signalOf(registry[m], "AncestryChanged"):Fire(obj, newParent) end
end

local function fireProp(obj, key, value)
    local d = registry[obj]
    if d.propSignals[key] then d.propSignals[key]:Fire() end
    if isA(d.props.ClassName, "ValueBase") then
        if key == "Value" then signalOf(d, "Changed"):Fire(value) end
    else
        signalOf(d, "Changed"):Fire(key)
    end
end

InstMT.__newindex = function(obj, key, value)
    local d = registry[obj]
    if key == "Parent" then setParent(obj, value) return end
    if key == "Position" and isA(d.props.ClassName, "BasePart") then
        d.props.CFrame = CFrame.new(value)
    elseif key == "CFrame" and isA(d.props.ClassName, "BasePart") then
        d.props.Position = value.Position
    end
    local old = d.props[key]
    d.props[key] = value
    if old ~= value then
        fireProp(obj, key, value)
        if key == "CFrame" then fireProp(obj, "Position", value.Position) end
        if key == "Position" then fireProp(obj, "CFrame", d.props.CFrame) end
    end
end
InstMT.__tostring = function(obj) return registry[obj].props.Name end

local DEFAULTS = {
    Humanoid = {Health = 100, MaxHealth = 100, WalkSpeed = 16, Jump = false, Sit = false, PlatformStand = false},
    Part = {Size = Vector3.new(2, 1, 4), Anchored = false, Transparency = 0},
    ProximityPrompt = {ActionText = "Interact", ObjectText = "", HoldDuration = 0, MaxActivationDistance = 10, Enabled = true,
        KeyboardKeyCode = Enum.KeyCode.E},
    ScreenGui = {Enabled = true},
    BillboardGui = {Enabled = true},
    Tool = {ToolTip = ""},
    IntValue = {Value = 0},
    NumberValue = {Value = 0},
    Camera = {CameraType = Enum.CameraType.Custom},
}

local function new(class, parent)
    local obj = setmetatable({}, InstMT)
    local props = {ClassName = class, Name = class}
    for k, v in pairs(DEFAULTS[class] or {}) do props[k] = v end
    if isA(class, "GuiObject") then
        props.Visible = true
        props.Text = props.Text or ""
        props.AbsolutePosition = Vector2.new(100, 100)
        props.AbsoluteSize = Vector2.new(100, 30)
    end
    if isA(class, "BasePart") then
        props.Position = Vector3.new(0, 0, 0)
        props.CFrame = CFrame.new(0, 0, 0)
        props.Size = props.Size or Vector3.new(2, 1, 4)
    end
    registry[obj] = {props = props, children = {}, signals = {}, propSignals = {}, attrs = {}, attrSignals = {}, Parent = nil}
    if parent then obj.Parent = parent end
    return obj
end
M.new = new

function Methods.IsA(obj, class) return isA(registry[obj].props.ClassName, class) end
function Methods.FindFirstChild(obj, name, recursive)
    local list = recursive and subtree(obj) or registry[obj].children
    for _, c in ipairs(list) do if registry[c].props.Name == name then return c end end
    return nil
end
function Methods.FindFirstChildOfClass(obj, class)
    for _, c in ipairs(registry[obj].children) do if registry[c].props.ClassName == class then return c end end
    return nil
end
function Methods.FindFirstChildWhichIsA(obj, class)
    for _, c in ipairs(registry[obj].children) do if isA(registry[c].props.ClassName, class) then return c end end
    return nil
end
function Methods.GetChildren(obj)
    local r = {}
    for i, c in ipairs(registry[obj].children) do r[i] = c end
    return r
end
function Methods.GetDescendants(obj) return subtree(obj) end
function Methods.IsDescendantOf(obj, anc)
    if anc == nil then return false end
    local p = registry[obj].Parent
    while p do
        if p == anc then return true end
        p = registry[p].Parent
    end
    return false
end
function Methods.GetFullName(obj)
    local names, node = {}, obj
    while node and registry[node].props.ClassName ~= "DataModel" do
        table.insert(names, 1, registry[node].props.Name)
        node = registry[node].Parent
    end
    return table.concat(names, ".")
end
function Methods.Destroy(obj)
    local d = registry[obj]
    if d.destroyed then return end
    for _, c in ipairs(Methods.GetChildren(obj)) do Methods.Destroy(c) end
    signalOf(d, "Destroying"):Fire()
    setParent(obj, nil)
    d.destroyed = true
    for _, s in pairs(d.signals) do s:DisconnectAll() end
    for _, s in pairs(d.propSignals) do s:DisconnectAll() end
    for _, s in pairs(d.attrSignals) do s:DisconnectAll() end
end
function Methods.GetPropertyChangedSignal(obj, prop)
    local d = registry[obj]
    d.propSignals[prop] = d.propSignals[prop] or Signal.new()
    return d.propSignals[prop]
end
function Methods.GetAttribute(obj, name) return registry[obj].attrs[name] end
function Methods.GetAttributes(obj)
    local r = {}
    for k, v in pairs(registry[obj].attrs) do r[k] = v end
    return r
end
function Methods.SetAttribute(obj, name, value)
    local d = registry[obj]
    d.attrs[name] = value
    if d.attrSignals[name] then d.attrSignals[name]:Fire() end
    signalOf(d, "AttributeChanged"):Fire(name)
end
function Methods.GetAttributeChangedSignal(obj, name)
    local d = registry[obj]
    d.attrSignals[name] = d.attrSignals[name] or Signal.new()
    return d.attrSignals[name]
end
-- Model
local function parts(obj)
    local r = {}
    if isA(registry[obj].props.ClassName, "BasePart") then r[1] = obj end
    for _, c in ipairs(subtree(obj)) do if isA(registry[c].props.ClassName, "BasePart") then r[#r + 1] = c end end
    return r
end
function Methods.GetBoundingBox(obj)
    local ps = parts(obj)
    if #ps == 0 then return CFrame.new(0, 0, 0), Vector3.new(0, 0, 0) end
    local minV, maxV = {math.huge, math.huge, math.huge}, {-math.huge, -math.huge, -math.huge}
    for _, p in ipairs(ps) do
        local pos, size = p.Position, p.Size
        for i, axis in ipairs({"X", "Y", "Z"}) do
            minV[i] = math.min(minV[i], pos[axis] - size[axis] / 2)
            maxV[i] = math.max(maxV[i], pos[axis] + size[axis] / 2)
        end
    end
    return CFrame.new((minV[1] + maxV[1]) / 2, (minV[2] + maxV[2]) / 2, (minV[3] + maxV[3]) / 2),
        Vector3.new(maxV[1] - minV[1], maxV[2] - minV[2], maxV[3] - minV[3])
end
function Methods.GetPivot(obj)
    local pp = registry[obj].props.PrimaryPart
    if pp then return pp.CFrame end
    local cf = Methods.GetBoundingBox(obj)
    return cf
end
-- Humanoid
function Methods.MoveTo(obj, pos) registry[obj].props._moveTarget = pos end
function Methods.Move(obj, dir) registry[obj].props._moveDir = dir end
function Methods.EquipTool(obj, tool)
    local char = registry[obj].Parent
    Methods.UnequipTools(obj)
    tool.Parent = char
    tool.Equipped:Fire()
end
function Methods.UnequipTools(obj)
    local char = registry[obj].Parent
    for _, c in ipairs(Methods.GetChildren(char)) do
        if registry[c].props.ClassName == "Tool" then
            c.Parent = M.backpack
            c.Unequipped:Fire()
        end
    end
end
-- Tool
function Methods.Activate(obj) obj.Activated:Fire() end
function Methods.Deactivate(obj) obj.Deactivated:Fire() end
-- ProximityPrompt
function Methods.InputHoldBegin(obj)
    if M.promptIgnoresInputHold then return end
    registry[obj].props._holdStart = S.now
end
function Methods.InputHoldEnd(obj)
    local d = registry[obj]
    local start = d.props._holdStart
    d.props._holdStart = nil
    if not start then return end
    M.tryTriggerPrompt(obj, S.now - start)
end
-- Shared by InputHoldEnd and by a held keyboard key (see M.holdKeyForPrompts).
function M.tryTriggerPrompt(obj, held)
    local d = registry[obj]
    if not d.props.Enabled then return end
    if held + 1e-6 < d.props.HoldDuration then return end
    local root = M.root()
    local anchor = d.Parent and (d.Parent.Position or (d.Parent.PrimaryPart and d.Parent.PrimaryPart.Position))
    if not root or not anchor or (root.Position - anchor).Magnitude > d.props.MaxActivationDistance then return end
    M.promptTriggers = (M.promptTriggers or 0) + 1
    obj.Triggered:Fire(M.player)
    if M.onPromptTriggered then M.onPromptTriggered(obj) end
end
-- Player / Camera / BindableEvent / services
function Methods.RequestStreamAroundAsync() end
function Methods.WorldToViewportPoint() return Vector3.new(400, 300, 10), true end
function Methods.Fire(obj, ...) obj.Event:Fire(...) end
function Methods.GetPlayers() return {M.player} end
function Methods.GetFocusedTextBox() return nil end
function Methods.GetGuiInset() return Vector2.new(0, 36) end
function Methods.SendMouseButtonEvent(obj, x, y, button, isDown)
    M.clicks = (M.clicks or 0) + 1
    if isDown and M.onClick then M.onClick(x, y) end
end
function Methods.SendMouseMoveEvent() end
function Methods.SendKeyEvent(obj, isDown, keyCode)
    M.keyEvents = (M.keyEvents or 0) + 1
    if M.onKey then M.onKey(keyCode, isDown) end
end
function Methods.JSONEncode() return "{}" end
function Methods.JSONDecode() return {} end
function Methods.Create(obj, inst, info, props)
    return {Play = function() for k, v in pairs(props) do inst[k] = v end end, Cancel = function() end}
end
function Methods.CreatePath(obj, params)
    local path = new("Path")
    registry[path].props.Status = Enum.PathStatus.NoPath
    registry[path].props._params = params
    return path
end
function Methods.ComputeAsync(path, from, to)
    M.pathCalls = (M.pathCalls or 0) + 1
    local points = M.pathfinder(from, to)
    local d = registry[path]
    if not points then
        d.props.Status = Enum.PathStatus.NoPath
        d.props._waypoints = {}
        return
    end
    local wps = {}
    for i, p in ipairs(points) do wps[i] = {Position = p, Action = Enum.PathWaypointAction.Walk, Label = ""} end
    d.props._waypoints = wps
    d.props.Status = Enum.PathStatus.Success
end
function Methods.GetWaypoints(path)
    local r = {}
    for i, w in ipairs(registry[path].props._waypoints or {}) do r[i] = w end
    return r
end
function Methods.Raycast(ws, origin, direction)
    local y = M.groundY
    if direction.Y < 0 and origin.Y >= y and origin.Y + direction.Y <= y then
        return {Position = Vector3.new(origin.X, y, origin.Z), Instance = M.baseplate, Normal = Vector3.new(0, 1, 0)}
    end
    return nil
end
function Methods.GetService(game, name)
    local svc = M.services[name]
    if not svc then error("'" .. tostring(name) .. "' is not a valid Service name") end
    return svc
end

-------------------------------------------------------------------------------- default path finder
function M.straightPath(from, to)
    local pts = {from}
    local dist = (to - from).Magnitude
    local steps = math.max(1, math.floor(dist / 4))
    for i = 1, steps do pts[#pts + 1] = from + (to - from) * (i / steps) end
    return pts
end

-------------------------------------------------------------------------------- world construction
function M.reset()
    S.now, S.sleeping, S.deferred, S.errors = 0, {}, {}, {}
    S.cancelled = setmetatable({}, {__mode = "k"})
    M.output, M.warnings = {}, {}
    M.pathCalls, M.promptTriggers, M.clicks = 0, 0, 0
    M.groundY = 0
    M.pathfinder = M.straightPath
    M.onPromptTriggered = nil
    M.walkBlocked = nil
    M.genv = {}
    M.inventory, M.money, M.mining, M.swings, M.missed = nil, nil, nil, nil, nil
    M.onKey, M.onClick, M.promptIgnoresInputHold, M.keyEvents = nil, nil, nil, 0
    M.character, M.humanoid = nil, nil

    local game = new("DataModel")
    game.PlaceId = 2317712696
    game.JobId = "mock-job"
    local workspace = new("Workspace", game)
    workspace.Name = "Workspace"
    local camera = new("Camera", workspace)
    camera.ViewportSize = Vector2.new(1280, 720)
    camera.CFrame = CFrame.new(0, 10, 0)
    workspace.CurrentCamera = camera
    local baseplate = new("Part", workspace)
    baseplate.Name = "Baseplate"
    baseplate.Anchored = true
    M.baseplate = baseplate
    local players = new("Players", game)
    local player = new("Player", players)
    player.Name = "Tester"
    player.UserId = 1
    local playerGui = new("PlayerGui", player)
    playerGui.Name = "PlayerGui"
    local backpack = new("Backpack", player)
    backpack.Name = "Backpack"
    players.LocalPlayer = player
    M.game, M.workspace, M.players, M.player, M.playerGui, M.backpack = game, workspace, players, player, playerGui, backpack
    M.services = {
        Players = players, Workspace = workspace, RunService = new("RunService"), UserInputService = new("UserInputService"),
        PathfindingService = new("PathfindingService"), TweenService = new("TweenService"),
        HttpService = new("HttpService"), VirtualInputManager = new("VirtualInputManager"), GuiService = new("GuiService"),
    }

    _G.game, _G.workspace = game, workspace
    _G.task = task
    _G.Instance = {new = function(class, parent) return new(class, parent) end}
    _G.Vector3, _G.Vector2, _G.CFrame, _G.Color3 = Vector3, Vector2, CFrame, Color3
    _G.UDim, _G.UDim2, _G.TweenInfo, _G.RaycastParams, _G.Enum = UDim, UDim2, TweenInfo, RaycastParams, Enum
    _G.typeof = function(x)
        if registry[x] then return "Instance" end
        local mt = getmetatable(x)
        if mt == V3 then return "Vector3" elseif mt == V2 then return "Vector2" elseif mt == CF then return "CFrame"
        elseif mt == C3 then return "Color3" elseif mt == UD2 then return "UDim2" end
        return type(x)
    end
    _G.getgenv = function() return M.genv end
    _G.identifyexecutor = function() return "MockExecutor", "1.0" end
    _G.warn = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        M.warnings[#M.warnings + 1] = table.concat(parts, " ")
    end
    _G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        M.output[#M.output + 1] = table.concat(parts, " ")
    end
    os.clock = function() return S.now end
    return M
end

function M.makeCharacter(pos)
    local char = new("Model")
    char.Name = "Tester"
    local root = new("Part", char)
    root.Name = "HumanoidRootPart"
    root.Size = Vector3.new(2, 2, 1)
    root.Position = pos or Vector3.new(0, 3, 0)
    local hum = new("Humanoid", char)
    hum.RootPart = root
    char.PrimaryPart = root
    char.Parent = M.workspace
    M.player.Character = char
    M.character, M.humanoid = char, hum
    M.player.CharacterAdded:Fire(char)
    return char, hum, root
end

function M.root()
    local c = M.player and M.player.Character
    return c and c:FindFirstChild("HumanoidRootPart")
end

function M.kill()
    local hum = M.humanoid
    hum.Health = 0
    hum.Died:Fire()
    local char = M.character
    M.player.CharacterRemoving:Fire(char)
    char:Destroy()
    M.player.Character = nil
end

-- Simple deposit: Model{Rock(Part), DepositInfo(Folder){OreRemaining(IntValue)}}
function M.makeDeposit(folder, name, pos, remaining, withInfo)
    local model = new("Model")
    model.Name = name or "Deposit"
    local rock = new("Part", model)
    rock.Name = "Rock"
    rock.Anchored = true
    rock.Size = Vector3.new(4, 4, 4)
    rock.Position = pos
    model.PrimaryPart = rock
    if withInfo ~= false then
        local info = new("Folder", model)
        info.Name = "DepositInfo"
        local v = new("IntValue", info)
        v.Name = "OreRemaining"
        v.Value = remaining or 3
    end
    model.Parent = folder
    return model
end

-------------------------------------------------------------------------------- time
local function simulateMovement(dt)
    local hum, root = M.humanoid, M.root()
    if not hum or not root or hum.Health <= 0 then return end
    if hum._frozen then return end
    local pos = root.Position
    local moveDir = registry[hum].props._moveDir
    local target = registry[hum].props._moveTarget
    if moveDir and moveDir.Magnitude > 0.01 then
        target = pos + Vector3.new(moveDir.X, 0, moveDir.Z).Unit * 1000
    elseif hum._ignoreMoveTo then
        return
    end
    if not target then return end
    local delta = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
    local dist = delta.Magnitude
    if dist < 0.05 then
        registry[hum].props._moveTarget = nil
        hum.MoveToFinished:Fire(true)
        return
    end
    local step = math.min(dist, hum.WalkSpeed * dt)
    local nextPos = pos + delta.Unit * step
    if M.walkBlocked and M.walkBlocked(pos, nextPos) then return end
    registry[root].props.Position = Vector3.new(nextPos.X, pos.Y, nextPos.Z)
    registry[root].props.CFrame = CFrame.new(registry[root].props.Position)
end

function M.step(dt)
    S.now = S.now + dt
    simulateMovement(dt)
    M.services.RunService.Heartbeat:Fire(dt)
    local guard = 0
    while #S.deferred > 0 and guard < 1000 do
        guard = guard + 1
        local item = table.remove(S.deferred, 1)
        resume(item.co, unpack(item.args, 1, item.n))
    end
    local due = {}
    for i = #S.sleeping, 1, -1 do
        if S.sleeping[i].wake <= S.now then
            due[#due + 1] = S.sleeping[i]
            table.remove(S.sleeping, i)
        end
    end
    table.sort(due, function(a, b) return a.wake < b.wake end)
    for _, item in ipairs(due) do resume(item.co, unpack(item.args, 1, item.n)) end
end

function M.run(seconds, dt)
    dt = dt or (1 / 30)
    local stop = S.now + seconds
    while S.now < stop do M.step(dt) end
end

-- Runs until predicate() is true or timeout; returns true if satisfied.
function M.runUntil(predicate, timeout, dt)
    dt = dt or (1 / 30)
    local stop = S.now + (timeout or 30)
    while S.now < stop do
        if predicate() then return true end
        M.step(dt)
    end
    return predicate() and true or false
end

function M.loadScript(path)
    local chunk, err = loadfile(path)
    if not chunk then error("cannot load script: " .. tostring(err)) end
    local result
    task.spawn(function() result = chunk() end)
    M.step(1 / 30)
    return function() return result end
end

function M.connectionCount(obj)
    local d = registry[obj]
    local n = 0
    for _, s in pairs(d.signals) do n = n + s:connectedCount() end
    for _, s in pairs(d.propSignals) do n = n + s:connectedCount() end
    for _, s in pairs(d.attrSignals) do n = n + s:connectedCount() end
    return n
end

return M
