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
	for _, id in { "Bag", "Engine", "Trunk", "Storage", "Treadmill" } do
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

test("speed progression", function()
	eq(Config.walkSpeedForLevel(0), 16)
	eq(Config.walkSpeedForLevel(Config.Speed.MaxLevel), 66)
	local totalXP = 0
	for level = 0, Config.Speed.MaxLevel - 1 do
		check(Config.xpForLevel(level) > 0, "xp must be positive")
		totalXP += Config.xpForLevel(level)
	end
	-- Max speed should take a while on a new treadmill but be quick on a fully upgraded one.
	local treadmill = Config.UpgradesById.Treadmill
	local slowMinutes = totalXP / treadmill.Values[1] / 60
	local fastMinutes = totalXP / treadmill.Values[#treadmill.Values] / 60
	check(slowMinutes > 15, "a level 1 treadmill maxes speed too fast: " .. slowMinutes)
	check(fastMinutes < 3, "a maxed treadmill maxes speed too slowly: " .. fastMinutes)
end)

test("house tiers get harder", function()
	eq(#Config.HouseTiers, 4)
	for tier = 2, 4 do
		local a, b = Config.HouseTiers[tier - 1], Config.HouseTiers[tier]
		check(b.GuardSpeed > a.GuardSpeed, "guard speed must increase")
		check(b.LockpickTime > a.LockpickTime, "lockpick time must increase")
		check(b.AlarmWindup <= a.AlarmWindup, "alarm windup must not increase")
	end
	-- The fastest guard must be beatable at max speed, the slowest at base speed.
	check(Config.HouseTiers[4].GuardSpeed < Config.walkSpeedForLevel(Config.Speed.MaxLevel), "mansion drones too fast")
	check(Config.HouseTiers[1].GuardSpeed < Config.Speed.BaseWalkSpeed, "cottage cats too fast for new players")
end)

test("the street: cats, then a different dog breed per house, then the Mansion's drones", function()
	eq(#Config.Houses, 11, "ten houses plus the Mansion")
	local last = Config.Houses[#Config.Houses]
	eq(last.Id, "Mansion", "the Mansion is at the end of the street")
	eq(Config.Guards[last.Guard].Kind, "Drone", "the Mansion keeps its drones")
	local breeds = {}
	local ids = {}
	local previousTier = 1
	for index, house in Config.Houses do
		check(ids[house.Id] == nil, "duplicate house id " .. house.Id)
		ids[house.Id] = true
		check(Config.getHouse(house.Id) == house, house.Id .. " lookup failed")
		check(house.Tier >= previousTier, "houses must get harder (or stay the same) down the street")
		previousTier = house.Tier
		local guard = Config.Guards[house.Guard]
		check(guard ~= nil, house.Id .. " has an unknown guard")
		if house.Tier == 1 then
			eq(guard.Kind, "Cat", house.DisplayName .. " should be guarded by a cat")
		elseif index < #Config.Houses then
			eq(guard.Kind, "Dog", house.DisplayName .. " should be guarded by dogs")
			check(breeds[house.Guard] == nil, "every dog house needs its own breed (" .. house.Guard .. " twice)")
			breeds[house.Guard] = true
		end
	end
	eq(Config.getGuard("House1").Kind, "Cat")
	eq(Config.getGuard("NotAHouse").Kind, "Drone", "unknown houses fall back to drones")
end)

test("guard models", function()
	for guardId, info in Config.Guards do
		local look = Guards.getLook(guardId)
		if info.Kind == "Drone" then
			check(look == nil, "drones are built separately")
			continue
		end
		check(look ~= nil, guardId .. " has no model")
		assert(look)
		eq(#look.Eyes, 2, guardId .. " eyes")
		local minCorner, maxCorner = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9)
		for _, spec in look.Parts do
			check(spec.Size.X > 0 and spec.Size.Y > 0 and spec.Size.Z > 0, guardId .. " has an empty part")
			minCorner = minCorner:Min(spec.Position - spec.Size / 2)
			maxCorner = maxCorner:Max(spec.Position + spec.Size / 2)
		end
		local size = maxCorner - minCorner
		check(math.abs(minCorner.Y) < 0.05, string.format("%s should stand on the ground (feet at %.2f)", guardId, minCorner.Y))
		check(size.Y < (if info.Kind == "Cat" then 2.5 else 4.2), string.format("%s is too tall (%.2f)", guardId, size.Y))
		check(size.Z < 5.5 and size.X < 2.2, string.format("%s is too big (%.2f x %.2f)", guardId, size.X, size.Z))
		for _, eye in look.Eyes do
			check(eye.Z < minCorner.Z + size.Z * 0.35, guardId .. "'s eyes should be at the front (-Z)")
		end
	end
end)

test("night and day", function()
	eq(Config.DayNight.NightLength + Config.DayNight.DayLength, 240, "loot restocks once every 4 minutes")
	eq(Config.DayNight.DayLength, 30, "daytime lasts 30 seconds")
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
	check(Config.Market.TrunkRange >= 20, "the trunk range should cover the stall's apron")
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

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	error("tests failed")
end
