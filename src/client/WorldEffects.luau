--!strict
--[[
	WorldEffects
	------------
	Purely visual/audio touches that only the local player needs:
	  * Flashing sirens + beeping on houses whose alarm is going off
	  * Moving stripes on the warehouse treadmills while someone runs on them
	  * A "YOUR WAREHOUSE" marker so you can always find your way home
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local WorldEffects = {}

local player = Players.LocalPlayer

type SirenHouse = {
	Model: Model,
	Sirens: { BasePart },
	Lights: { PointLight },
	BaseColors: { Color3 },
	Beeper: Sound?,
}

type Belt = {
	Model: Model,
	Part: BasePart,
	Stripes: { BasePart },
	Offset: number,
}

local SIREN_RED = Color3.fromRGB(255, 30, 30)
local SIREN_OFF = Color3.fromRGB(90, 10, 10)
local STRIPES_PER_BELT = 7

local function getMap(): Instance
	return Workspace:WaitForChild("Map")
end

--------------------------------------------------------------------------------
-- Sirens
--------------------------------------------------------------------------------
local function setupSirens(map: Instance)
	local houses: { SirenHouse } = {}
	local folder = map:WaitForChild("Houses")
	for _, model in folder:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local sirenFolder = model:WaitForChild("Sirens", 10)
		if not sirenFolder then
			continue
		end
		local entry: SirenHouse = { Model = model, Sirens = {}, Lights = {}, BaseColors = {}, Beeper = nil }
		for _, siren in sirenFolder:GetChildren() do
			if siren:IsA("BasePart") then
				local light = Instance.new("PointLight")
				light.Color = SIREN_RED
				light.Range = 18
				light.Brightness = 4
				light.Enabled = false
				light.Parent = siren
				table.insert(entry.Sirens, siren)
				table.insert(entry.Lights, light)
				table.insert(entry.BaseColors, siren.Color)
				if not entry.Beeper then
					local beeper = Instance.new("Sound")
					beeper.Name = "AlarmBeeper"
					beeper.SoundId = Config.Sounds.AlarmBeep
					beeper.Volume = 1
					beeper.RollOffMode = Enum.RollOffMode.InverseTapered
					beeper.RollOffMinDistance = 20
					beeper.RollOffMaxDistance = 180
					beeper.Parent = siren
					entry.Beeper = beeper
				end
			end
		end
		table.insert(houses, entry)
	end

	task.spawn(function()
		local flip = false
		while true do
			flip = not flip
			for _, house in houses do
				local active = house.Model:GetAttribute("AlarmActive") == true
				for index, siren in house.Sirens do
					if active then
						siren.Color = if flip then SIREN_RED else SIREN_OFF
						house.Lights[index].Enabled = flip
					elseif house.Lights[index].Enabled or siren.Color ~= house.BaseColors[index] then
						siren.Color = house.BaseColors[index]
						house.Lights[index].Enabled = false
					end
				end
				local beeper = house.Beeper
				if active and beeper then
					-- Alternate the pitch for a "wee-woo" siren.
					beeper.PlaybackSpeed = if flip then 1.6 else 1.15
					beeper:Play()
				end
			end
			task.wait(0.25)
		end
	end)
end

--------------------------------------------------------------------------------
-- Treadmills: the belt scrolls while its owner is running on it (the server sets
-- the Running and Level attributes on each warehouse's Treadmill model).
--------------------------------------------------------------------------------
local function addBelt(belts: { Belt }, treadmill: Model)
	local beltPart = treadmill:WaitForChild("Belt", 10)
	if not (beltPart and beltPart:IsA("BasePart")) then
		return
	end
	local belt: Belt = { Model = treadmill, Part = beltPart, Stripes = {}, Offset = 0 }
	for _ = 1, STRIPES_PER_BELT do
		local stripe = Instance.new("Part")
		stripe.Name = "BeltStripe"
		stripe.Anchored = true
		stripe.CanCollide = false
		stripe.CanQuery = false
		stripe.CanTouch = false
		stripe.CastShadow = false
		stripe.Size = Vector3.new(beltPart.Size.X - 0.1, 0.02, 0.3)
		stripe.Color = Color3.fromRGB(70, 70, 78)
		stripe.Material = Enum.Material.SmoothPlastic
		stripe.Parent = beltPart
		table.insert(belt.Stripes, stripe)
	end
	table.insert(belts, belt)
end

local function setupTreadmills(map: Instance)
	local folder = map:WaitForChild("Warehouses")
	local belts: { Belt } = {}
	for _, plot in folder:GetChildren() do
		local treadmill = plot:FindFirstChild("Treadmill")
		if treadmill and treadmill:IsA("Model") then
			addBelt(belts, treadmill)
		end
	end

	local settings = Config.Treadmill
	RunService.RenderStepped:Connect(function(dt: number)
		for _, belt in belts do
			local part = belt.Part
			local length = part.Size.Z
			local spacing = length / STRIPES_PER_BELT
			if belt.Model:GetAttribute("Running") == true then
				local level = belt.Model:GetAttribute("Level")
				local speed = settings.BeltSpeedBase
					+ (if type(level) == "number" then level - 1 else 0) * settings.BeltSpeedPerLevel
				-- The belt runs from the console towards the back, under the runner's feet.
				belt.Offset = (belt.Offset + speed * dt) % spacing
			end
			for index, stripe in belt.Stripes do
				local z = -length / 2 + ((index - 1) * spacing + belt.Offset) % length
				stripe.CFrame = part.CFrame * CFrame.new(0, part.Size.Y / 2 + 0.012, z)
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Warehouse marker
--------------------------------------------------------------------------------
local function setupWarehouseMarker(map: Instance)
	local folder = map:WaitForChild("Warehouses")
	local billboard: BillboardGui? = nil
	local distanceLabel: TextLabel? = nil
	local target: BasePart? = nil

	local function attach()
		if billboard then
			billboard:Destroy()
			billboard = nil
		end
		local index = player:GetAttribute("PlotIndex")
		if type(index) ~= "number" then
			return
		end
		local plot = folder:FindFirstChild("Plot" .. index)
		local marker = if plot then plot:FindFirstChild("Marker") else nil
		if not (marker and marker:IsA("BasePart")) then
			return
		end
		target = marker
		local gui = Instance.new("BillboardGui")
		gui.Name = "HomeMarker"
		gui.Size = UDim2.fromOffset(200, 64)
		gui.AlwaysOnTop = true
		gui.LightInfluence = 0
		gui.MaxDistance = 100000
		gui.Adornee = marker
		gui.Parent = marker
		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Size = UDim2.fromScale(1, 0.6)
		title.Font = Enum.Font.FredokaOne
		title.Text = "🏠 YOUR WAREHOUSE"
		title.TextScaled = true
		title.TextColor3 = Color3.fromRGB(120, 255, 150)
		title.TextStrokeTransparency = 0.2
		title.Parent = gui
		local distance = Instance.new("TextLabel")
		distance.BackgroundTransparency = 1
		distance.Position = UDim2.fromScale(0, 0.6)
		distance.Size = UDim2.fromScale(1, 0.4)
		distance.Font = Enum.Font.BuilderSansBold
		distance.TextScaled = true
		distance.TextColor3 = Color3.new(1, 1, 1)
		distance.TextStrokeTransparency = 0.3
		distance.Parent = gui
		billboard = gui
		distanceLabel = distance
	end

	player:GetAttributeChangedSignal("PlotIndex"):Connect(attach)
	attach()

	task.spawn(function()
		while true do
			task.wait(0.3)
			local gui, label, marker = billboard, distanceLabel, target
			local character = player.Character
			local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
			if gui and label and marker and root and root:IsA("BasePart") then
				local studs = (root.Position - marker.Position).Magnitude
				gui.Enabled = studs > 45
				label.Text = string.format("%d studs", math.floor(studs))
			end
		end
	end)
end

function WorldEffects.init()
	local map = getMap()
	task.spawn(setupSirens, map)
	task.spawn(setupTreadmills, map)
	task.spawn(setupWarehouseMarker, map)
end

return WorldEffects
