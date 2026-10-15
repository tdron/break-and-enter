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
	Level_ProTreadmill = 1,
	Level_EliteTreadmill = 1,
	AlarmHouse = "",
	Training = "",
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
	check(findText(hud, "Escape the property"), "objective should say escape")
	player:SetAttribute("AlarmHouse", "")
	Mock.advance(0.3)
	eq(banner.Visible, false, "banner hidden")
end)

step("busted screen", function()
	Remotes.Busted.OnClientEvent:Fire(3, 450, "Maple Cottage")
	Mock.advance(0.2)
	local busted = hud:FindFirstChild("Busted")
	eq(busted.Visible, true, "busted overlay shown")
	check(findText(busted, "3 items worth $450"), "busted text")
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

step("training bar", function()
	player:SetAttribute("Training", "Basic Treadmill")
	player:SetAttribute("SpeedXP", 4)
	Mock.advance(0.3)
	local training = hud:FindFirstChild("Training", true)
	eq(training.Visible, true, "training bar shown")
	check(findText(training, "Speed 16 ➜ 17"), "training text")
	player:SetAttribute("Training", "")
	Mock.advance(0.1)
	eq(training.Visible, false, "training bar hidden")
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

step("treadmill labels show lock state", function()
	local pro = Map.Gym.Treadmills.ProTreadmill.Belt
	local label = pro.TreadmillLabel:FindFirstChildOfClass("TextLabel")
	check(string.find(label.Text, "Unlock in Shop", 1, true), "pro treadmill should look locked")
	player:SetAttribute("Level_ProTreadmill", 2)
	Mock.advance(0.1)
	check(string.find(label.Text, "XP / sec", 1, true), "pro treadmill should look unlocked")
	check(#pro:GetChildren() >= 7, "belt stripes missing")
end)

step("sirens flash while a house alarm is active", function()
	local house = Map.Houses.Cottage1
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

step("no warnings were logged", function()
	check(#Mock.warnings == 0, "warnings:\n  " .. table.concat(Mock.warnings, "\n  "))
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("client tests failed")
end
