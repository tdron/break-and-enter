--!strict
--[[
	Houses
	------
	The heist part of the game:
	  * Locked doors you open with a "Pick Lock" prompt (harder houses take longer).
	  * Every house has its own set of loot (see Items) that spawns on furniture.
	  * Stealing anything trips the alarm: after a short wind-up the house's
	    defenders give chase. Who lives where is Config.Houses / Config.Guards:
	    a tuxedo cat, then a puppy, a labrador, a guard dog, the home owner, an
	    off-duty officer, a wizard, a T-Rex, security bots and finally the museum's
	    fleet of security cars. Get caught = BUSTED (you drop everything you're
	    carrying and get sent back to your warehouse).
	  * They do NOT give up at the property line any more: they chase you all the
	    way back down the street and turn around at the canyon mouth, so the yard
	    is the only safe place. While anybody is on a property (you or them)
	    everyone moves at the standard Roblox speed; the moment you are through
	    the front gate the real speeds apply — yours from the treadmill, theirs
	    from Config.Guards.Speed (and the late-game ones are very, very fast).
	  * The hardest houses also have blinking laser tripwires.
	  * DAYTIME (see DayNight): houses lock up, anyone inside is shown the door
	    and every house restocks. That's the only time loot comes back.

	Map layout expected (built by tools/map_builder.py):
	  Workspace.Map.Houses.<HouseId>  (Model named after its Config.Houses id; attributes Tier & DisplayName)
	    Zone        Part covering the whole property (invisible)
	    ItemSpots   Folder of Parts marking where loot appears
	    GuardDocks  Folder of Parts where the guards rest (pet beds / drone pads)
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
local Guards = require(ReplicatedStorage.Shared.Guards)
local ItemModels = require(ReplicatedStorage.Shared.ItemModels)
local Items = require(ReplicatedStorage.Shared.Items)
local DayNight = require(script.Parent.DayNight)
local Inventory = require(script.Parent.Inventory)
local Notify = require(script.Parent.Notify)
local PlayerData = require(script.Parent.PlayerData)
local Plots = require(script.Parent.Plots)

local BustedEvent = ReplicatedStorage.Remotes.Busted

type Spot = {
	Part: BasePart,
	Item: Model?,
	ItemId: string?,
}

type Guard = {
	Look: Guards.GuardModel,
	Root: BasePart,
	AlignPosition: AlignPosition,
	AlignOrientation: AlignOrientation,
	Home: CFrame, -- where the root rests
	Flying: boolean,
	State: string, -- "Idle" | "Windup" | "Chase"
	ActivateAt: number,
	Bob: number, -- phase offset for the trotting bounce
	Trot: number, -- how bouncy this kind of defender is (cars don't bounce)
}

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
	Id: string,
	Name: string,
	LootHouse: string, -- whose loot table to roll from (normally Id)
	Tier: number,
	Settings: Config.HouseTier,
	GuardId: string,
	GuardInfo: Config.GuardInfo,
	ZoneCFrame: CFrame,
	ZoneHalfSize: Vector3,
	FrontInset: number, -- how far the front wall sits inside the property
	GuardSpeed: number, -- the defenders' speed once they are out on the street
	ChaseMaxX: number, -- chases never go further east than this house's own property
	Loot: Folder,
	Spots: { Spot },
	Guards: { Guard },
	Doors: { Door },
	Lasers: { BasePart },
	AlarmActive: boolean,
	LastOccupiedAt: number,
	Intruders: { [Player]: boolean },
}

type Thief = { Player: Player, Root: BasePart, Humanoid: Humanoid }

local FEET_BELOW_ROOT = 3 -- a standard character's HumanoidRootPart floats this high above its feet
local CATCH_HEIGHT = 7 -- guards can't reach thieves this far above/below them
local SLEEPING = "💤"
local ALERT = "❗"
-- How much each kind of defender bounces while it runs (its size sets the catch radius).
local TROT = { Cat = 0.4, Dog = 0.4, Beast = 0.55, Human = 0.12, Wizard = 0.12, Robot = 0, Vehicle = 0 }

local Houses = {}

local houses: { House } = {}
-- Declared up here because the alarm opens the front door before the door code is defined.
local setDoorOpen: (door: Door, open: boolean) -> ()
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

-- A point on the ground, in the property's own coordinates: +Z points from the house out to the street.
local function lotPoint(house: House, localX: number, localZ: number): Vector3
	local half = house.ZoneHalfSize
	return house.ZoneCFrame:PointToWorldSpace(Vector3.new(localX, -half.Y + FEET_BELOW_ROOT, localZ))
end

-- Is this position still inside the building (rather than out in the front yard)?
local function insideHouse(house: House, position: Vector3): boolean
	return house.ZoneCFrame:PointToObjectSpace(position).Z < house.ZoneHalfSize.Z - house.FrontInset
end

-- How far a chase can go: this house's own property, plus the street from the front door
-- all the way back west to the canyon mouth. Inside the yard (past the mouth) it is over.
local function inChaseArea(house: House, position: Vector3): boolean
	if isInZone(house, position) then
		return true
	end
	if position.X < Config.Alarm.SafeX or position.X > house.ChaseMaxX then
		return false
	end
	return math.abs(position.Z) <= Config.Alarm.LaneHalfWidth
end

-- Keeps a chasing defender inside that area (but it is free to roam its own property).
local function clampToChase(house: House, position: Vector3): Vector3
	if isInZone(house, position) then
		return position
	end
	return Vector3.new(
		math.clamp(position.X, Config.Alarm.SafeX, house.ChaseMaxX),
		position.Y,
		math.clamp(position.Z, -Config.Alarm.LaneHalfWidth, Config.Alarm.LaneHalfWidth)
	)
end

-- Inside a property everybody moves at the standard Roblox speed: a defender only gets to use
-- its listed speed once it is out on the street (and so does the thief, with whatever the
-- treadmill has given them).
local function chaseSpeed(house: House, position: Vector3): number
	return if Houses.isOnProperty(position) then Config.Alarm.InsideSpeed else house.GuardSpeed
end

-- Big defenders (the T-Rex, the cars) catch you with their body, not their centre point.
local function catchRadius(guard: Guard): number
	local size = guard.Look.Size
	return math.max(Config.Alarm.CatchRadius, math.max(size.X, size.Z) * 0.5)
end

local function isImmune(player: Player, now: number): boolean
	return (bustedUntil[player] or 0) > now
end

-- "the Ginger Cat" / "the Pugs"
local function guardPhrase(house: House): string
	local name = house.GuardInfo.DisplayName
	return if #house.Guards == 1 then "the " .. name else "the " .. name .. "s"
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
	if house.AlarmActive or DayNight.isDaytime() then
		return
	end
	house.AlarmActive = true
	house.Model:SetAttribute("AlarmActive", true)
	for _, guard in house.Guards do
		guard.State = "Windup"
		guard.ActivateAt = now + house.Settings.AlarmWindup
		Guards.setAlert(guard.Look, house.GuardId, true)
		guard.Look.Status.Text = ALERT
		-- Drones rise up and animals jump out of bed during the wind-up, so players see them coming.
		guard.AlignPosition.Position = guard.Home.Position + Vector3.new(0, if guard.Flying then 1.5 else 0.6, 0)
	end
	-- They come out after you, so the way out is open.
	for _, door in house.Doors do
		if not door.IsOpen then
			setDoorOpen(door, true)
		end
	end
	if culprit then
		local phrase = guardPhrase(house)
		Notify.send(
			culprit,
			string.format(
				"🚨 ALARM! %s%s woke up! It moves at your speed in here — through the gate it runs at %s studs/s!",
				string.upper(string.sub(phrase, 1, 1)),
				string.sub(phrase, 2),
				Format.commas(house.GuardSpeed)
			),
			"warning"
		)
	end
end

local function clearIntruder(player: Player, house: House)
	house.Intruders[player] = nil
	if player.Parent and player:GetAttribute("AlarmHouse") == house.Name then
		player:SetAttribute("AlarmHouse", "")
		player:SetAttribute("AlarmGuard", "")
		player:SetAttribute("AlarmSpeed", 0)
	end
end

local function endAlarm(house: House)
	house.AlarmActive = false
	house.Model:SetAttribute("AlarmActive", false)
	for player in house.Intruders do
		clearIntruder(player, house)
	end
	for _, guard in house.Guards do
		guard.State = "Idle"
		guard.AlignPosition.Position = guard.Home.Position
		guard.AlignPosition.MaxVelocity = Config.Alarm.GuardReturnSpeed
		guard.AlignOrientation.CFrame = guard.Home.Rotation
		Guards.setAlert(guard.Look, house.GuardId, false)
		guard.Look.Status.Text = if guard.Flying then "" else SLEEPING
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
	local catcher = (if #house.Guards == 1 then "The " else "A ") .. house.GuardInfo.DisplayName
	BustedEvent:FireClient(player, #lost, lostValue, house.Name, catcher)

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

-- Where a guard heads to catch this position.
local function aimAt(guard: Guard, position: Vector3, now: number): Vector3
	if guard.Flying then
		return position + Vector3.new(0, Config.Alarm.DroneAimHeight, 0)
	end
	-- Animals run along the floor, with a little trotting bounce (cars and people keep their wheels on it).
	local feet = position.Y - FEET_BELOW_ROOT
	local bounce = if guard.Trot > 0 then math.abs(math.sin(now * 14 + guard.Bob)) * guard.Trot else 0
	return Vector3.new(position.X, feet + guard.Look.RootHeight + bounce, position.Z)
end

local function updateAlarm(house: House, thieves: { Thief }, now: number)
	local intruders: { Thief } = {}
	for _, thief in thieves do
		if inChaseArea(house, thief.Root.Position) and not isImmune(thief.Player, now) then
			table.insert(intruders, thief)
		end
	end

	-- Keep the "you're being chased" banner in sync.
	local present: { [Player]: boolean } = {}
	for _, thief in intruders do
		present[thief.Player] = true
		if not house.Intruders[thief.Player] then
			house.Intruders[thief.Player] = true
			thief.Player:SetAttribute("AlarmGuard", guardPhrase(house))
			thief.Player:SetAttribute("AlarmHouse", house.Name)
			thief.Player:SetAttribute("AlarmSpeed", house.GuardSpeed)
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

	for _, guard in house.Guards do
		if guard.State == "Windup" and now >= guard.ActivateAt then
			guard.State = "Chase"
		end
		if guard.State == "Chase" then
			local target: Thief? = nil
			local bestDistance = math.huge
			local from = guard.Root.Position
			for _, thief in intruders do
				local offset = thief.Root.Position - from
				local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
				if distance < bestDistance then
					target, bestDistance = thief, distance
				end
			end
			if target then
				local aimed = target.Root.Position
				-- A defender that is still indoors while the thief has made it outside heads for the
				-- front door first, so it leaves the way you would expect it to.
				if insideHouse(house, from) and not insideHouse(house, aimed) then
					local porch = lotPoint(house, 0, house.ZoneHalfSize.Z - house.FrontInset + 3)
					aimed = Vector3.new(porch.X, from.Y + guard.Look.RootHeight, porch.Z)
				end
				local aim = aimAt(guard, aimed, now)
				guard.AlignPosition.Position = clampToChase(house, aim)
				-- The standard speed in the house, its real (often terrifying) speed outside.
				guard.AlignPosition.MaxVelocity = chaseSpeed(house, from)
				local flat = Vector3.new(aim.X - from.X, 0, aim.Z - from.Z)
				if flat.Magnitude > 0.1 then
					guard.AlignOrientation.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
				end
				local height = math.abs(aimed.Y - from.Y)
				if bestDistance <= catchRadius(guard) and height <= CATCH_HEIGHT then
					bust(target.Player, house)
				end
			end
		end
	end
end

local function getThieves(): { Thief }
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
	return thieves
end

local function onHeartbeat()
	local now = os.clock()
	local thieves = getThieves()

	-- Inside a property everyone is held at the standard Roblox speed (see PlayerData).
	for _, thief in thieves do
		PlayerData.setInsideHouse(thief.Player, Houses.isOnProperty(thief.Root.Position))
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

local function setStealable(spot: Spot, stealable: boolean)
	local model = spot.Item
	local root = if model then model.PrimaryPart else nil
	local prompt = if root then root:FindFirstChild("StealPrompt") else nil
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = stealable
	end
end

local function spawnItem(house: House, spot: Spot)
	local itemId = Items.roll(house.LootHouse, rng)
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
		prompt.Enabled = not DayNight.isDaytime()
		prompt.Parent = root
		prompt.Triggered:Connect(function(player: Player)
			onSteal(house, spot, model, player)
		end)
	end
	model.Parent = house.Loot
	spot.Item = model
	spot.ItemId = itemId
end

-- Fresh loot on every spot (the old leftovers are taken away).
local function restock(house: House)
	for _, spot in house.Spots do
		local old = spot.Item
		if old then
			old:Destroy()
		end
		spot.Item = nil
		spot.ItemId = nil
		spawnItem(house, spot)
	end
end

onSteal = function(house: House, spot: Spot, model: Model, player: Player)
	local itemId = spot.ItemId
	if spot.Item ~= model or not itemId or not model.Parent then
		return
	end
	if DayNight.isDaytime() or isImmune(player, os.clock()) then
		return
	end
	local ok, reason = Inventory.addCarried(player, itemId)
	if not ok then
		Notify.send(player, reason or "You can't carry that right now.", "error")
		return
	end
	spot.Item = nil
	spot.ItemId = nil
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
		if PlayerData.discover(player, itemId) then
			Notify.send(
				player,
				string.format(
					"📖 New item discovered: %s! (%d/%d in your Loot Index)",
					def.DisplayName,
					PlayerData.getDiscoveredCount(player),
					#Items.List
				),
				"level"
			)
		end
	end
	triggerAlarm(house, player)
end

--------------------------------------------------------------------------------
-- Guards
--------------------------------------------------------------------------------
local function buildGuard(house: House, dock: BasePart): Guard
	local flying = house.GuardInfo.Kind == "Drone"
	local base = if flying
		then CFrame.new(dock.Position + Vector3.new(0, Config.Alarm.DroneDockHeight, 0)) * dock.CFrame.Rotation
		else CFrame.new(dock.Position + Vector3.new(0, dock.Size.Y / 2, 0)) * dock.CFrame.Rotation
	local look = Guards.build(house.GuardId, base)
	local model = look.Model
	model:SetAttribute("Kind", house.GuardInfo.Kind)
	model:SetAttribute("Breed", house.GuardInfo.DisplayName)
	local root = look.Root
	look.Status.Text = if flying then "" else SLEEPING

	local attachment = Instance.new("Attachment")
	attachment.Name = "GuardAttachment"
	attachment.Parent = root

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.Position = root.Position
	alignPosition.MaxForce = 1000000
	alignPosition.MaxVelocity = Config.Alarm.GuardReturnSpeed
	alignPosition.Responsiveness = 80
	alignPosition.Parent = root

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.CFrame = root.CFrame.Rotation
	alignOrientation.MaxTorque = 1000000
	alignOrientation.Responsiveness = 40
	alignOrientation.Parent = root

	model.Parent = house.Model
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	return {
		Look = look,
		Root = root,
		AlignPosition = alignPosition,
		AlignOrientation = alignOrientation,
		Home = root.CFrame,
		Flying = flying,
		State = "Idle",
		ActivateAt = 0,
		Bob = rng:NextNumber() * math.pi * 2,
		Trot = TROT[house.GuardInfo.Kind] or 0.4,
	}
end

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------
setDoorOpen = function(door: Door, open: boolean)
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
			if not door.IsOpen and not DayNight.isDaytime() then
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
	local pieces: { { Part: BasePart, Offset: CFrame } } = {}
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
	prompt.Enabled = not DayNight.isDaytime()
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
		if DayNight.isDaytime() then
			Notify.send(player, "☀️ The owners are home! Come back when it's dark.", "error")
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
		if laser.Transparency >= 1 or DayNight.isDaytime() then
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
			local phrase = guardPhrase(house)
			Notify.send(
				player,
				string.format(
					"🔴 You tripped a laser! %s%s %s awake!",
					string.upper(string.sub(phrase, 1, 1)),
					string.sub(phrase, 2),
					if #house.Guards == 1 then "is" else "are"
				),
				"warning"
			)
			triggerAlarm(house, nil)
		end
	end)
	table.insert(house.Lasers, laser)
end

local function updateLasers()
	local cycle = Config.Lasers.OnTime + Config.Lasers.OffTime
	local now = os.clock()
	local daytime = DayNight.isDaytime()
	for _, house in houses do
		for _, laser in house.Lasers do
			local phase = laser:GetAttribute("Phase")
			local offset = if type(phase) == "number" then phase else 0
			local on = not daytime and (now + offset) % cycle < Config.Lasers.OnTime
			local transparency = if on then 0.2 else 1
			if laser.Transparency ~= transparency then
				laser.Transparency = transparency
				laser.CanTouch = on
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Daytime: lock up, show everyone out, restock
--------------------------------------------------------------------------------
-- A spot on the pavement just outside the property, facing the street.
local function exitCFrame(house: House): CFrame
	local half = house.ZoneHalfSize
	local front = house.ZoneCFrame * CFrame.new(0, -half.Y + FEET_BELOW_ROOT, half.Z + 6)
	return front * CFrame.Angles(0, math.pi, 0)
end

local function showEveryoneOut()
	for _, thief in getThieves() do
		local seated = thief.Humanoid.SeatPart ~= nil
		for _, house in houses do
			if not seated and isInZone(house, thief.Root.Position) then
				local character = thief.Player.Character
				if character then
					character:PivotTo(exitCFrame(house))
				end
				Notify.send(thief.Player, "☀️ The owners came home! You slipped out just in time (and kept your loot).", "warning")
				break
			end
		end
	end
end

local function onDaytime()
	showEveryoneOut()
	for _, house in houses do
		if house.AlarmActive then
			endAlarm(house)
		end
		for _, door in house.Doors do
			door.Prompt.Enabled = false
			if door.IsOpen then
				setDoorOpen(door, false)
			end
		end
		restock(house)
		house.Model:SetAttribute("Open", false)
	end
end

local function onNightfall()
	for _, house in houses do
		for _, door in house.Doors do
			if not door.IsOpen then
				door.Prompt.Enabled = true
			end
		end
		for _, spot in house.Spots do
			setStealable(spot, true)
		end
		house.Model:SetAttribute("Open", true)
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
	local info = Config.getHouse(model.Name)
	local tierAttribute = model:GetAttribute("Tier")
	local tier = math.clamp(
		if info then info.Tier elseif type(tierAttribute) == "number" then tierAttribute else 1,
		1,
		#Config.HouseTiers
	)
	local displayName = model:GetAttribute("DisplayName")
	local guardId = if info then info.Guard else "TuxedoCat"
	local guardInfo = Config.Guards[guardId] or Config.Guards.TuxedoCat

	-- Houses added by hand in Studio borrow the loot of a listed house of the same tier.
	local lootHouse = model.Name
	if #Items.forHouse(lootHouse) == 0 then
		for _, other in Config.Houses do
			if other.Tier == tier then
				lootHouse = other.Id
				break
			end
		end
	end

	local loot = Instance.new("Folder")
	loot.Name = "Loot"
	loot.Parent = model

	-- The map marks where the front wall sits inside the property; fall back to the Config default.
	local inset = zone:GetAttribute("FrontInset")
	local half = zone.Size / 2
	-- How far east a chase is allowed to go: the east edge of this house's own lot.
	local maxX = -math.huge
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			maxX = math.max(maxX, zone.CFrame:PointToWorldSpace(Vector3.new(sx * half.X, 0, sz * half.Z)).X)
		end
	end

	local house: House = {
		Model = model,
		Id = model.Name,
		Name = if type(displayName) == "string" then displayName elseif info then info.DisplayName else model.Name,
		LootHouse = lootHouse,
		Tier = tier,
		Settings = Config.HouseTiers[tier],
		GuardId = guardId,
		GuardInfo = guardInfo,
		ZoneCFrame = zone.CFrame,
		ZoneHalfSize = half,
		FrontInset = if type(inset) == "number" then inset else Config.Alarm.HouseFrontInset,
		GuardSpeed = guardInfo.Speed,
		ChaseMaxX = maxX + 4,
		Loot = loot,
		Spots = {},
		Guards = {},
		Doors = {},
		Lasers = {},
		AlarmActive = false,
		LastOccupiedAt = 0,
		Intruders = {},
	}
	model:SetAttribute("AlarmActive", false)
	model:SetAttribute("Open", not DayNight.isDaytime())

	local spots = model:FindFirstChild("ItemSpots")
	if spots then
		for _, part in spots:GetChildren() do
			if part:IsA("BasePart") then
				local spot: Spot = { Part = part, Item = nil, ItemId = nil }
				table.insert(house.Spots, spot)
				spawnItem(house, spot)
			end
		end
	end

	local docks = model:FindFirstChild("GuardDocks")
	if docks then
		for _, dock in docks:GetChildren() do
			if dock:IsA("BasePart") then
				table.insert(house.Guards, buildGuard(house, dock))
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

local function doorLoop()
	while true do
		task.wait(1)
		local now = os.clock()
		for _, house in houses do
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
	DayNight.onChanged(function(isDaytime: boolean)
		if isDaytime then
			onDaytime()
		else
			onNightfall()
		end
	end)
	RunService.Heartbeat:Connect(onHeartbeat)
	RunService.Heartbeat:Connect(updateLasers)
	task.spawn(doorLoop)
end

return Houses
