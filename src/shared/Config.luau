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
}

export type HouseTier = {
	Name: string,
	Stars: number,
	DroneSpeed: number, -- studs per second; compare with your walk speed!
	LockpickTime: number, -- seconds you must hold the prompt to open a door
	RestockTime: number, -- seconds before a stolen item is replaced
	AlarmWindup: number, -- seconds between the alarm going off and drones chasing
	Color: Color3,
}

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
		Values = { 2, 3, 5, 8, 12, 17, 24, 34 },
		Costs = { 0, 300, 1200, 4000, 12000, 35000, 90000, 220000 },
		Format = "%d XP/s",
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
--------------------------------------------------------------------------------
Config.Speed = {
	BaseWalkSpeed = 16, -- Roblox default walk speed
	SpeedPerLevel = 1,
	MaxLevel = 50, -- max walk speed = 16 + 50 = 66
}

-- Training XP needed to go from `level` to `level + 1`.
function Config.xpForLevel(level: number): number
	return 8 + level * 2
end

function Config.walkSpeedForLevel(level: number): number
	return Config.Speed.BaseWalkSpeed + level * Config.Speed.SpeedPerLevel
end

-- Every warehouse has its own treadmill out front. Walk onto yours and you
-- run by yourself (AFK is fine) earning the "Treadmill" upgrade's XP/s.
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
		Name = "Cottage",
		Stars = 1,
		DroneSpeed = 11,
		LockpickTime = 0.6,
		RestockTime = 35,
		AlarmWindup = 2.0,
		Color = Color3.fromRGB(120, 220, 120),
	},
	{
		Name = "Suburban House",
		Stars = 2,
		DroneSpeed = 18,
		LockpickTime = 1.2,
		RestockTime = 50,
		AlarmWindup = 1.6,
		Color = Color3.fromRGB(90, 180, 255),
	},
	{
		Name = "Modern Villa",
		Stars = 3,
		DroneSpeed = 26,
		LockpickTime = 2.0,
		RestockTime = 65,
		AlarmWindup = 1.3,
		Color = Color3.fromRGB(190, 120, 255),
	},
	{
		Name = "Mansion",
		Stars = 4,
		DroneSpeed = 34,
		LockpickTime = 3.0,
		RestockTime = 80,
		AlarmWindup = 1.0,
		Color = Color3.fromRGB(255, 190, 40),
	},
} :: { HouseTier }

Config.Stealing = {
	HoldDuration = 0.35, -- seconds to hold the Steal prompt
	PromptDistance = 8,
}

Config.Alarm = {
	CatchRadius = 3.75, -- studs between a drone and your character to get BUSTED
	CalmDownTime = 4, -- seconds with nobody on the property before the alarm resets
	BustImmunity = 4, -- seconds you can't be caught again after getting busted
	DroneAimHeight = 1.5, -- drones aim this far above your HumanoidRootPart
	DroneDockHeight = 5, -- how high drones hover above their charging dock
	DroneReturnSpeed = 16,
}

Config.Doors = {
	StayOpenTime = 25, -- seconds a picked door stays open (it never closes on someone)
}

Config.Lasers = {
	OnTime = 2.2, -- seconds a laser beam is active
	OffTime = 1.4, -- seconds a laser beam is off
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
