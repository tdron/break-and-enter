--[[
	RobloxMock
	----------
	A tiny fake of the parts of the Roblox engine API that Steal an Item's
	server scripts use, so the real scripts can run under the standalone
	`luau` CLI for integration tests. It is deliberately simple:

	  * Instances with properties, children, attributes, signals and IsA().
	  * Vector3 / CFrame math, Color3, UDim2, Enum, TweenInfo, ...
	  * A virtual clock and task scheduler (task.wait/spawn/delay/defer).
	  * "Physics": AlignPosition moves its part toward its target at MaxVelocity.
	  * Input: ContextActionService bindings can be triggered with Mock.pressKey().
	  * Animations: Animator:LoadAnimation() returns tracks that remember Play/Stop/speed.
	  * An in-memory DataStore.

	This file is concatenated into the test bundle by tools/run_luau_tests.py.
]]

local Mock = {}

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------
local SignalMeta = {}
SignalMeta.__index = SignalMeta

local function newSignal()
	return setmetatable({ _handlers = {} }, SignalMeta)
end

function SignalMeta:Connect(fn)
	local handler = { fn = fn, connected = true }
	table.insert(self._handlers, handler)
	local connection = { Connected = true }
	function connection:Disconnect()
		handler.connected = false
		connection.Connected = false
	end
	return connection
end
SignalMeta.Once = SignalMeta.Connect

--------------------------------------------------------------------------------
-- Virtual time & scheduler
--------------------------------------------------------------------------------
local now = 0
local queue = {}
local realOs = os
os = setmetatable({
	clock = function()
		return now
	end,
	time = function()
		return 1700000000 + math.floor(now)
	end,
}, { __index = realOs })

local function resume(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then
		error(debug.traceback(co, tostring(err)), 0)
	end
end

local function schedule(at, co, ...)
	table.insert(queue, { time = at, co = co, args = table.pack(...) })
end

function SignalMeta:Fire(...)
	for _, handler in table.clone(self._handlers) do
		if handler.connected then
			resume(coroutine.create(handler.fn), ...)
		end
	end
end

task = {
	spawn = function(fn, ...)
		local co = if type(fn) == "thread" then fn else coroutine.create(fn)
		resume(co, ...)
		return co
	end,
	defer = function(fn, ...)
		local co = coroutine.create(fn)
		schedule(now, co, ...)
		return co
	end,
	delay = function(seconds, fn, ...)
		local co = coroutine.create(fn)
		schedule(now + (seconds or 0), co, ...)
		return co
	end,
	wait = function(seconds)
		local co = coroutine.running()
		schedule(now + (seconds or 0), co)
		coroutine.yield()
		return seconds or 0
	end,
}

local function runDueTasks()
	while true do
		local bestIndex, bestTime = nil, math.huge
		for index, entry in queue do
			if entry.time <= now and entry.time < bestTime then
				bestIndex, bestTime = index, entry.time
			end
		end
		if not bestIndex then
			return
		end
		local entry = table.remove(queue, bestIndex)
		resume(entry.co, table.unpack(entry.args, 1, entry.args.n))
	end
end

--------------------------------------------------------------------------------
-- Datatypes
--------------------------------------------------------------------------------
local V3Meta = {}
local V3Methods = {}
local function vec(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3Meta)
end
V3Meta.__index = function(v, key)
	if key == "Magnitude" then
		return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
	elseif key == "Unit" then
		local m = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		if m == 0 then
			return vec(0, 0, 0)
		end
		return vec(v.X / m, v.Y / m, v.Z / m)
	end
	return V3Methods[key]
end
V3Meta.__add = function(a, b)
	return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
V3Meta.__sub = function(a, b)
	return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
V3Meta.__unm = function(a)
	return vec(-a.X, -a.Y, -a.Z)
end
V3Meta.__mul = function(a, b)
	if type(a) == "number" then
		return vec(b.X * a, b.Y * a, b.Z * a)
	elseif type(b) == "number" then
		return vec(a.X * b, a.Y * b, a.Z * b)
	end
	return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3Meta.__div = function(a, b)
	if type(b) == "number" then
		return vec(a.X / b, a.Y / b, a.Z / b)
	end
	return vec(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V3Meta.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
V3Meta.__tostring = function(a)
	return string.format("%.2f, %.2f, %.2f", a.X, a.Y, a.Z)
end
function V3Methods:Dot(o)
	return self.X * o.X + self.Y * o.Y + self.Z * o.Z
end
function V3Methods:Cross(o)
	return vec(self.Y * o.Z - self.Z * o.Y, self.Z * o.X - self.X * o.Z, self.X * o.Y - self.Y * o.X)
end
function V3Methods:Min(o)
	return vec(math.min(self.X, o.X), math.min(self.Y, o.Y), math.min(self.Z, o.Z))
end
function V3Methods:Max(o)
	return vec(math.max(self.X, o.X), math.max(self.Y, o.Y), math.max(self.Z, o.Z))
end
function V3Methods:Lerp(o, t)
	return self + (o - self) * t
end
Vector3 = {
	new = vec,
	zero = vec(0, 0, 0),
	one = vec(1, 1, 1),
	xAxis = vec(1, 0, 0),
	yAxis = vec(0, 1, 0),
	zAxis = vec(0, 0, 1),
}
Mock.isVector3 = function(v)
	return getmetatable(v) == V3Meta
end

local CFMeta = {}
local CFMethods = {}
local function cframe(x, y, z, r)
	return setmetatable({ _p = vec(x, y, z), _r = r or { 1, 0, 0, 0, 1, 0, 0, 0, 1 } }, CFMeta)
end
local function matmul(a, b)
	local r = {}
	for i = 0, 2 do
		for j = 0, 2 do
			r[i * 3 + j + 1] = a[i * 3 + 1] * b[j + 1] + a[i * 3 + 2] * b[3 + j + 1] + a[i * 3 + 3] * b[6 + j + 1]
		end
	end
	return r
end
local function matvec(r, v)
	return vec(
		r[1] * v.X + r[2] * v.Y + r[3] * v.Z,
		r[4] * v.X + r[5] * v.Y + r[6] * v.Z,
		r[7] * v.X + r[8] * v.Y + r[9] * v.Z
	)
end
CFMeta.__index = function(c, key)
	local r = c._r
	if key == "Position" or key == "p" then
		return c._p
	elseif key == "X" then
		return c._p.X
	elseif key == "Y" then
		return c._p.Y
	elseif key == "Z" then
		return c._p.Z
	elseif key == "LookVector" then
		return vec(-r[3], -r[6], -r[9])
	elseif key == "RightVector" then
		return vec(r[1], r[4], r[7])
	elseif key == "UpVector" then
		return vec(r[2], r[5], r[8])
	elseif key == "Rotation" then
		return cframe(0, 0, 0, r)
	end
	return CFMethods[key]
end
CFMeta.__mul = function(a, b)
	if getmetatable(b) == CFMeta then
		local p = a._p + matvec(a._r, b._p)
		return cframe(p.X, p.Y, p.Z, matmul(a._r, b._r))
	end
	return a._p + matvec(a._r, b)
end
CFMeta.__add = function(a, v)
	return cframe(a._p.X + v.X, a._p.Y + v.Y, a._p.Z + v.Z, a._r)
end
CFMeta.__sub = function(a, v)
	return cframe(a._p.X - v.X, a._p.Y - v.Y, a._p.Z - v.Z, a._r)
end
function CFMethods:Inverse()
	local r = self._r
	local t = { r[1], r[4], r[7], r[2], r[5], r[8], r[3], r[6], r[9] }
	local p = matvec(t, self._p)
	return cframe(-p.X, -p.Y, -p.Z, t)
end
function CFMethods:PointToObjectSpace(v)
	return self:Inverse() * v
end
function CFMethods:PointToWorldSpace(v)
	return self * v
end
function CFMethods:ToObjectSpace(other)
	return self:Inverse() * other
end
function CFMethods:ToWorldSpace(other)
	return self * other
end
function CFMethods:GetComponents()
	local r = self._r
	return self._p.X, self._p.Y, self._p.Z, r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9]
end
CFrame = {}
function CFrame.new(a, b, c, ...)
	if a == nil then
		return cframe(0, 0, 0)
	elseif type(a) == "table" then
		return cframe(a.X, a.Y, a.Z)
	end
	if select("#", ...) == 9 then
		return cframe(a, b, c, { ... })
	end
	return cframe(a, b, c)
end
function CFrame.Angles(rx, ry, rz)
	local cx, sx = math.cos(rx), math.sin(rx)
	local cy, sy = math.cos(ry), math.sin(ry)
	local cz, sz = math.cos(rz), math.sin(rz)
	local mx = { 1, 0, 0, 0, cx, -sx, 0, sx, cx }
	local my = { cy, 0, sy, 0, 1, 0, -sy, 0, cy }
	local mz = { cz, -sz, 0, sz, cz, 0, 0, 0, 1 }
	return cframe(0, 0, 0, matmul(matmul(mx, my), mz))
end
CFrame.fromEulerAnglesXYZ = CFrame.Angles
function CFrame.lookAt(pos, target)
	local look = (target - pos).Unit
	local right = look:Cross(vec(0, 1, 0)).Unit
	local up = right:Cross(look)
	return cframe(pos.X, pos.Y, pos.Z, { right.X, up.X, -look.X, right.Y, up.Y, -look.Y, right.Z, up.Z, -look.Z })
end
CFrame.identity = cframe(0, 0, 0)
Mock.isCFrame = function(v)
	return getmetatable(v) == CFMeta
end

local Color3Meta = {}
Color3Meta.__index = Color3Meta
local function color3(r, g, b)
	return setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, Color3Meta)
end
function Color3Meta:Lerp(other, alpha)
	return color3(self.R + (other.R - self.R) * alpha, self.G + (other.G - self.G) * alpha, self.B + (other.B - self.B) * alpha)
end
Color3Meta.__eq = function(a, b)
	return a.R == b.R and a.G == b.G and a.B == b.B
end
Color3 = {
	new = color3,
	fromRGB = function(r, g, b)
		return color3((r or 0) / 255, (g or 0) / 255, (b or 0) / 255)
	end,
}
UDim = {
	new = function(scale, offset)
		return { Scale = scale, Offset = offset }
	end,
}
UDim2 = {
	new = function(xs, xo, ys, yo)
		return { X = UDim.new(xs or 0, xo or 0), Y = UDim.new(ys or 0, yo or 0) }
	end,
	fromOffset = function(x, y)
		return UDim2.new(0, x, 0, y)
	end,
	fromScale = function(x, y)
		return UDim2.new(x, 0, y, 0)
	end,
}
Vector2 = {
	new = function(x, y)
		return { X = x or 0, Y = y or 0 }
	end,
}
ColorSequence = {
	new = function(...)
		return { ... }
	end,
}
TweenInfo = {
	new = function(...)
		return { ... }
	end,
}
PhysicalProperties = {
	new = function(...)
		return { ... }
	end,
}
local function paramsFactory()
	return {
		new = function()
			return { FilterDescendantsInstances = {} }
		end,
	}
end
RaycastParams = paramsFactory()
OverlapParams = paramsFactory()

local enumCache = {}
Enum = setmetatable({}, {
	__index = function(_, group)
		if not enumCache[group] then
			enumCache[group] = setmetatable({}, {
				__index = function(t, name)
					local item = { Name = name, EnumType = group }
					rawset(t, name, item)
					return item
				end,
			})
		end
		return enumCache[group]
	end,
})

-- Deterministic Random
local RandomMeta = {}
RandomMeta.__index = RandomMeta
function RandomMeta:_next()
	local x = self.state
	x = bit32.bxor(x, bit32.lshift(x, 13))
	x = bit32.bxor(x, bit32.rshift(x, 17))
	x = bit32.bxor(x, bit32.lshift(x, 5))
	self.state = x
	return x / 4294967296
end
function RandomMeta:NextNumber(min, max)
	local n = self:_next()
	return if min then min + (max - min) * n else n
end
function RandomMeta:NextInteger(min, max)
	return min + math.floor(self:_next() * (max - min + 1))
end
Random = {
	new = function(seed)
		return setmetatable({ state = (seed or 7) % 4294967295 + 1 }, RandomMeta)
	end,
}

warn = function(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring((select(i, ...)))
	end
	table.insert(Mock.warnings, table.concat(parts, " "))
end
Mock.warnings = {}

--------------------------------------------------------------------------------
-- Instances
--------------------------------------------------------------------------------
local SUPER = {
	Part = "FormFactorPart",
	FormFactorPart = "BasePart",
	WedgePart = "FormFactorPart",
	SpawnLocation = "Part",
	Seat = "Part",
	VehicleSeat = "BasePart",
	BasePart = "PVInstance",
	Model = "PVInstance",
	Workspace = "Model",
	PVInstance = "Instance",
	Script = "BaseScript",
	LocalScript = "Script",
	BaseScript = "LuaSourceContainer",
	ModuleScript = "LuaSourceContainer",
	LuaSourceContainer = "Instance",
	BillboardGui = "LayerCollector",
	SurfaceGui = "LayerCollector",
	ScreenGui = "LayerCollector",
	LayerCollector = "GuiBase2d",
	TextLabel = "GuiObject",
	TextButton = "GuiButton",
	GuiButton = "GuiObject",
	Frame = "GuiObject",
	GuiObject = "GuiBase2d",
	GuiBase2d = "Instance",
	PointLight = "Light",
	Light = "Instance",
	AlignPosition = "Constraint",
	AlignOrientation = "Constraint",
	LinearVelocity = "Constraint",
	Constraint = "Instance",
	Weld = "JointInstance",
	JointInstance = "Instance",
	NumberValue = "ValueBase",
	IntValue = "ValueBase",
	ValueBase = "Instance",
	ScrollingFrame = "GuiObject",
	ImageLabel = "GuiObject",
	UICorner = "UIComponent",
	UIStroke = "UIComponent",
	UIPadding = "UIComponent",
	UIGradient = "UIComponent",
	UIScale = "UIComponent",
	UIListLayout = "UIGridStyleLayout",
	UIGridStyleLayout = "UILayout",
	UILayout = "UIComponent",
	UIComponent = "UIBase",
	UIBase = "Instance",
	PlayerGui = "BasePlayerGui",
	BasePlayerGui = "Instance",
}

local SIGNALS = {
	Touched = true,
	Triggered = true,
	DescendantAdded = true,
	DescendantRemoving = true,
	ChildAdded = true,
	ChildRemoved = true,
	AncestryChanged = true,
	CharacterAdded = true,
	PlayerAdded = true,
	PlayerRemoving = true,
	Heartbeat = true,
	Stepped = true,
	RenderStepped = true,
	Changed = true,
	OnClientEvent = true,
	OnServerEvent = true,
	Completed = true,
	PromptTriggered = true,
	PromptShown = true,
	Activated = true,
	MouseEnter = true,
	MouseLeave = true,
	MouseButton1Down = true,
	MouseButton1Up = true,
	MouseButton1Click = true,
}

local DEFAULTS = {
	BasePart = function()
		return {
			Size = vec(4, 1, 2),
			Transparency = 0,
			Anchored = false,
			CanCollide = true,
			CanTouch = true,
			CanQuery = true,
			Massless = false,
			AssemblyLinearVelocity = vec(0, 0, 0),
			PivotOffset = CFrame.new(),
			Color = Color3.new(0.6, 0.6, 0.6),
		}
	end,
	Humanoid = function()
		return {
			WalkSpeed = 16,
			Health = 100,
			MaxHealth = 100,
			MoveDirection = vec(0, 0, 0),
			Sit = false,
			Jump = false,
			AutoRotate = true,
			HipHeight = 2,
			RigType = Enum.HumanoidRigType.R15,
		}
	end,
	ProximityPrompt = function()
		return { Enabled = true, HoldDuration = 0, MaxActivationDistance = 10 }
	end,
	ValueBase = function()
		return { Value = 0 }
	end,
	Model = function()
		return { WorldPivot = CFrame.new() }
	end,
	Camera = function()
		return { CFrame = CFrame.new(), FieldOfView = 70 }
	end,
	Light = function()
		return { Enabled = true }
	end,
	AlignPosition = function()
		return { Position = vec(0, 0, 0), MaxVelocity = math.huge, Enabled = true }
	end,
	LinearVelocity = function()
		return { VectorVelocity = vec(0, 0, 0) }
	end,
}

local InstanceMethods = {}
local InstanceMeta = {}
Mock.alignPositions = setmetatable({}, { __mode = "k" })
Mock.movers = setmetatable({}, { __mode = "k" })

local function classChain(className)
	local chain = {}
	local current = className
	while current do
		table.insert(chain, current)
		current = SUPER[current]
	end
	table.insert(chain, "Instance")
	return chain
end

local function isA(instance, className)
	for _, name in classChain(rawget(instance, "ClassName")) do
		if name == className then
			return true
		end
	end
	return false
end

local function newInstance(className)
	local props = { Name = className }
	for _, name in classChain(className) do
		local factory = DEFAULTS[name]
		if factory then
			for key, value in factory() do
				if props[key] == nil then
					props[key] = value
				end
			end
		end
	end
	if props.Size ~= nil and className ~= "BillboardGui" and className ~= "TextLabel" then
		props.CFrame = CFrame.new()
	end
	local instance = setmetatable({
		ClassName = className,
		_props = props,
		_children = {},
		_attributes = {},
		_attrSignals = {},
		_propSignals = {},
		_signals = {},
	}, InstanceMeta)
	if className == "AlignPosition" then
		Mock.alignPositions[instance] = true
	elseif className == "LinearVelocity" or className == "AlignOrientation" then
		Mock.movers[instance] = true
	end
	return instance
end

-- Optional: ClassName -> { PropertyName = "ReadWrite" | "Read" | "None" | "Custom" }, generated from
-- the Roblox API database by the test runner. When present, the mock behaves like Roblox and errors
-- on unknown members and on writes to read-only properties.
Mock.propertyRules = nil :: any

local function rulesFor(instance)
	local rules = Mock.propertyRules
	return rules and rules[rawget(instance, "ClassName")]
end

InstanceMeta.__index = function(instance, key)
	local props = rawget(instance, "_props")
	-- A real property value wins over a method of the same name (Humanoid.Sit is a bool,
	-- Seat:Sit() is a method).
	local own = props[key]
	if own ~= nil and key ~= "Position" then
		return own
	end
	local method = InstanceMethods[key]
	if method then
		return method
	end
	if key == "Parent" then
		return rawget(instance, "_parent")
	elseif key == "Position" and props.CFrame then
		return props.CFrame.Position
	end
	local value = props[key]
	if value ~= nil then
		return value
	end
	if SIGNALS[key] then
		local signals = rawget(instance, "_signals")
		signals[key] = signals[key] or newSignal()
		return signals[key]
	end
	local child = InstanceMethods.FindFirstChild(instance, key)
	if child then
		return child
	end
	local rules = rulesFor(instance)
	if rules and rules[key] == nil and key ~= "ClassName" then
		error(string.format("%s is not a valid member of %s \"%s\"", tostring(key), rawget(instance, "ClassName"), props.Name), 2)
	end
	return nil
end

local function firePropertyChanged(instance, key)
	local signal = rawget(instance, "_propSignals")[key]
	if signal then
		signal:Fire()
	end
end

-- Fires an event only if something is listening (like Roblox does not, but it keeps the mock cheap).
local function fireSignal(instance, key, ...)
	local signals = rawget(instance, "_signals")
	local signal = signals and signals[key]
	if signal then
		signal:Fire(...)
	end
end

-- The instance plus every one of its descendants, in a snapshot (listeners may reparent things).
local function subtree(instance): { any }
	local nodes = { instance }
	local index = 1
	while index <= #nodes do
		local children = rawget(nodes[index], "_children")
		if children then
			for _, child in children do
				table.insert(nodes, child)
			end
		end
		index += 1
	end
	return nodes
end

-- ChildAdded on the new parent, DescendantAdded on it and every ancestor for the whole subtree.
local function fireParented(instance, parent)
	fireSignal(parent, "ChildAdded", instance)
	local nodes = subtree(instance)
	local node = parent
	while node do
		for _, child in nodes do
			fireSignal(node, "DescendantAdded", child)
		end
		node = rawget(node, "_parent")
	end
end

-- ChildRemoved on the old parent, DescendantRemoving on it and every ancestor for the whole subtree.
local function fireUnparented(instance, parent)
	fireSignal(parent, "ChildRemoved", instance)
	local nodes = subtree(instance)
	local node = parent
	while node do
		for _, child in nodes do
			fireSignal(node, "DescendantRemoving", child)
		end
		node = rawget(node, "_parent")
	end
end

InstanceMeta.__newindex = function(instance, key, value)
	local props = rawget(instance, "_props")
	local rules = rulesFor(instance)
	if rules and key ~= "Parent" then
		local access = rules[key]
		if access == nil then
			error(string.format("%s is not a valid member of %s", tostring(key), rawget(instance, "ClassName")), 2)
		elseif access ~= "ReadWrite" then
			error(string.format("Unable to assign property %s. Property is read only (%s.%s)", key, rawget(instance, "ClassName"), key), 2)
		end
	end
	if key == "Parent" then
		local old = rawget(instance, "_parent")
		if old == value then
			return
		end
		if old then
			local siblings = rawget(old, "_children")
			local index = table.find(siblings, instance)
			if index then
				table.remove(siblings, index)
			end
			fireUnparented(instance, old)
		end
		rawset(instance, "_parent", value)
		if value then
			table.insert(rawget(value, "_children"), instance)
			fireParented(instance, value)
		end
		return
	elseif key == "Position" and props.CFrame then
		props.CFrame = props.CFrame.Rotation + value
		firePropertyChanged(instance, "CFrame")
		return
	elseif key == "WorldPivot" and isA(instance, "Model") and props.PrimaryPart then
		local primary = props.PrimaryPart
		primary.PivotOffset = primary.CFrame:Inverse() * value
		return
	elseif key == "Sit" and value == false and isA(instance, "Humanoid") and props.SeatPart then
		local seat = props.SeatPart
		props.SeatPart = nil
		Mock.setRaw(seat, "Occupant", nil)
	end
	local old = props[key]
	props[key] = value
	if old ~= value then
		firePropertyChanged(instance, key)
	end
end

InstanceMeta.__tostring = function(instance)
	return rawget(instance, "_props").Name
end

function InstanceMethods:IsA(className)
	return isA(self, className)
end
function InstanceMethods:GetChildren()
	return table.clone(rawget(self, "_children"))
end
function InstanceMethods:GetDescendants()
	local result = {}
	local function walk(node)
		for _, child in rawget(node, "_children") do
			table.insert(result, child)
			walk(child)
		end
	end
	walk(self)
	return result
end
function InstanceMethods:FindFirstChild(name, recursive)
	for _, child in rawget(self, "_children") do
		if rawget(child, "_props").Name == name then
			return child
		end
	end
	if recursive then
		for _, child in rawget(self, "_children") do
			local found = InstanceMethods.FindFirstChild(child, name, true)
			if found then
				return found
			end
		end
	end
	return nil
end
function InstanceMethods:WaitForChild(name)
	local child = InstanceMethods.FindFirstChild(self, name)
	if not child then
		table.insert(Mock.warnings, "WaitForChild would wait forever for " .. name .. " in " .. self:GetFullName())
	end
	return child
end
function InstanceMethods:FindFirstChildOfClass(className)
	for _, child in rawget(self, "_children") do
		if rawget(child, "ClassName") == className then
			return child
		end
	end
	return nil
end
function InstanceMethods:FindFirstChildWhichIsA(className)
	for _, child in rawget(self, "_children") do
		if isA(child, className) then
			return child
		end
	end
	return nil
end
function InstanceMethods:FindFirstAncestorOfClass(className)
	local node = rawget(self, "_parent")
	while node do
		if rawget(node, "ClassName") == className then
			return node
		end
		node = rawget(node, "_parent")
	end
	return nil
end
function InstanceMethods:IsDescendantOf(ancestor)
	local node = rawget(self, "_parent")
	while node do
		if node == ancestor then
			return true
		end
		node = rawget(node, "_parent")
	end
	return false
end
function InstanceMethods:GetFullName()
	local names = {}
	local node = self
	while node do
		table.insert(names, 1, rawget(node, "_props").Name)
		node = rawget(node, "_parent")
	end
	return table.concat(names, ".")
end
function InstanceMethods:SetAttribute(name, value)
	local attributes = rawget(self, "_attributes")
	local old = attributes[name]
	attributes[name] = value
	if old ~= value then
		local signal = rawget(self, "_attrSignals")[name]
		if signal then
			signal:Fire()
		end
	end
end
function InstanceMethods:GetAttribute(name)
	return rawget(self, "_attributes")[name]
end
function InstanceMethods:GetAttributes()
	return table.clone(rawget(self, "_attributes"))
end
function InstanceMethods:GetAttributeChangedSignal(name)
	local signals = rawget(self, "_attrSignals")
	signals[name] = signals[name] or newSignal()
	return signals[name]
end
function InstanceMethods:GetPropertyChangedSignal(name)
	local signals = rawget(self, "_propSignals")
	signals[name] = signals[name] or newSignal()
	return signals[name]
end
function InstanceMethods:Destroy()
	self.Parent = nil
	rawset(self, "_destroyed", true)
	for _, child in table.clone(rawget(self, "_children")) do
		child:Destroy()
	end
end
function InstanceMethods:ClearAllChildren()
	for _, child in table.clone(rawget(self, "_children")) do
		child:Destroy()
	end
end
function InstanceMethods:GetPivot()
	local props = rawget(self, "_props")
	if isA(self, "BasePart") then
		return props.CFrame * props.PivotOffset
	end
	local primary = props.PrimaryPart
	if primary then
		return primary.CFrame * primary.PivotOffset
	end
	return props.WorldPivot
end
function InstanceMethods:PivotTo(target)
	local current = self:GetPivot()
	local delta = target * current:Inverse()
	if isA(self, "BasePart") then
		self.CFrame = delta * self.CFrame
		return
	end
	for _, descendant in self:GetDescendants() do
		if isA(descendant, "BasePart") then
			descendant.CFrame = delta * descendant.CFrame
		end
	end
	if not rawget(self, "_props").PrimaryPart then
		rawget(self, "_props").WorldPivot = target
	end
end
function InstanceMethods:SetNetworkOwner(owner)
	rawset(self, "_networkOwner", owner)
end
function Mock.setRaw(instance, key, value)
	local props = rawget(instance, "_props")
	local old = props[key]
	props[key] = value
	if old ~= value then
		firePropertyChanged(instance, key)
	end
end

function InstanceMethods:Sit(humanoid)
	Mock.setRaw(self, "Occupant", humanoid)
	Mock.setRaw(humanoid, "SeatPart", self)
	local weld = newInstance("Weld")
	weld.Name = "SeatWeld"
	weld.Parent = self
end
function InstanceMethods:FireClient(player, ...)
	table.insert(Mock.remoteLog, { remote = rawget(self, "_props").Name, player = player, args = table.pack(...) })
end
function InstanceMethods:FireAllClients(...)
	table.insert(Mock.remoteLog, { remote = rawget(self, "_props").Name, player = "all", args = table.pack(...) })
end
Mock.remoteLog = {}
Mock.invokeHandlers = {}
function InstanceMethods:InvokeServer(...)
	local handler = Mock.invokeHandlers[rawget(self, "_props").Name]
	assert(handler, "no InvokeServer handler for " .. rawget(self, "_props").Name)
	return handler(...)
end
Mock.soundsPlayed = 0
function InstanceMethods:Play(_fadeTime, _weight, speed)
	if rawget(self, "ClassName") == "AnimationTrack" then
		Mock.setRaw(self, "IsPlaying", true)
		if speed then
			Mock.setRaw(self, "Speed", speed)
		end
		return
	end
	Mock.soundsPlayed += 1
end
function InstanceMethods:Stop()
	if rawget(self, "ClassName") == "AnimationTrack" then
		Mock.setRaw(self, "IsPlaying", false)
	end
end
function InstanceMethods:AdjustSpeed(speed)
	Mock.setRaw(self, "Speed", speed or 1)
end

-- Animator
Mock.animationTracks = {}
function InstanceMethods:LoadAnimation(animation)
	assert(animation and rawget(animation, "ClassName") == "Animation", "LoadAnimation needs an Animation")
	local track = Mock.newInstance("AnimationTrack")
	Mock.setRaw(track, "Animation", animation)
	Mock.setRaw(track, "IsPlaying", false)
	Mock.setRaw(track, "Speed", 1)
	Mock.setRaw(track, "Looped", false)
	Mock.setRaw(track, "Priority", Enum.AnimationPriority.Core)
	table.insert(Mock.animationTracks, track)
	return track
end

-- Humanoid states
function InstanceMethods:SetStateEnabled(state, enabled)
	local states = rawget(self, "_states")
	if not states then
		states = {}
		rawset(self, "_states", states)
	end
	states[state] = enabled
end
function InstanceMethods:GetStateEnabled(state)
	local states = rawget(self, "_states")
	if states and states[state] ~= nil then
		return states[state]
	end
	return true
end

Instance = {
	new = function(className, parent)
		local instance = newInstance(className)
		if parent then
			instance.Parent = parent
		end
		return instance
	end,
}
Mock.newInstance = newInstance

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------
local function service(className)
	local instance = newInstance(className)
	instance.Name = className
	return instance
end

local DataModel = service("DataModel")
DataModel.Name = "Game"
DataModel.PlaceId = 123456
local services = {}
for _, name in {
	"Workspace",
	"Players",
	"ReplicatedStorage",
	"ServerScriptService",
	"RunService",
	"TweenService",
	"DataStoreService",
	"Lighting",
	"StarterPlayer",
	"SoundService",
	"ProximityPromptService",
	"ContextActionService",
	"UserInputService",
} do
	local instance = service(name)
	instance.Parent = DataModel
	services[name] = instance
end
Mock.bindToClose = {}
function InstanceMethods:GetService(name)
	return services[name] or error("Mock has no service " .. tostring(name))
end
function InstanceMethods:BindToClose(fn)
	table.insert(Mock.bindToClose, fn)
end
game = DataModel
workspace = services.Workspace
workspace.Gravity = 196.2

-- Players
function InstanceMethods:GetPlayers()
	local result = {}
	for _, child in rawget(services.Players, "_children") do
		if rawget(child, "ClassName") == "Player" then
			table.insert(result, child)
		end
	end
	return result
end
function InstanceMethods:GetPlayerFromCharacter(character)
	for _, player in services.Players:GetPlayers() do
		if rawget(player, "_props").Character == character then
			return player
		end
	end
	return nil
end

-- UserInputService: a keyboard + mouse player
Mock.setRaw(services.UserInputService, "KeyboardEnabled", true)
Mock.setRaw(services.UserInputService, "MouseEnabled", true)
Mock.setRaw(services.UserInputService, "TouchEnabled", false)
Mock.setRaw(services.UserInputService, "GamepadEnabled", false)

-- ContextActionService
Mock.boundActions = {}
function InstanceMethods:BindActionAtPriority(name, fn, _createTouchButton, priority, ...)
	Mock.boundActions[name] = { fn = fn, priority = priority, inputs = { ... } }
end
function InstanceMethods:BindAction(name, fn, _createTouchButton, ...)
	Mock.boundActions[name] = { fn = fn, inputs = { ... } }
end
function InstanceMethods:UnbindAction(name)
	Mock.boundActions[name] = nil
end
-- Simulates pressing a key/button. Returns true if some bound action handled it.
function Mock.pressKey(keyCode)
	local handled = false
	for name, action in table.clone(Mock.boundActions) do
		if table.find(action.inputs, keyCode) then
			local input = { KeyCode = keyCode, UserInputState = Enum.UserInputState.Begin }
			action.fn(name, Enum.UserInputState.Begin, input)
			handled = true
		end
	end
	return handled
end

-- RunService
function InstanceMethods:IsStudio()
	return true
end
function InstanceMethods:IsServer()
	return true
end

-- TweenService: tweens finish instantly
function InstanceMethods:Create(instance, _info, goals)
	local tween = { Completed = newSignal() }
	function tween:Play()
		for key, value in goals do
			instance[key] = value
		end
		tween.Completed:Fire(Enum.PlaybackState.Completed)
	end
	function tween:Cancel() end
	return tween
end

-- DataStoreService
Mock.dataStores = {}
local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in value do
		copy[k] = deepCopy(v)
	end
	return copy
end
function InstanceMethods:GetDataStore(name)
	local data = Mock.dataStores[name] or {}
	Mock.dataStores[name] = data
	local store = {}
	function store:GetAsync(key)
		return deepCopy(data[key])
	end
	function store:SetAsync(key, value)
		data[key] = deepCopy(value)
	end
	function store:UpdateAsync(key, transform)
		data[key] = deepCopy(transform(deepCopy(data[key])))
	end
	return store
end

-- Workspace queries: the ground is the "Grass" part at y = 0 everywhere.
function InstanceMethods:Raycast(origin, direction)
	local map = InstanceMethods.FindFirstChild(services.Workspace, "Map")
	local ground = map and InstanceMethods.FindFirstChild(map, "Ground")
	local grass = ground and InstanceMethods.FindFirstChild(ground, "Grass")
	if grass and direction.Y < 0 and origin.Y >= 0 and origin.Y + direction.Y <= 0 then
		return { Instance = grass, Position = vec(origin.X, 0, origin.Z), Normal = vec(0, 1, 0) }
	end
	return nil
end
function InstanceMethods:GetPartBoundsInBox()
	return {}
end
function InstanceMethods:GetServerTimeNow()
	return 1700000000 + now
end

--------------------------------------------------------------------------------
-- Time control
--------------------------------------------------------------------------------
local function physicsStep(dt)
	-- LinearVelocity drives its part at VectorVelocity; AlignOrientation snaps rotation to its goal.
	for mover in Mock.movers do
		local props = rawget(mover, "_props")
		local attachment = props.Attachment0
		local part = attachment and attachment.Parent
		if part and mover.Parent and not rawget(part, "_destroyed") and not part.Anchored then
			if rawget(mover, "ClassName") == "LinearVelocity" then
				local velocity = props.VectorVelocity or Vector3.zero
				rawget(part, "_props").AssemblyLinearVelocity = velocity
				local cf = part.CFrame
				rawget(part, "_props").CFrame = cf + velocity * dt
			elseif props.CFrame then
				rawget(part, "_props").CFrame = CFrame.new(part.Position) * props.CFrame.Rotation
			end
		end
	end
	for align in Mock.alignPositions do
		local attachment = rawget(align, "_props").Attachment0
		local part = attachment and attachment.Parent
		if part and align.Parent and not rawget(part, "_destroyed") then
			local target = align.Position
			local offset = target - part.Position
			local distance = offset.Magnitude
			local stepDistance = math.min(distance, align.MaxVelocity * dt)
			if distance > 1e-6 then
				part.CFrame = part.CFrame + offset.Unit * stepDistance
			end
		end
	end
end

function Mock.now()
	return now
end

-- Advances virtual time, firing Heartbeat and resuming due tasks.
function Mock.advance(seconds, step)
	step = step or (1 / 30)
	local target = now + seconds
	runDueTasks()
	while now < target - 1e-9 do
		local dt = math.min(step, target - now)
		now += dt
		physicsStep(dt)
		services.RunService.RenderStepped:Fire(dt)
		services.RunService.Heartbeat:Fire(dt)
		runDueTasks()
	end
end

function Mock.service(name)
	return services[name]
end

return Mock
