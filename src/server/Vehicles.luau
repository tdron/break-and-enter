--!strict
--[[
	Vehicles
	--------
	Each player has a getaway car, built out of parts at runtime so it can
	change with upgrades (Engine level = top speed, paint job and extras).

	The car is an arcade-style hover car: the server creates a LinearVelocity
	and an AlignOrientation on the chassis, and the driver's client steers it
	(see client/VehicleController). The driver gets network ownership so
	driving feels instant.

	  * "Get In" prompt: the owner drives, anyone else rides as a passenger.
	  * "Load Trunk" prompt (owner only): moves carried loot into the trunk.
	  * Park in your warehouse's yellow LOADING DOCK to unload the trunk automatically.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Houses = require(script.Parent.Houses)
local Inventory = require(script.Parent.Inventory)
local Notify = require(script.Parent.Notify)
local PlayerData = require(script.Parent.PlayerData)
local Plots = require(script.Parent.Plots)

type CarRecord = {
	Owner: Player,
	Model: Model,
	Chassis: Part,
	DriverSeat: VehicleSeat,
	PassengerSeat: Seat,
	Drive: LinearVelocity,
	Orient: AlignOrientation,
	DrivePrompt: ProximityPrompt,
	TrunkPrompt: ProximityPrompt,
	Label: TextLabel,
}

local CHASSIS_SIZE = Vector3.new(6, 1.6, 11.5)
local DARK = Color3.fromRGB(34, 34, 40)
local GLASS = Color3.fromRGB(70, 95, 120)

local Vehicles = {}

local cars: { [Player]: CarRecord } = {}
local lastSpawn: { [Player]: number } = {}
local attributeConnections: { [Player]: { RBXScriptConnection } } = {}
local carsFolder: Folder

local function flatRotation(cf: CFrame): CFrame
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(Vector3.zero, flat.Unit)
end

type PartOptions = {
	Shape: Enum.PartType?,
	Transparency: number?,
	CanCollide: boolean?,
	Reflectance: number?,
}

local function addPart(
	model: Model,
	chassisCFrame: CFrame,
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	material: Enum.Material,
	options: PartOptions?
): Part
	local part = Instance.new("Part")
	part.Name = name
	if options and options.Shape then
		part.Shape = options.Shape
	end
	part.Size = size
	part.CFrame = chassisCFrame * offset
	part.Color = color
	part.Material = material
	part.Transparency = if options and options.Transparency then options.Transparency else 0
	part.Reflectance = if options and options.Reflectance then options.Reflectance else 0
	part.CanCollide = if options and options.CanCollide then true else false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

local function trunkText(player: Player): string
	return string.format(
		"%d/%d",
		(player:GetAttribute("TrunkCount") :: number?) or 0,
		PlayerData.getUpgradeValue(player, "Trunk")
	)
end

local function updateLabel(player: Player)
	local record = cars[player]
	if not record then
		return
	end
	record.Label.Text = string.format("🚗 %s's Car\n🧳 Trunk %s", player.DisplayName, trunkText(player))
	record.TrunkPrompt.ObjectText = "Trunk " .. trunkText(player)
end

local function buildCar(player: Player, cf: CFrame): CarRecord
	local engineLevel = PlayerData.getUpgradeLevel(player, "Engine")
	local paints = Config.Vehicle.Paints
	local paint = paints[math.clamp(engineLevel, 1, #paints)]

	local model = Instance.new("Model")
	model.Name = player.Name .. "_Car"
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("MaxSpeed", PlayerData.getUpgradeValue(player, "Engine"))

	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.Size = CHASSIS_SIZE
	chassis.CFrame = cf
	chassis.Color = paint
	chassis.Material = Enum.Material.SmoothPlastic
	chassis.Reflectance = 0.08
	chassis.TopSurface = Enum.SurfaceType.Smooth
	chassis.BottomSurface = Enum.SurfaceType.Smooth
	chassis.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0.1)
	chassis.Parent = model
	model.PrimaryPart = chassis

	-- Body
	addPart(model, cf, "Cabin", Vector3.new(5.2, 2.6, 5.6), CFrame.new(0, 2.1, 0.8), GLASS, Enum.Material.Glass, {
		Transparency = 0.35,
	})
	addPart(model, cf, "Roof", Vector3.new(5.6, 0.3, 6.0), CFrame.new(0, 3.5, 0.8), paint, Enum.Material.SmoothPlastic, {
		Reflectance = 0.08,
	})
	for _, x in { -2.6, 2.6 } do
		for _, z in { -1.9, 3.5 } do
			addPart(model, cf, "Pillar", Vector3.new(0.3, 2.6, 0.3), CFrame.new(x, 2.1, z), paint, Enum.Material.SmoothPlastic)
		end
	end
	addPart(model, cf, "FrontBumper", Vector3.new(6.3, 0.7, 0.6), CFrame.new(0, -0.45, -5.95), DARK, Enum.Material.Metal, {
		CanCollide = true,
	})
	addPart(model, cf, "RearBumper", Vector3.new(6.3, 0.7, 0.6), CFrame.new(0, -0.45, 5.95), DARK, Enum.Material.Metal, {
		CanCollide = true,
	})
	addPart(model, cf, "Grille", Vector3.new(2.6, 0.55, 0.1), CFrame.new(0, 0.1, -5.8), DARK, Enum.Material.DiamondPlate)
	for _, x in { -2.1, 2.1 } do
		addPart(model, cf, "Headlight", Vector3.new(1.1, 0.45, 0.12), CFrame.new(x, 0.25, -5.78), Color3.fromRGB(255, 250, 225), Enum.Material.Neon)
		addPart(model, cf, "Taillight", Vector3.new(1.1, 0.45, 0.12), CFrame.new(x, 0.25, 5.78), Color3.fromRGB(255, 40, 40), Enum.Material.Neon)
	end
	for _, x in { -2.95, 2.95 } do
		for _, z in { -3.7, 3.7 } do
			addPart(model, cf, "Wheel", Vector3.new(1.0, 2.5, 2.5), CFrame.new(x, -0.65, z), Color3.fromRGB(24, 24, 24), Enum.Material.SmoothPlastic, {
				Shape = Enum.PartType.Cylinder,
			})
			addPart(model, cf, "Hubcap", Vector3.new(1.06, 1.3, 1.3), CFrame.new(x, -0.65, z), Color3.fromRGB(205, 205, 210), Enum.Material.Metal, {
				Shape = Enum.PartType.Cylinder,
			})
		end
	end

	-- Upgrade extras
	if engineLevel >= 3 then
		addPart(model, cf, "Spoiler", Vector3.new(5.8, 0.25, 1.3), CFrame.new(0, 1.75, 5.1), DARK, Enum.Material.Metal)
		for _, x in { -2.1, 2.1 } do
			addPart(model, cf, "SpoilerPost", Vector3.new(0.3, 0.9, 0.3), CFrame.new(x, 1.2, 5.1), DARK, Enum.Material.Metal)
		end
	end
	if engineLevel >= 4 then
		for _, x in { -0.75, 0.75 } do
			addPart(model, cf, "Stripe", Vector3.new(0.7, 0.06, 11.52), CFrame.new(x, 0.81, 0), Color3.fromRGB(250, 250, 250), Enum.Material.SmoothPlastic)
		end
	end
	if engineLevel >= 5 then
		local glow = addPart(model, cf, "Underglow", Vector3.new(5.4, 0.12, 10.6), CFrame.new(0, -0.86, 0), Config.Vehicle.UnderglowColor, Enum.Material.Neon)
		local glowLight = Instance.new("PointLight")
		glowLight.Color = Config.Vehicle.UnderglowColor
		glowLight.Range = 14
		glowLight.Brightness = 2
		glowLight.Parent = glow
	end

	-- Seats (sunk into the chassis so riders fit under the roof)
	local driverSeat = Instance.new("VehicleSeat")
	driverSeat.Name = "DriverSeat"
	driverSeat.Size = Vector3.new(2, 0.5, 2)
	driverSeat.CFrame = cf * CFrame.new(-1.25, 0.05, 0.9)
	driverSeat.Transparency = 1
	driverSeat.CanCollide = false
	driverSeat.Massless = true
	driverSeat.HeadsUpDisplay = false
	driverSeat.MaxSpeed = 0
	driverSeat.Parent = model

	local passengerSeat = Instance.new("Seat")
	passengerSeat.Name = "PassengerSeat"
	passengerSeat.Size = Vector3.new(2, 0.5, 2)
	passengerSeat.CFrame = cf * CFrame.new(1.25, 0.05, 0.9)
	passengerSeat.Transparency = 1
	passengerSeat.CanCollide = false
	passengerSeat.Massless = true
	passengerSeat.Parent = model

	-- Weld everything to the chassis
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part ~= chassis then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = chassis
			weld.Part1 = part
			weld.Parent = part
		end
	end

	-- Hover-car physics (driven by the client, see VehicleController)
	local attachment = Instance.new("Attachment")
	attachment.Name = "DriveAttachment"
	attachment.Parent = chassis

	local drive = Instance.new("LinearVelocity")
	drive.Name = "Drive"
	drive.Attachment0 = attachment
	drive.RelativeTo = Enum.ActuatorRelativeTo.World
	drive.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	drive.MaxForce = Config.Vehicle.MaxForce
	drive.VectorVelocity = Vector3.zero
	drive.Parent = chassis

	local orient = Instance.new("AlignOrientation")
	orient.Name = "Orient"
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.MaxTorque = Config.Vehicle.MaxTorque
	orient.Responsiveness = 30
	orient.CFrame = flatRotation(cf)
	orient.Parent = chassis

	-- Prompts
	local drivePrompt = Instance.new("ProximityPrompt")
	drivePrompt.Name = "DrivePrompt"
	drivePrompt.ActionText = "Get In"
	drivePrompt.ObjectText = player.DisplayName .. "'s Car"
	drivePrompt.HoldDuration = 0
	drivePrompt.MaxActivationDistance = 12
	drivePrompt.RequiresLineOfSight = false
	drivePrompt.KeyboardKeyCode = Enum.KeyCode.E
	drivePrompt.Parent = driverSeat

	local trunkAttachment = Instance.new("Attachment")
	trunkAttachment.Name = "TrunkAttachment"
	trunkAttachment.Position = Vector3.new(0, 1.2, 6.3)
	trunkAttachment.Parent = chassis

	local trunkPrompt = Instance.new("ProximityPrompt")
	trunkPrompt.Name = "TrunkPrompt"
	trunkPrompt.ActionText = "Load Trunk"
	trunkPrompt.ObjectText = "Trunk"
	trunkPrompt.HoldDuration = 0.25
	trunkPrompt.MaxActivationDistance = 9
	trunkPrompt.RequiresLineOfSight = false
	trunkPrompt.KeyboardKeyCode = Enum.KeyCode.F
	trunkPrompt:SetAttribute("OwnerUserId", player.UserId) -- hidden from other players on their clients
	trunkPrompt.Parent = trunkAttachment

	-- Name tag
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "CarLabel"
	billboard.Size = UDim2.fromOffset(220, 56)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 5.5, 0)
	billboard.MaxDistance = 140
	billboard.LightInfluence = 0
	billboard.Parent = chassis

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.3
	label.Text = ""
	label.Parent = billboard

	return {
		Owner = player,
		Model = model,
		Chassis = chassis,
		DriverSeat = driverSeat,
		PassengerSeat = passengerSeat,
		Drive = drive,
		Orient = orient,
		DrivePrompt = drivePrompt,
		TrunkPrompt = trunkPrompt,
		Label = label,
	}
end

local function eject(humanoid: Humanoid, seat: Seat | VehicleSeat)
	task.defer(function()
		local seatWeld = seat:FindFirstChild("SeatWeld")
		if seatWeld then
			seatWeld:Destroy()
		end
		humanoid.Sit = false
		humanoid.Jump = true
	end)
end

local function hookCar(record: CarRecord)
	local owner = record.Owner
	local seat = record.DriverSeat

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local humanoid = seat.Occupant
		if humanoid then
			local character = humanoid.Parent
			local occupant = if character and character:IsA("Model") then Players:GetPlayerFromCharacter(character) else nil
			if occupant ~= owner then
				eject(humanoid, seat)
				if occupant then
					Notify.send(occupant, "That's not your car! Spawn your own with the 🚗 button.", "error")
				end
				return
			end
			record.DrivePrompt.Enabled = false
			pcall(function()
				record.Chassis:SetNetworkOwner(owner)
			end)
		else
			record.DrivePrompt.Enabled = true
			record.Drive.VectorVelocity = Vector3.zero
			record.Orient.CFrame = flatRotation(record.Chassis.CFrame)
			pcall(function()
				record.Chassis:SetNetworkOwner(nil)
			end)
		end
	end)

	record.DrivePrompt.Triggered:Connect(function(who: Player)
		local character = who.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if not humanoid or humanoid.Health <= 0 or humanoid.SeatPart then
			return
		end
		if who == owner then
			if seat.Occupant == nil then
				seat:Sit(humanoid)
			end
		elseif record.PassengerSeat.Occupant == nil then
			record.PassengerSeat:Sit(humanoid)
		else
			Notify.send(who, "This car is full!", "error")
		end
	end)

	record.TrunkPrompt.Triggered:Connect(function(who: Player)
		if who ~= owner then
			Notify.send(who, "Only " .. owner.DisplayName .. " can use this trunk.", "error")
			return
		end
		if Inventory.getCarriedCount(owner) == 0 then
			Notify.send(owner, "You aren't carrying any loot. Go steal something!", "info")
			return
		end
		local moved, left = Inventory.loadTrunk(owner)
		if moved == 0 then
			Notify.send(owner, "🧳 Your trunk is full! Upgrade Trunk Space, or unload at your warehouse dock.", "error")
			return
		end
		local message = string.format("🧳 Loaded %d item%s into the trunk (%s)", moved, if moved == 1 then "" else "s", trunkText(owner))
		if left > 0 then
			message ..= string.format(" — %d didn't fit!", left)
		end
		Notify.send(owner, message, "success")
	end)
end

function Vehicles.getCar(player: Player): Model?
	local record = cars[player]
	return if record then record.Model else nil
end

function Vehicles.despawn(player: Player)
	local record = cars[player]
	if record then
		cars[player] = nil
		record.Model:Destroy()
	end
end

-- Finds a clear patch of ground next to the player for their car.
local function findSpawnNear(root: BasePart, exclude: { Instance }): CFrame?
	local map = Workspace:FindFirstChild("Map")
	local ground = if map then map:FindFirstChild("Ground") else nil
	if not ground then
		return nil
	end
	local look = root.CFrame.LookVector
	local forward = Vector3.new(look.X, 0, look.Z)
	if forward.Magnitude < 0.01 then
		forward = Vector3.new(0, 0, -1)
	end
	forward = forward.Unit
	local right = forward:Cross(Vector3.yAxis)

	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = exclude
	rayParams.RespectCanCollide = true

	local overlapExclude = table.clone(exclude)
	table.insert(overlapExclude, ground)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = overlapExclude
	overlapParams.RespectCanCollide = true

	for _, offset in { right * 9, -right * 9, forward * 14, -forward * 14 } do
		local probe = root.Position + offset
		local hit = Workspace:Raycast(probe + Vector3.new(0, 10, 0), Vector3.new(0, -40, 0), rayParams)
		if hit and hit.Instance:IsDescendantOf(ground) then
			local center = Vector3.new(probe.X, hit.Position.Y + Config.Vehicle.HoverHeight, probe.Z)
			local cf = CFrame.lookAt(center, center + forward)
			local blockers = Workspace:GetPartBoundsInBox(cf * CFrame.new(0, 0.8, 0), Vector3.new(7, 4.4, 13), overlapParams)
			if #blockers == 0 then
				return cf
			end
		end
	end
	return nil
end

-- Lifts a ground-level CFrame to hover height (raycasting for the real ground).
local function hoverCFrame(base: CFrame, exclude: { Instance }): CFrame
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = exclude
	rayParams.RespectCanCollide = true
	local hit = Workspace:Raycast(base.Position + Vector3.new(0, 10, 0), Vector3.new(0, -40, 0), rayParams)
	local groundY = if hit then hit.Position.Y else base.Position.Y
	local position = Vector3.new(base.Position.X, groundY + Config.Vehicle.HoverHeight, base.Position.Z)
	return CFrame.new(position) * flatRotation(base)
end

function Vehicles.spawn(player: Player): (boolean, string)
	local now = os.clock()
	if (lastSpawn[player] or 0) + Config.Vehicle.SpawnCooldown > now then
		return false, "Your mechanic needs a moment... try again shortly."
	end
	if not PlayerData.get(player) then
		return false, "Still loading your data..."
	end
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if humanoid and humanoid.SeatPart then
		return false, "Hop out of your seat first!"
	end
	lastSpawn[player] = now
	Vehicles.despawn(player)

	local exclude: { Instance } = { carsFolder }
	if character then
		table.insert(exclude, character)
	end

	local cf: CFrame? = nil
	local nearPlayer = false
	if root and root:IsA("BasePart") and not Houses.isOnProperty(root.Position) then
		cf = findSpawnNear(root, exclude)
		nearPlayer = cf ~= nil
	end
	if not cf then
		local base = Plots.getCarSpawnCFrame(player)
		if not base then
			if root and root:IsA("BasePart") then
				base = root.CFrame * CFrame.new(10, 0, 0)
			else
				return false, "Couldn't find anywhere to park your car."
			end
		end
		cf = hoverCFrame(base :: CFrame, exclude)
	end

	local record = buildCar(player, cf :: CFrame)
	cars[player] = record
	record.Model.Parent = carsFolder
	pcall(function()
		record.Chassis:SetNetworkOwner(nil)
	end)
	hookCar(record)
	updateLabel(player)

	if nearPlayer then
		return true, "🚗 Your getaway car pulled up!"
	end
	return true, "🚗 Your car is waiting at your warehouse's car spot."
end

-- Rebuilds the car (if nobody is in it) so engine upgrades show up immediately.
function Vehicles.onEngineUpgraded(player: Player)
	local record = cars[player]
	if not record then
		return
	end
	record.Model:SetAttribute("MaxSpeed", PlayerData.getUpgradeValue(player, "Engine"))
	if record.DriverSeat.Occupant or record.PassengerSeat.Occupant then
		Notify.send(player, "🔧 Engine upgraded! Respawn your car to see the new paint job.", "info")
		return
	end
	local cf = record.Chassis.CFrame
	Vehicles.despawn(player)
	local rebuilt = buildCar(player, CFrame.new(cf.Position) * flatRotation(cf))
	cars[player] = rebuilt
	rebuilt.Model.Parent = carsFolder
	pcall(function()
		rebuilt.Chassis:SetNetworkOwner(nil)
	end)
	hookCar(rebuilt)
	updateLabel(player)
end

function Vehicles.updateLabel(player: Player)
	updateLabel(player)
end

-- Cars parked in their owner's loading dock unload automatically.
local function dockLoop()
	while true do
		task.wait(0.5)
		for player, record in cars do
			local position = record.Chassis.Position
			local hasPlot = Plots.getPlot(player) ~= nil
			if record.Model.Parent and not hasPlot and Plots.isInAnyDock(position) then
				local items = Inventory.takeTrunk(player)
				if #items > 0 then
					Plots.sellAll(player, items)
				end
			elseif record.Model.Parent and hasPlot and Plots.isInDock(player, position) then
				local items = Inventory.takeTrunk(player)
				local occupant = record.DriverSeat.Occupant
				if occupant and occupant.Parent == player.Character then
					for _, itemId in Inventory.takeCarried(player) do
						table.insert(items, itemId)
					end
				end
				if #items > 0 then
					Plots.deposit(player, items)
				end
			end
		end
	end
end

function Vehicles.onPlayerAdded(player: Player)
	local connections = {
		player:GetAttributeChangedSignal("TrunkCount"):Connect(function()
			updateLabel(player)
		end),
		player:GetAttributeChangedSignal("TrunkCapacity"):Connect(function()
			updateLabel(player)
		end),
	}
	attributeConnections[player] = connections
end

function Vehicles.onPlayerRemoving(player: Player)
	Vehicles.despawn(player)
	lastSpawn[player] = nil
	local connections = attributeConnections[player]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
		attributeConnections[player] = nil
	end
end

function Vehicles.init()
	local existing = Workspace:FindFirstChild("Cars")
	if existing and existing:IsA("Folder") then
		carsFolder = existing
	else
		carsFolder = Instance.new("Folder")
		carsFolder.Name = "Cars"
		carsFolder.Parent = Workspace
	end

	ReplicatedStorage.Remotes.SpawnCar.OnServerInvoke = function(player: Player)
		local ok, message = Vehicles.spawn(player)
		return { Ok = ok, Message = message }
	end

	task.spawn(dockLoop)
end

return Vehicles
