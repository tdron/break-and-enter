--[[
	Client smoke test: boots the real client scripts (src/client) inside the
	RobloxMock engine and pokes every piece of UI the server can trigger.
	With the API database available, the mock rejects unknown or read-only
	properties exactly like Roblox, so typos in UI property tables fail here.

	Run with:  python3 tools/run_luau_tests.py
]]

local Players = Mock.service("Players")
local ReplicatedStorage = Mock.service("ReplicatedStorage")
local Remotes = ReplicatedStorage.Remotes
local Map = workspace.Map

local passed, failed = 0, 0
local function step(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
		print("ok    " .. name)
	else
		failed += 1
		print("FAIL  " .. name .. "\n      " .. tostring(err))
	end
end
local function check(condition: any, message: string)
	if not condition then
		error(message, 2)
	end
end
local function eq(actual: any, expected: any, label: string)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", label, tostring(expected), tostring(actual)), 2)
	end
end

local function findButton(root, text: string)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("TextButton") and descendant.Text == text then
			return descendant
		end
	end
	error("no button labelled " .. text)
end

local function findText(root, fragment: string)
	for _, descendant in root:GetDescendants() do
		if (descendant:IsA("TextLabel") or descendant:IsA("TextButton")) and descendant.Text
			and string.find(descendant.Text, fragment, 1, true)
		then
			return descendant
		end
	end
	return nil
end

-- A local player like the one Roblox gives a client
local player = Mock.newInstance("Player")
Mock.setRaw(player, "Name", "Tester")
Mock.setRaw(player, "DisplayName", "Tester")
Mock.setRaw(player, "UserId", 7)
player.Parent = Players
Mock.setRaw(Players, "LocalPlayer", player)
local playerGui = Mock.newInstance("PlayerGui")
Mock.setRaw(playerGui, "Name", "PlayerGui")
playerGui.Parent = player
local camera = Mock.newInstance("Camera")
Mock.setRaw(camera, "ViewportSize", Vector2.new(1280, 720))
camera.Parent = workspace
workspace.CurrentCamera = camera

-- Lighting as saved in the place file, and the heist clock the server publishes (night, 3:30 left)
local Lighting = Mock.service("Lighting")
local Config = require(SharedFolder.Config)
Lighting.ClockTime = 14.2
Lighting.Brightness = 2.6
Lighting.ExposureCompensation = 0
Lighting.Ambient = Color3.fromRGB(92, 92, 104)
Lighting.OutdoorAmbient = Color3.fromRGB(138, 138, 150)
Lighting.FogColor = Color3.fromRGB(192, 192, 192)
workspace:SetAttribute("Daytime", false)
workspace:SetAttribute("PhaseEndsAt", workspace:GetServerTimeNow() + 210)

-- Attributes the server would replicate
for name, value in {
	Cash = 0,
	Income = 0,
	Carried = 0,
	BagCapacity = 2,
	TrunkCount = 0,
	TrunkCapacity = 4,
	StoredCount = 0,
	StorageCapacity = 10,
	WalkSpeed = 16,
	SpeedLevel = 0,
	SpeedXP = 0,
	SpeedXPNeeded = 8,
	Level_Bag = 1,
	Level_Engine = 1,
	Level_Trunk = 1,
	Level_Storage = 1,
	Level_Treadmill = 1,
	AlarmHouse = "",
	Training = false,
} do
	player:SetAttribute(name, value)
end

local purchases = {}
Mock.invokeHandlers.Purchase = function(upgradeId)
	table.insert(purchases, upgradeId)
	return { Ok = true, Message = "Bought " .. tostring(upgradeId) }
end
local carRequests = 0
Mock.invokeHandlers.SpawnCar = function()
	carRequests += 1
	return { Ok = true, Message = "🚗 Your getaway car pulled up!" }
end
-- A tiny stand-in for the server's treadmill handler.
local treadmillRequests = {}
local serverAcceptsTreadmill = true
Mock.invokeHandlers.Treadmill = function(action)
	table.insert(treadmillRequests, action)
	if action == "Start" then
		if not serverAcceptsTreadmill then
			return { Ok = false, Message = "Walk onto your treadmill to train!" }
		end
		player:SetAttribute("Training", true)
	else
		player:SetAttribute("Training", false)
	end
	return { Ok = true, Message = "" }
end

-- The default PlayerModule, reduced to the controls API the treadmill uses.
local controlsEnabled = true
local playerScripts = Mock.newInstance("PlayerScripts")
Mock.setRaw(playerScripts, "Name", "PlayerScripts")
playerScripts.Parent = player
local playerModule = Mock.newInstance("ModuleScript")
playerModule.Name = "PlayerModule"
playerModule.Parent = playerScripts
rawset(playerModule, "_factory", function()
	local controls = {}
	function controls:Enable(enabled)
		controlsEnabled = enabled ~= false
	end
	function controls:Disable()
		controlsEnabled = false
	end
	return {
		GetControls = function()
			return controls
		end,
	}
end)

local hud
step("mock enforces Roblox property rules", function()
	check(Mock.propertyRules ~= nil, "API database not loaded, property checks are off")
	local ok = pcall(function()
		local part = Instance.new("Part")
		part.Sizee = Vector3.one
	end)
	check(not ok, "mock accepted an unknown property")
	ok = pcall(function()
		local seat = Instance.new("VehicleSeat")
		seat.Occupant = nil
	end)
	check(not ok, "mock allowed writing a read-only property")
end)

step("client boots and builds the HUD", function()
	task.spawn(RunClient)
	Mock.advance(0.5)
	-- Your saved Loot Index arrives with the rest of your data (it isn't "new")
	player:SetAttribute("Discovered", "OldRadio")
	Mock.advance(0.1)
	hud = playerGui:FindFirstChild("StealAnItemHUD")
	check(hud, "no HUD ScreenGui")
	eq(hud.ResetOnSpawn, false, "HUD survives respawns")
	check(findText(hud, "SHOP"), "no shop button")
	check(findText(hud, "CAR"), "no car button")
	check(#Mock.warnings == 0, "warnings: " .. table.concat(Mock.warnings, "; "))
end)

step("HUD shows cash, income and stats", function()
	player:SetAttribute("Cash", 12345)
	player:SetAttribute("Income", 42)
	player:SetAttribute("Carried", 2)
	player:SetAttribute("DataLoaded", true)
	Mock.advance(2)
	eq(findButton(hud, "📖 LOOT INDEX"):FindFirstChild("NewBadge").Visible, false, "saved discoveries don't count as new")
	check(findText(hud, "$12,345"), "cash label not updated")
	check(findText(hud, "+$42 / sec"), "income label not updated")
	check(findText(hud, "2 / 2"), "bag label not updated")
	check(findText(hud, "Bag full"), "objective should tell you the bag is full")
end)

step("notifications appear and fade away", function()
	Remotes.Notify.OnClientEvent:Fire("Stole a Toaster!", "steal")
	Mock.advance(0.1)
	check(findText(hud, "Stole a Toaster!"), "toast not shown")
	Mock.advance(6)
	check(not findText(hud, "Stole a Toaster!"), "toast never went away")
	for index = 1, 8 do
		Remotes.Notify.OnClientEvent:Fire("Spam " .. index, "info")
	end
	Mock.advance(0.1)
	check(not findText(hud, "Spam 1"), "oldest toast should be dropped when there are too many")
	check(findText(hud, "Spam 8"), "newest toast missing")
end)

step("alarm banner and objective react to being chased", function()
	player:SetAttribute("AlarmHouse", "Maple Cottage")
	Mock.advance(0.3)
	local banner = hud:FindFirstChild("AlarmBanner", true)
	eq(banner.Visible, true, "banner visible")
	check(findText(banner, "MAPLE COTTAGE"), "banner should name the house")
	check(findText(banner, "before the guards catch you"), "generic guard hint")
	player:SetAttribute("AlarmGuard", "the Ginger Cat")
	player:SetAttribute("AlarmHouse", "")
	Mock.advance(0.1)
	player:SetAttribute("AlarmHouse", "Maple Cottage")
	Mock.advance(0.1)
	check(findText(banner, "before the Ginger Cat catches you"), "the hint should name the cat")
	check(findText(hud, "Escape the property"), "objective should say escape")
	player:SetAttribute("AlarmHouse", "")
	Mock.advance(0.3)
	eq(banner.Visible, false, "banner hidden")
end)

step("busted screen", function()
	Remotes.Busted.OnClientEvent:Fire(3, 450, "Maple Cottage", "The Ginger Cat")
	Mock.advance(0.2)
	local busted = hud:FindFirstChild("Busted")
	eq(busted.Visible, true, "busted overlay shown")
	check(findText(busted, "3 items worth $450"), "busted text")
	check(findText(busted, "The Ginger Cat at the Maple Cottage caught you"), "busted text names the guard")
	Mock.advance(4)
	eq(busted.Visible, false, "busted overlay hidden again")
end)

step("shop opens from the HUD and buys upgrades", function()
	findButton(hud, "🛒 SHOP").Activated:Fire()
	Mock.advance(0.3)
	local shop = hud:FindFirstChild("Shop")
	eq(shop.Visible, true, "shop window open")
	check(findText(shop, "Loot Bag"), "bag card")
	check(findText(shop, "2 items  ➜  3 items"), "bag card shows the next level")
	check(findText(shop, "$150"), "bag price")
	local bagCard = shop:FindFirstChild("Bag", true)
	bagCard.Buy.Activated:Fire()
	Mock.advance(0.3)
	eq(purchases[1], "Bag", "purchase sent to the server")
	check(findText(hud, "Bought Bag"), "purchase result shown")
	player:SetAttribute("Level_Bag", 8)
	Mock.advance(0.1)
	eq(bagCard.Buy.Text, "MAXED", "maxed upgrade")
	shop.Close.Activated:Fire()
	Mock.advance(0.1)
	eq(shop.Visible, false, "shop closes")
	-- The shop counter prompt also opens it
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "OpenShopPrompt"
	Mock.service("ProximityPromptService").PromptTriggered:Fire(prompt, player)
	Mock.advance(0.1)
	eq(shop.Visible, true, "shop opens from the counter prompt")
end)

step("car button requests a car", function()
	findButton(hud, "🚗 CAR").Activated:Fire()
	Mock.advance(0.2)
	eq(carRequests, 1, "spawn request sent")
	check(findText(hud, "getaway car pulled up"), "spawn result shown")
end)

step("driving the car moves it and shows the speedometer", function()
	local car = Instance.new("Model")
	local chassis = Instance.new("Part")
	chassis.Name = "Chassis"
	chassis.CFrame = CFrame.new(0, 2, 0)
	chassis.Parent = car
	car.PrimaryPart = chassis
	car:SetAttribute("MaxSpeed", 45)
	local attachment = Instance.new("Attachment")
	attachment.Parent = chassis
	local drive = Instance.new("LinearVelocity")
	drive.Name = "Drive"
	drive.Attachment0 = attachment
	drive.Parent = chassis
	local orient = Instance.new("AlignOrientation")
	orient.Name = "Orient"
	orient.Attachment0 = attachment
	orient.Parent = chassis
	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriverSeat"
	seat.Parent = car
	car.Parent = workspace
	local character = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = character
	character.Parent = workspace
	player.Character = character
	Mock.setRaw(humanoid, "SeatPart", seat)
	Mock.setRaw(seat, "ThrottleFloat", 1)
	Mock.setRaw(seat, "SteerFloat", 0)
	Mock.advance(1)
	local forward = drive.VectorVelocity:Dot(chassis.CFrame.LookVector)
	check(forward > 20, "car should accelerate forward, speed " .. forward)
	eq(hud:FindFirstChild("Speedometer", true).Visible, true, "speedometer visible")
	Mock.setRaw(seat, "ThrottleFloat", 0)
	Mock.setRaw(seat, "SteerFloat", 1)
	local before = orient.CFrame.LookVector
	Mock.advance(0.5)
	check((orient.CFrame.LookVector - before).Magnitude > 0.05, "steering should turn the car")
	Mock.setRaw(humanoid, "SeatPart", nil)
	Mock.advance(0.2)
	eq(hud:FindFirstChild("Speedometer", true).Visible, false, "speedometer hidden after leaving")
end)

step("home marker points at your warehouse", function()
	player:SetAttribute("PlotIndex", 3)
	Mock.advance(0.5)
	local marker = Map.Warehouses.Plot3.Marker
	check(marker:FindFirstChild("HomeMarker"), "no YOUR WAREHOUSE marker")
end)

--------------------------------------------------------------------------------
-- Your treadmill
--------------------------------------------------------------------------------
local TreadmillController = require(ClientScript.TreadmillController)
local myTreadmill = Map.Warehouses.Plot3.Treadmill -- PlotIndex is 3 (set above)
local belt = myTreadmill.Belt
local character, humanoid, root, runAnimation

local function spawnRunner()
	character = Instance.new("Model")
	character.Name = "Tester"
	humanoid = Instance.new("Humanoid")
	humanoid.Parent = character
	local animator = Instance.new("Animator")
	animator.Parent = humanoid
	local animate = Instance.new("LocalScript")
	animate.Name = "Animate"
	animate.Parent = character
	local runFolder = Instance.new("StringValue")
	runFolder.Name = "run"
	runFolder.Parent = animate
	runAnimation = Instance.new("Animation")
	runAnimation.Name = "RunAnim"
	runAnimation.AnimationId = "rbxassetid://507767714"
	runAnimation.Parent = runFolder
	root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = myTreadmill.ExitPoint.CFrame
	root.Parent = character
	character.PrimaryPart = root
	character.Parent = workspace
	player.Character = character
	player.CharacterAdded:Fire(character)
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

step("your treadmill is signposted and every belt has stripes", function()
	local sign = belt:FindFirstChild("MyTreadmillSign")
	check(sign, "no YOUR TREADMILL sign over your treadmill")
	eq(sign.Enabled, true, "sign visible")
	check(Map.Warehouses.Plot1.Treadmill.Belt:FindFirstChild("MyTreadmillSign") == nil, "sign on someone else's treadmill")
	local stripes = 0
	for _, child in belt:GetChildren() do
		if child.Name == "BeltStripe" then
			stripes += 1
		end
	end
	check(stripes >= 7, "belt stripes missing")
end)

step("belts only scroll while their owner is running", function()
	local stripe = Map.Warehouses.Plot1.Treadmill.Belt:FindFirstChild("BeltStripe")
	local other = Map.Warehouses.Plot1.Treadmill
	Mock.advance(0.1)
	local resting = stripe.Position
	Mock.advance(0.5)
	check((stripe.Position - resting).Magnitude < 1e-6, "idle belt should not move")
	other:SetAttribute("Level", 4)
	other:SetAttribute("Running", true)
	Mock.advance(0.2)
	check((stripe.Position - resting).Magnitude > 0.01, "belt should scroll while someone runs on it")
	other:SetAttribute("Running", false)
end)

step("walking onto your treadmill makes you run by yourself", function()
	spawnRunner()
	Mock.advance(0.2)
	eq(TreadmillController.isRunning(), false, "standing beside it does nothing")
	root.CFrame = belt.CFrame + Vector3.new(0, 3, 2)
	Mock.advance(0.1)
	check(TreadmillController.isRunning(), "should start running when you walk onto the belt")
	eq(treadmillRequests[#treadmillRequests], "Start", "server told to start")
	eq(humanoid.AutoRotate, false, "auto-rotate off while running")
	eq(humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping), false, "no jumping on the treadmill")
	eq(controlsEnabled, false, "movement keys switched off (AFK-proof)")
	check(root:FindFirstChild("TreadmillHold"), "no hold constraint")
	Mock.advance(0.5)
	check(flatDistance(root.Position, myTreadmill.RunPoint.Position) < 0.1, "held in the middle of the belt")
	local facing = root.CFrame.LookVector:Dot(myTreadmill.RunPoint.CFrame.LookVector)
	check(facing > 0.99, "should face the console, dot " .. facing)

	local track = Mock.animationTracks[#Mock.animationTracks]
	check(track and track.IsPlaying, "run animation should play")
	eq(track.Animation, runAnimation, "uses the character's own run animation")
	eq(track.Priority, Enum.AnimationPriority.Action, "run animation priority")
	eq(track.Looped, true, "run animation loops")

	local escape = hud:FindFirstChild("TreadmillEscape", true)
	eq(escape.Visible, true, "ESCAPE button shown")
	check(findText(escape, "ESCAPE"), "escape label")
	check(findText(escape, "SPACE"), "Space key hint")
	local training = hud:FindFirstChild("Training", true)
	eq(training.Visible, true, "training bar shown")
	check(findText(training, "Speed 16 ➜ 17"), "training progress text")
	check(findText(training, "2 XP/s"), "training rate")
	check(findText(hud, "go AFK"), "objective should say AFK is fine")
	eq(belt.MyTreadmillSign.Enabled, false, "sign hidden while you run")

	-- Go AFK for a while: you keep running.
	Mock.advance(30)
	check(TreadmillController.isRunning(), "still running after 30 AFK seconds")
	eq(track.IsPlaying, true, "still animating")
	player:SetAttribute("Level_Treadmill", 4)
	Mock.advance(0.1)
	check(track.Speed > 1, "legs move faster on an upgraded treadmill")
	check(findText(training, "Lv 4"), "training bar shows the treadmill level")
end)

step("Space hops you off the treadmill", function()
	local track = Mock.animationTracks[#Mock.animationTracks]
	check(Mock.pressKey(Enum.KeyCode.Space), "Space isn't bound while running")
	Mock.advance(0.1)
	eq(TreadmillController.isRunning(), false, "Space should hop you off")
	eq(treadmillRequests[#treadmillRequests], "Stop", "server told to stop")
	check(root:FindFirstChild("TreadmillHold") == nil, "hold constraint removed")
	check(root:FindFirstChild("TreadmillAttachment") == nil, "attachment removed")
	eq(humanoid.AutoRotate, true, "auto-rotate restored")
	eq(humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping), true, "jumping restored")
	eq(controlsEnabled, true, "movement keys back on")
	eq(track.IsPlaying, false, "run animation stopped")
	check(flatDistance(root.Position, myTreadmill.ExitPoint.Position) < 0.1, "stepped off beside the treadmill")
	eq(hud:FindFirstChild("TreadmillEscape", true).Visible, false, "ESCAPE button hidden")
	eq(hud:FindFirstChild("Training", true).Visible, false, "training bar hidden")
	eq(belt.MyTreadmillSign.Enabled, true, "sign back")
	check(not Mock.pressKey(Enum.KeyCode.Space), "Space should jump normally again")
end)

step("walking back on starts you running again, and the ESCAPE button works", function()
	root.CFrame = belt.CFrame + Vector3.new(0, 3, 0)
	Mock.advance(0.1)
	eq(TreadmillController.isRunning(), false, "short cooldown right after hopping off")
	root.CFrame = myTreadmill.ExitPoint.CFrame
	Mock.advance(1)
	root.CFrame = belt.CFrame + Vector3.new(0, 3, -2)
	Mock.advance(0.1)
	check(TreadmillController.isRunning(), "should run again")
	hud:FindFirstChild("EscapeButton", true).Activated:Fire()
	Mock.advance(0.1)
	eq(TreadmillController.isRunning(), false, "ESCAPE button hops you off")
	check(Mock.pressKey(Enum.KeyCode.ButtonA) == false, "gamepad A is unbound again too")
end)

step("someone else's treadmill doesn't grab you", function()
	Mock.advance(1)
	local other = Map.Warehouses.Plot1.Treadmill
	root.CFrame = other.Belt.CFrame + Vector3.new(0, 3, 0)
	Mock.advance(0.2)
	eq(TreadmillController.isRunning(), false, "shouldn't run on another player's treadmill")
	check(findText(hud, "someone else's treadmill"), "no hint about whose treadmill it is")
	root.CFrame = myTreadmill.ExitPoint.CFrame
	Mock.advance(0.2)
end)

step("the server has the final say", function()
	-- The server ends your run (e.g. you were moved away): the client hops off too.
	root.CFrame = belt.CFrame + Vector3.new(0, 3, 0)
	Mock.advance(0.1)
	check(TreadmillController.isRunning(), "running")
	player:SetAttribute("Training", false)
	Mock.advance(0.1)
	eq(TreadmillController.isRunning(), false, "client follows the server stopping the run")
	eq(controlsEnabled, true, "controls restored")
	-- A rejected start hops you off and says why.
	root.CFrame = myTreadmill.ExitPoint.CFrame
	Mock.advance(1)
	serverAcceptsTreadmill = false
	root.CFrame = belt.CFrame + Vector3.new(0, 3, 0)
	Mock.advance(0.1)
	eq(TreadmillController.isRunning(), false, "rejected start")
	check(findText(hud, "Walk onto your treadmill"), "rejection reason shown")
	serverAcceptsTreadmill = true
	Mock.advance(1)
	eq(TreadmillController.isRunning(), false, "no retry loop while still standing on the belt")
	root.CFrame = myTreadmill.ExitPoint.CFrame
	Mock.advance(1)
end)

step("respawning while running resets everything", function()
	root.CFrame = belt.CFrame + Vector3.new(0, 3, 0)
	Mock.advance(0.1)
	check(TreadmillController.isRunning(), "running")
	local oldRoot = root
	spawnRunner()
	Mock.advance(0.1)
	eq(TreadmillController.isRunning(), false, "new character isn't stuck on the treadmill")
	eq(controlsEnabled, true, "controls enabled for the new character")
	check(oldRoot:FindFirstChild("TreadmillHold") == nil, "old hold cleaned up")
	root.CFrame = myTreadmill.ExitPoint.CFrame
	Mock.advance(0.2)
end)

step("sirens flash while a house alarm is active", function()
	local house = Map.Houses.House1
	local siren = house.Sirens:GetChildren()[1]
	local light = siren:FindFirstChildOfClass("PointLight")
	check(light, "siren light missing")
	house:SetAttribute("AlarmActive", true)
	local sawOn, sawOff = false, false
	for _ = 1, 10 do
		Mock.advance(0.25)
		if light.Enabled then
			sawOn = true
		else
			sawOff = true
		end
	end
	check(sawOn and sawOff, "siren should blink")
	house:SetAttribute("AlarmActive", false)
	Mock.advance(0.6)
	eq(light.Enabled, false, "siren off after the alarm")
end)

step("owner-only prompts are hidden from other players", function()
	local prompt = Instance.new("ProximityPrompt")
	prompt:SetAttribute("OwnerUserId", 999)
	Mock.service("ProximityPromptService").PromptShown:Fire(prompt)
	eq(prompt.Enabled, false, "someone else's sell prompt should be hidden")
	local mine = Instance.new("ProximityPrompt")
	mine:SetAttribute("OwnerUserId", 7)
	Mock.service("ProximityPromptService").PromptShown:Fire(mine)
	eq(mine.Enabled, true, "your own prompt stays visible")
end)

--------------------------------------------------------------------------------
-- Night & day
--------------------------------------------------------------------------------
step("the clock counts down the night and the sky fades to daytime", function()
	local clock = hud:FindFirstChild("Clock")
	check(clock, "no clock")
	check(findText(clock, "NIGHT"), "it starts at night")
	check(Lighting.ClockTime < 5 or Lighting.ClockTime > 19, "the sky should be dark at night, ClockTime " .. Lighting.ClockTime)
	local title = clock:FindFirstChild("Title")
	local minutes, seconds = string.match(title.Text, "(%d+):(%d%d)")
	check(minutes, "no countdown in " .. title.Text)
	local left = tonumber(minutes) * 60 + tonumber(seconds)
	local expected = workspace:GetAttribute("PhaseEndsAt") - workspace:GetServerTimeNow()
	check(math.abs(left - expected) <= 1.5, string.format("countdown %d vs %.1f", left, expected))

	player:SetAttribute("Carried", 0) -- (a full bag would take priority in the objective)
	player:SetAttribute("StoredCount", 3)
	workspace:SetAttribute("PhaseEndsAt", workspace:GetServerTimeNow() + 30)
	workspace:SetAttribute("Daytime", true)
	Mock.advance(0.2)
	check(findText(clock, "DAYTIME · 0:30") or findText(clock, "DAYTIME · 0:29"), "daytime countdown: " .. title.Text)
	check(findText(clock, "Houses closed"), "the clock says the houses are closed")
	check(findText(hud, "owners are home"), "the objective explains daytime")
	Mock.advance(Config.DayNight.FadeTime + 0.5)
	check(math.abs(Lighting.ClockTime - Config.DayNight.Day.ClockTime) < 0.01, "sunrise should end at the daytime ClockTime, got " .. Lighting.ClockTime)
	eq(Lighting.Brightness, Config.DayNight.Day.Brightness, "daytime brightness")

	-- Halfway through the sunset the sun is going down in the west (clock past 18:00), not rewinding.
	workspace:SetAttribute("PhaseEndsAt", workspace:GetServerTimeNow() + 210)
	workspace:SetAttribute("Daytime", false)
	Mock.advance(Config.DayNight.FadeTime / 2)
	check(Lighting.ClockTime > 16, "the clock should move forward into the evening, got " .. Lighting.ClockTime)
	Mock.advance(Config.DayNight.FadeTime)
	check(math.abs(Lighting.ClockTime - Config.DayNight.Night.ClockTime) < 0.01, "night ClockTime, got " .. Lighting.ClockTime)
	check(findText(clock, "NIGHT"), "night again")
end)

--------------------------------------------------------------------------------
-- Loot Index
--------------------------------------------------------------------------------
step("the loot index lists every item by house, locked until you steal it", function()
	local Items = require(SharedFolder.Items)
	local index = hud:FindFirstChild("LootIndex")
	check(index, "no LootIndex window")
	eq(index.Visible, false, "closed at first")
	findButton(hud, "📖 LOOT INDEX").Activated:Fire()
	Mock.advance(0.3)
	eq(index.Visible, true, "the HUD button opens it")
	local list = index:FindFirstChild("List")
	local sections = 0
	for _, child in list:GetChildren() do
		if child:IsA("Frame") then
			sections += 1
		end
	end
	eq(sections, #Config.Houses, "one section per house")
	check(findText(index, "MAPLE COTTAGE"), "house names are shown")
	check(findText(index, "guarded by a Ginger Cat"), "the guard is shown")
	check(findText(index, "guarded by 2 Pugs"), "dog houses show their breed")
	check(findText(index, string.format("1 / %d found", #Items.List)), "progress includes your saved discoveries")
	check(findText(list.House3, "1/4"), "Old Radio counts for Rose Cottage")
	local card = list.House1.Items.Toaster
	local picture = card:FindFirstChild("Picture")
	check(picture and picture:IsA("ViewportFrame"), "every card has a 3D picture")
	check(picture.CurrentCamera and picture.CurrentCamera.Parent == picture, "the picture has its own camera")
	check(picture:FindFirstChild("Toaster"), "the item model is in the picture")
	eq(card.ItemName.Text, "???", "locked items are hidden")
	eq(picture.ImageColor3, Color3.new(0, 0, 0), "locked items are silhouettes")
	-- Steal one (the server adds it to the Discovered attribute)
	player:SetAttribute("Discovered", "OldRadio,Toaster")
	Mock.advance(0.1)
	eq(card.ItemName.Text, "Toaster", "unlocked")
	eq(picture.ImageColor3, Color3.new(1, 1, 1), "unlocked items are in full colour")
	check(findText(card, "$25"), "unlocked items show their value")
	check(findText(index, string.format("2 / %d found", #Items.List)), "progress updated")
	check(findText(list.House1, "1/4"), "per-house progress")
	index.Close.Activated:Fire()
	Mock.advance(0.1)
	eq(index.Visible, false, "closes")
end)

step("new discoveries light up the index button until you look", function()
	local button = findButton(hud, "📖 LOOT INDEX")
	local badge = button:FindFirstChild("NewBadge")
	check(badge, "no badge")
	eq(badge.Visible, false, "nothing new yet")
	player:SetAttribute("Discovered", "OldRadio,Toaster,YarnBasket,CoffeeMaker,GrandmasJewels")
	Mock.advance(0.1)
	eq(badge.Visible, true, "badge shows new items")
	eq(badge.Text, "3", "three new items")
	button.Activated:Fire()
	Mock.advance(0.2)
	eq(badge.Visible, false, "opening the index clears the badge")
	check(findText(hud.LootIndex.List.House1, "✅ 4/4"), "a completed house is ticked off")
	-- The shop and the index never overlap
	findButton(hud, "🛒 SHOP").Activated:Fire()
	Mock.advance(0.2)
	eq(hud.LootIndex.Visible, false, "opening the shop closes the index")
	eq(hud.Shop.Visible, true, "shop open")
	hud.Shop.Close.Activated:Fire()
	Mock.advance(0.1)
end)

step("no warnings were logged", function()
	check(#Mock.warnings == 0, "warnings:\n  " .. table.concat(Mock.warnings, "\n  "))
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("client tests failed")
end
