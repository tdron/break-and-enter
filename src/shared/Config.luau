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
	GuardSpeed: number, -- studs per second; compare with your walk speed!
	LockpickTime: number, -- seconds you must hold the prompt to open a door
	AlarmWindup: number, -- seconds between the alarm going off and the guards giving chase
	Color: Color3,
}

export type HouseInfo = {
	Id: string, -- name of the house model in Workspace.Map.Houses
	DisplayName: string,
	Tier: number, -- index into Config.HouseTiers
	Guard: string, -- key into Config.Guards
}

export type GuardInfo = {
	DisplayName: string,
	Kind: string, -- "Cat" | "Dog" | "Drone"
	Icon: string,
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
		Id = "Engine",
		DisplayName = "Getaway Engine",
		Icon = "🏎️",
		Description = "A faster getaway car. New paint job included!",
		Values = { 45, 55, 66, 78, 92, 110 },
		Costs = { 0, 400, 1600, 6000, 22000, 80000 },
		Format = "%d mph",
	},
	{
		Id = "Trunk",
		DisplayName = "Trunk Space",
		Icon = "🧳",
		Description = "Stash more loot in your car's trunk.",
		Values = { 4, 6, 9, 13, 18, 25 },
		Costs = { 0, 300, 1200, 4500, 16000, 60000 },
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
-- Houses & security
--------------------------------------------------------------------------------
-- Index = the Tier attribute on each house model.
Config.HouseTiers = {
	{
		Name = "Easy",
		Stars = 1,
		GuardSpeed = 11,
		LockpickTime = 0.6,
		AlarmWindup = 2.0,
		Color = Color3.fromRGB(120, 220, 120),
	},
	{
		Name = "Medium",
		Stars = 2,
		GuardSpeed = 18,
		LockpickTime = 1.2,
		AlarmWindup = 1.6,
		Color = Color3.fromRGB(90, 180, 255),
	},
	{
		Name = "Hard",
		Stars = 3,
		GuardSpeed = 26,
		LockpickTime = 2.0,
		AlarmWindup = 1.3,
		Color = Color3.fromRGB(190, 120, 255),
	},
	{
		Name = "Extreme",
		Stars = 4,
		GuardSpeed = 34,
		LockpickTime = 3.0,
		AlarmWindup = 1.0,
		Color = Color3.fromRGB(255, 190, 40),
	},
} :: { HouseTier }

-- Every house on the street, in order from the yard (spawn) to the Mansion at the end of the road.
-- Keep one house per line: tools/map_builder.py reads this list to build the street.
Config.Houses = {
	{ Id = "House1", DisplayName = "Maple Cottage", Tier = 1, Guard = "GingerCat" },
	{ Id = "House2", DisplayName = "Willow Cottage", Tier = 1, Guard = "TuxedoCat" },
	{ Id = "House3", DisplayName = "Rose Cottage", Tier = 1, Guard = "SiameseCat" },
	{ Id = "House4", DisplayName = "Daisy Cottage", Tier = 1, Guard = "GreyTabby" },
	{ Id = "House5", DisplayName = "Blue Oak House", Tier = 2, Guard = "Chihuahua" },
	{ Id = "House6", DisplayName = "Cedar House", Tier = 2, Guard = "Pug" },
	{ Id = "House7", DisplayName = "Elm Street House", Tier = 2, Guard = "Corgi" },
	{ Id = "House8", DisplayName = "Birch House", Tier = 2, Guard = "Dalmatian" },
	{ Id = "House9", DisplayName = "Pine Ridge House", Tier = 3, Guard = "GermanShepherd" },
	{ Id = "House10", DisplayName = "Aspen House", Tier = 3, Guard = "Doberman" },
	{ Id = "Mansion", DisplayName = "Grand Mansion", Tier = 4, Guard = "Drone" },
} :: { HouseInfo }

-- Who guards each house (models live in shared/Guards). One guard per line, read by the map builder.
Config.Guards = {
	GingerCat = { DisplayName = "Ginger Cat", Kind = "Cat", Icon = "🐱" },
	TuxedoCat = { DisplayName = "Tuxedo Cat", Kind = "Cat", Icon = "🐱" },
	SiameseCat = { DisplayName = "Siamese Cat", Kind = "Cat", Icon = "🐱" },
	GreyTabby = { DisplayName = "Grey Tabby", Kind = "Cat", Icon = "🐱" },
	Chihuahua = { DisplayName = "Chihuahua", Kind = "Dog", Icon = "🐶" },
	Pug = { DisplayName = "Pug", Kind = "Dog", Icon = "🐶" },
	Corgi = { DisplayName = "Corgi", Kind = "Dog", Icon = "🐶" },
	Dalmatian = { DisplayName = "Dalmatian", Kind = "Dog", Icon = "🐶" },
	GermanShepherd = { DisplayName = "German Shepherd", Kind = "Dog", Icon = "🐕" },
	Doberman = { DisplayName = "Doberman", Kind = "Dog", Icon = "🐕" },
	Drone = { DisplayName = "Security Drone", Kind = "Drone", Icon = "🤖" },
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
	return Config.Guards[if house then house.Guard else "Drone"]
end

Config.Stealing = {
	HoldDuration = 0.35, -- seconds to hold the Steal prompt
	PromptDistance = 8,
}

Config.Alarm = {
	CatchRadius = 3.75, -- studs (measured along the ground) between a guard and you to get BUSTED
	CalmDownTime = 4, -- seconds with nobody on the property before the alarm resets
	BustImmunity = 4, -- seconds you can't be caught again after getting busted
	DroneAimHeight = 1.5, -- drones aim this far above your HumanoidRootPart
	DroneDockHeight = 5, -- how high drones hover above their charging dock
	GuardReturnSpeed = 16, -- how fast guards walk/fly back to bed once the alarm calms down
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
		ClockTime = 0.3,
		Brightness = 1.4,
		ExposureCompensation = 0.35,
		Ambient = Color3.fromRGB(78, 82, 112),
		OutdoorAmbient = Color3.fromRGB(96, 104, 148),
		FogColor = Color3.fromRGB(30, 36, 60),
		AtmosphereColor = Color3.fromRGB(60, 72, 110),
		AtmosphereDecay = Color3.fromRGB(40, 50, 90),
	},
	Day = {
		ClockTime = 13.5,
		Brightness = 2.6,
		ExposureCompensation = 0,
		Ambient = Color3.fromRGB(92, 92, 104),
		OutdoorAmbient = Color3.fromRGB(138, 138, 150),
		FogColor = Color3.fromRGB(192, 192, 192),
		AtmosphereColor = Color3.fromRGB(205, 220, 235),
		AtmosphereDecay = Color3.fromRGB(120, 140, 170),
	},
} :: {
	NightLength: number,
	DayLength: number,
	FadeTime: number,
	Night: LightingPreset,
	Day: LightingPreset,
}

--------------------------------------------------------------------------------
-- Getaway car
--------------------------------------------------------------------------------
Config.Vehicle = {
	HoverHeight = 2.0, -- studs between the ground and the chassis centre
	Acceleration = 38, -- studs/s²
	Braking = 95,
	Coast = 22, -- deceleration when you let go of the throttle
	ReverseFactor = 0.45, -- reverse top speed = top speed * this
	TurnRate = 2.1, -- radians per second at full steering
	MaxForce = 250000,
	MaxTorque = 600000,
	SpawnCooldown = 4, -- seconds between car spawns
	-- Paint colour for each Engine level
	Paints = {
		Color3.fromRGB(196, 72, 56),
		Color3.fromRGB(40, 110, 205),
		Color3.fromRGB(32, 32, 38),
		Color3.fromRGB(255, 160, 20),
		Color3.fromRGB(135, 50, 210),
		Color3.fromRGB(245, 245, 250),
	},
	UnderglowColor = Color3.fromRGB(0, 255, 200),
}

--------------------------------------------------------------------------------
-- Sell point (the market stall in the yard, where loot you are carrying is sold)
--------------------------------------------------------------------------------
Config.Market = {
	-- How close your car has to be to the stall before its trunk can be sold too.
	TrunkRange = 45,
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
