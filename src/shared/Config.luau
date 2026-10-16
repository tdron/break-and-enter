--!strict
--[[
	Config
	------
	Every tunable number in Steal an Item lives here, so you can rebalance the
	game without touching any game logic. This module lives in
	ReplicatedStorage, so both the server and the client read the same values.
]]

export type Upgrade = {
	Id: string,
	DisplayName: string,
	Icon: string,
	Description: string,
	-- Values[level] is what the upgrade gives you at that level (level 1 = free starting level)
	Values: { number },
	-- Costs[level] is the price to reach that level (Costs[1] is always 0)
	Costs: { number },
	-- string.format pattern used to display a value, e.g. "%d items"
	Format: string,
	-- Optional: write the value out yourself (the treadmill uses this for its
	-- "+2 speed / 2s" rates). Falls back to string.format(Format, value).
	Describe: ((level: number, value: number) -> string)?,
}

export type HouseTier = {
	Name: string,
	Stars: number,
	LockpickTime: number, -- seconds you must hold the prompt to open a door
	AlarmWindup: number, -- seconds between the alarm going off and the defenders giving chase
	Color: Color3,
}

export type HouseInfo = {
	Id: string, -- name of the house model in Workspace.Map.Houses
	DisplayName: string,
	Tier: number, -- index into Config.HouseTiers
	Guard: string, -- key into Config.Guards
	GuardCount: number?, -- how many of that defender the house has (default 1)
}

export type GuardInfo = {
	DisplayName: string,
	Kind: string, -- "Cat" | "Dog" | "Human" | "Wizard" | "Beast" | "Robot" | "Vehicle"
	Icon: string,
	-- Studs per second the defender moves at once it is out of the house. Inside a
	-- house everyone moves at the standard Roblox speed instead (Config.Alarm.InsideSpeed).
	Speed: number,
}

export type LightingPreset = {
	ClockTime: number,
	Brightness: number,
	ExposureCompensation: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	FogColor: Color3,
	AtmosphereColor: Color3,
	AtmosphereDecay: Color3,
}

local Format = require(script.Parent.Format)

local Config = {}

Config.GameName = "Steal an Item"

--------------------------------------------------------------------------------
-- Economy
--------------------------------------------------------------------------------
Config.Economy = {
	StartingCash = 0,
	-- Every item sitting in your warehouse earns (value * IncomeRatio) cash per second.
	IncomeRatio = 1 / 40,
	-- Items sold from your warehouse shelves pay out this fraction of their value.
	SellRatio = 1,
	AutosaveInterval = 90, -- seconds
}

--------------------------------------------------------------------------------
-- Upgrades (bought in the shop)
--------------------------------------------------------------------------------
Config.Upgrades = {
	{
		Id = "Bag",
		DisplayName = "Loot Bag",
		Icon = "🎒",
		Description = "Carry more stolen items at once.",
		Values = { 2, 3, 4, 5, 6, 8, 10, 12 },
		Costs = { 0, 150, 600, 2000, 6000, 18000, 55000, 160000 },
		Format = "%d items",
	},
	{
		Id = "Storage",
		DisplayName = "Warehouse Space",
		Icon = "📦",
		Description = "More shelves = more items earning you cash.",
		Values = { 10, 15, 20, 30, 40, 50 },
		Costs = { 0, 600, 3000, 12000, 45000, 150000 },
		Format = "%d slots",
	},
	{
		Id = "Treadmill",
		DisplayName = "Treadmill",
		Icon = "🏃",
		Description = "Your warehouse treadmill trains faster (AFK works!)",
		-- Speed handed out per tick of training. Every level doubles it and halves
		-- the wait between ticks (see Config.treadmillTick), so each level trains
		-- four times as fast as the last.
		Values = { 1, 2, 4, 8, 16, 32, 64, 128 },
		-- Exponential: every level costs 4x the last, in step with the treadmill.
		Costs = { 0, 300, 1200, 4800, 19200, 76800, 307200, 1228800 },
		Format = "+%s speed",
		Describe = function(level: number): string
			return Config.treadmillText(level)
		end,
	},
} :: { Upgrade }

local upgradesById: { [string]: Upgrade } = {}
for _, upgrade in Config.Upgrades do
	upgradesById[upgrade.Id] = upgrade
end
Config.UpgradesById = upgradesById

-- Returns the value an upgrade gives at a given level (clamped to valid levels).
function Config.getUpgradeValue(upgradeId: string, level: number): number
	local upgrade = upgradesById[upgradeId]
	if not upgrade then
		return 0
	end
	local index = math.clamp(math.floor(level), 1, #upgrade.Values)
	return upgrade.Values[index]
end

--------------------------------------------------------------------------------
-- Speed training
--
-- The "Speed" stat (the HUD, the leaderboard and the treadmill all quote it) is
-- a quarter of the speed you actually move at:
--
--     Speed 4  =  16 studs/s   (what you start with)
--     Speed 5  =  20 studs/s   (one speed point = four studs/s)
--
-- There is no ceiling: the longer you run, the faster you get.
--------------------------------------------------------------------------------
Config.Speed = {
	BaseWalkSpeed = 16, -- Roblox default walk speed
	SpeedDivisor = 4, -- the speed you move at is the Speed stat times this
	-- Speed is uncapped; set a number here if you ever want a ceiling back.
	MaxWalkSpeed = math.huge,
}

-- The Speed stat for a number of trained speed points (it starts at BaseWalkSpeed / SpeedDivisor).
function Config.speedStatForPoints(points: number): number
	local base = math.floor(Config.Speed.BaseWalkSpeed / Config.Speed.SpeedDivisor)
	return base + math.max(0, math.floor(points))
end

-- The speed you move at: always exactly SpeedDivisor times the Speed stat.
function Config.walkSpeedForPoints(points: number): number
	local walkSpeed = Config.speedStatForPoints(points) * Config.Speed.SpeedDivisor
	return math.min(walkSpeed, Config.Speed.MaxWalkSpeed)
end

-- Every warehouse has its own treadmill out front. Walk onto yours and you
-- run by yourself (AFK is fine), earning the "Treadmill" upgrade's speed/s.
Config.Treadmill = {
	-- Training stops if your character ends up further than this (studs) from the middle of the belt.
	MaxDistance = 4,
	-- Seconds after hopping off before walking onto the belt starts you running again.
	RemountCooldown = 0.75,
	-- How fast the belt stripes scroll (studs/s) and how fast your legs move, per level.
	BeltSpeedBase = 8,
	BeltSpeedPerLevel = 1.5,
	RunAnimSpeedBase = 1,
	RunAnimSpeedPerLevel = 0.08,
	-- Speed training in two numbers: at level 1 the treadmill hands you
	-- `BaseAmount` speed every `BaseInterval` seconds. Every level doubles the
	-- amount and halves the interval, so level 8 gives 128 speed every 1/32 s.
	-- (Config.treadmillTick turns a level into those two numbers.)
	BaseAmount = 1,
	BaseInterval = 4,
	-- The treadmill's trim gets flashier with every upgrade level.
	LevelColors = {
		Color3.fromRGB(200, 205, 215), -- 1 silver
		Color3.fromRGB(80, 220, 120), -- 2 green
		Color3.fromRGB(70, 170, 255), -- 3 blue
		Color3.fromRGB(170, 110, 255), -- 4 purple
		Color3.fromRGB(255, 110, 200), -- 5 pink
		Color3.fromRGB(255, 140, 40), -- 6 orange
		Color3.fromRGB(255, 70, 70), -- 7 red
		Color3.fromRGB(255, 205, 40), -- 8 gold
	},
}

-- How much speed a treadmill of this level hands out and how long you wait for it:
-- (amount, interval) in seconds. Level 1 is (1, 4), level 2 (2, 2), level 8 (128, 1/32).
function Config.treadmillTick(level: number): (number, number)
	local settings = Config.Treadmill
	local amount = math.max(Config.getUpgradeValue("Treadmill", level), 1e-9)
	local interval = settings.BaseInterval * (settings.BaseAmount / amount)
	return amount, interval
end

-- Speed per second a treadmill of this level trains you at: the first level gives
-- 0.25, and every level after that is four times faster.
function Config.treadmillRate(level: number): number
	local amount, interval = Config.treadmillTick(level)
	return amount / interval
end

-- The treadmill's rate in words: "+2 speed / 2s" while a tick takes a second or
-- longer, "64 speed/s" once the ticks come faster than that.
function Config.treadmillText(level: number): string
	local amount, interval = Config.treadmillTick(level)
	if interval >= 1 then
		return string.format("+%s speed / %ss", Format.decimal(amount, 3), Format.decimal(interval, 3))
	end
	return string.format("%s speed/s", Format.commas(Config.treadmillRate(level)))
end

-- Writes an upgrade's value the way the shop and the purchase toasts show it.
function Config.describeUpgrade(upgradeId: string, level: number): string
	local upgrade = upgradesById[upgradeId]
	if not upgrade then
		return tostring(level)
	end
	local index = math.clamp(math.floor(level), 1, #upgrade.Values)
	local value = upgrade.Values[index]
	if upgrade.Describe then
		return upgrade.Describe(index, value)
	end
	return string.format(upgrade.Format, value)
end

-- Treadmill trim colour for an upgrade level.
function Config.treadmillColor(level: number): Color3
	local colors = Config.Treadmill.LevelColors
	return colors[math.clamp(math.floor(level), 1, #colors)]
end

--------------------------------------------------------------------------------
-- Rebirth
-- Trade every speed point you have trained for a permanent production
-- multiplier (treadmill training AND warehouse income). The first rebirth
-- costs a million speed and every one after costs x2.5 more, so the ladder
-- never ends; each rebirth adds a flat x0.1 to the multiplier, forever.
--------------------------------------------------------------------------------
Config.Rebirth = {
	BaseCost = 1_000_000, -- speed points for your first rebirth
	CostGrowth = 2.5, -- every rebirth after costs this many times more (no cap)
	BonusStep = 0.1, -- the multiplier grows by this per rebirth: x1, x1.1, x1.2, ...
	PromptDistance = 10,
}

-- The speed-point price of rebirth #count+1 (count = rebirths completed so far).
function Config.rebirthCost(count: number): number
	return math.floor(Config.Rebirth.BaseCost * Config.Rebirth.CostGrowth ^ math.max(0, math.floor(count)))
end

-- The production multiplier at a given rebirth count: x1 with none, x1.5 at one.
function Config.rebirthMultiplier(count: number): number
	return 1 + Config.Rebirth.BonusStep * math.max(0, math.floor(count))
end

--------------------------------------------------------------------------------
-- Houses & security
--------------------------------------------------------------------------------
-- Index = the Tier attribute on each house model.
Config.HouseTiers = {
	{
		Name = "Easy",
		Stars = 1,
		LockpickTime = 0.6,
		AlarmWindup = 2.0,
		Color = Color3.fromRGB(120, 220, 120),
	},
	{
		Name = "Medium",
		Stars = 2,
		LockpickTime = 1.2,
		AlarmWindup = 1.6,
		Color = Color3.fromRGB(90, 180, 255),
	},
	{
		Name = "Hard",
		Stars = 3,
		LockpickTime = 2.0,
		AlarmWindup = 1.3,
		Color = Color3.fromRGB(190, 120, 255),
	},
	{
		Name = "Extreme",
		Stars = 4,
		LockpickTime = 3.0,
		AlarmWindup = 1.0,
		Color = Color3.fromRGB(255, 190, 40),
	},
} :: { HouseTier }

-- Every house on the street, in order from the yard (spawn) to the Mansion at the end of the road.
-- Keep one house per line: tools/map_builder.py reads this list to build the street.
Config.Houses = {
	{ Id = "House1", DisplayName = "Maple Cottage", Tier = 1, Guard = "TuxedoCat" },
	{ Id = "House2", DisplayName = "Willow Cottage", Tier = 1, Guard = "Puppy" },
	{ Id = "House3", DisplayName = "Rose Cottage", Tier = 1, Guard = "Labrador" },
	{ Id = "House4", DisplayName = "Daisy Cottage", Tier = 1, Guard = "GuardDog" },
	{ Id = "House5", DisplayName = "Blue Oak House", Tier = 2, Guard = "HomeOwner" },
	{ Id = "House6", DisplayName = "Cedar House", Tier = 2, Guard = "OffDutyOfficer" },
	{ Id = "House7", DisplayName = "Elm Street House", Tier = 2, Guard = "Wizard" },
	{ Id = "House8", DisplayName = "Birch House", Tier = 2, Guard = "TRex" },
	{ Id = "House9", DisplayName = "Pine Ridge House", Tier = 3, Guard = "SecurityBot", GuardCount = 3 },
	{ Id = "House10", DisplayName = "Aspen House", Tier = 3, Guard = "SecurityCar" },
	{ Id = "Mansion", DisplayName = "Grand Mansion", Tier = 4, Guard = "SecurityCar", GuardCount = 4 },
} :: { HouseInfo }

-- Who defends each house (models live in shared/Guards; docks are built by tools/map_builder.py).
-- `Speed` is the speed the defender chases you at once it is out of the house — inside, everyone
-- moves at the standard Roblox speed. The defenders get terrifyingly fast down the street, so the
-- house itself is the fair fight and the front gate is where you find out if you're faster.
-- One guard per line, read by the map builder.
Config.Guards = {
	TuxedoCat = { DisplayName = "Tuxedo Cat", Kind = "Cat", Icon = "🐱", Speed = 10 },
	Puppy = { DisplayName = "Puppy", Kind = "Dog", Icon = "🐶", Speed = 25 },
	Labrador = { DisplayName = "Labrador", Kind = "Dog", Icon = "🐶", Speed = 70 },
	GuardDog = { DisplayName = "Guard Dog", Kind = "Dog", Icon = "🐕", Speed = 300 },
	HomeOwner = { DisplayName = "Home Owner", Kind = "Human", Icon = "🧑", Speed = 1200 },
	OffDutyOfficer = { DisplayName = "Off-Duty Officer", Kind = "Human", Icon = "👮", Speed = 17500 },
	Wizard = { DisplayName = "Wizard", Kind = "Wizard", Icon = "🧙", Speed = 50000 },
	TRex = { DisplayName = "T-Rex", Kind = "Beast", Icon = "🦖", Speed = 100000 },
	SecurityBot = { DisplayName = "Security Bot", Kind = "Robot", Icon = "🤖", Speed = 1100000 },
	SecurityCar = { DisplayName = "Security Car", Kind = "Vehicle", Icon = "🚔", Speed = 125000000 },
} :: { [string]: GuardInfo }

local housesById: { [string]: HouseInfo } = {}
for order, house in Config.Houses do
	housesById[house.Id] = house
	assert(Config.Guards[house.Guard], "Unknown guard " .. house.Guard .. " for " .. house.Id)
	assert(Config.HouseTiers[house.Tier], "Unknown tier for " .. house.Id .. " (#" .. order .. ")")
end

function Config.getHouse(houseId: string): HouseInfo?
	return housesById[houseId]
end

function Config.getGuard(houseId: string): GuardInfo
	local house = housesById[houseId]
	return Config.Guards[if house then house.Guard else "TuxedoCat"]
end

Config.Stealing = {
	HoldDuration = 0.35, -- seconds to hold the Steal prompt
	PromptDistance = 8,
}

Config.Alarm = {
	CatchRadius = 3.75, -- studs (measured along the ground) between a guard and you to get BUSTED
	CalmDownTime = 4, -- seconds with nobody in the chase area before the alarm resets
	BustImmunity = 4, -- seconds you can't be caught again after getting busted
	DroneAimHeight = 1.5, -- drones aim this far above your HumanoidRootPart
	DroneDockHeight = 5, -- how high drones hover above their charging dock
	GuardReturnSpeed = 16, -- how fast guards walk/fly back to bed once the alarm calms down
	-- Defenders do not give up at the property line any more: they chase you all the way back
	-- down the street and turn around at the canyon mouth. The yard is safe.
	InsideSpeed = 16, -- the standard Roblox movement speed: everyone (you and them) moves this fast inside a house
	LaneHalfWidth = 22, -- how far off the middle of the road a chase is willing to go (studs)
	SafeX = -200, -- once you are west of this (the canyon mouth) the chase is over
	HouseFrontInset = 18, -- the front wall sits this far inside the property (the map sets it per house)
}

Config.Doors = {
	StayOpenTime = 25, -- seconds a picked door stays open (it never closes on someone)
}

Config.Lasers = {
	OnTime = 2.2, -- seconds a laser beam is active
	OffTime = 1.4, -- seconds a laser beam is off
}

--------------------------------------------------------------------------------
-- Night & day
--------------------------------------------------------------------------------
-- Heists happen at night. Every cycle ends with a short DAYTIME when the owners
-- are home: all houses lock up, nothing can be stolen and every house restocks
-- its loot. That's the only time loot comes back!
Config.DayNight = {
	NightLength = 210, -- seconds (3½ minutes of stealing)
	DayLength = 30, -- seconds (houses closed, loot restocks)
	FadeTime = 5, -- seconds the sky takes to change
	Night = {
		-- Pastel moonlight: clearly night, but soft violet instead of pitch navy.
		ClockTime = 0.3,
		Brightness = 1.9,
		ExposureCompensation = 0.4,
		Ambient = Color3.fromRGB(118, 120, 158),
		OutdoorAmbient = Color3.fromRGB(150, 152, 198),
		FogColor = Color3.fromRGB(96, 102, 148),
		AtmosphereColor = Color3.fromRGB(132, 142, 202),
		AtmosphereDecay = Color3.fromRGB(98, 108, 172),
	},
	Day = {
		-- Bright washed daylight: white-ish sky that makes the candy town glow.
		ClockTime = 13.5,
		Brightness = 3.0,
		ExposureCompensation = 0.05,
		Ambient = Color3.fromRGB(150, 150, 168),
		OutdoorAmbient = Color3.fromRGB(188, 188, 204),
		FogColor = Color3.fromRGB(228, 226, 240),
		AtmosphereColor = Color3.fromRGB(212, 220, 250),
		AtmosphereDecay = Color3.fromRGB(160, 170, 220),
	},
} :: {
	NightLength: number,
	DayLength: number,
	FadeTime: number,
	Night: LightingPreset,
	Day: LightingPreset,
}

--------------------------------------------------------------------------------
-- Sell point (the market stall in the yard, where loot you are carrying is sold)
--------------------------------------------------------------------------------
Config.Market = {
	PromptDistance = 12,
}

--------------------------------------------------------------------------------
-- Rarity auras
-- Items of this rarity and above glow in the world in their rarity's colour
-- (the same colour the Loot Index and the toasts use).
--------------------------------------------------------------------------------
Config.Aura = {
	MinOrder = 3, -- 1 Common, 2 Rare, 3 Epic, 4 Legendary — so Epic and above
	Size = 1.18, -- the glow shell is this much wider than the item's widest side
	Transparency = 0.86,
	Pulse = 0.06, -- the client breathes the shell's transparency by this much
	FillTransparency = 0.78, -- the outline glow around the item's silhouette
	OutlineTransparency = 0.1,
}

--------------------------------------------------------------------------------
-- Sounds
-- These use sounds that ship with every Roblox client so they always work.
-- Swap in your own "rbxassetid://..." audio for a more polished feel!
--------------------------------------------------------------------------------
Config.Sounds = {
	Steal = "rbxasset://sounds/action_get_up.mp3",
	Deposit = "rbxasset://sounds/volume_slider.ogg",
	Purchase = "rbxasset://sounds/volume_slider.ogg",
	Click = "rbxasset://sounds/volume_slider.ogg",
	Error = "rbxasset://sounds/action_jump_land.mp3",
	Busted = "rbxasset://sounds/ouch.ogg",
	AlarmBeep = "rbxasset://sounds/volume_slider.ogg",
	LevelUp = "rbxasset://sounds/action_jump.mp3",
}

return Config
