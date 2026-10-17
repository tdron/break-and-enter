--!strict
--[[
	Items
	-----
	Every stealable item: its name, value, rarity, the one house it can be found
	in, and a little 3D model made from plain parts (no uploaded meshes needed).
	Every house has its own set of loot, so collecting them all (see the Loot
	Index in the HUD) means robbing every house on the street.

	Model conventions:
	  * The origin (0, 0, 0) is the bottom-centre of the item, so it sits on a surface.
	  * The item's "front" faces -Z (Roblox's LookVector direction).
	  * Keep items under ~4 studs tall and ~3.6 studs wide so they fit on shelves.
]]

local Config = require(script.Parent.Config)

export type LightSpec = { Color: Color3, Range: number, Brightness: number }

export type PartSpec = {
	Shape: string, -- "Block" | "Ball" | "Cylinder" | "Wedge"
	Size: Vector3,
	Position: Vector3,
	Rotation: Vector3?, -- degrees
	Color: Color3,
	Material: Enum.Material?,
	Transparency: number?,
	Reflectance: number?,
	Light: LightSpec?,
}

export type ItemDef = {
	Id: string,
	DisplayName: string,
	House: string, -- Config.Houses id of the only house this item spawns in
	Tier: number, -- that house's tier
	Value: number,
	Rarity: string,
	Parts: { PartSpec },
}

export type Rarity = { Color: Color3, Weight: number, Order: number }

type Extra = {
	Rotation: Vector3?,
	Transparency: number?,
	Reflectance: number?,
	Light: LightSpec?,
}

local Items = {}

Items.Rarities = {
	Common = { Color = Color3.fromRGB(225, 225, 225), Weight = 60, Order = 1 },
	Rare = { Color = Color3.fromRGB(80, 170, 255), Weight = 28, Order = 2 },
	Epic = { Color = Color3.fromRGB(190, 100, 255), Weight = 10, Order = 3 },
	Legendary = { Color = Color3.fromRGB(255, 190, 40), Weight = 2, Order = 4 },
} :: { [string]: Rarity }

local V = Vector3.new
local C = Color3.fromRGB
local M = Enum.Material

local VERTICAL = V(0, 0, 90) -- rotate a cylinder so its axis points up
local FACING = V(0, 90, 0) -- rotate a cylinder so its axis points forward

local GOLD = C(255, 196, 54)
local SILVER = C(200, 202, 208)
local BLACK = C(28, 28, 32)
local WHITE = C(240, 240, 240)

local function P(
	shape: string,
	size: Vector3,
	position: Vector3,
	color: Color3,
	material: Enum.Material?,
	extra: Extra?
): PartSpec
	local spec: PartSpec = {
		Shape = shape,
		Size = size,
		Position = position,
		Color = color,
		Material = material,
	}
	if extra then
		spec.Rotation = extra.Rotation
		spec.Transparency = extra.Transparency
		spec.Reflectance = extra.Reflectance
		spec.Light = extra.Light
	end
	return spec
end

local list: { ItemDef } = {}
local byId: { [string]: ItemDef } = {}

local function define(id: string, displayName: string, houseId: string, value: number, rarity: string, parts: { PartSpec })
	assert(Items.Rarities[rarity], "Unknown rarity " .. rarity)
	assert(byId[id] == nil, "Duplicate item id " .. id)
	local house = Config.getHouse(houseId)
	assert(house, "Unknown house " .. houseId .. " for item " .. id)
	local def: ItemDef = {
		Id = id,
		DisplayName = displayName,
		House = houseId,
		Tier = house.Tier,
		Value = value,
		Rarity = rarity,
		Parts = parts,
	}
	table.insert(list, def)
	byId[id] = def
end

--------------------------------------------------------------------------------
-- Maple Cottage — guarded by a ginger cat
--------------------------------------------------------------------------------
define("Toaster", "Toaster", "House1", 25, "Common", {
	P("Block", V(1.6, 1.0, 1.0), V(0, 0.5, 0), SILVER, M.Metal),
	P("Block", V(1.1, 0.06, 0.18), V(0, 1.01, -0.22), BLACK),
	P("Block", V(1.1, 0.06, 0.18), V(0, 1.01, 0.22), BLACK),
	P("Block", V(0.95, 0.4, 0.12), V(0, 1.15, -0.22), C(214, 160, 92)),
	P("Block", V(0.15, 0.3, 0.2), V(0.88, 0.62, 0), BLACK),
})

local YARN_RED = C(220, 60, 70)
define("YarnBasket", "Yarn Basket", "House1", 30, "Common", {
	P("Cylinder", V(0.9, 1.6, 1.6), V(0, 0.45, 0), C(176, 124, 72), M.WoodPlanks, { Rotation = VERTICAL }),
	P("Cylinder", V(0.14, 1.72, 1.72), V(0, 0.9, 0), C(130, 86, 46), M.Wood, { Rotation = VERTICAL }),
	P("Ball", V(0.72, 0.72, 0.72), V(-0.3, 1.05, -0.12), YARN_RED, M.Fabric),
	P("Ball", V(0.66, 0.66, 0.66), V(0.34, 1.02, 0.12), C(70, 120, 220), M.Fabric),
	P("Ball", V(0.6, 0.6, 0.6), V(0.02, 1.08, 0.42), C(250, 200, 60), M.Fabric),
	P("Block", V(0.07, 1.5, 0.07), V(-0.05, 1.55, 0.1), SILVER, M.Metal, { Rotation = V(0, 0, 24) }),
	P("Block", V(0.07, 1.5, 0.07), V(0.12, 1.55, 0.1), SILVER, M.Metal, { Rotation = V(0, 0, -18) }),
	P("Block", V(0.07, 0.8, 0.07), V(-0.83, 0.55, -0.18), YARN_RED, M.Fabric, { Rotation = V(0, 0, 8) }),
})

define("CoffeeMaker", "Coffee Maker", "House1", 70, "Rare", {
	P("Block", V(1.2, 0.2, 1.0), V(0, 0.1, 0), BLACK),
	P("Block", V(1.2, 1.9, 0.4), V(0, 0.95, 0.3), BLACK),
	P("Block", V(1.2, 0.35, 1.0), V(0, 2.07, 0), BLACK),
	P(
		"Cylinder",
		V(0.8, 0.72, 0.72),
		V(0, 0.6, -0.15),
		C(190, 225, 255),
		M.Glass,
		{ Rotation = VERTICAL, Transparency = 0.45 }
	),
	P("Cylinder", V(0.45, 0.62, 0.62), V(0, 0.43, -0.15), C(84, 50, 28), nil, { Rotation = VERTICAL }),
	P("Block", V(0.2, 0.08, 0.08), V(0.4, 1.95, -0.51), C(255, 60, 60), M.Neon),
})

define("GrandmasJewels", "Grandma's Jewels", "House1", 400, "Epic", {
	P("Block", V(1.3, 0.6, 0.9), V(0, 0.3, 0), C(110, 30, 64), M.Fabric),
	P("Block", V(1.3, 0.9, 0.1), V(0, 1.0, 0.48), C(110, 30, 64), M.Fabric, { Rotation = V(15, 0, 0) }),
	P("Block", V(1.34, 0.08, 0.94), V(0, 0.6, 0), GOLD, M.Metal),
	P("Ball", V(0.24, 0.24, 0.24), V(-0.35, 0.68, -0.15), WHITE),
	P("Ball", V(0.24, 0.24, 0.24), V(-0.12, 0.7, -0.2), WHITE),
	P("Ball", V(0.24, 0.24, 0.24), V(0.12, 0.7, -0.2), WHITE),
	P("Ball", V(0.24, 0.24, 0.24), V(0.35, 0.68, -0.15), WHITE),
	P("Ball", V(0.34, 0.34, 0.34), V(0, 0.75, 0.15), C(255, 40, 90), M.Glass, { Transparency = 0.1 }),
})

--------------------------------------------------------------------------------
-- Willow Cottage — guarded by a tuxedo cat
--------------------------------------------------------------------------------
define("DeskLamp", "Desk Lamp", "House2", 45, "Common", {
	P("Cylinder", V(0.2, 1.2, 1.2), V(0, 0.1, 0), C(60, 60, 66), M.Metal, { Rotation = VERTICAL }),
	P("Block", V(0.16, 1.7, 0.16), V(0, 1.05, 0), C(60, 60, 66), M.Metal),
	P("Cylinder", V(0.9, 1.2, 1.2), V(0, 2.1, 0), C(255, 214, 102), M.SmoothPlastic, { Rotation = VERTICAL }),
	P("Ball", V(0.5, 0.5, 0.5), V(0, 1.75, 0), C(255, 244, 200), M.Neon),
})

local FUR = C(156, 104, 62)
local SNOUT = C(214, 172, 124)
define("TeddyBear", "Teddy Bear", "House2", 50, "Common", {
	P("Ball", V(1.3, 1.3, 1.3), V(0, 0.75, 0), FUR, M.Fabric),
	P("Ball", V(1.05, 1.05, 1.05), V(0, 1.75, 0), FUR, M.Fabric),
	P("Ball", V(0.42, 0.42, 0.42), V(-0.4, 2.2, 0), FUR, M.Fabric),
	P("Ball", V(0.42, 0.42, 0.42), V(0.4, 2.2, 0), FUR, M.Fabric),
	P("Ball", V(0.45, 0.45, 0.45), V(0, 1.62, -0.42), SNOUT, M.Fabric),
	P("Ball", V(0.14, 0.14, 0.14), V(0, 1.7, -0.64), BLACK),
	P("Ball", V(0.15, 0.15, 0.15), V(-0.2, 1.88, -0.45), BLACK),
	P("Ball", V(0.15, 0.15, 0.15), V(0.2, 1.88, -0.45), BLACK),
	P("Ball", V(0.5, 0.5, 0.5), V(-0.62, 0.95, -0.15), FUR, M.Fabric),
	P("Ball", V(0.5, 0.5, 0.5), V(0.62, 0.95, -0.15), FUR, M.Fabric),
	P("Ball", V(0.55, 0.55, 0.55), V(-0.38, 0.28, -0.38), FUR, M.Fabric),
	P("Ball", V(0.55, 0.55, 0.55), V(0.38, 0.28, -0.38), FUR, M.Fabric),
	P("Block", V(0.6, 0.22, 0.16), V(0, 1.28, -0.5), C(220, 40, 60)),
})

local CLOCK_WOOD = C(118, 72, 40)
define("CuckooClock", "Cuckoo Clock", "House2", 130, "Rare", {
	P("Block", V(1.4, 1.4, 0.7), V(0, 0.7, 0), CLOCK_WOOD, M.Wood),
	P("Block", V(1.0, 0.1, 0.9), V(-0.39, 1.67, 0), C(70, 40, 22), M.Wood, { Rotation = V(0, 0, 35) }),
	P("Block", V(1.0, 0.1, 0.9), V(0.39, 1.67, 0), C(70, 40, 22), M.Wood, { Rotation = V(0, 0, -35) }),
	P("Cylinder", V(0.06, 0.8, 0.8), V(0, 0.72, -0.36), C(245, 238, 220), nil, { Rotation = FACING }),
	P("Block", V(0.05, 0.3, 0.03), V(0, 0.82, -0.4), BLACK),
	P("Block", V(0.22, 0.05, 0.03), V(0.09, 0.72, -0.4), BLACK),
	P("Block", V(0.32, 0.3, 0.04), V(0, 1.25, -0.36), C(40, 26, 16)),
	P("Ball", V(0.2, 0.2, 0.2), V(0, 1.27, -0.44), C(250, 210, 60)),
	P("Block", V(0.06, 0.06, 0.12), V(0, 1.27, -0.57), C(255, 140, 40)),
	P("Block", V(0.3, 0.12, 0.12), V(-0.45, 0.06, -0.3), C(60, 120, 50), M.Wood),
	P("Block", V(0.3, 0.12, 0.12), V(0.45, 0.06, -0.3), C(60, 120, 50), M.Wood),
})

local TEA_SILVER = C(214, 216, 224)
define("SilverTeaSet", "Silver Tea Set", "House2", 650, "Epic", {
	P("Block", V(2.3, 0.08, 1.5), V(0, 0.04, 0), TEA_SILVER, M.Metal, { Reflectance = 0.3 }),
	P("Ball", V(0.95, 0.95, 0.95), V(-0.45, 0.55, 0), TEA_SILVER, M.Metal, { Reflectance = 0.35 }),
	P("Block", V(0.13, 0.55, 0.13), V(-1.02, 0.66, 0), TEA_SILVER, M.Metal, { Rotation = V(0, 0, 40), Reflectance = 0.35 }),
	P("Block", V(0.1, 0.5, 0.1), V(0.08, 0.6, 0), TEA_SILVER, M.Metal, { Reflectance = 0.35 }),
	P("Cylinder", V(0.1, 0.5, 0.5), V(-0.45, 1.02, 0), TEA_SILVER, M.Metal, { Rotation = VERTICAL, Reflectance = 0.35 }),
	P("Ball", V(0.2, 0.2, 0.2), V(-0.45, 1.14, 0), GOLD, M.Metal),
	P("Cylinder", V(0.04, 0.66, 0.66), V(0.55, 0.1, -0.32), TEA_SILVER, M.Metal, { Rotation = VERTICAL }),
	P("Cylinder", V(0.36, 0.44, 0.44), V(0.55, 0.3, -0.32), WHITE, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.04, 0.66, 0.66), V(0.6, 0.1, 0.38), TEA_SILVER, M.Metal, { Rotation = VERTICAL }),
	P("Cylinder", V(0.36, 0.44, 0.44), V(0.6, 0.3, 0.38), WHITE, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.05, 0.36, 0.36), V(0.55, 0.47, -0.32), C(150, 90, 40), nil, { Rotation = VERTICAL }),
})

--------------------------------------------------------------------------------
-- Rose Cottage — guarded by a Siamese cat
--------------------------------------------------------------------------------
define("OldRadio", "Old Radio", "House3", 75, "Common", {
	P("Block", V(1.8, 1.1, 0.8), V(0, 0.55, 0), C(122, 78, 44), M.Wood),
	P("Block", V(0.8, 0.8, 0.06), V(-0.4, 0.55, -0.41), C(48, 40, 34), M.Fabric),
	P("Cylinder", V(0.08, 0.42, 0.42), V(0.48, 0.7, -0.42), C(236, 226, 196), nil, { Rotation = FACING }),
	P("Cylinder", V(0.12, 0.2, 0.2), V(0.34, 0.28, -0.44), BLACK, nil, { Rotation = FACING }),
	P("Cylinder", V(0.12, 0.2, 0.2), V(0.62, 0.28, -0.44), BLACK, nil, { Rotation = FACING }),
	P("Block", V(0.06, 1.3, 0.06), V(0.6, 1.6, 0.2), SILVER, M.Metal, { Rotation = V(0, 0, -18) }),
	P("Block", V(1.0, 0.12, 0.16), V(0, 1.22, 0), C(70, 46, 26), M.Wood),
})

define("CookieJar", "Cookie Jar", "House3", 85, "Common", {
	P("Cylinder", V(1.2, 1.2, 1.2), V(0, 0.6, 0), C(200, 235, 245), M.Glass, { Rotation = VERTICAL, Transparency = 0.45 }),
	P("Cylinder", V(0.14, 0.85, 0.85), V(0, 0.2, 0), C(196, 136, 72), nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.14, 0.85, 0.85), V(0.05, 0.4, 0.04), C(176, 116, 58), nil, { Rotation = V(4, 0, 90) }),
	P("Cylinder", V(0.14, 0.85, 0.85), V(-0.04, 0.6, -0.03), C(196, 136, 72), nil, { Rotation = V(-5, 0, 90) }),
	P("Cylinder", V(0.14, 0.85, 0.85), V(0.02, 0.8, 0.05), C(176, 116, 58), nil, { Rotation = VERTICAL }),
	P("Ball", V(0.1, 0.1, 0.1), V(0.2, 0.88, -0.2), C(70, 40, 24)),
	P("Ball", V(0.1, 0.1, 0.1), V(-0.18, 0.88, 0.12), C(70, 40, 24)),
	P("Cylinder", V(0.22, 1.28, 1.28), V(0, 1.3, 0), C(220, 70, 70), nil, { Rotation = VERTICAL }),
	P("Ball", V(0.36, 0.36, 0.36), V(0, 1.5, 0), C(220, 70, 70)),
})

local PINK = C(255, 160, 196)
define("PiggyBank", "Piggy Bank", "House3", 220, "Rare", {
	P("Ball", V(1.4, 1.4, 1.4), V(0, 0.95, 0), PINK),
	P("Cylinder", V(0.26, 0.55, 0.55), V(0, 0.9, -0.75), C(255, 130, 176), nil, { Rotation = FACING }),
	P("Cylinder", V(0.4, 0.32, 0.32), V(-0.35, 0.2, -0.3), PINK, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.4, 0.32, 0.32), V(0.35, 0.2, -0.3), PINK, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.4, 0.32, 0.32), V(-0.35, 0.2, 0.3), PINK, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.4, 0.32, 0.32), V(0.35, 0.2, 0.3), PINK, nil, { Rotation = VERTICAL }),
	P("Block", V(0.3, 0.3, 0.1), V(-0.32, 1.6, -0.3), PINK, nil, { Rotation = V(0, 0, 20) }),
	P("Block", V(0.3, 0.3, 0.1), V(0.32, 1.6, -0.3), PINK, nil, { Rotation = V(0, 0, -20) }),
	P("Ball", V(0.14, 0.14, 0.14), V(-0.25, 1.15, -0.6), BLACK),
	P("Ball", V(0.14, 0.14, 0.14), V(0.25, 1.15, -0.6), BLACK),
	P("Cylinder", V(0.08, 0.5, 0.5), V(0, 1.75, 0.1), GOLD, M.Metal, { Reflectance = 0.2 }),
})

local musicBox: { PartSpec } = {
	P("Block", V(1.5, 0.7, 1.0), V(0, 0.35, 0), C(92, 50, 30), M.Wood),
	P("Block", V(1.54, 0.08, 1.04), V(0, 0.7, 0), GOLD, M.Metal),
	P("Block", V(1.5, 0.95, 0.08), V(0, 1.15, 0.53), C(92, 50, 30), M.Wood, { Rotation = V(15, 0, 0) }),
	P("Block", V(1.3, 0.75, 0.02), V(0, 1.16, 0.48), C(170, 210, 235), M.Glass, { Rotation = V(15, 0, 0), Reflectance = 0.4 }),
	P("Cylinder", V(0.06, 0.34, 0.34), V(0, 0.77, -0.05), GOLD, M.Metal, { Rotation = VERTICAL }),
	P("Block", V(0.06, 0.32, 0.06), V(0, 0.96, -0.05), C(250, 220, 200)),
	P("Cylinder", V(0.1, 0.52, 0.52), V(0, 1.14, -0.05), C(255, 170, 210), M.Fabric, { Rotation = VERTICAL }),
	P("Block", V(0.15, 0.3, 0.1), V(0, 1.32, -0.05), C(255, 150, 200)),
	P("Block", V(0.52, 0.05, 0.05), V(0, 1.42, -0.05), C(250, 220, 200), nil, { Rotation = V(0, 0, 12) }),
	P("Ball", V(0.17, 0.17, 0.17), V(0, 1.55, -0.05), C(250, 220, 200)),
	P("Block", V(0.32, 0.06, 0.06), V(0.9, 0.4, 0), GOLD, M.Metal),
	P("Ball", V(0.14, 0.14, 0.14), V(1.06, 0.4, 0), GOLD, M.Metal),
}
define("MusicBox", "Antique Music Box", "House3", 1050, "Epic", musicBox)

--------------------------------------------------------------------------------
-- Daisy Cottage — guarded by a grey tabby
--------------------------------------------------------------------------------
define("SnowGlobe", "Snow Globe", "House4", 120, "Common", {
	P("Cylinder", V(0.5, 1.2, 1.2), V(0, 0.25, 0), C(120, 72, 40), M.Wood, { Rotation = VERTICAL }),
	P("Cylinder", V(0.08, 1.24, 1.24), V(0, 0.5, 0), GOLD, M.Metal, { Rotation = VERTICAL }),
	P("Cylinder", V(0.06, 1.0, 1.0), V(0, 0.56, 0), WHITE, nil, { Rotation = VERTICAL }),
	P("Block", V(0.1, 0.3, 0.1), V(0, 0.68, 0), C(100, 64, 36), M.Wood),
	P("Ball", V(0.46, 0.46, 0.46), V(0, 0.95, 0), C(40, 120, 60)),
	P("Ball", V(0.32, 0.32, 0.32), V(0, 1.22, 0), C(50, 140, 70)),
	P("Ball", V(0.1, 0.1, 0.1), V(0, 1.42, 0), C(255, 220, 60), M.Neon),
	P("Ball", V(0.08, 0.08, 0.08), V(0.3, 1.3, -0.2), WHITE),
	P("Ball", V(0.08, 0.08, 0.08), V(-0.32, 1.1, 0.12), WHITE),
	P("Ball", V(0.08, 0.08, 0.08), V(0.15, 1.55, 0.25), WHITE),
	P("Ball", V(1.3, 1.3, 1.3), V(0, 1.12, 0), C(210, 236, 255), M.Glass, { Transparency = 0.6, Reflectance = 0.2 }),
})

local DRYER = C(70, 196, 196)
define("HairDryer", "Hair Dryer", "House4", 135, "Common", {
	P("Cylinder", V(1.2, 0.62, 0.62), V(0, 1.0, 0), DRYER, nil, { Rotation = FACING }),
	P("Cylinder", V(0.32, 0.44, 0.44), V(0, 1.0, -0.74), C(50, 54, 60), nil, { Rotation = FACING }),
	P("Cylinder", V(0.06, 0.56, 0.56), V(0, 1.0, 0.62), C(70, 74, 80), nil, { Rotation = FACING }),
	P("Block", V(0.36, 0.8, 0.4), V(0, 0.45, 0.15), DRYER, nil, { Rotation = V(-10, 0, 0) }),
	P("Block", V(0.12, 0.2, 0.06), V(0, 0.6, -0.08), C(230, 60, 60), nil, { Rotation = V(-10, 0, 0) }),
	P("Block", V(0.08, 0.08, 0.9), V(0, 0.05, 0.62), BLACK),
})

define("RecordPlayer", "Record Player", "House4", 380, "Rare", {
	P("Block", V(2.0, 0.5, 1.6), V(0, 0.25, 0), C(140, 90, 50), M.Wood),
	P("Block", V(1.9, 0.04, 1.5), V(0, 0.52, 0), C(40, 40, 44)),
	P("Cylinder", V(0.04, 1.3, 1.3), V(-0.2, 0.56, 0), C(20, 20, 22), nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.05, 0.42, 0.42), V(-0.2, 0.565, 0), C(220, 50, 50), nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.16, 0.26, 0.26), V(0.72, 0.6, 0.5), SILVER, M.Metal, { Rotation = VERTICAL }),
	P("Block", V(0.08, 0.06, 1.0), V(0.58, 0.66, 0.05), SILVER, M.Metal, { Rotation = V(0, 18, 0) }),
	P("Cylinder", V(0.08, 0.16, 0.16), V(0.55, 0.25, -0.81), GOLD, M.Metal, { Rotation = FACING }),
	P("Cylinder", V(0.08, 0.16, 0.16), V(0.8, 0.25, -0.81), GOLD, M.Metal, { Rotation = FACING }),
	P("Block", V(2.0, 1.4, 0.04), V(0, 1.2, 0.86), C(200, 220, 235), M.Glass, { Rotation = V(15, 0, 0), Transparency = 0.6 }),
})

local CRYSTAL = C(180, 228, 255)
local function crystal(): Extra
	return { Transparency = 0.25, Reflectance = 0.3 }
end
define("CrystalCat", "Crystal Cat Statue", "House4", 1650, "Epic", {
	P("Block", V(1.3, 0.3, 1.1), V(0, 0.15, 0), BLACK, M.Marble),
	P("Block", V(1.34, 0.06, 1.14), V(0, 0.3, 0), GOLD, M.Metal),
	P("Ball", V(0.95, 0.95, 0.95), V(0, 0.78, 0.08), CRYSTAL, M.Glass, crystal()),
	P("Ball", V(0.7, 0.7, 0.7), V(0, 1.08, -0.14), CRYSTAL, M.Glass, crystal()),
	P("Ball", V(0.66, 0.66, 0.66), V(0, 1.58, -0.14), CRYSTAL, M.Glass, crystal()),
	P("Block", V(0.18, 0.26, 0.08), V(-0.18, 1.9, -0.14), CRYSTAL, M.Glass, { Rotation = V(0, 0, 20), Transparency = 0.25 }),
	P("Block", V(0.18, 0.26, 0.08), V(0.18, 1.9, -0.14), CRYSTAL, M.Glass, { Rotation = V(0, 0, -20), Transparency = 0.25 }),
	P("Block", V(0.14, 0.14, 0.85), V(0.45, 0.45, -0.18), CRYSTAL, M.Glass, { Rotation = V(0, 28, 0), Transparency = 0.25 }),
	P("Ball", V(0.11, 0.11, 0.11), V(-0.13, 1.64, -0.45), C(190, 90, 255), M.Neon),
	P("Ball", V(0.11, 0.11, 0.11), V(0.13, 1.64, -0.45), C(190, 90, 255), M.Neon, {
		Light = { Color = C(170, 200, 255), Range = 6, Brightness = 1 },
	}),
})

--------------------------------------------------------------------------------
-- Blue Oak House — guarded by Chihuahuas
--------------------------------------------------------------------------------
define("Microwave", "Microwave", "House5", 220, "Common", {
	P("Block", V(2.0, 1.2, 1.3), V(0, 0.6, 0), C(232, 232, 236)),
	P("Block", V(1.25, 0.82, 0.06), V(-0.3, 0.6, -0.66), C(24, 26, 30), M.Glass, { Transparency = 0.15 }),
	P("Block", V(0.5, 1.0, 0.06), V(0.68, 0.6, -0.66), C(54, 54, 60)),
	P("Block", V(0.36, 0.16, 0.07), V(0.68, 0.94, -0.67), C(80, 255, 120), M.Neon),
	P("Block", V(0.08, 0.5, 0.12), V(0.35, 0.6, -0.72), SILVER, M.Metal),
})

define("Blender", "Blender", "House5", 250, "Common", {
	P("Block", V(1.0, 0.7, 1.0), V(0, 0.35, 0), C(50, 50, 56)),
	P("Cylinder", V(0.05, 0.16, 0.16), V(-0.25, 0.35, -0.52), C(80, 220, 120), nil, { Rotation = FACING }),
	P("Cylinder", V(0.05, 0.16, 0.16), V(0, 0.35, -0.52), C(255, 200, 60), nil, { Rotation = FACING }),
	P("Cylinder", V(0.05, 0.16, 0.16), V(0.25, 0.35, -0.52), C(240, 70, 70), nil, { Rotation = FACING }),
	P("Cylinder", V(0.8, 0.74, 0.74), V(0, 1.1, 0), C(232, 84, 124), nil, { Rotation = VERTICAL }),
	P("Cylinder", V(1.5, 0.86, 0.86), V(0, 1.45, 0), C(220, 236, 245), M.Glass, { Rotation = VERTICAL, Transparency = 0.5 }),
	P("Cylinder", V(0.16, 0.9, 0.9), V(0, 2.28, 0), BLACK, nil, { Rotation = VERTICAL }),
	P("Block", V(0.15, 1.0, 0.26), V(0.52, 1.45, 0), C(50, 50, 56)),
})

local GUITAR_RED = C(200, 30, 40)
define("ElectricGuitar", "Electric Guitar", "House5", 700, "Rare", {
	P("Cylinder", V(0.3, 1.45, 1.45), V(0, 0.75, 0), GUITAR_RED, nil, { Rotation = FACING }),
	P("Cylinder", V(0.3, 1.05, 1.05), V(0, 1.5, 0), GUITAR_RED, nil, { Rotation = FACING }),
	P("Block", V(0.62, 0.62, 0.05), V(0.05, 0.85, -0.16), WHITE),
	P("Block", V(0.26, 2.0, 0.14), V(0, 2.75, 0), C(150, 98, 52), M.Wood),
	P("Block", V(0.42, 0.62, 0.12), V(0, 4.0, 0), BLACK),
	P("Block", V(0.5, 0.08, 0.08), V(0, 0.55, -0.17), SILVER, M.Metal),
})

define("GoldenWatch", "Golden Watch", "House5", 2600, "Epic", {
	P("Block", V(1.1, 0.5, 0.85), V(0, 0.25, 0), C(30, 30, 34), M.Fabric),
	P("Block", V(0.85, 0.14, 0.62), V(0, 0.57, 0), C(236, 226, 200), M.Fabric),
	P("Block", V(0.26, 0.06, 1.0), V(0, 0.66, 0), GOLD, M.Metal, { Reflectance = 0.2 }),
	P("Cylinder", V(0.14, 0.62, 0.62), V(0, 0.72, 0), GOLD, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Cylinder", V(0.15, 0.48, 0.48), V(0, 0.73, 0), WHITE, nil, { Rotation = VERTICAL }),
	P("Block", V(0.03, 0.02, 0.2), V(0, 0.81, -0.06), BLACK),
	P("Block", V(0.15, 0.02, 0.03), V(0.06, 0.81, 0), BLACK),
})

--------------------------------------------------------------------------------
-- Cedar House — guarded by Pugs
--------------------------------------------------------------------------------
define("Laptop", "Laptop", "House6", 380, "Common", {
	P("Block", V(1.9, 0.12, 1.3), V(0, 0.06, 0), C(70, 72, 82), M.Metal),
	P("Block", V(1.6, 0.03, 0.62), V(0, 0.13, -0.16), C(30, 30, 36)),
	P("Block", V(1.9, 1.25, 0.08), V(0, 0.72, 0.72), C(70, 72, 82), M.Metal, { Rotation = V(15, 0, 0) }),
	P("Block", V(1.7, 1.05, 0.02), V(0, 0.73, 0.67), C(90, 180, 255), M.Neon, { Rotation = V(15, 0, 0) }),
})

define("SmartSpeaker", "Smart Speaker", "House6", 350, "Common", {
	P("Cylinder", V(0.12, 1.0, 1.0), V(0, 0.06, 0), C(40, 40, 46), nil, { Rotation = VERTICAL }),
	P("Cylinder", V(1.6, 0.92, 0.92), V(0, 0.9, 0), C(120, 124, 132), M.Fabric, { Rotation = VERTICAL }),
	P("Cylinder", V(0.1, 0.94, 0.94), V(0, 1.75, 0), C(30, 30, 34), nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.04, 0.8, 0.8), V(0, 1.81, 0), C(60, 200, 255), M.Neon, { Rotation = VERTICAL }),
	P("Cylinder", V(0.05, 0.5, 0.5), V(0, 1.83, 0), C(30, 30, 34), nil, { Rotation = VERTICAL }),
})

define("FlatscreenTV", "Flatscreen TV", "House6", 1100, "Rare", {
	P("Block", V(1.4, 0.1, 0.7), V(0, 0.05, 0), BLACK),
	P("Block", V(0.25, 0.7, 0.2), V(0, 0.45, 0.1), BLACK),
	P("Block", V(3.6, 2.1, 0.16), V(0, 1.85, 0.05), BLACK),
	P("Block", V(3.4, 1.9, 0.04), V(0, 1.85, -0.04), C(40, 110, 220), M.Neon),
})

local collar: { PartSpec } = {
	P("Block", V(1.5, 0.4, 1.5), V(0, 0.2, 0), C(120, 30, 70), M.Fabric),
	P("Cylinder", V(0.05, 0.34, 0.34), V(0, 0.42, -0.62), GOLD, M.Metal, { Rotation = FACING, Reflectance = 0.3 }),
}
for i = 0, 11 do
	local angle = math.rad(i * 30)
	local x, z = math.sin(angle) * 0.48, math.cos(angle) * 0.48
	table.insert(collar, P("Block", V(0.27, 0.14, 0.1), V(x, 0.47, z), C(235, 90, 150), nil, { Rotation = V(0, i * 30 + 90, 0) }))
	table.insert(collar, P("Ball", V(0.13, 0.13, 0.13), V(x * 1.08, 0.5, z * 1.08), WHITE, M.Glass, { Reflectance = 0.4 }))
end
table.insert(collar, P("Ball", V(0.26, 0.26, 0.26), V(0, 0.52, -0.55), C(200, 245, 255), M.Glass, {
	Reflectance = 0.5,
	Light = { Color = C(200, 230, 255), Range = 6, Brightness = 1 },
}))
define("DiamondCollar", "Diamond Dog Collar", "House6", 4200, "Epic", collar)

--------------------------------------------------------------------------------
-- Elm Street House — guarded by Corgis
--------------------------------------------------------------------------------
define("GameConsole", "Game Console", "House7", 600, "Common", {
	P("Block", V(1.7, 0.42, 1.25), V(0, 0.21, 0), BLACK),
	P("Block", V(1.3, 0.05, 0.05), V(0, 0.28, -0.63), C(60, 160, 255), M.Neon),
	P("Block", V(0.9, 0.16, 0.42), V(0, 0.5, -0.12), C(50, 50, 58)),
	P("Ball", V(0.38, 0.38, 0.38), V(-0.42, 0.48, -0.02), C(50, 50, 58)),
	P("Ball", V(0.38, 0.38, 0.38), V(0.42, 0.48, -0.02), C(50, 50, 58)),
	P("Ball", V(0.1, 0.1, 0.1), V(0.22, 0.6, -0.18), C(255, 70, 70)),
	P("Ball", V(0.1, 0.1, 0.1), V(0.3, 0.6, -0.1), C(70, 200, 255)),
})

define("RetroCamera", "Retro Camera", "House7", 550, "Common", {
	P("Block", V(1.5, 0.7, 0.6), V(0, 0.35, 0), C(34, 34, 38), M.Fabric),
	P("Block", V(1.5, 0.22, 0.6), V(0, 0.81, 0), SILVER, M.Metal),
	P("Block", V(0.5, 0.25, 0.42), V(0, 1.04, 0), SILVER, M.Metal),
	P("Cylinder", V(0.5, 0.62, 0.62), V(0, 0.45, -0.52), C(30, 30, 34), nil, { Rotation = FACING }),
	P("Cylinder", V(0.05, 0.46, 0.46), V(0, 0.45, -0.78), C(90, 140, 210), M.Glass, { Rotation = FACING, Reflectance = 0.4 }),
	P("Block", V(0.34, 0.18, 0.05), V(-0.5, 0.82, -0.31), WHITE, M.Glass),
	P("Cylinder", V(0.1, 0.18, 0.18), V(0.5, 0.97, 0), C(220, 50, 50), nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.1, 0.24, 0.24), V(-0.45, 0.97, 0), SILVER, M.Metal, { Rotation = VERTICAL }),
})

local BRASS = C(214, 170, 80)
local telescope: { PartSpec } = {
	P("Cylinder", V(0.22, 0.36, 0.36), V(0, 1.86, 0), C(40, 40, 46), M.Metal, { Rotation = VERTICAL }),
	P("Cylinder", V(2.4, 0.5, 0.5), V(0, 2.18, -0.2), C(30, 50, 110), M.Metal, { Rotation = V(25, 90, 0) }),
	P("Cylinder", V(0.16, 0.62, 0.62), V(0, 2.69, -1.29), BRASS, M.Metal, { Rotation = V(25, 90, 0), Reflectance = 0.2 }),
	P("Cylinder", V(0.36, 0.24, 0.24), V(0, 1.66, 0.92), C(30, 30, 34), nil, { Rotation = V(25, 90, 0) }),
	P("Cylinder", V(0.6, 0.18, 0.18), V(0.3, 2.36, 0.1), BRASS, M.Metal, { Rotation = V(25, 90, 0) }),
}
for _, yaw in { 90, 210, 330 } do
	local outward = math.rad(yaw)
	local reach = 0.33
	table.insert(
		telescope,
		P("Block", V(0.1, 1.92, 0.1), V(math.cos(outward) * reach, 0.9, -math.sin(outward) * reach), BRASS, M.Metal, {
			Rotation = V(0, yaw, 20),
		})
	)
end
define("Telescope", "Telescope", "House7", 1800, "Rare", telescope)

local CORGI_ORANGE = C(226, 146, 62)
define("CorgiPortrait", "Royal Corgi Portrait", "House7", 6800, "Epic", {
	P("Block", V(1.6, 0.15, 0.8), V(0, 0.075, 0.1), C(60, 44, 32), M.Wood),
	P("Block", V(0.15, 1.2, 0.15), V(0, 0.75, 0.15), C(60, 44, 32), M.Wood),
	P("Block", V(2.3, 2.5, 0.18), V(0, 2.55, 0.08), GOLD, M.Metal, { Reflectance = 0.15 }),
	P("Block", V(1.95, 2.15, 0.05), V(0, 2.55, -0.03), C(84, 46, 136), M.Fabric),
	P("Cylinder", V(0.03, 1.0, 1.0), V(0, 2.42, -0.07), CORGI_ORANGE, nil, { Rotation = FACING }),
	P("Cylinder", V(0.03, 0.52, 0.52), V(0, 2.2, -0.09), WHITE, nil, { Rotation = FACING }),
	P("Block", V(0.32, 0.5, 0.03), V(-0.36, 2.95, -0.07), CORGI_ORANGE, nil, { Rotation = V(0, 0, 18) }),
	P("Block", V(0.32, 0.5, 0.03), V(0.36, 2.95, -0.07), CORGI_ORANGE, nil, { Rotation = V(0, 0, -18) }),
	P("Ball", V(0.12, 0.12, 0.12), V(0, 2.3, -0.11), BLACK),
	P("Ball", V(0.1, 0.1, 0.1), V(-0.2, 2.52, -0.1), BLACK),
	P("Ball", V(0.1, 0.1, 0.1), V(0.2, 2.52, -0.1), BLACK),
	P("Block", V(0.5, 0.22, 0.03), V(0, 3.12, -0.07), GOLD, M.Metal),
	P("Ball", V(0.12, 0.12, 0.12), V(-0.2, 3.28, -0.07), GOLD, M.Metal),
	P("Ball", V(0.12, 0.12, 0.12), V(0, 3.3, -0.07), C(230, 30, 60)),
	P("Ball", V(0.12, 0.12, 0.12), V(0.2, 3.28, -0.07), GOLD, M.Metal),
})

--------------------------------------------------------------------------------
-- Birch House — guarded by Dalmatians
--------------------------------------------------------------------------------
define("Boombox", "Boombox", "House8", 900, "Common", {
	P("Block", V(2.4, 1.2, 0.7), V(0, 0.6, 0), C(160, 160, 168), M.Metal),
	P("Cylinder", V(0.08, 0.82, 0.82), V(-0.76, 0.55, -0.36), C(30, 30, 34), nil, { Rotation = FACING }),
	P("Cylinder", V(0.08, 0.82, 0.82), V(0.76, 0.55, -0.36), C(30, 30, 34), nil, { Rotation = FACING }),
	P("Cylinder", V(0.1, 0.34, 0.34), V(-0.76, 0.55, -0.39), C(80, 80, 88), nil, { Rotation = FACING }),
	P("Cylinder", V(0.1, 0.34, 0.34), V(0.76, 0.55, -0.39), C(80, 80, 88), nil, { Rotation = FACING }),
	P("Block", V(0.62, 0.42, 0.04), V(0, 0.52, -0.36), C(24, 24, 28), M.Glass),
	P("Block", V(0.5, 0.06, 0.03), V(0, 0.92, -0.36), C(80, 255, 140), M.Neon),
	P("Block", V(1.8, 0.12, 0.12), V(0, 1.66, 0), BLACK),
	P("Block", V(0.12, 0.46, 0.12), V(-0.85, 1.4, 0), BLACK),
	P("Block", V(0.12, 0.46, 0.12), V(0.85, 1.4, 0), BLACK),
	P("Block", V(0.18, 0.08, 0.18), V(-0.3, 1.24, -0.1), C(220, 60, 60)),
	P("Block", V(0.18, 0.08, 0.18), V(0, 1.24, -0.1), C(40, 40, 46)),
	P("Block", V(0.18, 0.08, 0.18), V(0.3, 1.24, -0.1), C(40, 40, 46)),
})

local FIRE_RED = C(196, 30, 30)
define("FireHelmet", "Vintage Fire Helmet", "House8", 850, "Common", {
	P("Ball", V(1.3, 1.3, 1.3), V(0, 0.66, 0), FIRE_RED, nil, { Reflectance = 0.15 }),
	P("Cylinder", V(0.1, 2.0, 2.0), V(0, 0.06, 0), FIRE_RED, nil, { Rotation = VERTICAL }),
	P("Block", V(1.0, 0.1, 0.8), V(0, 0.1, 0.9), FIRE_RED, nil, { Rotation = V(8, 0, 0) }),
	P("Block", V(0.16, 0.26, 1.24), V(0, 1.26, 0.02), C(150, 20, 20)),
	P("Block", V(0.6, 0.7, 0.08), V(0, 0.8, -0.66), GOLD, M.Metal, { Rotation = V(-15, 0, 0), Reflectance = 0.2 }),
	P("Block", V(0.2, 0.3, 0.04), V(0, 0.8, -0.71), BLACK, nil, { Rotation = V(-15, 0, 0) }),
})

local SAX = C(232, 186, 70)
local saxophone: { PartSpec } = {
	P("Cylinder", V(0.1, 1.2, 1.2), V(0, 0.05, 0), BLACK, nil, { Rotation = VERTICAL }),
	P("Block", V(0.1, 0.32, 0.1), V(-0.1, 0.25, 0.3), BLACK),
	P("Cylinder", V(2.0, 0.42, 0.42), V(-0.2, 1.65, 0), SAX, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Ball", V(0.56, 0.56, 0.56), V(0.02, 0.6, 0), SAX, M.Metal, { Reflectance = 0.25 }),
	P("Cylinder", V(1.0, 0.48, 0.48), V(0.3, 0.98, 0), SAX, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Cylinder", V(0.26, 0.88, 0.88), V(0.3, 1.54, 0), SAX, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Cylinder", V(0.82, 0.22, 0.22), V(0.06, 2.95, 0), SAX, M.Metal, { Rotation = V(0, 0, 50), Reflectance = 0.25 }),
	P("Cylinder", V(0.32, 0.15, 0.15), V(0.38, 3.33, 0), BLACK, nil, { Rotation = V(0, 0, 50) }),
}
for i = 0, 4 do
	table.insert(saxophone, P("Ball", V(0.13, 0.13, 0.13), V(-0.2, 1.05 + i * 0.32, -0.22), C(245, 240, 225)))
end
define("Saxophone", "Saxophone", "House8", 2900, "Rare", saxophone)

local ring: { PartSpec } = {
	P("Block", V(1.2, 0.6, 1.0), V(0, 0.3, 0), C(120, 20, 36), M.Fabric),
	P("Block", V(1.2, 0.9, 0.08), V(0, 0.95, 0.5), C(120, 20, 36), M.Fabric, { Rotation = V(15, 0, 0) }),
	P("Block", V(1.05, 0.75, 0.02), V(0, 0.96, 0.45), C(245, 240, 236), M.Fabric, { Rotation = V(15, 0, 0) }),
	P("Block", V(0.9, 0.12, 0.6), V(0, 0.62, -0.05), C(30, 26, 30), M.Fabric),
	P("Block", V(0.32, 0.32, 0.32), V(0, 1.24, -0.05), C(230, 20, 50), M.Glass, {
		Rotation = V(45, 0, 45),
		Reflectance = 0.4,
		Light = { Color = C(255, 80, 100), Range = 6, Brightness = 1.2 },
	}),
}
for i = 0, 7 do
	local angle = math.rad(i * 45)
	table.insert(
		ring,
		P("Block", V(0.2, 0.07, 0.07), V(math.cos(angle) * 0.24, 0.92 + math.sin(angle) * 0.24, -0.05), GOLD, M.Metal, {
			Rotation = V(0, 0, i * 45 + 90),
			Reflectance = 0.3,
		})
	)
end
define("RubyRing", "Ruby Ring", "House8", 11000, "Epic", ring)

--------------------------------------------------------------------------------
-- Pine Ridge House — guarded by German Shepherds
--------------------------------------------------------------------------------
define("EspressoMachine", "Espresso Machine", "House9", 1500, "Common", {
	P("Block", V(1.7, 1.7, 1.3), V(0, 0.85, 0.1), C(186, 188, 196), M.Metal, { Reflectance = 0.15 }),
	P("Block", V(1.7, 0.1, 1.3), V(0, 1.75, 0.1), BLACK),
	P("Block", V(0.7, 0.3, 0.5), V(0, 1.2, -0.75), BLACK),
	P("Block", V(1.3, 0.15, 0.6), V(0, 0.075, -0.8), BLACK),
	P("Cylinder", V(0.38, 0.34, 0.34), V(0, 0.34, -0.8), WHITE, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.05, 0.36, 0.36), V(0.52, 1.35, -0.56), WHITE, nil, { Rotation = FACING }),
	P("Cylinder", V(0.05, 0.36, 0.36), V(-0.52, 1.35, -0.56), WHITE, nil, { Rotation = FACING }),
})

define("GamingPC", "Gaming PC", "House9", 2200, "Common", {
	P("Block", V(1.0, 2.1, 2.0), V(0, 1.05, 0), BLACK),
	P("Block", V(0.04, 1.9, 1.8), V(-0.51, 1.05, 0), C(120, 140, 170), M.Glass, { Transparency = 0.4 }),
	P("Cylinder", V(0.06, 0.75, 0.75), V(-0.45, 1.5, 0.35), C(255, 60, 200), M.Neon),
	P("Cylinder", V(0.06, 0.75, 0.75), V(-0.45, 0.65, 0.35), C(60, 230, 255), M.Neon),
	P("Block", V(0.06, 1.8, 0.08), V(-0.45, 1.05, -0.82), C(140, 80, 255), M.Neon),
	P("Block", V(0.4, 0.05, 0.05), V(0, 1.95, -1.01), C(60, 160, 255), M.Neon),
})

define("ModernArt", "Modern Art", "House9", 4500, "Rare", {
	P("Block", V(1.6, 0.15, 0.8), V(0, 0.075, 0.1), C(60, 44, 32), M.Wood),
	P("Block", V(0.15, 1.3, 0.15), V(0, 0.8, 0.12), C(60, 44, 32), M.Wood),
	P("Block", V(2.4, 1.9, 0.12), V(0, 2.4, 0.06), WHITE, M.Fabric),
	P("Block", V(0.9, 0.9, 0.04), V(-0.55, 2.65, -0.02), C(230, 40, 50)),
	P("Block", V(1.1, 0.6, 0.04), V(0.5, 1.95, -0.02), C(40, 90, 230)),
	P("Block", V(0.12, 1.7, 0.04), V(0.02, 2.4, -0.025), BLACK),
	P("Block", V(2.2, 0.12, 0.04), V(0, 2.2, -0.025), BLACK),
	P("Ball", V(0.55, 0.55, 0.55), V(0.62, 2.85, -0.05), C(255, 210, 40)),
})

local jewelryBox: { PartSpec } = {
	P("Block", V(1.5, 0.7, 1.0), V(0, 0.35, 0), C(84, 42, 22), M.Wood),
	P("Block", V(1.54, 0.08, 1.04), V(0, 0.7, 0), GOLD, M.Metal),
	P("Block", V(1.5, 0.95, 0.1), V(0, 1.15, 0.52), C(84, 42, 22), M.Wood, { Rotation = V(15, 0, 0) }),
	P("Block", V(1.3, 0.75, 0.02), V(0, 1.16, 0.46), C(150, 20, 40), M.Fabric, { Rotation = V(15, 0, 0) }),
	P("Ball", V(0.36, 0.36, 0.36), V(0, 0.86, 0.05), C(230, 20, 60), M.Glass, { Transparency = 0.1, Reflectance = 0.2 }),
	P("Ball", V(0.3, 0.3, 0.3), V(0.42, 0.84, 0.25), C(40, 220, 120), M.Glass, { Transparency = 0.1 }),
	P("Ball", V(0.3, 0.3, 0.3), V(-0.42, 0.84, 0.25), C(60, 120, 255), M.Glass, { Transparency = 0.1 }),
}
for i = 0, 5 do
	local x = -0.5 + i * 0.2
	local z = -0.1 - (1 - math.abs(x) / 0.5) * 0.18
	table.insert(jewelryBox, P("Ball", V(0.2, 0.2, 0.2), V(x, 0.8, z), WHITE))
end
define("JewelryBox", "Jewelry Box", "House9", 9500, "Epic", jewelryBox)

local necklace: { PartSpec } = {
	P("Block", V(1.3, 0.25, 0.8), V(0, 0.125, 0), BLACK, M.Marble),
	P("Block", V(1.2, 1.0, 0.55), V(0, 0.75, 0), C(24, 24, 28), M.Fabric),
	P("Cylinder", V(0.8, 0.5, 0.5), V(0, 1.65, 0), C(24, 24, 28), M.Fabric, { Rotation = VERTICAL }),
	P("Ball", V(0.38, 0.38, 0.38), V(0, 1.02, -0.33), C(185, 240, 255), M.Glass, {
		Transparency = 0.15,
		Reflectance = 0.4,
		Light = { Color = C(170, 230, 255), Range = 8, Brightness = 1.5 },
	}),
}
for i = 0, 8 do
	local angle = math.rad(-80 + i * 20)
	table.insert(
		necklace,
		P(
			"Ball",
			V(0.16, 0.16, 0.16),
			V(math.sin(angle) * 0.4, 1.28 - math.cos(angle) * 0.12, -0.29),
			WHITE,
			M.Glass,
			{ Reflectance = 0.3 }
		)
	)
end
define("DiamondNecklace", "Diamond Necklace", "House9", 22000, "Legendary", necklace)

--------------------------------------------------------------------------------
-- Aspen House — guarded by Dobermans
--------------------------------------------------------------------------------
local ROBOT = C(232, 234, 240)
local robotDog: { PartSpec } = {
	P("Block", V(0.9, 0.7, 1.6), V(0, 1.1, 0.1), ROBOT, M.Metal),
	P("Block", V(0.6, 0.55, 0.7), V(0, 1.55, -0.85), ROBOT, M.Metal),
	P("Block", V(0.52, 0.2, 0.04), V(0, 1.6, -1.21), C(60, 220, 255), M.Neon),
	P("Block", V(0.12, 0.3, 0.08), V(-0.2, 1.95, -0.8), C(60, 62, 70), M.Metal),
	P("Block", V(0.12, 0.3, 0.08), V(0.2, 1.95, -0.8), C(60, 62, 70), M.Metal),
	P("Block", V(0.08, 0.5, 0.08), V(0, 1.6, 1.0), C(60, 62, 70), M.Metal, { Rotation = V(-30, 0, 0) }),
	P("Ball", V(0.12, 0.12, 0.12), V(0, 1.84, 1.14), C(255, 60, 60), M.Neon),
}
for _, x in { -0.32, 0.32 } do
	for _, z in { -0.45, 0.6 } do
		table.insert(robotDog, P("Block", V(0.22, 0.8, 0.22), V(x, 0.4, z), C(60, 62, 70), M.Metal))
		table.insert(robotDog, P("Ball", V(0.3, 0.3, 0.3), V(x, 0.8, z), C(28, 28, 32), M.Metal))
	end
end
define("RobotDog", "Robot Dog", "House10", 2400, "Common", robotDog)

define("VRHeadset", "VR Headset", "House10", 2600, "Common", {
	P("Cylinder", V(0.15, 1.3, 1.3), V(0, 0.075, 0), BLACK, nil, { Rotation = VERTICAL }),
	P("Block", V(0.15, 1.0, 0.15), V(0, 0.65, 0.1), C(60, 62, 70), M.Metal),
	P("Block", V(1.4, 0.75, 0.8), V(0, 1.45, 0), WHITE),
	P("Block", V(1.3, 0.62, 0.06), V(0, 1.45, -0.42), C(20, 20, 24), M.Glass, { Reflectance = 0.4 }),
	P("Block", V(1.2, 0.05, 0.03), V(0, 1.2, -0.45), C(60, 140, 255), M.Neon),
	P("Block", V(0.1, 0.3, 1.0), V(-0.72, 1.45, 0.7), C(50, 50, 56), M.Fabric),
	P("Block", V(0.1, 0.3, 1.0), V(0.72, 1.45, 0.7), C(50, 50, 56), M.Fabric),
	P("Block", V(1.54, 0.3, 0.1), V(0, 1.45, 1.2), C(50, 50, 56), M.Fabric),
	P("Block", V(0.24, 0.5, 0.24), V(-0.42, 0.4, -0.35), C(40, 40, 46)),
	P("Block", V(0.24, 0.5, 0.24), V(0.42, 0.4, -0.35), C(40, 40, 46)),
	P("Cylinder", V(0.06, 0.42, 0.42), V(-0.42, 0.68, -0.35), C(60, 140, 255), M.Neon, { Rotation = VERTICAL }),
	P("Cylinder", V(0.06, 0.42, 0.42), V(0.42, 0.68, -0.35), C(60, 140, 255), M.Neon, { Rotation = VERTICAL }),
})

define("GoldenTrophy", "Golden Trophy", "House10", 7000, "Rare", {
	P("Block", V(1.1, 0.45, 1.1), V(0, 0.225, 0), C(32, 32, 36), M.Marble),
	P("Block", V(0.7, 0.25, 0.04), V(0, 0.225, -0.57), GOLD, M.Metal),
	P("Cylinder", V(0.75, 0.32, 0.32), V(0, 0.82, 0), GOLD, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Cylinder", V(0.15, 0.7, 0.7), V(0, 1.22, 0), GOLD, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Cylinder", V(1.0, 1.05, 1.05), V(0, 1.8, 0), GOLD, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Block", V(0.18, 0.7, 0.18), V(-0.65, 1.85, 0), GOLD, M.Metal, { Reflectance = 0.25 }),
	P("Block", V(0.18, 0.7, 0.18), V(0.65, 1.85, 0), GOLD, M.Metal, { Reflectance = 0.25 }),
	P("Cylinder", V(0.04, 0.9, 0.9), V(0, 2.31, 0), C(196, 140, 30), M.Metal, { Rotation = VERTICAL }),
})

local sneakers: { PartSpec } = {
	P("Block", V(2.2, 0.3, 1.7), V(0, 0.15, 0), BLACK),
	P("Block", V(2.24, 0.06, 1.74), V(0, 0.03, 0), C(170, 80, 255), M.Neon),
}
for _, x in { -0.5, 0.5 } do
	local shoe = C(214, 30, 44)
	table.insert(sneakers, P("Block", V(0.6, 0.2, 1.4), V(x, 0.4, 0), WHITE))
	table.insert(sneakers, P("Block", V(0.56, 0.45, 0.95), V(x, 0.72, 0.17), shoe, M.Fabric))
	table.insert(sneakers, P("Block", V(0.56, 0.3, 0.46), V(x, 0.62, -0.46), shoe, M.Fabric))
	table.insert(sneakers, P("Block", V(0.5, 0.26, 0.4), V(x, 1.02, 0.42), WHITE, M.Fabric))
	table.insert(sneakers, P("Block", V(0.02, 0.12, 0.62), V(x + (if x < 0 then -0.29 else 0.29), 0.72, 0.05), WHITE, nil, {
		Rotation = V(15, 0, 0),
	}))
	for i = 0, 2 do
		table.insert(sneakers, P("Block", V(0.36, 0.05, 0.08), V(x, 0.96 - i * 0.06, -0.12 - i * 0.16), WHITE))
	end
end
define("RareSneakers", "Limited Sneakers", "House10", 13000, "Epic", sneakers)

local tiara: { PartSpec } = {
	P("Cylinder", V(0.5, 1.5, 1.5), V(0, 0.25, 0), C(30, 30, 40), M.Fabric, { Rotation = VERTICAL }),
	P("Block", V(0.36, 0.36, 0.36), V(0, 1.32, -0.55), C(40, 80, 230), M.Glass, {
		Rotation = V(45, 0, 45),
		Reflectance = 0.4,
		Light = { Color = C(90, 140, 255), Range = 8, Brightness = 1.5 },
	}),
}
for i = -5, 5 do
	local angle = math.rad(i * 18)
	local x, z = math.sin(angle) * 0.56, -math.cos(angle) * 0.56
	table.insert(tiara, P("Block", V(0.22, 0.1, 0.08), V(x, 0.6, z), SILVER, M.Metal, { Rotation = V(0, -i * 18, 0), Reflectance = 0.3 }))
	local height = 0.18 + 0.5 * math.cos(angle * 2.2)
	if i ~= 0 and height > 0.12 then
		table.insert(tiara, P("Block", V(0.07, height, 0.07), V(x, 0.65 + height / 2, z), SILVER, M.Metal, { Reflectance = 0.3 }))
		table.insert(tiara, P("Ball", V(0.13, 0.13, 0.13), V(x, 0.68 + height, z), if i % 2 == 0 then C(60, 110, 240) else WHITE, M.Glass, {
			Reflectance = 0.3,
		}))
	end
end
define("SapphireTiara", "Sapphire Tiara", "House10", 36000, "Legendary", tiara)

--------------------------------------------------------------------------------
-- The Grand Mansion — guarded by security drones
--------------------------------------------------------------------------------
local function goldBar(x: number, y: number): PartSpec
	return P("Block", V(0.62, 0.36, 1.25), V(x, y, 0), GOLD, M.Metal, { Reflectance = 0.3 })
end
define("GoldBars", "Gold Bars", "Mansion", 12000, "Common", {
	goldBar(-0.68, 0.18),
	goldBar(0, 0.18),
	goldBar(0.68, 0.18),
	goldBar(-0.34, 0.54),
	goldBar(0.34, 0.54),
	goldBar(0, 0.9),
})

local PORCELAIN = C(238, 240, 245)
local COBALT = C(32, 64, 160)
define("AncientVase", "Ancient Vase", "Mansion", 15000, "Common", {
	P("Cylinder", V(0.3, 0.85, 0.85), V(0, 0.15, 0), COBALT, nil, { Rotation = VERTICAL }),
	P("Ball", V(1.7, 1.7, 1.7), V(0, 1.1, 0), PORCELAIN),
	P("Cylinder", V(0.28, 1.72, 1.72), V(0, 1.1, 0), COBALT, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.9, 0.62, 0.62), V(0, 2.2, 0), PORCELAIN, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.16, 0.9, 0.9), V(0, 2.65, 0), COBALT, nil, { Rotation = VERTICAL }),
})

define("Masterpiece", "Masterpiece Painting", "Mansion", 28000, "Rare", {
	P("Block", V(1.6, 0.15, 0.8), V(0, 0.075, 0.1), C(60, 44, 32), M.Wood),
	P("Block", V(0.15, 1.2, 0.15), V(0, 0.75, 0.15), C(60, 44, 32), M.Wood),
	P("Block", V(2.5, 2.7, 0.2), V(0, 2.6, 0.08), GOLD, M.Metal, { Reflectance = 0.15 }),
	P("Block", V(2.1, 2.3, 0.05), V(0, 2.6, -0.04), C(96, 112, 74), M.Fabric),
	P("Block", V(1.2, 1.0, 0.03), V(0, 2.05, -0.07), C(44, 34, 26), M.Fabric),
	P("Cylinder", V(0.03, 0.85, 0.85), V(0, 3.0, -0.075), C(54, 38, 26), nil, { Rotation = FACING }),
	P("Cylinder", V(0.03, 0.66, 0.66), V(0, 2.92, -0.09), C(232, 196, 156), nil, { Rotation = FACING }),
})

local crown: { PartSpec } = {
	P("Block", V(1.5, 0.45, 1.5), V(0, 0.225, 0), C(150, 20, 36), M.Fabric),
	P("Cylinder", V(0.55, 1.05, 1.05), V(0, 0.72, 0), GOLD, M.Metal, { Rotation = VERTICAL, Reflectance = 0.3 }),
	P("Ball", V(0.6, 0.6, 0.6), V(0, 1.0, 0), C(150, 20, 36), M.Fabric),
	P("Ball", V(0.2, 0.2, 0.2), V(0, 0.72, -0.52), C(230, 20, 60), M.Glass),
	P("Ball", V(0.2, 0.2, 0.2), V(-0.52, 0.72, 0), C(40, 120, 255), M.Glass),
	P("Ball", V(0.2, 0.2, 0.2), V(0.52, 0.72, 0), C(40, 220, 120), M.Glass),
	P("Ball", V(0.2, 0.2, 0.2), V(0, 0.72, 0.52), C(230, 20, 60), M.Glass),
}
for i = 0, 5 do
	local angle = math.rad(i * 60)
	local x, z = math.sin(angle) * 0.48, math.cos(angle) * 0.48
	table.insert(
		crown,
		P("Block", V(0.16, 0.42, 0.16), V(x, 1.15, z), GOLD, M.Metal, { Reflectance = 0.3, Rotation = V(0, i * 60, 0) })
	)
	table.insert(crown, P("Ball", V(0.17, 0.17, 0.17), V(x, 1.4, z), WHITE))
end
for _, corner in { V(-0.7, 0.2, -0.7), V(0.7, 0.2, -0.7), V(-0.7, 0.2, 0.7), V(0.7, 0.2, 0.7) } do
	table.insert(crown, P("Ball", V(0.18, 0.18, 0.18), corner, GOLD, M.Metal))
end
define("RoyalCrown", "Royal Crown", "Mansion", 45000, "Epic", crown)

define("GiantDiamond", "Giant Diamond", "Mansion", 120000, "Legendary", {
	P("Cylinder", V(0.7, 1.3, 1.3), V(0, 0.35, 0), C(242, 242, 246), M.Marble, { Rotation = VERTICAL }),
	P("Cylinder", V(0.1, 1.45, 1.45), V(0, 0.72, 0), GOLD, M.Metal, { Rotation = VERTICAL }),
	P(
		"Block",
		V(1.15, 1.15, 1.15),
		V(0, 1.78, 0),
		C(170, 230, 255),
		M.Glass,
		{ Rotation = V(45, 0, 45), Transparency = 0.2, Reflectance = 0.5 }
	),
	P("Ball", V(0.7, 0.7, 0.7), V(0, 1.78, 0), C(210, 248, 255), M.Neon, {
		Light = { Color = C(160, 220, 255), Range = 12, Brightness = 2 },
	}),
})

local LAPIS = C(30, 60, 170)
local mask: { PartSpec } = {
	P("Block", V(1.5, 0.3, 1.2), V(0, 0.15, 0), BLACK, M.Marble),
	P("Block", V(1.6, 0.36, 0.8), V(0, 0.48, 0.05), GOLD, M.Metal, { Reflectance = 0.25 }),
	P("Block", V(1.62, 0.1, 0.82), V(0, 0.5, 0.05), C(40, 170, 170)),
	P("Block", V(1.5, 0.5, 0.8), V(0, 2.3, 0.2), GOLD, M.Metal, { Reflectance = 0.25 }),
	P("Block", V(0.95, 1.25, 0.5), V(0, 1.5, -0.15), GOLD, M.Metal, { Reflectance = 0.3 }),
	P("Block", V(0.26, 0.1, 0.05), V(-0.22, 1.75, -0.41), BLACK),
	P("Block", V(0.26, 0.1, 0.05), V(0.22, 1.75, -0.41), BLACK),
	P("Block", V(0.16, 0.32, 0.12), V(0, 1.5, -0.44), GOLD, M.Metal, { Reflectance = 0.3 }),
	P("Block", V(0.3, 0.06, 0.05), V(0, 1.18, -0.41), C(150, 60, 40)),
	P("Block", V(0.2, 0.55, 0.16), V(0, 0.7, -0.32), LAPIS),
	P("Block", V(0.16, 0.3, 0.1), V(0, 2.22, -0.25), GOLD, M.Metal),
	P("Ball", V(0.08, 0.08, 0.08), V(0, 2.3, -0.31), C(230, 30, 40)),
}
for _, side in { -1, 1 } do
	table.insert(mask, P("Block", V(0.45, 1.6, 0.6), V(side * 0.72, 1.3, 0.12), GOLD, M.Metal, { Reflectance = 0.25 }))
	for i = 0, 4 do
		table.insert(mask, P("Block", V(0.47, 0.12, 0.62), V(side * 0.72, 0.7 + i * 0.32, 0.12), LAPIS))
	end
end
for i = 0, 2 do
	table.insert(mask, P("Block", V(1.52, 0.1, 0.82), V(0, 2.12 + i * 0.16, 0.2), LAPIS))
end
table.insert(mask, P("Ball", V(0.3, 0.3, 0.3), V(0, 2.3, 0.2), GOLD, M.Metal, {
	Light = { Color = C(255, 210, 120), Range = 8, Brightness = 1.2 },
}))
define("PharaohMask", "Pharaoh Mask", "Mansion", 85000, "Legendary", mask)

--------------------------------------------------------------------------------
-- API
--------------------------------------------------------------------------------
Items.List = list
Items.ById = byId

function Items.get(itemId: string): ItemDef?
	return byId[itemId]
end

function Items.getValue(itemId: string): number
	local def = byId[itemId]
	return if def then def.Value else 0
end

function Items.getSellValue(itemId: string): number
	return math.floor(Items.getValue(itemId) * Config.Economy.SellRatio)
end

-- The rarity table for an item (colour, weight, order), or nil for an unknown id.
function Items.getRarity(itemId: string): Rarity?
	local def = byId[itemId]
	return if def then Items.Rarities[def.Rarity] else nil
end

-- Epic and above: these items get a coloured aura in the world (see ItemModels).
function Items.hasAura(itemId: string): boolean
	local rarity = Items.getRarity(itemId)
	return rarity ~= nil and rarity.Order >= Config.Aura.MinOrder
end

-- Cash per second this item earns while stored in a warehouse.
function Items.getIncome(itemId: string): number
	local def = byId[itemId]
	if not def then
		return 0
	end
	return math.max(1, math.floor(def.Value * Config.Economy.IncomeRatio + 0.5))
end

-- Every item found in a house, sorted from Common to Legendary (then by value).
function Items.forHouse(houseId: string): { ItemDef }
	local result: { ItemDef } = {}
	for _, def in list do
		if def.House == houseId then
			table.insert(result, def)
		end
	end
	table.sort(result, function(a: ItemDef, b: ItemDef): boolean
		local orderA, orderB = Items.Rarities[a.Rarity].Order, Items.Rarities[b.Rarity].Order
		if orderA ~= orderB then
			return orderA < orderB
		end
		return a.Value < b.Value
	end)
	return result
end

-- Picks a random item from a house's own loot, weighted by rarity.
function Items.roll(houseId: string, rng: Random): string
	local byRarity: { [string]: { ItemDef } } = {}
	local rarities: { string } = {}
	local totalWeight = 0
	for _, def in list do
		if def.House == houseId then
			local bucket = byRarity[def.Rarity]
			if not bucket then
				bucket = {}
				byRarity[def.Rarity] = bucket
				table.insert(rarities, def.Rarity)
				totalWeight += Items.Rarities[def.Rarity].Weight
			end
			table.insert(bucket, def)
		end
	end
	if totalWeight <= 0 then
		return list[1].Id
	end
	-- Walk the rarities in a fixed order so the same random number always gives the same item.
	table.sort(rarities, function(a: string, b: string): boolean
		return Items.Rarities[a].Order < Items.Rarities[b].Order
	end)
	local roll = rng:NextNumber() * totalWeight
	for _, rarityName in rarities do
		roll -= Items.Rarities[rarityName].Weight
		if roll <= 0 then
			local bucket = byRarity[rarityName]
			return bucket[rng:NextInteger(1, #bucket)].Id
		end
	end
	-- Floating point safety net: the rarest bucket.
	local bucket = byRarity[rarities[#rarities]]
	return bucket[1].Id
end

return Items
