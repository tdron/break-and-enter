--[[
	Unit tests for the shared modules (Config, Items, ItemModels, Format).
	Run with:  python3 tools/run_luau_tests.py   (needs the `luau` CLI on PATH)

	The runner bundles this file with the modules and lightweight mocks of the
	Roblox datatypes they use (Vector3, Color3, Enum, Random).
]]

local Config = require(Shared.Config)
local Items = require(Shared.Items)
local ItemModels = require(Shared.ItemModels)
local Format = require(Shared.Format)

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
	for _, id in { "Bag", "Engine", "Trunk", "Storage", "ProTreadmill", "EliteTreadmill" } do
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
	-- Max speed should take a while on the basic treadmill but be quick on the elite one.
	local basicMinutes = totalXP / Config.Treadmills.Basic.XPPerSecond / 60
	local eliteMinutes = totalXP / Config.Treadmills.Elite.XPPerSecond / 60
	check(basicMinutes > 15, "basic treadmill maxes too fast: " .. basicMinutes)
	check(eliteMinutes < 5, "elite treadmill maxes too slowly: " .. eliteMinutes)
end)

test("house tiers get harder", function()
	eq(#Config.HouseTiers, 4)
	for tier = 2, 4 do
		local a, b = Config.HouseTiers[tier - 1], Config.HouseTiers[tier]
		check(b.DroneSpeed > a.DroneSpeed, "drone speed must increase")
		check(b.LockpickTime > a.LockpickTime, "lockpick time must increase")
		check(b.AlarmWindup <= a.AlarmWindup, "alarm windup must not increase")
	end
	-- The fastest drone must be beatable at max speed, the slowest at base speed.
	check(Config.HouseTiers[4].DroneSpeed < Config.walkSpeedForLevel(Config.Speed.MaxLevel), "mansion drones too fast")
	check(Config.HouseTiers[1].DroneSpeed < Config.Speed.BaseWalkSpeed, "cottage drones too fast for new players")
end)

test("treadmills reference real unlock upgrades", function()
	for key, treadmill in Config.Treadmills do
		if treadmill.Unlock then
			local upgrade = Config.UpgradesById[treadmill.Unlock]
			check(upgrade ~= nil, key .. " unlock upgrade missing")
			eq(upgrade.Kind, "Unlock", key .. " unlock kind")
		end
	end
	check(Config.Treadmills.Basic.Unlock == nil, "basic treadmill must be free")
end)

--------------------------------------------------------------------------------
-- Items
--------------------------------------------------------------------------------
test("every tier has loot of every common rarity", function()
	local counts = {}
	for _, def in Items.List do
		counts[def.Tier] = counts[def.Tier] or {}
		counts[def.Tier][def.Rarity] = (counts[def.Tier][def.Rarity] or 0) + 1
		check(def.Value > 0, def.Id .. " has no value")
		check(#def.Parts > 0, def.Id .. " has no parts")
		check(Items.Rarities[def.Rarity] ~= nil, def.Id .. " has unknown rarity")
		check(Items.get(def.Id) == def, def.Id .. " lookup failed")
	end
	for tier = 1, 4 do
		check(counts[tier] ~= nil, "tier " .. tier .. " has no items")
		check((counts[tier].Common or 0) >= 2, "tier " .. tier .. " needs at least 2 common items")
		check((counts[tier].Rare or 0) >= 1, "tier " .. tier .. " needs a rare item")
	end
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

test("rolls respect tiers and rarity weights", function()
	local rng = Random.new(1234)
	for tier = 1, 4 do
		local rarityCounts = {}
		local rolls = 20000
		for _ = 1, rolls do
			local id = Items.roll(tier, rng)
			local def = Items.get(id)
			check(def ~= nil and def.Tier == tier, "rolled " .. tostring(id) .. " for tier " .. tier)
			rarityCounts[def.Rarity] = (rarityCounts[def.Rarity] or 0) + 1
		end
		-- Expected share of each rarity among the rarities that exist in this tier
		local totalWeight = 0
		for name in rarityCounts do
			totalWeight += Items.Rarities[name].Weight
		end
		for name, count in rarityCounts do
			local expected = Items.Rarities[name].Weight / totalWeight
			local actual = count / rolls
			check(math.abs(actual - expected) < 0.02, string.format("tier %d %s: expected %.3f got %.3f", tier, name, expected, actual))
		end
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
