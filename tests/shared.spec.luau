--[[
	Unit tests for the shared modules (Config, Items, ItemModels, Guards, Format).
	Run with:  python3 tools/run_luau_tests.py   (needs the `luau` CLI on PATH)

	The runner bundles this file with the modules and lightweight mocks of the
	Roblox datatypes they use (Vector3, Color3, Enum, Random).
]]

local Config = require(Shared.Config)
local Items = require(Shared.Items)
local ItemModels = require(Shared.ItemModels)
local Format = require(Shared.Format)
local Guards = require(Shared.Guards)

local passed, failed = 0, 0

local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print("FAIL  " .. name .. "\n      " .. tostring(err))
	end
end

local function eq(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(string.format("%sexpected %s, got %s", if label then label .. ": " else "", tostring(expected), tostring(actual)), 2)
	end
end

local function check(condition: boolean, message: string)
	if not condition then
		error(message, 2)
	end
end

--------------------------------------------------------------------------------
-- Format
--------------------------------------------------------------------------------
test("Format.commas", function()
	eq(Format.commas(0), "0")
	eq(Format.commas(7), "7")
	eq(Format.commas(999), "999")
	eq(Format.commas(1000), "1,000")
	eq(Format.commas(12345), "12,345")
	eq(Format.commas(1234567), "1,234,567")
	eq(Format.commas(-1500), "-1,500")
	eq(Format.commas(12.7), "12")
end)

test("Format.short", function()
	eq(Format.short(999), "999")
	eq(Format.short(1000), "1K")
	eq(Format.short(1500), "1.5K")
	eq(Format.short(12345), "12.3K")
	eq(Format.short(100000), "100K")
	eq(Format.short(1000000), "1M")
	eq(Format.short(2500000), "2.5M")
	eq(Format.short(123456789), "123M")
	eq(Format.short(1e9), "1B")
	eq(Format.short(-2000), "-2K")
end)

test("Format.money", function()
	eq(Format.money(0), "$0")
	eq(Format.money(25), "$25")
	eq(Format.money(999999), "$999,999")
	eq(Format.money(1000000), "$1M")
	eq(Format.money(2345678), "$2.34M")
end)

--------------------------------------------------------------------------------
-- Config
--------------------------------------------------------------------------------
test("upgrade tables are consistent", function()
	local seen = {}
	for _, upgrade in Config.Upgrades do
		check(not seen[upgrade.Id], "duplicate upgrade " .. upgrade.Id)
		seen[upgrade.Id] = true
		eq(#upgrade.Values, #upgrade.Costs, upgrade.Id .. " values/costs length")
		eq(upgrade.Costs[1], 0, upgrade.Id .. " first cost")
		for level = 2, #upgrade.Costs do
			check(upgrade.Costs[level] > upgrade.Costs[level - 1], upgrade.Id .. " costs must increase")
			check(upgrade.Values[level] >= upgrade.Values[level - 1], upgrade.Id .. " values must not decrease")
		end
		check(Config.UpgradesById[upgrade.Id] == upgrade, "UpgradesById missing " .. upgrade.Id)
		check(string.format(upgrade.Format, upgrade.Values[1]) ~= nil, "bad format for " .. upgrade.Id)
	end
	for _, id in { "Bag", "Storage", "Treadmill" } do
		check(seen[id] == true, "missing upgrade " .. id)
	end
end)

test("getUpgradeValue clamps levels", function()
	eq(Config.getUpgradeValue("Bag", 1), 2)
	eq(Config.getUpgradeValue("Bag", 0), 2)
	eq(Config.getUpgradeValue("Bag", 99), 12)
	eq(Config.getUpgradeValue("Nope", 1), 0)
end)

test("warehouse storage fits the 50 shelf slots", function()
	local storage = Config.UpgradesById.Storage
	check(storage.Values[#storage.Values] <= 50, "max storage exceeds the 50 slots in each warehouse")
end)

test("the displayed Speed is five times real movement speed, with no ceiling", function()
	eq(Config.Speed.DisplayMultiplier, 5)
	eq(Config.speedStatForPoints(0), 80, "a fresh player is Speed 80")
	eq(Config.walkSpeedForPoints(0), 16, "and walks at the usual 16 studs/s")
	for points = 0, 20 do
		local stat = Config.speedStatForPoints(points)
		eq(stat, 80 + points, "one speed point is +1 displayed Speed")
		eq(stat, Config.walkSpeedForPoints(points) * Config.Speed.DisplayMultiplier, "displayed Speed is 5x studs/s")
	end
	eq(Config.walkSpeedForPoints(6.75), 17.2, "fractional points don't round the display stat up")
	-- No ceiling: the speed keeps climbing.
	check(Config.walkSpeedForPoints(1000) > Config.walkSpeedForPoints(999), "speed must keep growing")
	eq(Config.walkSpeedForPoints(1000), 216)
end)

test("treadmill levels: the gain doubles and the wait halves, four times faster each level", function()
	local treadmill = Config.UpgradesById.Treadmill
	eq(#treadmill.Values, 8, "eight treadmill levels")
	local amount, interval = Config.treadmillTick(1)
	eq(amount, 1, "level 1 gives one speed per tick")
	eq(interval, 4, "every four seconds")
	eq(Config.treadmillRate(1), 0.25, "a quarter of a speed per second")
	for level = 2, #treadmill.Values do
		local nextAmount, nextInterval = Config.treadmillTick(level)
		eq(nextAmount, amount * 2, "level " .. level .. " doubles the amount")
		eq(nextInterval, interval / 2, "level " .. level .. " halves the wait")
		eq(treadmill.Values[level], nextAmount, "the value table lists the amounts")
		eq(Config.treadmillRate(level), Config.treadmillRate(level - 1) * 4, "level " .. level .. " is 4x faster")
		amount, interval = nextAmount, nextInterval
	end
	eq(Config.treadmillRate(8), 4096, "a maxed treadmill pours on 4,096 speed a second")

	-- Prices follow an exponential curve, in step with the training rate (level 1 is free).
	eq(treadmill.Costs[1], 0, "the first level is free")
	check(treadmill.Costs[2] > 0, "level 2 costs money")
	for level = 3, #treadmill.Costs do
		local price, previous = treadmill.Costs[level], treadmill.Costs[level - 1]
		eq(price, previous * 4, "price of level " .. level)
		check(price > previous, "prices must go up")
	end

	-- ...and the shop/console say so in words.
	eq(Config.treadmillText(1), "+1 speed / 4s")
	eq(Config.treadmillText(2), "+2 speed / 2s")
	eq(Config.treadmillText(3), "+4 speed / 1s")
	eq(Config.treadmillText(8), "4,096 speed/s")
	eq(Config.describeUpgrade("Treadmill", 2), "+2 speed / 2s", "the shop card uses the rate text")
	eq(Config.describeUpgrade("Treadmill", 9), "4,096 speed/s", "and clamps past the last level")
	eq(Config.describeUpgrade("Bag", 2), "3 items", "other upgrades keep their plain values")
end)

test("Format.decimal trims what it doesn't need", function()
	eq(Format.decimal(4), "4")
	eq(Format.decimal(2.5), "2.5")
	eq(Format.decimal(0.25), "0.25")
	eq(Format.decimal(0.03125, 3), "0.031")
	eq(Format.decimal(1234), "1234")
	eq(Format.decimal(2.5, 3), "2.5")
	eq(Format.decimal(0.5, 1), "0.5")
end)

test("house tiers get harder", function()
	eq(#Config.HouseTiers, 4)
	for tier = 2, 4 do
		local a, b = Config.HouseTiers[tier - 1], Config.HouseTiers[tier]
		check(b.LockpickTime > a.LockpickTime, "lockpick time must increase")
		check(b.AlarmWindup <= a.AlarmWindup, "alarm windup must not increase")
	end
end)

test("the street: a tuxedo cat, then worse, ending with the museum's fleet", function()
	eq(#Config.Houses, 11, "ten houses plus the Mansion")
	local expected = {
		"TuxedoCat", "Puppy", "Labrador", "GuardDog", "HomeOwner",
		"OffDutyOfficer", "Wizard", "TRex", "SecurityBot", "SecurityCar", "SecurityCar",
	}
	local speeds = {}
	local ids = {}
	local previousTier = 1
	for index, house in Config.Houses do
		local guard = Config.Guards[house.Guard]
		eq(house.Guard, expected[index], house.DisplayName .. " defender")
		check(ids[house.Id] == nil, "duplicate house id " .. house.Id)
		ids[house.Id] = true
		check(Config.getHouse(house.Id) == house, house.Id .. " lookup failed")
		check(house.Tier >= previousTier, "houses must get harder (or stay the same) down the street")
		previousTier = house.Tier
		check(guard.Speed > 0, house.Id .. " defender needs a speed")
		table.insert(speeds, guard.Speed)
	end
	-- Exactly the speeds the design asks for, and they climb down the street.
	local want = { 10, 25, 70, 300, 1200, 17500, 50000, 100000, 1100000, 125000000, 125000000 }
	for index, speed in want do
		eq(speeds[index], speed, "speed #" .. index)
	end
	for index = 2, #speeds - 1 do
		check(speeds[index] > speeds[index - 1], "defenders must get faster down the street")
	end
	check(speeds[#speeds] >= speeds[#speeds - 1], "the museum's fleet is at least as fast as the last house")

	-- The Mansion is now a museum with a fleet of security cars; house 9 has a squad of bots.
	local last = Config.Houses[#Config.Houses]
	eq(last.Id, "Mansion")
	eq(Config.Guards[last.Guard].Kind, "Vehicle")
	eq(last.GuardCount, 4, "the museum keeps a fleet of security cars")
	local bots = Config.Houses[9]
	eq(bots.Guard, "SecurityBot")
	eq(bots.GuardCount, 3, "three security bots")
	for _, house in Config.Houses do
		eq(house.GuardCount or 1, if house.Id == "Mansion" then 4 elseif house.Id == "House9" then 3 else 1,
			house.Id .. " defender count")
	end
	-- Nothing else guards a house.
	local used = {}
	for _, house in Config.Houses do
		used[house.Guard] = true
	end
	for guardId in Config.Guards do
		check(used[guardId], guardId .. " is not used by any house")
	end

	eq(Config.getGuard("House1").DisplayName, "Tuxedo Cat")
	eq(Config.getGuard("NotAHouse").DisplayName, "Tuxedo Cat", "unknown houses fall back to the first defender")
end)

test("defenders are only fast once they are out of the house", function()
	-- Everything about the speed rule hangs off these two numbers.
	eq(Config.Alarm.InsideSpeed, 16, "the standard Roblox movement speed")
	eq(Config.Speed.BaseWalkSpeed, 16, "which is what a fresh player walks at")
	eq(Config.walkSpeedForPoints(0), Config.Alarm.InsideSpeed, "so a new player is never the slow one indoors")
	check(Config.Alarm.SafeX < 0, "the safe zone is back at the yard")
	check(Config.Alarm.LaneHalfWidth > 0, "chases follow the street")
	-- Only the cat is slower than a fresh player; everything past the puppy is faster than you
	-- will ever be without a treadmill.
	check(Config.Guards.TuxedoCat.Speed < Config.Alarm.InsideSpeed, "you can outrun the cat")
	for _, guardId in { "GuardDog", "HomeOwner", "OffDutyOfficer", "Wizard", "TRex", "SecurityBot", "SecurityCar" } do
		check(Config.Guards[guardId].Speed > Config.Alarm.InsideSpeed * 10, guardId .. " should be terrifying outside")
	end
end)

test("guard models", function()
	-- Every defender has a model that stands on the ground, faces -Z and fits in the house it
	-- guards (the door is 9 studs tall, the rooms 12).
	local tallest = { Cat = 2.8, Dog = 4.8, Human = 7.4, Wizard = 8.2, Beast = 8.6, Robot = 6.6, Vehicle = 5.0 }
	for guardId, info in Config.Guards do
		local look = Guards.getLook(guardId)
		check(look ~= nil, guardId .. " has no model")
		assert(look)
		check(#look.Eyes >= 2, guardId .. " needs eyes (they glow red during an alarm)")
		local minCorner, maxCorner = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9)
		for _, spec in look.Parts do
			check(spec.Size.X > 0 and spec.Size.Y > 0 and spec.Size.Z > 0, guardId .. " has an empty part")
			minCorner = minCorner:Min(spec.Position - spec.Size / 2)
			maxCorner = maxCorner:Max(spec.Position + spec.Size / 2)
		end
		local size = maxCorner - minCorner
		check(math.abs(minCorner.Y) < 0.05, string.format("%s should stand on the ground (feet at %.2f)", guardId, minCorner.Y))
		check(size.Y < tallest[info.Kind], string.format("%s is too tall (%.2f)", guardId, size.Y))
		-- (People carry things: the torch, the wand and the rolling pin stick out sideways a bit.)
		local maxX = if info.Kind == "Beast" then 5.2
			elseif info.Kind == "Vehicle" then 5.9
			elseif info.Kind == "Human" or info.Kind == "Wizard" then 3.4
			elseif info.Kind == "Robot" then 2.9
			else 2.6
		local maxZ = if info.Kind == "Beast" then 13.5 elseif info.Kind == "Vehicle" then 11.5 else 10.5
		check(size.Z < maxZ and size.X < maxX, string.format("%s is too big (%.2f x %.2f)", guardId, size.X, size.Z))
		-- The first eye is the face; extra entries in the list are glowing props (a torch,
		-- a wand tip, a car's light bar) that turn red with the rest of it during an alarm.
		check(look.Eyes[1].Z < minCorner.Z + size.Z * 0.35, guardId .. "'s eyes should be at the front (-Z)")
	end
end)

test("night and day", function()
	eq(Config.DayNight.NightLength, 300, "night lasts 5 minutes")
	eq(Config.DayNight.DayLength, 30, "daytime lasts 30 seconds")
	eq(Config.DayNight.NightLength + Config.DayNight.DayLength, 330, "loot restocks once every 5½ minutes")
	check(Config.DayNight.Night.ClockTime < 5 or Config.DayNight.Night.ClockTime > 19, "night should be dark")
	check(Config.DayNight.Day.ClockTime > 8 and Config.DayNight.Day.ClockTime < 16, "daytime should be bright")
end)

test("treadmill settings", function()
	local treadmill = Config.UpgradesById.Treadmill
	eq(#Config.Treadmill.LevelColors, #treadmill.Values, "one trim colour per treadmill level")
	eq(Config.treadmillColor(1), Config.Treadmill.LevelColors[1])
	eq(Config.treadmillColor(99), Config.Treadmill.LevelColors[#treadmill.Values], "colour clamps to the top level")
	eq(Config.treadmillColor(0), Config.Treadmill.LevelColors[1], "colour clamps to level 1")
	check(Config.Treadmill.MaxDistance > 0 and Config.Treadmill.RemountCooldown > 0, "treadmill timings must be positive")
end)

--------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------
test("every house has its own loot", function()
	local counts = {}
	local names = {}
	for _, def in Items.List do
		local house = Config.getHouse(def.House)
		check(house ~= nil, def.Id .. " belongs to an unknown house " .. tostring(def.House))
		assert(house)
		eq(def.Tier, house.Tier, def.Id .. " tier")
		counts[def.House] = counts[def.House] or {}
		counts[def.House][def.Rarity] = (counts[def.House][def.Rarity] or 0) + 1
		check(def.Value > 0, def.Id .. " has no value")
		check(#def.Parts > 0, def.Id .. " has no parts")
		check(Items.Rarities[def.Rarity] ~= nil, def.Id .. " has unknown rarity")
		check(Items.get(def.Id) == def, def.Id .. " lookup failed")
		check(names[def.DisplayName] == nil, "two items are called " .. def.DisplayName)
		names[def.DisplayName] = true
	end
	for _, house in Config.Houses do
		local c = counts[house.Id]
		check(c ~= nil, house.DisplayName .. " has no loot")
		check((c.Common or 0) >= 2, house.DisplayName .. " needs at least 2 common items")
		check((c.Rare or 0) >= 1, house.DisplayName .. " needs a rare item")
		check((c.Epic or 0) >= 1, house.DisplayName .. " needs an epic item")
		local items = Items.forHouse(house.Id)
		check(#items >= 4, house.DisplayName .. " should have at least 4 different items")
		for index = 2, #items do
			check(
				Items.Rarities[items[index - 1].Rarity].Order <= Items.Rarities[items[index].Rarity].Order,
				"Items.forHouse should list commons first"
			)
		end
	end
	check(#Items.List >= 44, "there should be lots of items to collect, found " .. #Items.List)
	eq(#Items.forHouse("NotAHouse"), 0, "unknown houses have no loot")
end)

test("higher tiers are worth more", function()
	local averages = {}
	for tier = 1, 4 do
		local total, count = 0, 0
		for _, def in Items.List do
			if def.Tier == tier then
				total += def.Value
				count += 1
			end
		end
		averages[tier] = total / count
	end
	for tier = 2, 4 do
		check(averages[tier] > averages[tier - 1] * 3, "tier " .. tier .. " loot isn't worth enough more")
	end
end)

test("income per item", function()
	for _, def in Items.List do
		local income = Items.getIncome(def.Id)
		check(income >= 1, def.Id .. " income below 1")
		check(math.abs(income - def.Value * Config.Economy.IncomeRatio) <= 1, def.Id .. " income doesn't match ratio")
	end
	eq(Items.getIncome("NotAnItem"), 0)
	eq(Items.getValue("NotAnItem"), 0)
end)

test("rolls only give a house's own loot, weighted by rarity", function()
	local rng = Random.new(1234)
	for _, house in Config.Houses do
		local rarityCounts = {}
		local seenItems = {}
		local rolls = 8000
		for _ = 1, rolls do
			local id = Items.roll(house.Id, rng)
			local def = Items.get(id)
			check(def ~= nil and def.House == house.Id, "rolled " .. tostring(id) .. " in " .. house.Id)
			assert(def)
			seenItems[id] = true
			rarityCounts[def.Rarity] = (rarityCounts[def.Rarity] or 0) + 1
		end
		for _, def in Items.forHouse(house.Id) do
			check(seenItems[def.Id] == true, def.Id .. " never spawned in " .. house.Id)
		end
		-- Expected share of each rarity among the rarities that exist in this tier
		local totalWeight = 0
		for name in rarityCounts do
			totalWeight += Items.Rarities[name].Weight
		end
		for name, count in rarityCounts do
			local expected = Items.Rarities[name].Weight / totalWeight
			local actual = count / rolls
			check(math.abs(actual - expected) < 0.025, string.format("%s %s: expected %.3f got %.3f", house.Id, name, expected, actual))
		end
	end
end)

test("rarities are ranked in the shop's colours, and Epic and up glows", function()
	eq(Items.Rarities.Common.Order, 1)
	eq(Items.Rarities.Rare.Order, 2)
	eq(Items.Rarities.Epic.Order, 3)
	eq(Items.Rarities.Legendary.Order, 4)
	eq(Items.Rarities.Epic.Color, Color3.fromRGB(190, 100, 255))
	eq(Items.Rarities.Legendary.Color, Color3.fromRGB(255, 190, 40))
	eq(Config.Aura.MinOrder, 3, "the aura starts at Epic")
	local glowing, plain = 0, 0
	for _, def in Items.List do
		local rarity = Items.Rarities[def.Rarity]
		check(rarity ~= nil, def.Id .. " has an unknown rarity " .. tostring(def.Rarity))
		eq(Items.getRarity(def.Id).Color, rarity.Color, def.Id .. " rarity colour")
		eq(Items.hasAura(def.Id), rarity.Order >= Config.Aura.MinOrder, def.Id .. " aura")
		if Items.hasAura(def.Id) then
			glowing += 1
		else
			plain += 1
		end
	end
	check(glowing > 0 and plain > 0, "there should be both glowing and plain loot")
end)

test("selling pays the item's value and the stall's trunk range is sane", function()
	check(Config.Economy.SellRatio > 0, "selling has to pay something")
	-- The getaway car is gone (spawn, engine, trunk and all).
	check(Config.Vehicle == nil, "there is no car config any more")
	check(Config.Market.TrunkRange == nil, "and no trunk range at the sell point")
	for _, id in { "Engine", "Trunk" } do
		check(Config.UpgradesById[id] == nil, id .. " should no longer be a shop upgrade")
	end
	check(Config.Market.PromptDistance >= 6, "the stall prompt has to be reachable")
	for _, def in Items.List do
		eq(Items.getSellValue(def.Id), math.floor(def.Value * Config.Economy.SellRatio), def.Id .. " sell value")
		check(Items.getSellValue(def.Id) > 0, def.Id .. " should be worth something")
	end
end)

test("item models fit on shelves and furniture", function()
	for _, def in Items.List do
		local size, center = ItemModels.getBounds(def.Id)
		check(size.Y <= 4.4, string.format("%s is too tall (%.2f)", def.Id, size.Y))
		check(size.X <= 3.8 and size.Z <= 3.8, string.format("%s is too wide (%.2f x %.2f)", def.Id, size.X, size.Z))
		local bottom = center.Y - size.Y / 2
		check(math.abs(bottom) < 0.06, string.format("%s doesn't sit on its origin (bottom %.2f)", def.Id, bottom))
	end
end)

test("rebirths cost speed, each x2.5 more than the last", function()
	eq(Config.rebirthCost(0), 1000000, "the first rebirth costs a million speed")
	eq(Config.rebirthCost(1), 2500000, "then x2.5")
	eq(Config.rebirthCost(2), 6250000)
	eq(Config.rebirthCost(3), 15625000)
	local last = 0
	for count = 0, 16 do
		local cost = Config.rebirthCost(count)
		check(cost > last, "every rebirth must cost strictly more (rebirth " .. count .. ")")
		last = cost
	end
	eq(Config.rebirthCost(-2), Config.rebirthCost(0), "negative counts clamp to the first price")
end)

test("the rebirth multiplier gains x0.1 per rebirth, forever", function()
	eq(Config.rebirthMultiplier(0), 1, "no rebirths, no bonus")
	eq(Format.decimal(Config.rebirthMultiplier(1), 2), "1.1")
	eq(Format.decimal(Config.rebirthMultiplier(2), 2), "1.2")
	eq(Format.decimal(Config.rebirthMultiplier(25), 2), "3.5", "the ladder never stops")
	eq(Config.rebirthMultiplier(-1), 1, "clamped before the first rebirth")
end)

test("the stride keeps up with the ground the body is covering", function()
	local WalkCycle = require(Shared.WalkCycle)
	eq(WalkCycle.strideRate(Config.Walk.Stride), 1, "one stride per Stride studs")
	eq(WalkCycle.strideRate(Config.Walk.Stride * 0.5), 0.5, "half the speed, half the stride rate")
	eq(WalkCycle.strideRate(-Config.Walk.Stride), 1, "backwards strides too")
	eq(WalkCycle.strideRate(0), Config.Walk.MinRate, "standing still strides no slower than the floor")
	eq(WalkCycle.strideRate(Config.Walk.Stride * 0.01), Config.Walk.MinRate)
	eq(WalkCycle.strideRate(Config.Walk.Stride * 1000), Config.Walk.MaxRate, "nor faster than the ceiling")
	check(Config.Walk.MaxRate > Config.Walk.MinRate, "the ceiling must be above the floor")
	check(Config.Walk.Swing > 0 and Config.Walk.Swing < 90, "the legs need a sensible swing")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed")
end
