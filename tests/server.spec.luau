--[[
	Integration test: runs the real server scripts (src/server + src/shared)
	inside the RobloxMock engine with the real generated map, then plays
	through the game loop:

	  join -> spawn at your warehouse -> pick a lock -> steal (and discover) ->
	  alarm -> get busted by the house cat -> steal again and escape -> deposit ->
	  earn income -> buy upgrades -> AFK-train on your own treadmill -> spawn the
	  car -> load the trunk -> unload at the dock -> manage storage (take / sell) ->
	  sell loot at the market stall -> daytime (houses lock, everyone is shown out,
	  loot restocks) -> night -> leave (save) -> rejoin (load)

	Run with:  python3 tools/run_luau_tests.py
	(the runner provides `Mock`, `ServerScript`, `SharedFolder` and the map)
]]

local Players = Mock.service("Players")
local ReplicatedStorage = Mock.service("ReplicatedStorage")
local Remotes = ReplicatedStorage.Remotes
local Map = workspace.Map
local Config = require(SharedFolder.Config)
local Items = require(SharedFolder.Items)

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

local function notificationsFor(player, since: number)
	local messages = {}
	for index = since + 1, #Mock.remoteLog do
		local entry = Mock.remoteLog[index]
		if entry.remote == "Notify" and entry.player == player then
			table.insert(messages, entry.args[1])
		end
	end
	return messages
end
local function sawMessage(player, since: number, fragment: string): boolean
	for _, message in notificationsFor(player, since) do
		if string.find(message, fragment, 1, true) then
			return true
		end
	end
	return false
end

local function sawBroadcast(since: number, fragment: string): boolean
	for index = since + 1, #Mock.remoteLog do
		local entry = Mock.remoteLog[index]
		if entry.remote == "Notify" and entry.player == "all" and string.find(entry.args[1], fragment, 1, true) then
			return true
		end
	end
	return false
end

local function newPlayer(userId: number, name: string)
	local player = Mock.newInstance("Player")
	Mock.setRaw(player, "Name", name)
	Mock.setRaw(player, "DisplayName", name)
	Mock.setRaw(player, "UserId", userId)
	player.Parent = Players
	Players.PlayerAdded:Fire(player)
	Mock.advance(0.1)
	return player
end

local function spawnCharacter(player, position: Vector3)
	local character = Mock.newInstance("Model")
	character.Name = player.Name
	local humanoid = Mock.newInstance("Humanoid")
	humanoid.Parent = character
	local root = Mock.newInstance("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = CFrame.new(position)
	root.Parent = character
	local torso = Mock.newInstance("Part")
	torso.Name = "UpperTorso"
	torso.Size = Vector3.new(2, 1.6, 1)
	torso.CFrame = CFrame.new(position + Vector3.new(0, 0.6, 0))
	torso.Parent = character
	character.PrimaryPart = root
	character.Parent = workspace
	player.Character = character
	player.CharacterAdded:Fire(character)
	return character, humanoid, root
end

local function moduleOf(name: string)
	return require(ServerScript[name])
end

--------------------------------------------------------------------------------
-- Boot the server
--------------------------------------------------------------------------------
step("server boots without errors or warnings", function()
	task.spawn(RunServer)
	Mock.advance(0.5)
	check(#Mock.warnings == 0, "warnings during boot:\n  " .. table.concat(Mock.warnings, "\n  "))
	local items = 0
	for _, house in Map.Houses:GetChildren() do
		local loot = house:FindFirstChild("Loot")
		check(loot, house.Name .. " has no Loot folder")
		items += #loot:GetChildren()
	end
	eq(items, 103, "loot spawned in houses")
	local kinds = { Cat = 0, Dog = 0, Drone = 0 }
	for _, house in Map.Houses:GetChildren() do
		local info = Config.getHouse(house.Name)
		check(info, house.Name .. " isn't in Config.Houses")
		local guardInfo = Config.Guards[info.Guard]
		for _, child in house:GetChildren() do
			if child.Name == "Guard" then
				local kind = child:GetAttribute("Kind")
				eq(kind, guardInfo.Kind, house.Name .. " guard kind")
				eq(child:GetAttribute("Breed"), guardInfo.DisplayName, house.Name .. " guard breed")
				kinds[kind] += 1
			end
		end
		-- Every house only ever spawns its own loot.
		for _, item in house.Loot:GetChildren() do
			local def = Items.get(item:GetAttribute("ItemId"))
			check(def and def.House == house.Name, tostring(item.Name) .. " spawned in the wrong house: " .. house.Name)
		end
	end
	eq(kinds.Cat, 4, "one cat in each of the 4 cottages")
	eq(kinds.Dog, 6 * 2, "two dogs in each of the 6 dog houses")
	eq(kinds.Drone, 4, "the Mansion keeps its 4 drones")
	eq(workspace:GetAttribute("Daytime"), false, "the game starts at night")
	local left = workspace:GetAttribute("PhaseEndsAt") - workspace:GetServerTimeNow()
	check(math.abs(left - Config.DayNight.NightLength) < 1, "night should last 3½ minutes, got " .. left)
end)

local thief = newPlayer(101, "Thief")
local character, humanoid, root = spawnCharacter(thief, Vector3.new(0, 5, 0))
local plot = Map.Warehouses.Plot1

step("player gets a warehouse, data and a spawn", function()
	Mock.advance(1)
	eq(thief:GetAttribute("PlotIndex"), 1, "PlotIndex")
	eq(thief:GetAttribute("DataLoaded"), true, "DataLoaded")
	eq(thief:GetAttribute("Cash"), 0, "Cash")
	eq(thief:GetAttribute("BagCapacity"), 2, "BagCapacity")
	eq(thief:GetAttribute("StorageCapacity"), 10, "StorageCapacity")
	eq(thief:GetAttribute("WalkSpeed"), 16, "WalkSpeed")
	eq(humanoid.WalkSpeed, 16, "humanoid walk speed")
	check(thief:FindFirstChild("leaderstats"), "leaderstats missing")
	eq(thief.RespawnLocation, plot.Spawn, "RespawnLocation")
	eq(plot:FindFirstChild("OwnerText", true).Text, "THIEF'S WAREHOUSE", "owner sign")
	-- spawned far away (origin) -> moved to the warehouse spawn by the safety net
	check((root.Position - plot.Spawn.Position).Magnitude < 10, "not moved to the plot spawn: " .. tostring(root.Position))
	check(sawMessage(thief, 0, "Welcome"), "no welcome message")
end)

local cottage = Map.Houses.House1 -- Maple Cottage, guarded by a ginger cat

step("pick the front door lock", function()
	local door = cottage.Doors:GetChildren()[1]
	local panel = door.Panel
	local before = panel.Position
	panel.LockpickPrompt.Triggered:Fire(thief)
	Mock.advance(1)
	check((panel.Position - before).Magnitude > 1, "door didn't swing open")
	eq(panel.LockpickPrompt.Enabled, false, "lockpick prompt disabled while open")
	-- The door swings outwards (toward the street side of the house)
	local outward = cottage.Zone.CFrame:PointToObjectSpace(panel.Position).Z
		- cottage.Zone.CFrame:PointToObjectSpace(before).Z
	check(outward > 0.5, "door should swing outward, moved " .. outward)
end)

local function stealFrom(house, player, rootPart)
	local item = house.Loot:GetChildren()[1]
	check(item, "no loot left in " .. house.Name)
	rootPart.CFrame = CFrame.new(item.Root.Position + Vector3.new(0, 2, 0))
	item.Root.StealPrompt.Triggered:Fire(player)
	return item
end

step("steal an item and trip the alarm", function()
	local mark = #Mock.remoteLog
	local item = stealFrom(cottage, thief, root)
	Mock.advance(0.1)
	eq(thief:GetAttribute("Carried"), 1, "Carried")
	eq(item.Parent, nil, "stolen item removed")
	eq(cottage:GetAttribute("AlarmActive"), true, "alarm")
	eq(thief:GetAttribute("AlarmHouse"), "Maple Cottage", "AlarmHouse banner")
	eq(thief:GetAttribute("AlarmGuard"), "the Ginger Cat", "the banner names the guard")
	check(character:FindFirstChild("LootSack"), "loot sack not shown")
	check(sawMessage(thief, mark, "Stole"), "no steal message")
	check(sawMessage(thief, mark, "Ginger Cat woke up"), "the alarm message should name the cat")
	eq(#cottage.Loot:GetChildren(), 5, "loot left")
	-- First time stealing this item: it's unlocked in the Loot Index
	local itemId = item:GetAttribute("ItemId")
	eq(thief:GetAttribute("Discovered"), itemId, "Discovered attribute")
	check(sawMessage(thief, mark, "New item discovered"), "no discovery toast")
	local cat = cottage:FindFirstChild("Guard")
	eq(cat.Root.Status.Icon.Text, "❗", "the cat wakes up")
end)

step("standing still gets you busted by the cat", function()
	local mark = #Mock.remoteLog
	local busted = nil
	local cat = cottage:FindFirstChild("Guard")
	local start = cat.Root.Position
	for _ = 1, 60 do
		Mock.advance(0.25)
		for index = mark + 1, #Mock.remoteLog do
			if Mock.remoteLog[index].remote == "Busted" then
				busted = Mock.remoteLog[index]
			end
		end
		if busted then
			break
		end
		-- Cats run along the floor; they never fly up to you like drones.
		check(cat.Root.Position.Y < start.Y + 1.5, "the cat left the ground: " .. tostring(cat.Root.Position))
	end
	check(busted, "the cat never caught the thief")
	eq(busted.args[3], "Maple Cottage", "busted at")
	eq(busted.args[4], "The Ginger Cat", "busted by")
	eq(thief:GetAttribute("Carried"), 0, "carried loot lost")
	eq(character:FindFirstChild("LootSack"), nil, "sack removed")
	Mock.advance(0.5)
	check((root.Position - plot.Spawn.Position).Magnitude < 10, "not teleported home after bust")
	eq(thief:GetAttribute("AlarmHouse"), "", "banner cleared")
end)

step("alarm calms down once the property is empty", function()
	Mock.advance(6)
	eq(cottage:GetAttribute("AlarmActive"), false, "alarm should reset")
end)

step("steal again and escape before the drone arrives", function()
	local mark = #Mock.remoteLog
	stealFrom(cottage, thief, root)
	Mock.advance(0.2)
	-- Run to the sidewalk (outside the lot) before the drone winds up
	root.CFrame = CFrame.new(cottage.Zone.Position.X, 3, -20)
	Mock.advance(1)
	eq(thief:GetAttribute("Carried"), 1, "still carrying the loot")
	eq(thief:GetAttribute("AlarmHouse"), "", "banner cleared after escaping")
	check(sawMessage(thief, mark, "escaped"), "no escape message")
	Mock.advance(6)
	eq(cottage:GetAttribute("AlarmActive"), false, "alarm resets after escape")
end)

step("deposit loot on the warehouse pad for passive income", function()
	local mark = #Mock.remoteLog
	root.CFrame = plot.DepositPad.CFrame + Vector3.new(0, 2, 0)
	plot.DepositPad.Touched:Fire(root)
	Mock.advance(0.1)
	eq(thief:GetAttribute("Carried"), 0, "bag emptied")
	eq(thief:GetAttribute("StoredCount"), 1, "stored")
	check((thief:GetAttribute("Income") or 0) >= 1, "income not set")
	eq(#plot.Display:GetChildren(), 1, "item shown on shelf")
	check(sawMessage(thief, mark, "Stashed"), "no stash message")
	check(string.find(plot:FindFirstChild("StatsText", true).Text, "1 / 10", 1, true), "stats board not updated")
	local cashBefore = thief:GetAttribute("Cash")
	Mock.advance(3.05)
	check(thief:GetAttribute("Cash") >= cashBefore + 3 * thief:GetAttribute("Income"), "income not paid")
end)

step("buy upgrades in the shop", function()
	local purchase = Remotes.Purchase.OnServerInvoke
	local result = purchase(thief, "Bag")
	eq(result.Ok, false, "should not afford the bag yet")
	eq(purchase(thief, "NotARealUpgrade").Ok, false, "unknown upgrade rejected")
	eq(purchase(thief, 42).Ok, false, "bad argument rejected")
	moduleOf("PlayerData").addCash(thief, 5000)
	Mock.advance(0.3)
	local cash = thief:GetAttribute("Cash")
	result = purchase(thief, "Bag")
	eq(result.Ok, true, "bag purchase: " .. tostring(result.Message))
	eq(thief:GetAttribute("BagCapacity"), 3, "bag capacity")
	eq(thief:GetAttribute("Cash"), cash - 150, "cash spent")
	Mock.advance(0.3)
	eq(purchase(thief, "Storage").Ok, true, "storage purchase")
	eq(thief:GetAttribute("StorageCapacity"), 15, "storage capacity")
	eq(plot.Slots.Slot15.Transparency, 0, "slot 15 unlocked")
	eq(plot.Slots.Slot16.Transparency > 0, true, "slot 16 still locked")
	Mock.advance(0.3)
	eq(purchase(thief, "Treadmill").Ok, true, "treadmill upgrade")
	eq(thief:GetAttribute("Level_Treadmill"), 2, "treadmill level")
	eq(purchase(thief, "Treadmill").Ok, false, "purchases are rate limited")
	Mock.advance(0.3)
	local treadmill = plot.Treadmill
	eq(treadmill:GetAttribute("Level"), 2, "treadmill shows its new level")
	check(string.find(treadmill.Console:FindFirstChild("TreadmillText", true).Text, "LV 2", 1, true), "console level")
	eq(treadmill.Console:FindFirstChild("TreadmillOwnerText", true).Text, "THIEF'S TREADMILL", "console owner")
	eq(treadmill.AccentBar.Color, Config.treadmillColor(2), "trim colour follows the level")
end)

local function speedToasts(player, since: number): number
	local count = 0
	for _, message in notificationsFor(player, since) do
		if string.find(message, "Speed up", 1, true) then
			count += 1
		end
	end
	return count
end

step("AFK training on your own treadmill", function()
	local mark = #Mock.remoteLog
	local treadmill = plot.Treadmill
	local request = Remotes.Treadmill.OnServerInvoke
	local console = treadmill.Console:FindFirstChild("TreadmillText", true)
	local session = moduleOf("PlayerData").get(thief)
	session.Profile.Levels.Treadmill = 1 -- back to a stock treadmill for the rate checks
	eq(treadmill:GetAttribute("OwnerUserId"), 101, "treadmill knows its owner")
	eq(treadmill:GetAttribute("Running"), false, "belt idle")
	eq(thief:GetAttribute("SpeedPoints"), 0, "no speed trained yet")
	eq(thief:GetAttribute("Speed"), 4, "Speed starts at a quarter of the 16 studs/s you walk at")
	eq(humanoid.WalkSpeed, 16, "walking at the Roblox default")

	-- You have to actually be on it.
	root.CFrame = CFrame.new(-140, 3, -40)
	Mock.advance(0.1)
	eq(request(thief, "Start").Ok, false, "can't start training from across town")
	check(thief:GetAttribute("Training") ~= true, "not training")
	eq(request(thief, "Fly").Ok, false, "unknown action rejected")

	-- Standing on the belt with no input at all (AFK) still trains you.
	root.CFrame = treadmill.RunPoint.CFrame
	root.AssemblyLinearVelocity = Vector3.zero
	local result = request(thief, "Start")
	eq(result.Ok, true, "start training: " .. tostring(result.Message))
	eq(thief:GetAttribute("Training"), true, "training attribute")
	eq(treadmill:GetAttribute("Running"), true, "belt runs while you train")
	eq(request(thief, "Start").Ok, true, "starting twice is harmless")
	Mock.advance(0.3)
	check(string.find(console.Text, "+1 speed / 4s", 1, true), "console shows the level 1 rate: " .. console.Text)

	-- Level 1 hands out one speed every 4 seconds: +1 Speed, which is +4 studs/s.
	Mock.advance(5)
	eq(thief:GetAttribute("Speed"), 5, "one speed after the first 4 seconds")
	eq(humanoid.WalkSpeed, 20, "and you really do move 4 studs/s faster")
	check(sawMessage(thief, mark, "Speed up"), "no speed-up message")
	Mock.advance(8)
	eq(thief:GetAttribute("Speed"), 7, "a speed point every 4 seconds (3 of them in 12 seconds)")
	eq(humanoid.WalkSpeed, 28, "walk speed is 4x the Speed stat")
	eq(thief:GetAttribute("Training"), true, "still training")

	-- Level 2 doubles the gain and halves the wait: four times the speed per second.
	moduleOf("PlayerData").addCash(thief, 5000)
	eq(Remotes.Purchase.OnServerInvoke(thief, "Treadmill").Ok, true, "treadmill upgrade")
	eq(thief:GetAttribute("Level_Treadmill"), 2, "treadmill level 2")
	Mock.advance(0.3)
	check(string.find(console.Text, "+2 speed / 2s", 1, true), "console rate for level 2: " .. console.Text)
	local before = thief:GetAttribute("Speed")
	Mock.advance(5)
	check(thief:GetAttribute("Speed") >= before + 4, "level 2 should train 4x faster than level 1")
	check(thief:GetAttribute("Speed") <= before + 6, "level 2 shouldn't be faster than that")

	-- A maxed treadmill pours speed on; the toasts get batched.
	session.Profile.Levels.Treadmill = #Config.UpgradesById.Treadmill.Values
	local burstMark = #Mock.remoteLog
	before = thief:GetAttribute("Speed")
	Mock.advance(3)
	check(thief:GetAttribute("Speed") >= before + 8000, "a maxed treadmill should pour on the speed")
	check(speedToasts(thief, burstMark) <= 2, "speed toasts should be batched, got " .. speedToasts(thief, burstMark))
	eq(thief:GetAttribute("SpeedMaxed"), nil, "there is no speed cap")
	session.Profile.Levels.Treadmill = 2
	Mock.advance(0.3)

	-- ESCAPE / Space sends "Stop".
	eq(request(thief, "Stop").Ok, true, "stop")
	eq(thief:GetAttribute("Training"), false, "stopped training")
	eq(treadmill:GetAttribute("Running"), false, "belt stops")
	local points = thief:GetAttribute("SpeedPoints")
	Mock.advance(2)
	eq(thief:GetAttribute("SpeedPoints"), points, "no speed after stopping")

	-- Wandering off (e.g. being moved) stops training after a short grace period.
	eq(request(thief, "Start").Ok, true, "start again")
	root.CFrame = treadmill.RunPoint.CFrame + Vector3.new(10, 0, 0)
	Mock.advance(1)
	eq(thief:GetAttribute("Training"), true, "brief grace period")
	Mock.advance(2)
	eq(thief:GetAttribute("Training"), false, "training stops when you leave the treadmill")
	check(sawMessage(thief, mark, "left your treadmill"), "no message about leaving")

	-- So does dying.
	root.CFrame = treadmill.RunPoint.CFrame
	eq(request(thief, "Start").Ok, true, "start once more")
	humanoid.Health = 0
	Mock.advance(0.5)
	eq(thief:GetAttribute("Training"), false, "dead players don't train")
	humanoid.Health = 100

	-- The console upgrades the treadmill itself.
	local prompt = treadmill.Console.UpgradeTreadmillPrompt
	eq(prompt:GetAttribute("OwnerUserId"), 101, "prompt is owner-only")
	eq(prompt.Enabled, true, "prompt enabled")
	check(string.find(prompt.ActionText, "$1,200", 1, true), "prompt shows the next price: " .. prompt.ActionText)
	moduleOf("PlayerData").addCash(thief, 2000)
	local upgradeMark = #Mock.remoteLog
	prompt.Triggered:Fire(thief)
	eq(thief:GetAttribute("Level_Treadmill"), 3, "console upgrade bought")
	check(sawMessage(thief, upgradeMark, "Treadmill upgraded to level 3"), "no upgrade message")
	eq(treadmill:GetAttribute("Level"), 3, "treadmill level 3")
	check(string.find(console.Text, "+4 speed / 1s", 1, true), "console rate for level 3: " .. console.Text)
end)

local car
step("spawn the getaway car, load the trunk and unload at the dock", function()
	root.CFrame = CFrame.new(-140, 3, -40) -- hub plaza
	Mock.advance(0.2)
	local result = Remotes.SpawnCar.OnServerInvoke(thief)
	eq(result.Ok, true, "spawn car: " .. tostring(result.Message))
	car = workspace.Cars:GetChildren()[1]
	check(car, "no car in Workspace.Cars")
	eq(car:GetAttribute("MaxSpeed"), 45, "engine speed")
	eq(Remotes.SpawnCar.OnServerInvoke(thief).Ok, false, "spawn cooldown")
	-- steal something from another cottage and load it into the trunk
	stealFrom(Map.Houses.House2, thief, root)
	Mock.advance(0.1)
	root.CFrame = CFrame.new(-140, 3, -40)
	Mock.advance(0.5)
	local trunkPrompt = car.Chassis.TrunkAttachment.TrunkPrompt
	eq(trunkPrompt:GetAttribute("OwnerUserId"), 101, "trunk prompt owner")
	trunkPrompt.Triggered:Fire(thief)
	eq(thief:GetAttribute("TrunkCount"), 1, "trunk count")
	eq(thief:GetAttribute("Carried"), 0, "carried after loading")
	-- drive into the loading dock
	local stored = thief:GetAttribute("StoredCount")
	car:PivotTo(plot.Dock.CFrame + Vector3.new(0, 1.2, 0))
	Mock.advance(1)
	eq(thief:GetAttribute("TrunkCount"), 0, "trunk unloaded at the dock")
	eq(thief:GetAttribute("StoredCount"), stored + 1, "unloaded loot stored")
end)

step("drive the car and upgrade the engine", function()
	local seat = car.DriverSeat
	seat.DrivePrompt.Triggered:Fire(thief)
	Mock.advance(0.1)
	eq(seat.Occupant, humanoid, "driver seated")
	eq(rawget(car.Chassis, "_networkOwner"), thief, "driver owns the car physics")
	moduleOf("PlayerData").addCash(thief, 2000)
	eq(Remotes.Purchase.OnServerInvoke(thief, "Engine").Ok, true, "engine purchase")
	eq(car:GetAttribute("MaxSpeed"), 55, "max speed updated while driving")
	humanoid.Sit = false
	Mock.advance(0.1)
	eq(seat.Occupant, nil, "driver left")
	eq(rawget(car.Chassis, "_networkOwner"), nil, "server owns the parked car")
	moduleOf("PlayerData").addCash(thief, 2000)
	Mock.advance(0.3)
	eq(Remotes.Purchase.OnServerInvoke(thief, "Engine").Ok, true, "second engine purchase")
	local rebuilt = workspace.Cars:GetChildren()[1]
	check(rebuilt ~= car, "car should be rebuilt with the new look")
	eq(rebuilt:GetAttribute("MaxSpeed"), 66, "rebuilt car speed")
	check(rebuilt:FindFirstChild("Spoiler"), "level 3 engine adds a spoiler")
	car = rebuilt
end)

local rival
step("a second player gets their own warehouse and can't touch yours", function()
	rival = newPlayer(202, "Rival")
	local _, _, rivalRoot = spawnCharacter(rival, Vector3.new(0, 5, 0))
	Mock.advance(1)
	eq(rival:GetAttribute("PlotIndex"), 2, "second plot")
	local mark = #Mock.remoteLog
	local shelfItem = plot.Display:GetChildren()[1]
	local shelfId = shelfItem:GetAttribute("ItemId")
	local cash = thief:GetAttribute("Cash")
	local prompt = shelfItem.Root:FindFirstChild("ShelfPrompt")
	check(prompt, "shelf items carry a storage prompt")
	eq(prompt:GetAttribute("OwnerUserId"), 101, "the storage prompt belongs to the owner")
	local rivalList = Remotes.Storage.OnServerInvoke(rival, "List")
	check(not table.find(rivalList.Items, shelfId), "the item isn't on the rival's shelves")
	eq(Remotes.Storage.OnServerInvoke(rival, "Sell", shelfId).Ok, false, "rival can't sell your items")
	eq(thief:GetAttribute("StoredCount"), 2, "rival can't sell your items")
	eq(thief:GetAttribute("Cash"), cash, "no cash change")
	car.Chassis.TrunkAttachment.TrunkPrompt.Triggered:Fire(rival)
	check(sawMessage(rival, mark, "Only Thief"), "rival used your trunk")
	stealFrom(Map.Houses.House3, rival, rivalRoot)
	Mock.advance(0.1)
	rivalRoot.CFrame = plot.DepositPad.CFrame + Vector3.new(0, 2, 0)
	plot.DepositPad.Touched:Fire(rivalRoot)
	eq(rival:GetAttribute("Carried"), 1, "rival can't deposit in your warehouse")
	check(sawMessage(rival, mark, "warehouse"), "no wrong-warehouse warning")

	-- Treadmills are personal too.
	local request = Remotes.Treadmill.OnServerInvoke
	rivalRoot.CFrame = plot.Treadmill.RunPoint.CFrame
	eq(request(rival, "Start").Ok, false, "rival can't train on your treadmill")
	local level = thief:GetAttribute("Level_Treadmill")
	plot.Treadmill.Console.UpgradeTreadmillPrompt.Triggered:Fire(rival)
	eq(thief:GetAttribute("Level_Treadmill"), level, "rival can't upgrade your treadmill")
	check(sawMessage(rival, mark, "not your treadmill"), "rival not told off at the console")
	local rivalTreadmill = Map.Warehouses.Plot2.Treadmill
	eq(rivalTreadmill:GetAttribute("OwnerUserId"), 202, "rival owns the plot 2 treadmill")
	eq(rivalTreadmill:GetAttribute("Level"), 1, "rival's treadmill starts at level 1")
	rivalRoot.CFrame = rivalTreadmill.RunPoint.CFrame
	eq(request(rival, "Start").Ok, true, "rival trains on their own treadmill")
	eq(rivalTreadmill:GetAttribute("Running"), true, "rival's belt runs")
	eq(plot.Treadmill:GetAttribute("Running"), false, "your belt doesn't")
	eq(request(rival, "Stop").Ok, true, "rival stops")
end)

step("take an item off a shelf and put it back in your bag", function()
	local before = thief:GetAttribute("StoredCount")
	local carried = thief:GetAttribute("Carried")
	local list = Remotes.Storage.OnServerInvoke(thief, "List")
	eq(#list.Items, before, "the storage list matches the shelves")
	local itemId = list.Items[1]
	local take = Remotes.Storage.OnServerInvoke(thief, "Take", itemId)
	eq(take.Ok, true, "take worked: " .. tostring(take.Message))
	eq(thief:GetAttribute("StoredCount"), before - 1, "shelf freed")
	eq(thief:GetAttribute("Carried"), carried + 1, "item is in the bag")
	local session = moduleOf("PlayerData").get(thief)
	check(table.find(session.Profile.Stored, itemId) == nil, "item left the shelves")
	check(table.find(session.Carried, itemId), "item is carried")
	eq(#take.Items, before - 1, "the window gets the new list back")
end)

step("a full bag stops you taking an item back", function()
	-- Fill the bag right up, then try to take another shelf item.
	local Inventory = moduleOf("Inventory")
	local capacity = thief:GetAttribute("BagCapacity")
	while Inventory.getCarriedCount(thief) < capacity do
		check(Inventory.addCarried(thief, "Toaster"), "the bag should take a filler item")
	end
	local list = Remotes.Storage.OnServerInvoke(thief, "List")
	local before = thief:GetAttribute("StoredCount")
	local take = Remotes.Storage.OnServerInvoke(thief, "Take", list.Items[1])
	eq(take.Ok, false, "a full bag can't take more")
	check(string.find(tostring(take.Message), "bag is full", 1, true), "the message should mention the bag")
	eq(thief:GetAttribute("StoredCount"), before, "nothing left the shelves")
	-- Empty the bag again for the steps that follow.
	Inventory.takeCarried(thief)
	Inventory.refresh(thief)
	eq(thief:GetAttribute("Carried"), 0, "bag emptied again")
end)

step("selling an item from your shelf pays cash", function()
	local before = thief:GetAttribute("StoredCount")
	local cash = thief:GetAttribute("Cash")
	local list = Remotes.Storage.OnServerInvoke(thief, "List")
	local itemId = list.Items[#list.Items]
	local sell = Remotes.Storage.OnServerInvoke(thief, "Sell", itemId)
	eq(sell.Ok, true, "sell worked: " .. tostring(sell.Message))
	Mock.advance(0.1)
	eq(thief:GetAttribute("StoredCount"), before - 1, "stored after selling")
	check(thief:GetAttribute("Cash") > cash, "no cash from selling")
	eq(Remotes.Storage.OnServerInvoke(thief, "Sell", itemId).Ok, false, "can't sell the same item twice")
end)

step("the sell point buys carried loot and frees the bag", function()
	local Sell = Map.SellPoint.SellCounter
	local prompt = Sell:FindFirstChild("OpenSellPrompt")
	check(prompt, "the trader's counter has a prompt")
	eq(prompt.ObjectText, "💰 SELL POINT", "the prompt names the stall")

	-- Carry some loot to the stall.
	local Inventory = moduleOf("Inventory")
	check(Inventory.addCarried(thief, "Toaster"), "the bag takes the toaster")
	check(Inventory.addCarried(thief, "DiamondNecklace"), "the bag takes the necklace")

	local listing = Remotes.Sell.OnServerInvoke(thief, "List")
	eq(listing.Ok, true, "listing worked")
	eq(#listing.Sales, 2, "both carried items are for sale")
	eq(listing.Sales[1].Source, "Bag", "carried loot comes from the bag")
	eq(listing.TrunkReady, false, "the car isn't at the stall yet")

	local cash = thief:GetAttribute("Cash")
	local expected = Items.getSellValue("Toaster") + Items.getSellValue("DiamondNecklace")
	local sale = Remotes.Sell.OnServerInvoke(thief, "Sell", "DiamondNecklace", "Bag")
	eq(sale.Ok, true, "selling one item worked: " .. tostring(sale.Message))
	eq(thief:GetAttribute("Cash"), cash + Items.getSellValue("DiamondNecklace"), "paid the item's value")
	eq(thief:GetAttribute("Carried"), 1, "the item left the bag")

	local all = Remotes.Sell.OnServerInvoke(thief, "All")
	eq(all.Ok, true, "selling the rest worked")
	eq(all.Count, 1, "one item left to sell")
	eq(thief:GetAttribute("Cash"), cash + expected, "the lot paid out")
	eq(thief:GetAttribute("Carried"), 0, "the bag is empty")
	eq(Remotes.Sell.OnServerInvoke(thief, "All").Ok, false, "nothing left to sell")
end)

step("the stall buys the trunk too, once the car is parked there", function()
	local session = moduleOf("PlayerData").get(thief)
	table.insert(session.Profile.Trunk, "RubyRing")
	moduleOf("Inventory").refresh(thief)

	-- The car is at the warehouse, far from the stall: the trunk isn't for sale yet.
	local away = Remotes.Sell.OnServerInvoke(thief, "List")
	eq(away.TrunkReady, false, "the trunk is out of reach")
	eq(#away.Sales, 0, "no trunk items while parked away")
	eq(Remotes.Sell.OnServerInvoke(thief, "Sell", "RubyRing", "Trunk").Ok, false, "can't sell a distant trunk")

	-- Park the car at the stall and try again.
	car.Chassis.CFrame = Map.SellPoint.SellCounter.CFrame * CFrame.new(0, 0, 16)
	local nearby = Remotes.Sell.OnServerInvoke(thief, "List")
	eq(nearby.TrunkReady, true, "the car is parked at the stall")
	eq(#nearby.Sales, 1, "the trunk item is listed")
	eq(nearby.Sales[1].Source, "Trunk", "it is listed as trunk loot")
	local cash = thief:GetAttribute("Cash")
	local sale = Remotes.Sell.OnServerInvoke(thief, "Sell", "RubyRing", "Trunk")
	eq(sale.Ok, true, "sold from the trunk: " .. tostring(sale.Message))
	eq(thief:GetAttribute("Cash"), cash + Items.getSellValue("RubyRing"), "trunk loot paid out")
	eq(thief:GetAttribute("TrunkCount"), 0, "the trunk is empty")
end)

step("full warehouse keeps your best items", function()
	local Plots = moduleOf("Plots")
	local capacity = thief:GetAttribute("StorageCapacity")
	local filler = {}
	for _ = 1, capacity do
		table.insert(filler, "Toaster")
	end
	Plots.deposit(thief, filler)
	eq(thief:GetAttribute("StoredCount"), capacity, "warehouse full")
	local cash = thief:GetAttribute("Cash")
	Plots.deposit(thief, { "GiantDiamond", "Toaster" })
	eq(thief:GetAttribute("StoredCount"), capacity, "still full")
	local session = moduleOf("PlayerData").get(thief)
	check(table.find(session.Profile.Stored, "GiantDiamond"), "diamond should replace a cheap item")
	eq(session.Profile.Stored[1], "GiantDiamond", "best item on the first shelf")
	check(thief:GetAttribute("Cash") >= cash + 50, "overflow should be sold")
	eq(#plot.Display:GetChildren(), capacity, "shelves show every item")
end)

step("lasers trip the alarm in the hardest houses", function()
	local villa = Map.Houses.House9 -- Pine Ridge House (German Shepherds)
	eq(villa:GetAttribute("AlarmActive"), false, "villa calm")
	local laser = villa.Lasers:GetChildren()[1]
	local tripped = false
	for _ = 1, 30 do
		Mock.advance(0.2)
		if laser.Transparency < 1 then
			root.CFrame = laser.CFrame
			laser.Touched:Fire(root)
			tripped = villa:GetAttribute("AlarmActive") == true
			break
		end
	end
	check(tripped, "laser didn't trip the alarm")
end)

step("stolen loot doesn't come back until daytime", function()
	local before = #cottage.Loot:GetChildren()
	check(before < 6, "the cottage should be missing some loot")
	Mock.advance(60, 0.5)
	eq(#cottage.Loot:GetChildren(), before, "no restocking at night")
	eq(workspace:GetAttribute("Daytime"), false, "still night")
end)

step("daytime: houses lock up, everyone is shown out and all loot restocks", function()
	-- Wait inside Maple Cottage with the front door open.
	local door = cottage.Doors:GetChildren()[1]
	if door.Panel.LockpickPrompt.Enabled then
		door.Panel.LockpickPrompt.Triggered:Fire(thief)
	end
	root.CFrame = CFrame.new(cottage.Zone.Position.X, 3.7, cottage.Zone.Position.Z)
	local carried = thief:GetAttribute("Carried")
	local mark = #Mock.remoteLog
	local left = workspace:GetAttribute("PhaseEndsAt") - workspace:GetServerTimeNow()
	Mock.advance(left + 0.5, 0.25)
	eq(workspace:GetAttribute("Daytime"), true, "daytime started on schedule")
	check(sawBroadcast(mark, "Daytime"), "everyone is told it's daytime")
	local endsIn = workspace:GetAttribute("PhaseEndsAt") - workspace:GetServerTimeNow()
	check(math.abs(endsIn - 30) < 1, "daytime lasts 30 seconds, got " .. endsIn)
	-- Shown the door
	local zone = cottage.Zone
	local relative = zone.CFrame:PointToObjectSpace(root.Position)
	check(math.abs(relative.Z) > zone.Size.Z / 2, "the thief should be outside the property, at " .. tostring(root.Position))
	check(sawMessage(thief, mark, "owners came home"), "no eviction message")
	eq(thief:GetAttribute("Carried"), carried, "you keep what you carried out")
	-- Locked up
	eq(door.Panel.LockpickPrompt.Enabled, false, "lockpicking is off during the day")
	door.Panel.LockpickPrompt.Triggered:Fire(thief)
	check(sawMessage(thief, mark, "owners are home"), "picking a lock in daylight should be refused")
	for _, house in Map.Houses:GetChildren() do
		local spots = #house.ItemSpots:GetChildren()
		eq(#house.Loot:GetChildren(), spots, house.Name .. " restocked")
		eq(house:GetAttribute("AlarmActive"), false, house.Name .. " alarm off")
		for _, item in house.Loot:GetChildren() do
			eq(item.Root.StealPrompt.Enabled, false, "nothing can be stolen in daylight")
		end
	end
	for _, laser in Map.Houses.House9.Lasers:GetChildren() do
		eq(laser.Transparency, 1, "lasers are off in daylight")
	end
	local item = cottage.Loot:GetChildren()[1]
	item.Root.StealPrompt.Triggered:Fire(thief)
	eq(thief:GetAttribute("Carried"), carried, "the server refuses daytime steals too")

	-- Night falls again: everything reopens
	mark = #Mock.remoteLog
	Mock.advance(Config.DayNight.DayLength + 0.5, 0.25)
	eq(workspace:GetAttribute("Daytime"), false, "night again after 30 seconds")
	check(sawBroadcast(mark, "Night falls"), "everyone is told it's night")
	eq(door.Panel.LockpickPrompt.Enabled, true, "doors can be picked again")
	eq(item.Root.StealPrompt.Enabled, true, "loot can be stolen again")
	eq(#cottage.Loot:GetChildren(), 6, "still fully stocked")
end)

step("progress saves on leave and loads on rejoin", function()
	root.CFrame = CFrame.new(-140, 3, -40)
	Mock.advance(8)
	local session = moduleOf("PlayerData").get(thief)
	local stored = table.clone(session.Profile.Stored)
	local cash = session.Profile.Cash
	thief.Parent = nil
	Players.PlayerRemoving:Fire(thief)
	Mock.advance(0.5)
	local saved = Mock.dataStores.StealAnItem_PlayerData_v1.Player_101
	check(saved, "nothing saved")
	eq(#saved.Stored, #stored, "saved stored items")
	eq(saved.Levels.Bag, 2, "saved bag level")
	eq(saved.Levels.Engine, 3, "saved engine level")
	eq(saved.Levels.Treadmill, 3, "saved treadmill level")
	check(type(saved.SpeedPoints) == "number" and saved.SpeedPoints > 0, "trained speed is saved")
	check(type(saved.Discovered) == "table" and #saved.Discovered >= 2, "the Loot Index is saved")
	eq(plot:FindFirstChild("OwnerText", true).Text, "EMPTY WAREHOUSE", "plot released")
	eq(#plot.Display:GetChildren(), 0, "shelves cleared")
	eq(#workspace.Cars:GetChildren(), 0, "car removed")
	Mock.advance(0.3)
	eq(plot.Treadmill:GetAttribute("OwnerUserId"), 0, "treadmill released")
	eq(plot.Treadmill.Console:FindFirstChild("TreadmillText", true).Text, "EMPTY", "treadmill console reset")
	eq(plot.Treadmill.Console.UpgradeTreadmillPrompt.Enabled, false, "no upgrades on an empty treadmill")

	local returning = newPlayer(101, "Thief")
	spawnCharacter(returning, Vector3.new(0, 5, 0))
	Mock.advance(1)
	eq(returning:GetAttribute("PlotIndex"), 1, "gets a free plot again")
	eq(returning:GetAttribute("StoredCount"), #stored, "stored items restored")
	eq(returning:GetAttribute("Level_Bag"), 2, "upgrade restored")
	check(returning:GetAttribute("Cash") >= cash, "cash restored")
	eq(#plot.Display:GetChildren(), #stored, "shelves rebuilt")
	check(returning:GetAttribute("SpeedPoints") >= 1, "trained speed restored")
	check(returning:GetAttribute("Speed") >= 5, "Speed stat restored")
	eq(returning:GetAttribute("WalkSpeed"), 4 * returning:GetAttribute("Speed"), "walk speed is 4x the Speed stat")
	eq(returning:GetAttribute("Level_Treadmill"), 3, "treadmill level restored")
	local discovered = string.split(returning:GetAttribute("Discovered"), ",")
	eq(#discovered, #saved.Discovered, "Loot Index restored")
	Mock.advance(0.3)
	eq(plot.Treadmill:GetAttribute("Level"), 3, "treadmill shows the restored level")
end)

step("old saves with gym treadmill unlocks become treadmill levels", function()
	local store = Mock.dataStores.StealAnItem_PlayerData_v1
	store.Player_303 = { Cash = 10, Levels = { Bag = 2, ProTreadmill = 2, EliteTreadmill = 2 }, Stored = { "Toaster", "Laptop" } }
	store.Player_404 = { Cash = 10, Levels = { ProTreadmill = 2, EliteTreadmill = 1 } }
	store.Player_505 = { Cash = 10, SpeedLevel = 8, SpeedXP = 3 }
	local elite = newPlayer(303, "EliteRunner")
	local pro = newPlayer(404, "ProRunner")
	Mock.advance(0.5)
	eq(elite:GetAttribute("Level_Treadmill"), 6, "elite unlock -> treadmill level 6")
	eq(elite:GetAttribute("Level_Bag"), 2, "other upgrades kept")
	eq(elite:GetAttribute("Discovered"), "Toaster,Laptop", "items you already own count as discovered")
	eq(pro:GetAttribute("Level_Treadmill"), 3, "pro unlock -> treadmill level 3")

	-- Speed used to be saved as whole levels worth +1 walk speed each: an old save
	-- with 8 levels must come back at exactly the same walk speed (16 + 8 = 24).
	local legacy = newPlayer(505, "LegacyRunner")
	Mock.advance(0.5)
	eq(legacy:GetAttribute("SpeedPoints"), 2, "8 old speed levels -> 2 speed points")
	eq(legacy:GetAttribute("Speed"), 6, "which is Speed 6 at a quarter of the speed")
	eq(legacy:GetAttribute("WalkSpeed"), 24, "and the same walk speed they had before")

	for _, player in { elite, pro, legacy } do
		player.Parent = nil
		Players.PlayerRemoving:Fire(player)
	end
	Mock.advance(0.5)
end)

step("no warnings were logged", function()
	check(#Mock.warnings == 0, "warnings:\n  " .. table.concat(Mock.warnings, "\n  "))
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("integration tests failed")
end
