--[[
	Integration test: runs the real server scripts (src/server + src/shared)
	inside the RobloxMock engine with the real generated map, then plays
	through the game loop:

	  join -> spawn at your warehouse -> pick a lock -> steal (and discover) ->
	  alarm -> get busted by the house cat -> steal again and escape -> deposit ->
	  earn income -> buy upgrades -> AFK-train on your own treadmill -> spawn the
	  manage storage (take / sell) -> sell at the stall -> save/reload ->
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
	-- A tiny articulated limb makes the integration catch test exercise the real Motor6D ->
	-- BallSocket ragdoll conversion, not just Humanoid.PlatformStand.
	local arm = Mock.newInstance("Part")
	arm.Name = "LeftArm"
	arm.Size = Vector3.new(0.5, 1.4, 0.5)
	arm.CFrame = CFrame.new(position + Vector3.new(-1.2, 0.5, 0))
	arm.Parent = character
	local shoulder = Mock.newInstance("Motor6D")
	shoulder.Name = "LeftShoulder"
	shoulder.Part0 = torso
	shoulder.Part1 = arm
	shoulder.C0 = CFrame.new()
	shoulder.C1 = CFrame.new()
	shoulder.Enabled = true
	shoulder.Parent = torso
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
	eq(items, 55, "loot spawned in houses (five per house, however big they get)")
	local kinds = {}
	local total = 0
	for _, house in Map.Houses:GetChildren() do
		local info = Config.getHouse(house.Name)
		check(info, house.Name .. " isn't in Config.Houses")
		local guardInfo = Config.Guards[info.Guard]
		local found = 0
		for _, child in house:GetChildren() do
			if child.Name == "Guard" then
				found += 1
				total += 1
				local kind = child:GetAttribute("Kind")
				eq(kind, guardInfo.Kind, house.Name .. " guard kind")
				eq(child:GetAttribute("Breed"), guardInfo.DisplayName, house.Name .. " guard breed")
				kinds[kind] = (kinds[kind] or 0) + 1
			end
		end
		eq(found, info.GuardCount or 1, house.Name .. " defender count")
		-- Every house only ever spawns its own loot.
		for _, item in house.Loot:GetChildren() do
			local def = Items.get(item:GetAttribute("ItemId"))
			check(def and def.House == house.Name, tostring(item.Name) .. " spawned in the wrong house: " .. house.Name)
		end
	end
	eq(total, 16, "one defender for eight houses, three bots in house 9, one car in house 10, a fleet of four at the Mansion")
	eq(kinds.Cat, 1, "the tuxedo cat guards Maple Cottage")
	eq(kinds.Dog, 3, "a puppy, a labrador and a guard dog")
	eq(kinds.Human, 2, "the home owner and the off-duty officer")
	eq(kinds.Wizard, 1, "a wizard on Elm Street")
	eq(kinds.Beast, 1, "a T-Rex in Birch House")
	eq(kinds.Robot, 3, "three security bots in Pine Ridge House")
	eq(kinds.Vehicle, 5, "a security car in Aspen House and four parked outside the museum")
	eq(workspace:GetAttribute("Daytime"), false, "the game starts at night")
	local left = workspace:GetAttribute("PhaseEndsAt") - workspace:GetServerTimeNow()
	check(math.abs(left - Config.DayNight.NightLength) < 1, "night should last 5 minutes, got " .. left)
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
	eq(thief:GetAttribute("WalkSpeed"), nil, "true walk speed is not replicated")
	eq(humanoid.WalkSpeed, 16, "humanoid walk speed")
	check(thief:FindFirstChild("leaderstats"), "leaderstats missing")
	eq(thief.RespawnLocation, plot.Spawn, "RespawnLocation")
	eq(plot:FindFirstChild("OwnerText", true).Text, "THIEF'S WAREHOUSE", "owner sign")
	-- spawned far away (origin) -> moved to the warehouse spawn by the safety net
	check((root.Position - plot.Spawn.Position).Magnitude < 10, "not moved to the plot spawn: " .. tostring(root.Position))
	check(sawMessage(thief, 0, "Welcome"), "no welcome message")
end)

local cottage = Map.Houses.House1 -- Maple Cottage, guarded by a ginger cat

-- Every house stands on the same 0.5-stud foundation, so the floor inside one is always at this
-- height: it is where a thief - and the guard that comes after them - walks.
local HOUSE_FLOOR = 0.7
local firstStolenItemId: string? = nil
local firstStolenSpot: Vector3? = nil

local function itemAt(house, itemId: string, position: Vector3)
	for _, item in house.Loot:GetChildren() do
		local rootPart = item:FindFirstChild("Root")
		if item:GetAttribute("ItemId") == itemId and rootPart and rootPart:IsA("BasePart")
			and (rootPart.Position - position).Magnitude < 0.05 then
			return item
		end
	end
	return nil
end

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
	-- Stand beside it on the floor, which is where a thief is when the alarm goes off. (The item
	-- itself sits on a table, and a guard with a body cannot walk into a table any more.)
	local spot = item.Root.Position
	rootPart.CFrame = CFrame.new(spot.X + 2, HOUSE_FLOOR + 3, spot.Z)
	item.Root.StealPrompt.Triggered:Fire(player)
	return item
end

step("steal an item and trip the alarm", function()
	local mark = #Mock.remoteLog
	local item = cottage.Loot:GetChildren()[1]
	firstStolenItemId = item:GetAttribute("ItemId")
	firstStolenSpot = item.Root.Position
	stealFrom(cottage, thief, root)
	Mock.advance(0.1)
	eq(thief:GetAttribute("Carried"), 1, "Carried")
	eq(item.Parent, nil, "stolen item removed")
	eq(cottage:GetAttribute("AlarmActive"), true, "alarm")
	eq(thief:GetAttribute("AlarmHouse"), "Maple Cottage", "AlarmHouse banner")
	eq(thief:GetAttribute("AlarmGuard"), "the Tuxedo Cat", "the banner names the guard")
	eq(thief:GetAttribute("AlarmSpeed"), nil, "the guard's true speed is not replicated")
	eq(thief:GetAttribute("InHouse"), true, "the thief is inside a house")
	eq(humanoid.WalkSpeed, Config.Alarm.InsideSpeed, "where everyone moves at the standard Roblox speed")
	check(character:FindFirstChild("LootSack"), "loot sack not shown")
	check(sawMessage(thief, mark, "Stole"), "no steal message")
	check(sawMessage(thief, mark, "Tuxedo Cat woke up"), "the alarm message should name the cat")
	check(sawMessage(thief, mark, "before it reaches full speed"), "the alarm warns about the gate without revealing studs/s")
	eq(#cottage.Loot:GetChildren(), 4, "loot left")
	-- First time stealing this item: it's unlocked in the Loot Index
	local itemId = item:GetAttribute("ItemId")
	eq(thief:GetAttribute("Discovered"), itemId, "Discovered attribute")
	check(sawMessage(thief, mark, "New item discovered"), "no discovery toast")
	local cat = cottage:FindFirstChild("Guard")
	eq(cat.Root.Status.Icon.Text, "❗", "the cat wakes up")
end)

step("an indoor catch ragdolls you through the door and restores the exact loot spot", function()
	local mark = #Mock.remoteLog
	local sounds = Mock.soundsPlayed
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
	eq(busted.args[4], "The Tuxedo Cat", "busted by")
	eq(busted.args[5], "door", "indoor catch outcome")
	eq(thief:GetAttribute("Carried"), 0, "bag emptied by the catcher")
	eq(character:FindFirstChild("LootSack"), nil, "sack removed")
	check(humanoid.PlatformStand, "the indoor bust should ragdoll the thief")
	check(character:GetAttribute("Ragdolled"), "the character advertises its ragdoll state")
	check(character:FindFirstChild("BustRagdollJoint", true), "the ragdoll should replace body motors with ball sockets")
	check(firstStolenItemId and firstStolenSpot, "the theft origin was not recorded")
	check(itemAt(cottage, firstStolenItemId :: string, firstStolenSpot :: Vector3), "stolen item did not return to its original marker")
	eq(#cottage.Loot:GetChildren(), 5, "the caught item is returned immediately inside")
	Mock.advance(0.5)
	-- The launch starts at the actual front door, never at the warehouse spawn.
	check((root.Position - cottage.Route.Door.Position).Magnitude < 6, "not placed at the front door for ejection")
	check((root.Position - plot.Spawn.Position).Magnitude > 20, "the old warehouse teleport must be gone")
	check(root.AssemblyLinearVelocity.Z > 0, "House1's indoor launch should head toward the road")
	local door = cottage.Doors:GetChildren()[1]
	eq(door.OpenAngle.Value, 0, "the front door slams shut after the ejection")
	check(door.Panel:FindFirstChild("SlamSound"), "the slammed door needs a replicated sound")
	check(Mock.soundsPlayed > sounds, "the slam should play a sound")
	eq(thief:GetAttribute("AlarmHouse"), "", "banner cleared")
end)

step("alarm calms down once the property is empty", function()
	Mock.advance(6)
	eq(cottage:GetAttribute("AlarmActive"), false, "alarm should reset")
end)

step("a road catch sends the guard home carrying loot before it restores the source spot", function()
	-- Let the first catcher settle fully at its post before beginning a second theft.
	Mock.advance(20)
	local Houses = moduleOf("Houses")
	local cat = cottage:FindFirstChild("Guard")
	local home = cat.Root.AlignPosition.Position
	check((cat.Root.Position - home).Magnitude < 8, "the cat did not return home before the road catch")

	local item = cottage.Loot:GetChildren()[1]
	local itemId = item:GetAttribute("ItemId")
	local origin = item.Root.Position
	stealFrom(cottage, thief, root)
	local mark = #Mock.remoteLog
	-- Get well down the road while the cat finds its way through the building, so it cannot make a
	-- second indoor catch before crossing the gate.
	local street = cottage.Route.Street.Position + Vector3.new(0, 3, 0)
	root.CFrame = CFrame.new(street + Vector3.new(-70, 0, 0))
	local reachedRoad = false
	for _ = 1, 120 do
		Mock.advance(0.5)
		if not Houses.isOnProperty(cat.Root.Position) then
			reachedRoad = true
			break
		end
	end
	check(reachedRoad, "the cat never reached the road to make an outdoor catch")
	root.CFrame = CFrame.new(street)

	local busted = nil
	for _ = 1, 160 do
		Mock.advance(0.25)
		for index = mark + 1, #Mock.remoteLog do
			if Mock.remoteLog[index].remote == "Busted" then
				busted = Mock.remoteLog[index]
			end
		end
		if busted then
			break
		end
	end
	check(busted, "the cat never caught the thief on the road")
	eq(busted.args[5], "road", "road catch outcome")
	eq(thief:GetAttribute("Carried"), 0, "the road catcher took the bag")
	check(humanoid.PlatformStand, "the road catch should ragdoll the thief")
	check(character:GetAttribute("Ragdolled"), "road catch sets the ragdoll state")
	check(cat:FindFirstChild("RecoveredLoot", true), "the catcher should visibly carry the recovered loot")
	check(not itemAt(cottage, itemId, origin), "the item should travel home with the catcher before restoring")

	local beforeReturn = (cat.Root.Position - home).Magnitude
	Mock.advance(4)
	check((cat.Root.Position - home).Magnitude < beforeReturn, "the catcher should retreat toward its own house")

	local restored = false
	for _ = 1, 80 do
		Mock.advance(1)
		if itemAt(cottage, itemId, origin) and not cat:FindFirstChild("RecoveredLoot", true) then
			restored = true
			break
		end
	end
	check(restored, "the road catch did not return the exact stolen item to its original spot")
	check((root.Position - plot.Spawn.Position).Magnitude > 20, "a road bust must not teleport to the warehouse")
end)

step("they chase you out of the house and all the way back down the street", function()
	local mark = #Mock.remoteLog
	local PlayerData = moduleOf("PlayerData")
	-- Train a pile of speed first: inside a house it must not matter one bit.
	PlayerData.addSpeed(thief, 5000)
	Mock.advance(0.2)
	local realSpeed = humanoid.WalkSpeed
	check(realSpeed > 1000, "training should have made you quick, got " .. tostring(realSpeed))
	eq(thief:GetAttribute("WalkSpeed"), nil, "training must not expose true walk speed")

	-- Let anything from the last step get home first, so "its post" is where the cat sleeps.
	Mock.advance(30)
	local cat = cottage:FindFirstChild("Guard")
	local post = cat.Root.AlignPosition.Position
	check((cat.Root.Position - post).Magnitude < 8, "the cat should be asleep at its post, at " .. tostring(cat.Root.Position))

	stealFrom(cottage, thief, root)
	Mock.advance(0.2)
	eq(thief:GetAttribute("InHouse"), true, "the thief is in the house")
	eq(humanoid.WalkSpeed, Config.Alarm.InsideSpeed, "inside everyone moves at the standard Roblox speed")
	eq(thief:GetAttribute("AlarmGuard"), "the Tuxedo Cat", "the cat is awake")

	-- Step outside to the street: the chase follows you, and outside the real speeds apply.
	root.CFrame = CFrame.new(cottage.Zone.Position.X, 3, -12)
	Mock.advance(Config.HouseTiers[1].AlarmWindup + 0.3)
	eq(humanoid.WalkSpeed, realSpeed, "your real speed applies again outside")
	eq(thief:GetAttribute("InHouse"), false, "off the property")
	eq(thief:GetAttribute("AlarmHouse"), "Maple Cottage", "they do NOT give up at the property line")
	-- It is out in the yard by now, but still on the property, so still at the standard speed.
	eq(cat.Root.AlignPosition.MaxVelocity, Config.Alarm.InsideSpeed, "on the property it still moves at the standard speed")

	-- The gate is where the property ends: the street is not "on property" any more, and that
	-- is what hands the defender its real speed back (a guard post is still on the property).
	local Houses = moduleOf("Houses")
	check(not Houses.isOnProperty(Vector3.new(0, 3, -12)), "the street is outside the properties")
	check(Houses.isOnProperty(post), "a defender's post is on the property")

	-- The cat has a body and a house to get out of: it has to walk out of the room it sleeps in,
	-- down the hall and through the front door - the same door you walked out of - before it can
	-- come after you at all. You keep running the whole time, so it never quite catches you.
	-- You wait on the street, a long way off, while it finds its way out of the house; then the
	-- two of you play cat and mouse down the street, you keeping one step ahead of it.
	root.CFrame = CFrame.new(-40, 3, -12)
	local outside = nil
	for _ = 1, 40 do
		Mock.advance(0.5)
		local p = cat.Root.Position
		check(p.Y < 8, "the cat left the ground: " .. tostring(p))
		if p.Z > -26 then
			outside = p
			break
		end
	end
	check(outside, "the cat should have come out of the house and through the gate by now, at " .. tostring(cat.Root.Position))

	local onStreet = false
	local chasedTo = nil
	local legs = {}
	for _, part in cat:GetDescendants() do
		if part:IsA("Motor6D") and string.sub(part.Name, 1, 3) == "Leg" then
			table.insert(legs, part)
		end
	end
	check(#legs >= 2, "the cat should have legs to walk on, found " .. #legs)
	local stepped = false
	for hop = 1, 12 do
		local before = cat.Root.Position.X
		local poseBefore = legs[1].C0._r[5]
		root.CFrame = CFrame.new(-40 - hop * 8, 3, -12)
		Mock.advance(1)
		stepped = stepped or legs[1].C0._r[5] ~= poseBefore
		local p = cat.Root.Position
		check(p.X < before - 1, string.format("the cat should have closed on you at hop %d: %.1f -> %.1f", hop, before, p.X))
		eq(thief:GetAttribute("AlarmHouse"), "Maple Cottage", "still coming for you, hop " .. hop)
		local onProperty = Houses.isOnProperty(p)
		onStreet = onStreet or not onProperty
		local expected = if onProperty then Config.Alarm.InsideSpeed else Config.Guards.TuxedoCat.Speed
		eq(cat.Root.AlignPosition.MaxVelocity, expected, "the cat moves at the speed its ground allows")
		chasedTo = p.X
	end
	check(stepped, "the cat's legs should have moved while it was running after you")
	check(onStreet, "the cat should have been out on the street at some point, not just round the yards")
	check(chasedTo < -60, "the cat should have been well down the street by now, at " .. tostring(chasedTo))

	-- Through the canyon mouth and into the yard: the chase is over.
	root.CFrame = CFrame.new(-230, 3, -12)
	Mock.advance(0.6)

	-- Back to an untrained thief for the rest of the spec (before the asserts below, so a
	-- failure there can never leak a trained thief into the treadmill step).
	PlayerData.get(thief).Profile.SpeedPoints = 0
	PlayerData.replicate(thief)
	PlayerData.applyWalkSpeed(thief)
	Mock.advance(0.2)

	eq(thief:GetAttribute("SpeedPoints"), 0, "and no trained speed on the books")
	eq(humanoid.WalkSpeed, 16, "back to the standard walking speed")
	eq(thief:GetAttribute("Carried"), 1, "you keep the loot once you are back in the yard")
	eq(thief:GetAttribute("AlarmHouse"), "", "banner cleared in the yard")
	check(sawMessage(thief, mark, "escaped"), "no escape message")

	-- It gives up (a few seconds after you are out of reach) and walks home, rather than blinking
	-- back through the walls it walked round to get to you.
	Mock.advance(Config.Alarm.CalmDownTime + 1)
	eq(cottage:GetAttribute("AlarmActive"), false, "the alarm resets once you are safe")
	local turnedAt = cat.Root.Position.X
	Mock.advance(4)
	check(cat.Root.Position.X > turnedAt + 1, "the cat should have turned for home, at " .. tostring(cat.Root.Position))
	check(chasedTo < turnedAt + 1, "the cat was down the street at " .. tostring(chasedTo))
	local closest = cat.Root.Position.X
	for _ = 1, 8 do
		Mock.advance(5)
		closest = math.min(closest, cat.Root.Position.X)
	end
	check(closest > -212, "the cat should stop at the canyon mouth, not follow you into the yard: " .. closest)
	check((cat.Root.AlignPosition.Position - post).Magnitude < 10, "the cat should be back at its post, at " .. tostring(cat.Root.AlignPosition.Position))
	check((cat.Root.Position - post).Magnitude < 8, "and asleep in it, at " .. tostring(cat.Root.Position))
end)

step("legs step in stops, and only on things that have legs", function()
	local WalkCycle = require(SharedFolder.WalkCycle)
	local function limb(phase)
		local part = Instance.new("Part")
		local joint = Instance.new("Motor6D")
		joint.Name = "Leg1"
		joint.Parent = part
		return { Joint = joint, Base = CFrame.new(0, 2, 0), Phase = phase }
	end

	-- Standing still strikes nothing at all, however many frames go by.
	local still = WalkCycle.new({ limb(0) })
	for _ = 1, 60 do
		WalkCycle.update(still, 1 / 60, 0)
	end
	eq(still.Poses, 0, "a defender that is not moving does not step")
	eq(still.Moving, false, "and knows it is standing still")

	-- A second of running: a pose every 1 / FramesPerSecond, not one every frame. This is the
	-- whole point of the walk - it is meant to look like stop-motion.
	local front, back = limb(0), limb(0.5)
	local walk = WalkCycle.new({ front, back })
	for _ = 1, 60 do
		WalkCycle.update(walk, 1 / 60, 16)
	end
	local wanted = Config.Walk.FramesPerSecond
	check(walk.Poses >= wanted - 1 and walk.Poses <= wanted + 1,
		string.format("%d poses in a second of walking, wanted about %d", walk.Poses, wanted))
	check(walk.Poses <= 12, "the gait must stay in stops, not smooth out into a pose a frame")
	check(math.abs(front.Joint.C0._r[6] - back.Joint.C0._r[6]) > 0.05, "the legs should step alternately")

	-- A hitch (or a teleport) never unloads a burst of poses when it catches up.
	local stalled = WalkCycle.new({ limb(0) })
	WalkCycle.update(stalled, 10, 16)
	check(stalled.Poses <= Config.Walk.MaxCatchUp, "a long stall caught up in " .. stalled.Poses .. " poses")

	-- Nothing to step with: a drone that hovers or a car that rolls is given no cycle to drive.
	local rolling = WalkCycle.new({})
	WalkCycle.update(rolling, 1, 16)
	eq(rolling.Poses, 0, "no limbs, no poses")

	-- And in the world: the cat has legs, the security car does not.
	local function legCount(guard)
		local found = 0
		for _, part in guard:GetDescendants() do
			if part:IsA("Motor6D") and string.sub(part.Name, 1, 3) == "Leg" then
				found += 1
			end
		end
		return found
	end
	local cat = cottage:FindFirstChild("Guard")
	check(legCount(cat) >= 2, "the cat should be built with legs")
	local car = Map.Houses.House10:FindFirstChild("Guard")
	if car then
		eq(legCount(car), 0, "the security car has no legs to step with")
	end
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

	-- A second shelf item, so the storage steps below have something to take and sell.
	stealFrom(cottage, thief, root)
	Mock.advance(0.2)
	root.CFrame = plot.DepositPad.CFrame + Vector3.new(0, 2, 0)
	plot.DepositPad.Touched:Fire(root)
	Mock.advance(0.2)
	eq(thief:GetAttribute("StoredCount"), 2, "two items on the shelves")
	eq(#plot.Display:GetChildren(), 2, "both are shown on the shelf")
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
	eq(thief:GetAttribute("Speed"), 80, "Speed starts at five times the 16 studs/s you walk at")
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

	-- Level 1 hands out one displayed speed every 4 seconds. The displayed
	-- value is always exactly five times the physical studs/s value.
	Mock.advance(5)
	eq(thief:GetAttribute("Speed"), 81, "one displayed speed after the first 4 seconds")
	eq(humanoid.WalkSpeed, 16.2, "Speed 81 means 16.2 studs/s")
	Mock.advance(8)
	eq(thief:GetAttribute("Speed"), 83, "a displayed speed point every 4 seconds (3 in 12 seconds)")
	eq(humanoid.WalkSpeed, 16.6, "displayed Speed stays 5x the walk speed")
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

	-- A maxed treadmill pours speed on. The client converts each replicated
	-- increase into its own floating number instead of server toast batching.
	session.Profile.Levels.Treadmill = #Config.UpgradesById.Treadmill.Values
	before = thief:GetAttribute("Speed")
	Mock.advance(3)
	check(thief:GetAttribute("Speed") >= before + 8000, "a maxed treadmill should pour on the speed")
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

	local cash = thief:GetAttribute("Cash")
	local expected = Items.getSellValue("Toaster") + Items.getSellValue("DiamondNecklace")
	local sale = Remotes.Sell.OnServerInvoke(thief, "Sell", "DiamondNecklace")
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

step("daytime: indoor thieves lose their bags, everyone is shown out and loot restocks", function()
	-- Bring bag loot inside Maple Cottage with the front door open.
	local door = cottage.Doors:GetChildren()[1]
	if door.Panel.LockpickPrompt.Enabled then
		door.Panel.LockpickPrompt.Triggered:Fire(thief)
	end
	-- Add bag loot directly so this daylight rule is isolated from the guard catch loop.
	local Inventory = moduleOf("Inventory")
	check(Inventory.addCarried(thief, "Toaster"), "the indoor thief needs loot to lose at sunrise")
	root.CFrame = CFrame.new(cottage.Zone.Position.X, 3.7, cottage.Zone.Position.Z)
	local carried = thief:GetAttribute("Carried")
	check(carried > 0, "the indoor thief needs loot to lose at sunrise")
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
	check(sawMessage(thief, mark, "owners came home and caught you inside"), "no indoor-loss message")
	eq(thief:GetAttribute("Carried"), 0, "an indoor thief loses every carried item at sunrise")
	eq(character:FindFirstChild("LootSack"), nil, "the lost bag is removed at sunrise")
	-- Locked up
	eq(door.Panel.LockpickPrompt.Enabled, false, "lockpicking is off during the day")
	eq(door.OpenAngle.Value, 0, "and the door is shut for the day")
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
	eq(thief:GetAttribute("Carried"), 0, "the server refuses daytime steals too")

	-- Night falls again: everything reopens
	mark = #Mock.remoteLog
	Mock.advance(Config.DayNight.DayLength + 0.5, 0.25)
	eq(workspace:GetAttribute("Daytime"), false, "night again after 30 seconds")
	check(sawBroadcast(mark, "Night falls"), "everyone is told it's night")
	eq(door.Panel.LockpickPrompt.Enabled, true, "doors can be picked again")
	eq(item.Root.StealPrompt.Enabled, true, "loot can be stolen again")
	eq(#cottage.Loot:GetChildren(), 5, "still fully stocked")
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
	eq(saved.Levels.Engine, nil, "the getaway car's upgrades are gone from the save")
	eq(saved.Trunk, nil, "and so is the trunk")
	eq(saved.Levels.Treadmill, 3, "saved treadmill level")
	check(type(saved.SpeedPoints) == "number" and saved.SpeedPoints > 0, "trained speed is saved")
	check(type(saved.Discovered) == "table" and #saved.Discovered >= 2, "the Loot Index is saved")
	eq(plot:FindFirstChild("OwnerText", true).Text, "EMPTY WAREHOUSE", "plot released")
	eq(#plot.Display:GetChildren(), 0, "shelves cleared")
	check(workspace:FindFirstChild("Cars") == nil, "there is no cars folder any more")
	Mock.advance(0.3)
	eq(plot.Treadmill:GetAttribute("OwnerUserId"), 0, "treadmill released")
	eq(plot.Treadmill.Console:FindFirstChild("TreadmillText", true).Text, "EMPTY", "treadmill console reset")
	eq(plot.Treadmill.Console.UpgradeTreadmillPrompt.Enabled, false, "no upgrades on an empty treadmill")

	local returning = newPlayer(101, "Thief")
	local _, returningHumanoid = spawnCharacter(returning, Vector3.new(0, 5, 0))
	Mock.advance(1)
	eq(returning:GetAttribute("PlotIndex"), 1, "gets a free plot again")
	eq(returning:GetAttribute("StoredCount"), #stored, "stored items restored")
	eq(returning:GetAttribute("Level_Bag"), 2, "upgrade restored")
	check(returning:GetAttribute("Cash") >= cash, "cash restored")
	eq(#plot.Display:GetChildren(), #stored, "shelves rebuilt")
	check(returning:GetAttribute("SpeedPoints") >= 1, "trained speed restored")
	check(returning:GetAttribute("Speed") >= 80, "Speed stat restored")
	eq(returning:GetAttribute("WalkSpeed"), nil, "rejoined players do not receive true walk speed")
	eq(returning:GetAttribute("Speed"), 5 * returningHumanoid.WalkSpeed, "displayed Speed remains 5x walk speed server-side")
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

	-- Old saves still convert to the same server-side movement rate, but that raw
	-- value is no longer published as a Player attribute.
	local legacy = newPlayer(505, "LegacyRunner")
	Mock.advance(0.5)
	eq(legacy:GetAttribute("SpeedPoints"), 40, "8 old speed levels -> 40 display-speed points")
	eq(legacy:GetAttribute("Speed"), 120, "which is Speed 120")
	eq(legacy:GetAttribute("WalkSpeed"), nil, "legacy players do not receive true walk speed")
	eq(moduleOf("PlayerData").getWalkSpeed(legacy), 24, "legacy movement rate stays intact server-side")

	for _, player in { elite, pro, legacy } do
		player.Parent = nil
		Players.PlayerRemoving:Fire(player)
	end
	Mock.advance(0.5)
end)

step("the rebirth shrine trades all your speed for a permanent multiplier", function()
	local PlayerData = moduleOf("PlayerData")
	local shrine = Map:FindFirstChild("RebirthShrine", true)
	check(shrine and shrine:IsA("BasePart"), "the map has a rebirth shrine part")
	local prompt = shrine:FindFirstChild("OpenRebirthPrompt")
	check(prompt, "the shrine has a prompt")
	eq(prompt.ObjectText, "🔁 REBIRTH SHRINE", "the prompt names the shrine")

	-- A fresh arrival with a toaster on the shelves (so there's an income to multiply).
	local spinner = newPlayer(606, "Rebirther")
	local _, spinnerHumanoid = spawnCharacter(spinner, Vector3.new(0, 5, 0))
	Mock.advance(1)
	moduleOf("Plots").deposit(spinner, { "Toaster" })
	Mock.advance(0.5)

	-- A fresh account starts at x1 with the first million priced in.
	eq(spinner:GetAttribute("Rebirths"), 0, "starts with no rebirths")
	local state = Remotes.Rebirth.OnServerInvoke(spinner, "State")
	eq(state.Rebirths, 0, "the state reports zero rebirths")
	eq(state.Multiplier, 1, "and a x1 multiplier")
	eq(state.Cost, 1000000, "first rebirth costs 1M")
	eq(state.CanAfford, false, "no free rebirths")

	-- Not enough speed yet: the shrine says so and nothing changes.
	local miss = Remotes.Rebirth.OnServerInvoke(spinner, "Buy")
	eq(miss.Ok, false, "buying without the speed fails")
	check(string.find(tostring(miss.Message), "speed", 1, true), "the error explains why")
	eq(spinner:GetAttribute("Rebirths"), 0, "nothing was bought")

	-- Train up a million-fifty thousand and take the trade.
	PlayerData.addSpeed(spinner, 1050000 - PlayerData.getSpeedPoints(spinner))
	local incomeBefore = spinner:GetAttribute("Income")
	check(incomeBefore > 0, "the rebirther's warehouse must earn something for this test")
	local bought = Remotes.Rebirth.OnServerInvoke(spinner, "Buy")
	eq(bought.Ok, true, "rebirth bought: " .. tostring(bought.Message))
	eq(spinner:GetAttribute("Rebirths"), 1, "the rebirth is counted")
	eq(spinner:GetAttribute("SpeedPoints"), 0, "every speed point is spent")
	eq(spinner:GetAttribute("Speed"), 80, "the Speed stat starts over")
	eq(spinner:GetAttribute("WalkSpeed"), nil, "rebirth does not expose true walk speed")
	eq(spinnerHumanoid.WalkSpeed, 16, "and you jog at the base speed again")
	eq(spinner.leaderstats.Rebirths.Value, 1, "the leaderboard brags about the rebirth")
	eq(spinner:GetAttribute("Income"), incomeBefore * 1.1, "coins per second pick up the x1.1")

	-- The treadmill bonus follows suit: 100 trained points land as 110.
	PlayerData.addSpeed(spinner, 100)
	check(math.abs(spinner:GetAttribute("SpeedPoints") - 110) < 0.01, "treadmill gains are multiplied too")

	-- And the next rebirth costs x2.5 more.
	local nextState = Remotes.Rebirth.OnServerInvoke(spinner, "State")
	eq(nextState.Cost, 2500000, "the second rebirth costs 2.5M")
	check(math.abs(nextState.NextMultiplier - 1.2) < 1e-9, "x1.2 is the next step")
	Mock.advance(0.5)
end)

step("no warnings were logged", function()
	check(#Mock.warnings == 0, "warnings:\n  " .. table.concat(Mock.warnings, "\n  "))
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("integration tests failed")
end
