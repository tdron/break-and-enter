--!strict
--[[
	Houses
	------
	The heist part of the game:
	  * Locked doors you open with a "Pick Lock" prompt (harder houses take longer).
	  * Loot spawns on furniture, rolled from the house tier's item pool.
	  * Stealing anything trips the alarm: after a short wind-up, security drones
	    chase the nearest thief on the property. Get caught = BUSTED (you drop
	    everything you're carrying and get sent back to your warehouse).
	  * Leave the property (the fenced lot) and the drones give up.
	  * Villas and the Mansion also have blinking laser tripwires.

	Map layout expected (built by tools/build_place.py):
	  Workspace.Map.Houses.<House>   (Model, attributes Tier & DisplayName)
	    Zone        Part covering the whole property (invisible)
	    ItemSpots   Folder of Parts marking where loot appears
	    DroneDocks  Folder of Parts where drones rest
	    Doors       Folder of Models: a "Hinge" part + door parts (attribute OpenAngle)
	    Lasers      Folder of Parts (attribute Phase)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local ItemModels = require(ReplicatedStorage.Shared.ItemModels)
local Items = require(ReplicatedStorage.Shared.Items)
local Inventory = require(script.Parent.Inventory)
local Notify = require(script.Parent.Notify)
local PlayerData = require(script.Parent.PlayerData)
local Plots = require(script.Parent.Plots)

local BustedEvent = ReplicatedStorage.Remotes.Busted

type Spot = {
	Part: BasePart,
	Item: Model?,
	ItemId: string?,
	RespawnAt: number,
}

type Drone = {
	Model: Model,
	Body: BasePart,
	Eye: BasePart,
	Light: PointLight,
	AlignPosition: AlignPosition,
	AlignOrientation: AlignOrientation,
	Home: CFrame,
	State: string, -- "Idle" | "Windup" | "Chase"
	ActivateAt: number,
}

type DoorPiece = { Part: BasePart, Offset: CFrame }

type Door = {
	Model: Model,
	Prompt: ProximityPrompt,
	Angle: NumberValue,
	OpenAngle: number,
	IsOpen: boolean,
	CloseAt: number,
}

type House = {
	Model: Model,
	Name: string,
	Tier: number,
	Settings: Config.HouseTier,
	ZoneCFrame: CFrame,
	ZoneHalfSize: Vector3,
	Loot: Folder,
	Spots: { Spot },
	Drones: { Drone },
	Doors: { Door },
	Lasers: { BasePart },
	AlarmActive: boolean,
	LastOccupiedAt: number,
	Intruders: { [Player]: boolean },
}

type Thief = { Player: Player, Root: BasePart, Humanoid: Humanoid }

local EYE_IDLE = Color3.fromRGB(70, 200, 255)
local EYE_ALERT = Color3.fromRGB(255, 40, 40)

local Houses = {}

local houses: { House } = {}
local rng = Random.new()
local bustedUntil: { [Player]: number } = {}
local laserCooldown: { [Player]: number } = {}

local function playerFromHit(hit: BasePart): Player?
	local model = hit:FindFirstAncestorOfClass("Model")
	if not model then
		return nil
	end
	return Players:GetPlayerFromCharacter(model)
end

local function isInZone(house: House, position: Vector3): boolean
	local relative = house.ZoneCFrame:PointToObjectSpace(position)
	local half = house.ZoneHalfSize
	return math.abs(relative.X) <= half.X and math.abs(relative.Y) <= half.Y and math.abs(relative.Z) <= half.Z
end

local function clampToZone(house: House, position: Vector3): Vector3
	local relative = house.ZoneCFrame:PointToObjectSpace(position)
	local half = house.ZoneHalfSize
	local clamped = Vector3.new(
		math.clamp(relative.X, -half.X, half.X),
		math.clamp(relative.Y, -half.Y, half.Y),
		math.clamp(relative.Z, -half.Z, half.Z)
	)
	return house.ZoneCFrame:PointToWorldSpace(clamped)
end

local function isImmune(player: Player, now: number): boolean
	return (bustedUntil[player] or 0) > now
end

-- Is this position on any house's property? (Used to stop cars spawning inside.)
function Houses.isOnProperty(position: Vector3): boolean
	for _, house in houses do
		if isInZone(house, position) then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Alarm
--------------------------------------------------------------------------------
local function triggerAlarm(house: House, culprit: Player?)
	local now = os.clock()
	house.LastOccupiedAt = now
	if house.AlarmActive then
		return
	end
	house.AlarmActive = true
	house.Model:SetAttribute("AlarmActive", true)
	for _, drone in house.Drones do
		drone.State = "Windup"
		drone.ActivateAt = now + house.Settings.AlarmWindup
		drone.Eye.Color = EYE_ALERT
		drone.Light.Enabled = true
		-- Rise up a little during the wind-up so players can see them coming.
		drone.AlignPosition.Position = drone.Home.Position + Vector3.new(0, 1.5, 0)
	end
	if culprit then
		Notify.send(culprit, "🚨 ALARM! Security drones are waking up — get off the property!", "warning")
	end
end

local function clearIntruder(player: Player, house: House)
	house.Intruders[player] = nil
	if player.Parent and player:GetAttribute("AlarmHouse") == house.Name then
		player:SetAttribute("AlarmHouse", "")
	end
end

local function endAlarm(house: House)
	house.AlarmActive = false
	house.Model:SetAttribute("AlarmActive", false)
	for player in house.Intruders do
		clearIntruder(player, house)
	end
	for _, drone in house.Drones do
		drone.State = "Idle"
		drone.AlignPosition.Position = drone.Home.Position
		drone.AlignPosition.MaxVelocity = Config.Alarm.DroneReturnSpeed
		drone.AlignOrientation.CFrame = drone.Home.Rotation
		drone.Eye.Color = EYE_IDLE
		drone.Light.Enabled = false
	end
end

local function bust(player: Player, house: House)
	local now = os.clock()
	if isImmune(player, now) then
		return
	end
	bustedUntil[player] = now + Config.Alarm.BustImmunity
	clearIntruder(player, house)

	local lost = Inventory.takeCarried(player)
	local lostValue = 0
	for _, itemId in lost do
		lostValue += Items.getValue(itemId)
	end
	BustedEvent:FireClient(player, #lost, lostValue, house.Name)

	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid and humanoid.SeatPart then
		local seatWeld = humanoid.SeatPart:FindFirstChild("SeatWeld")
		if seatWeld then
			seatWeld:Destroy()
		end
		humanoid.Sit = false
	end
	local target = Plots.getSpawnCFrame(player)
	if character and target then
		task.delay(0.2, function()
			if character.Parent then
				character:PivotTo(target)
			end
		end)
	end
end

local function updateAlarm(house: House, thieves: { Thief }, now: number)
	local intruders: { Thief } = {}
	for _, thief in thieves do
		if isInZone(house, thief.Root.Position) and not isImmune(thief.Player, now) then
			table.insert(intruders, thief)
		end
	end

	-- Keep the "you're being chased" banner in sync.
	local present: { [Player]: boolean } = {}
	for _, thief in intruders do
		present[thief.Player] = true
		if not house.Intruders[thief.Player] then
			house.Intruders[thief.Player] = true
			thief.Player:SetAttribute("AlarmHouse", house.Name)
		end
	end
	for player in house.Intruders do
		if not present[player] then
			clearIntruder(player, house)
			if player.Parent and Inventory.getCarriedCount(player) > 0 and not isImmune(player, now) then
				Notify.send(player, "😎 You escaped with the loot! Now stash it in your warehouse.", "success")
			end
		end
	end

	if #intruders > 0 then
		house.LastOccupiedAt = now
	elseif now - house.LastOccupiedAt >= Config.Alarm.CalmDownTime then
		endAlarm(house)
		return
	end

	for _, drone in house.Drones do
		if drone.State == "Windup" and now >= drone.ActivateAt then
			drone.State = "Chase"
		end
		if drone.State == "Chase" then
			local target: Thief? = nil
			local bestDistance = math.huge
			for _, thief in intruders do
				local distance = (thief.Root.Position - drone.Body.Position).Magnitude
				if distance < bestDistance then
					target, bestDistance = thief, distance
				end
			end
			if target then
				local aim = target.Root.Position + Vector3.new(0, Config.Alarm.DroneAimHeight, 0)
				drone.AlignPosition.Position = clampToZone(house, aim)
				drone.AlignPosition.MaxVelocity = house.Settings.DroneSpeed
				local from = drone.Body.Position
				local flat = Vector3.new(aim.X - from.X, 0, aim.Z - from.Z)
				if flat.Magnitude > 0.1 then
					drone.AlignOrientation.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
				end
				if bestDistance <= Config.Alarm.CatchRadius then
					bust(target.Player, house)
				end
			end
		end
	end
end

local function onHeartbeat()
	local now = os.clock()
	local thieves: { Thief } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart")
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
				table.insert(thieves, { Player = player, Root = root, Humanoid = humanoid })
			end
		end
	end
	for _, house in houses do
		if house.AlarmActive then
			updateAlarm(house, thieves, now)
		end
	end
end

--------------------------------------------------------------------------------
-- Loot
--------------------------------------------------------------------------------
local function makeItemLabel(def: Items.ItemDef, root: BasePart)
	local rarity = Items.Rarities[def.Rarity]
	local gui = Instance.new("BillboardGui")
	gui.Name = "ItemLabel"
	gui.Size = UDim2.fromOffset(180, 50)
	gui.StudsOffsetWorldSpace = Vector3.new(0, root.Size.Y / 2 + 1.2, 0)
	gui.MaxDistance = 28
	gui.LightInfluence = 0
	gui.Parent = root

	local name = Instance.new("TextLabel")
	name.Name = "ItemName"
	name.BackgroundTransparency = 1
	name.Size = UDim2.fromScale(1, 0.55)
	name.Font = Enum.Font.FredokaOne
	name.Text = def.DisplayName
	name.TextScaled = true
	name.TextColor3 = rarity.Color
	name.TextStrokeTransparency = 0.25
	name.Parent = gui

	local value = Instance.new("TextLabel")
	value.Name = "ItemValue"
	value.BackgroundTransparency = 1
	value.Position = UDim2.fromScale(0, 0.55)
	value.Size = UDim2.fromScale(1, 0.45)
	value.Font = Enum.Font.BuilderSansBold
	value.Text = string.format("%s • %s", Format.money(def.Value), def.Rarity)
	value.TextScaled = true
	value.TextColor3 = Color3.fromRGB(130, 255, 150)
	value.TextStrokeTransparency = 0.3
	value.Parent = gui
end

local onSteal: (house: House, spot: Spot, model: Model, player: Player) -> ()

local function spawnItem(house: House, spot: Spot)
	local itemId = Items.roll(house.Tier, rng)
	local def = Items.get(itemId)
	local model = ItemModels.build(itemId)
	if not def or not model then
		return
	end
	model:PivotTo(spot.Part.CFrame)
	local root = model.PrimaryPart
	if root then
		makeItemLabel(def, root)
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "StealPrompt"
		prompt.ActionText = "Steal"
		prompt.ObjectText = string.format("%s (%s)", def.DisplayName, Format.money(def.Value))
		prompt.HoldDuration = Config.Stealing.HoldDuration
		prompt.MaxActivationDistance = Config.Stealing.PromptDistance
		prompt.RequiresLineOfSight = false
		prompt.Parent = root
		prompt.Triggered:Connect(function(player: Player)
			onSteal(house, spot, model, player)
		end)
	end
	model.Parent = house.Loot
	spot.Item = model
	spot.ItemId = itemId
end

onSteal = function(house: House, spot: Spot, model: Model, player: Player)
	local itemId = spot.ItemId
	if spot.Item ~= model or not itemId or not model.Parent then
		return
	end
	if isImmune(player, os.clock()) then
		return
	end
	local ok, reason = Inventory.addCarried(player, itemId)
	if not ok then
		Notify.send(player, reason or "You can't carry that right now.", "error")
		return
	end
	spot.Item = nil
	spot.ItemId = nil
	spot.RespawnAt = os.clock() + house.Settings.RestockTime
	model:Destroy()
	PlayerData.addStolen(player, 1)

	local def = Items.get(itemId)
	if def then
		Notify.send(
			player,
			string.format(
				"🦝 Stole %s (%s)! Bag: %d/%d",
				def.DisplayName,
				Format.money(def.Value),
				Inventory.getCarriedCount(player),
				PlayerData.getUpgradeValue(player, "Bag")
			),
			"steal"
		)
	end
	triggerAlarm(house, player)
end

--------------------------------------------------------------------------------
-- Drones
--------------------------------------------------------------------------------
local function buildDrone(house: House, dock: BasePart): Drone
	local home = CFrame.new(dock.Position + Vector3.new(0, Config.Alarm.DroneDockHeight, 0)) * dock.CFrame.Rotation
	local model = Instance.new("Model")
	model.Name = "SecurityDrone"

	local function piece(name: string, shape: Enum.PartType, size: Vector3, offset: CFrame, color: Color3, material: Enum.Material): Part
		local part = Instance.new("Part")
		part.Name = name
		part.Shape = shape
		part.Size = size
		part.CFrame = home * offset
		part.Color = color
		part.Material = material
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Massless = true
		part.Parent = model
		return part
	end

	local body = piece("Body", Enum.PartType.Ball, Vector3.new(2.2, 2.2, 2.2), CFrame.new(), Color3.fromRGB(46, 48, 56), Enum.Material.Metal)
	body.Massless = false
	local eye = piece("Eye", Enum.PartType.Ball, Vector3.new(0.95, 0.95, 0.95), CFrame.new(0, 0, -0.75), EYE_IDLE, Enum.Material.Neon)
	piece(
		"Ring",
		Enum.PartType.Cylinder,
		Vector3.new(0.25, 3.7, 3.7),
		CFrame.new(0, 0.35, 0) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(28, 28, 32),
		Enum.Material.Metal
	)
	for _, offset in { Vector3.new(1.3, 0.75, 1.3), Vector3.new(-1.3, 0.75, 1.3), Vector3.new(1.3, 0.75, -1.3), Vector3.new(-1.3, 0.75, -1.3) } do
		piece(
			"Rotor",
			Enum.PartType.Cylinder,
			Vector3.new(0.12, 1.4, 1.4),
			CFrame.new(offset) * CFrame.Angles(0, 0, math.rad(90)),
			Color3.fromRGB(205, 205, 215),
			Enum.Material.SmoothPlastic
		)
	end
	piece("Antenna", Enum.PartType.Block, Vector3.new(0.12, 0.9, 0.12), CFrame.new(0, 1.35, 0.35), Color3.fromRGB(28, 28, 32), Enum.Material.Metal)

	local light = Instance.new("PointLight")
	light.Color = EYE_ALERT
	light.Range = 14
	light.Brightness = 3
	light.Enabled = false
	light.Parent = eye

	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part ~= body then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = body
			weld.Part1 = part
			weld.Parent = part
		end
	end

	local attachment = Instance.new("Attachment")
	attachment.Name = "DroneAttachment"
	attachment.Parent = body

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.Position = home.Position
	alignPosition.MaxForce = 1000000
	alignPosition.MaxVelocity = Config.Alarm.DroneReturnSpeed
	alignPosition.Responsiveness = 80
	alignPosition.Parent = body

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.CFrame = home.Rotation
	alignOrientation.MaxTorque = 1000000
	alignOrientation.Responsiveness = 40
	alignOrientation.Parent = body

	model.PrimaryPart = body
	model.Parent = house.Model
	pcall(function()
		body:SetNetworkOwner(nil)
	end)

	return {
		Model = model,
		Body = body,
		Eye = eye,
		Light = light,
		AlignPosition = alignPosition,
		AlignOrientation = alignOrientation,
		Home = home,
		State = "Idle",
		ActivateAt = 0,
	}
end

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------
local function setDoorOpen(door: Door, open: boolean)
	door.IsOpen = open
	if open then
		door.Prompt.Enabled = false
		door.CloseAt = os.clock() + Config.Doors.StayOpenTime
		TweenService:Create(door.Angle, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Value = door.OpenAngle,
		}):Play()
	else
		TweenService:Create(door.Angle, TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
			Value = 0,
		}):Play()
		task.delay(0.9, function()
			if not door.IsOpen then
				door.Prompt.Enabled = true
			end
		end)
	end
end

local function setupDoor(house: House, doorModel: Model): Door?
	local hinge = doorModel:FindFirstChild("Hinge")
	if not (hinge and hinge:IsA("BasePart")) then
		warn("[Houses] Door " .. doorModel:GetFullName() .. " has no Hinge part")
		return nil
	end
	local hingeCFrame = hinge.CFrame
	local pieces: { DoorPiece } = {}
	local panel: BasePart? = nil
	for _, descendant in doorModel:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= hinge then
			table.insert(pieces, { Part = descendant, Offset = hingeCFrame:ToObjectSpace(descendant.CFrame) })
			if panel == nil or descendant.Size.Magnitude > panel.Size.Magnitude then
				panel = descendant
			end
		end
	end
	if not panel then
		return nil
	end

	local angle = Instance.new("NumberValue")
	angle.Name = "OpenAngle"
	angle.Value = 0
	angle.Parent = doorModel
	angle:GetPropertyChangedSignal("Value"):Connect(function()
		local base = hingeCFrame * CFrame.Angles(0, math.rad(angle.Value), 0)
		for _, doorPiece in pieces do
			doorPiece.Part.CFrame = base * doorPiece.Offset
		end
	end)

	local openAngle = doorModel:GetAttribute("OpenAngle")
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LockpickPrompt"
	prompt.ActionText = "Pick Lock"
	prompt.ObjectText = house.Name
	prompt.HoldDuration = house.Settings.LockpickTime
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = panel

	local door: Door = {
		Model = doorModel,
		Prompt = prompt,
		Angle = angle,
		OpenAngle = if type(openAngle) == "number" then openAngle else -95,
		IsOpen = false,
		CloseAt = 0,
	}
	prompt.Triggered:Connect(function(player: Player)
		if door.IsOpen then
			return
		end
		setDoorOpen(door, true)
		Notify.send(player, "🔓 Lock picked! Grab the loot... the alarm trips when you steal.", "info")
	end)
	return door
end

local function anyoneOnProperty(house: House): boolean
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if root and root:IsA("BasePart") and isInZone(house, root.Position) then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Lasers
--------------------------------------------------------------------------------
local function setupLaser(house: House, laser: BasePart)
	laser.CanCollide = false
	laser.CanQuery = false
	laser.Touched:Connect(function(hit: BasePart)
		if laser.Transparency >= 1 then
			return
		end
		local player = playerFromHit(hit)
		if not player then
			return
		end
		local now = os.clock()
		if (laserCooldown[player] or 0) > now or isImmune(player, now) then
			return
		end
		laserCooldown[player] = now + 2
		if not house.AlarmActive then
			Notify.send(player, "🔴 You tripped a laser! The drones are awake!", "warning")
			triggerAlarm(house, nil)
		end
	end)
	table.insert(house.Lasers, laser)
end

local function updateLasers()
	local cycle = Config.Lasers.OnTime + Config.Lasers.OffTime
	local now = os.clock()
	for _, house in houses do
		for _, laser in house.Lasers do
			local phase = laser:GetAttribute("Phase")
			local offset = if type(phase) == "number" then phase else 0
			local on = (now + offset) % cycle < Config.Lasers.OnTime
			local transparency = if on then 0.2 else 1
			if laser.Transparency ~= transparency then
				laser.Transparency = transparency
				laser.CanTouch = on
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Setup & loops
--------------------------------------------------------------------------------
local function setupHouse(model: Model)
	local zone = model:FindFirstChild("Zone")
	if not (zone and zone:IsA("BasePart")) then
		warn("[Houses] " .. model:GetFullName() .. " has no Zone part, skipping")
		return
	end
	local tierAttribute = model:GetAttribute("Tier")
	local tier = math.clamp(if type(tierAttribute) == "number" then tierAttribute else 1, 1, #Config.HouseTiers)
	local displayName = model:GetAttribute("DisplayName")

	local loot = Instance.new("Folder")
	loot.Name = "Loot"
	loot.Parent = model

	local house: House = {
		Model = model,
		Name = if type(displayName) == "string" then displayName else model.Name,
		Tier = tier,
		Settings = Config.HouseTiers[tier],
		ZoneCFrame = zone.CFrame,
		ZoneHalfSize = zone.Size / 2,
		Loot = loot,
		Spots = {},
		Drones = {},
		Doors = {},
		Lasers = {},
		AlarmActive = false,
		LastOccupiedAt = 0,
		Intruders = {},
	}
	model:SetAttribute("AlarmActive", false)

	local spots = model:FindFirstChild("ItemSpots")
	if spots then
		for _, part in spots:GetChildren() do
			if part:IsA("BasePart") then
				local spot: Spot = { Part = part, Item = nil, ItemId = nil, RespawnAt = 0 }
				table.insert(house.Spots, spot)
				spawnItem(house, spot)
			end
		end
	end

	local docks = model:FindFirstChild("DroneDocks")
	if docks then
		for _, dock in docks:GetChildren() do
			if dock:IsA("BasePart") then
				table.insert(house.Drones, buildDrone(house, dock))
			end
		end
	end

	local doors = model:FindFirstChild("Doors")
	if doors then
		for _, doorModel in doors:GetChildren() do
			if doorModel:IsA("Model") then
				local door = setupDoor(house, doorModel)
				if door then
					table.insert(house.Doors, door)
				end
			end
		end
	end

	local lasers = model:FindFirstChild("Lasers")
	if lasers then
		for _, laser in lasers:GetChildren() do
			if laser:IsA("BasePart") then
				setupLaser(house, laser)
			end
		end
	end

	table.insert(houses, house)
end

local function maintenanceLoop()
	while true do
		task.wait(1)
		local now = os.clock()
		for _, house in houses do
			for _, spot in house.Spots do
				if spot.Item == nil and now >= spot.RespawnAt then
					spawnItem(house, spot)
				end
			end
			for _, door in house.Doors do
				if door.IsOpen and now >= door.CloseAt then
					if anyoneOnProperty(house) then
						door.CloseAt = now + 5 -- never slam a door on someone
					else
						setDoorOpen(door, false)
					end
				end
			end
		end
	end
end

function Houses.onPlayerRemoving(player: Player)
	bustedUntil[player] = nil
	laserCooldown[player] = nil
	for _, house in houses do
		house.Intruders[player] = nil
	end
end

function Houses.init()
	local map = Workspace:WaitForChild("Map")
	local folder = map:WaitForChild("Houses")
	for _, model in folder:GetChildren() do
		if model:IsA("Model") then
			setupHouse(model)
		end
	end
	RunService.Heartbeat:Connect(onHeartbeat)
	RunService.Heartbeat:Connect(updateLasers)
	task.spawn(maintenanceLoop)
end

return Houses
