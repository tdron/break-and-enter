--!strict
--[[
	Items
	-----
	Every stealable item: its name, value, rarity, which house tier it shows up
	in, and a little 3D model made from plain parts (no uploaded meshes needed).

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
	Tier: number,
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

local function define(id: string, displayName: string, tier: number, value: number, rarity: string, parts: { PartSpec })
	assert(Items.Rarities[rarity], "Unknown rarity " .. rarity)
	assert(byId[id] == nil, "Duplicate item id " .. id)
	local def: ItemDef = {
		Id = id,
		DisplayName = displayName,
		Tier = tier,
		Value = value,
		Rarity = rarity,
		Parts = parts,
	}
	table.insert(list, def)
	byId[id] = def
end

--------------------------------------------------------------------------------
-- Tier 1: Cottages
--------------------------------------------------------------------------------
define("Toaster", "Toaster", 1, 25, "Common", {
	P("Block", V(1.6, 1.0, 1.0), V(0, 0.5, 0), SILVER, M.Metal),
	P("Block", V(1.1, 0.06, 0.18), V(0, 1.01, -0.22), BLACK),
	P("Block", V(1.1, 0.06, 0.18), V(0, 1.01, 0.22), BLACK),
	P("Block", V(0.95, 0.4, 0.12), V(0, 1.15, -0.22), C(214, 160, 92)),
	P("Block", V(0.15, 0.3, 0.2), V(0.88, 0.62, 0), BLACK),
})

define("DeskLamp", "Desk Lamp", 1, 30, "Common", {
	P("Cylinder", V(0.2, 1.2, 1.2), V(0, 0.1, 0), C(60, 60, 66), M.Metal, { Rotation = VERTICAL }),
	P("Block", V(0.16, 1.7, 0.16), V(0, 1.05, 0), C(60, 60, 66), M.Metal),
	P("Cylinder", V(0.9, 1.2, 1.2), V(0, 2.1, 0), C(255, 214, 102), M.SmoothPlastic, { Rotation = VERTICAL }),
	P("Ball", V(0.5, 0.5, 0.5), V(0, 1.75, 0), C(255, 244, 200), M.Neon),
})

local FUR = C(156, 104, 62)
local SNOUT = C(214, 172, 124)
define("TeddyBear", "Teddy Bear", 1, 35, "Common", {
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

define("OldRadio", "Old Radio", 1, 45, "Common", {
	P("Block", V(1.8, 1.1, 0.8), V(0, 0.55, 0), C(122, 78, 44), M.Wood),
	P("Block", V(0.8, 0.8, 0.06), V(-0.4, 0.55, -0.41), C(48, 40, 34), M.Fabric),
	P("Cylinder", V(0.08, 0.42, 0.42), V(0.48, 0.7, -0.42), C(236, 226, 196), nil, { Rotation = FACING }),
	P("Cylinder", V(0.12, 0.2, 0.2), V(0.34, 0.28, -0.44), BLACK, nil, { Rotation = FACING }),
	P("Cylinder", V(0.12, 0.2, 0.2), V(0.62, 0.28, -0.44), BLACK, nil, { Rotation = FACING }),
	P("Block", V(0.06, 1.3, 0.06), V(0.6, 1.6, 0.2), SILVER, M.Metal, { Rotation = V(0, 0, -18) }),
	P("Block", V(1.0, 0.12, 0.16), V(0, 1.22, 0), C(70, 46, 26), M.Wood),
})

define("CoffeeMaker", "Coffee Maker", 1, 70, "Rare", {
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

local PINK = C(255, 160, 196)
define("PiggyBank", "Piggy Bank", 1, 150, "Rare", {
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

define("GrandmasJewels", "Grandma's Jewels", 1, 400, "Epic", {
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
-- Tier 2: Suburban houses
--------------------------------------------------------------------------------
define("Microwave", "Microwave", 2, 160, "Common", {
	P("Block", V(2.0, 1.2, 1.3), V(0, 0.6, 0), C(232, 232, 236)),
	P("Block", V(1.25, 0.82, 0.06), V(-0.3, 0.6, -0.66), C(24, 26, 30), M.Glass, { Transparency = 0.15 }),
	P("Block", V(0.5, 1.0, 0.06), V(0.68, 0.6, -0.66), C(54, 54, 60)),
	P("Block", V(0.36, 0.16, 0.07), V(0.68, 0.94, -0.67), C(80, 255, 120), M.Neon),
	P("Block", V(0.08, 0.5, 0.12), V(0.35, 0.6, -0.72), SILVER, M.Metal),
})

define("Laptop", "Laptop", 2, 280, "Common", {
	P("Block", V(1.9, 0.12, 1.3), V(0, 0.06, 0), C(70, 72, 82), M.Metal),
	P("Block", V(1.6, 0.03, 0.62), V(0, 0.13, -0.16), C(30, 30, 36)),
	P("Block", V(1.9, 1.25, 0.08), V(0, 0.72, 0.72), C(70, 72, 82), M.Metal, { Rotation = V(15, 0, 0) }),
	P("Block", V(1.7, 1.05, 0.02), V(0, 0.73, 0.67), C(90, 180, 255), M.Neon, { Rotation = V(15, 0, 0) }),
})

define("GameConsole", "Game Console", 2, 320, "Common", {
	P("Block", V(1.7, 0.42, 1.25), V(0, 0.21, 0), BLACK),
	P("Block", V(1.3, 0.05, 0.05), V(0, 0.28, -0.63), C(60, 160, 255), M.Neon),
	P("Block", V(0.9, 0.16, 0.42), V(0, 0.5, -0.12), C(50, 50, 58)),
	P("Ball", V(0.38, 0.38, 0.38), V(-0.42, 0.48, -0.02), C(50, 50, 58)),
	P("Ball", V(0.38, 0.38, 0.38), V(0.42, 0.48, -0.02), C(50, 50, 58)),
	P("Ball", V(0.1, 0.1, 0.1), V(0.22, 0.6, -0.18), C(255, 70, 70)),
	P("Ball", V(0.1, 0.1, 0.1), V(0.3, 0.6, -0.1), C(70, 200, 255)),
})

local GUITAR_RED = C(200, 30, 40)
define("ElectricGuitar", "Electric Guitar", 2, 450, "Rare", {
	P("Cylinder", V(0.3, 1.45, 1.45), V(0, 0.75, 0), GUITAR_RED, nil, { Rotation = FACING }),
	P("Cylinder", V(0.3, 1.05, 1.05), V(0, 1.5, 0), GUITAR_RED, nil, { Rotation = FACING }),
	P("Block", V(0.62, 0.62, 0.05), V(0.05, 0.85, -0.16), WHITE),
	P("Block", V(0.26, 2.0, 0.14), V(0, 2.75, 0), C(150, 98, 52), M.Wood),
	P("Block", V(0.42, 0.62, 0.12), V(0, 4.0, 0), BLACK),
	P("Block", V(0.5, 0.08, 0.08), V(0, 0.55, -0.17), SILVER, M.Metal),
})

define("FlatscreenTV", "Flatscreen TV", 2, 600, "Rare", {
	P("Block", V(1.4, 0.1, 0.7), V(0, 0.05, 0), BLACK),
	P("Block", V(0.25, 0.7, 0.2), V(0, 0.45, 0.1), BLACK),
	P("Block", V(3.6, 2.1, 0.16), V(0, 1.85, 0.05), BLACK),
	P("Block", V(3.4, 1.9, 0.04), V(0, 1.85, -0.04), C(40, 110, 220), M.Neon),
})

define("GoldenWatch", "Golden Watch", 2, 1500, "Epic", {
	P("Block", V(1.1, 0.5, 0.85), V(0, 0.25, 0), C(30, 30, 34), M.Fabric),
	P("Block", V(0.85, 0.14, 0.62), V(0, 0.57, 0), C(236, 226, 200), M.Fabric),
	P("Block", V(0.26, 0.06, 1.0), V(0, 0.66, 0), GOLD, M.Metal, { Reflectance = 0.2 }),
	P("Cylinder", V(0.14, 0.62, 0.62), V(0, 0.72, 0), GOLD, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Cylinder", V(0.15, 0.48, 0.48), V(0, 0.73, 0), WHITE, nil, { Rotation = VERTICAL }),
	P("Block", V(0.03, 0.02, 0.2), V(0, 0.81, -0.06), BLACK),
	P("Block", V(0.15, 0.02, 0.03), V(0.06, 0.81, 0), BLACK),
})

--------------------------------------------------------------------------------
-- Tier 3: Modern villas
--------------------------------------------------------------------------------
define("EspressoMachine", "Espresso Machine", 3, 1400, "Common", {
	P("Block", V(1.7, 1.7, 1.3), V(0, 0.85, 0.1), C(186, 188, 196), M.Metal, { Reflectance = 0.15 }),
	P("Block", V(1.7, 0.1, 1.3), V(0, 1.75, 0.1), BLACK),
	P("Block", V(0.7, 0.3, 0.5), V(0, 1.2, -0.75), BLACK),
	P("Block", V(1.3, 0.15, 0.6), V(0, 0.075, -0.8), BLACK),
	P("Cylinder", V(0.38, 0.34, 0.34), V(0, 0.34, -0.8), WHITE, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.05, 0.36, 0.36), V(0.52, 1.35, -0.56), WHITE, nil, { Rotation = FACING }),
	P("Cylinder", V(0.05, 0.36, 0.36), V(-0.52, 1.35, -0.56), WHITE, nil, { Rotation = FACING }),
})

define("GamingPC", "Gaming PC", 3, 2000, "Common", {
	P("Block", V(1.0, 2.1, 2.0), V(0, 1.05, 0), BLACK),
	P("Block", V(0.04, 1.9, 1.8), V(-0.51, 1.05, 0), C(120, 140, 170), M.Glass, { Transparency = 0.4 }),
	P("Cylinder", V(0.06, 0.75, 0.75), V(-0.45, 1.5, 0.35), C(255, 60, 200), M.Neon),
	P("Cylinder", V(0.06, 0.75, 0.75), V(-0.45, 0.65, 0.35), C(60, 230, 255), M.Neon),
	P("Block", V(0.06, 1.8, 0.08), V(-0.45, 1.05, -0.82), C(140, 80, 255), M.Neon),
	P("Block", V(0.4, 0.05, 0.05), V(0, 1.95, -1.01), C(60, 160, 255), M.Neon),
})

define("ModernArt", "Modern Art", 3, 3200, "Rare", {
	P("Block", V(1.6, 0.15, 0.8), V(0, 0.075, 0.1), C(60, 44, 32), M.Wood),
	P("Block", V(0.15, 1.3, 0.15), V(0, 0.8, 0.12), C(60, 44, 32), M.Wood),
	P("Block", V(2.4, 1.9, 0.12), V(0, 2.4, 0.06), WHITE, M.Fabric),
	P("Block", V(0.9, 0.9, 0.04), V(-0.55, 2.65, -0.02), C(230, 40, 50)),
	P("Block", V(1.1, 0.6, 0.04), V(0.5, 1.95, -0.02), C(40, 90, 230)),
	P("Block", V(0.12, 1.7, 0.04), V(0.02, 2.4, -0.025), BLACK),
	P("Block", V(2.2, 0.12, 0.04), V(0, 2.2, -0.025), BLACK),
	P("Ball", V(0.55, 0.55, 0.55), V(0.62, 2.85, -0.05), C(255, 210, 40)),
})

define("GoldenTrophy", "Golden Trophy", 3, 4000, "Rare", {
	P("Block", V(1.1, 0.45, 1.1), V(0, 0.225, 0), C(32, 32, 36), M.Marble),
	P("Block", V(0.7, 0.25, 0.04), V(0, 0.225, -0.57), GOLD, M.Metal),
	P("Cylinder", V(0.75, 0.32, 0.32), V(0, 0.82, 0), GOLD, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Cylinder", V(0.15, 0.7, 0.7), V(0, 1.22, 0), GOLD, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Cylinder", V(1.0, 1.05, 1.05), V(0, 1.8, 0), GOLD, M.Metal, { Rotation = VERTICAL, Reflectance = 0.25 }),
	P("Block", V(0.18, 0.7, 0.18), V(-0.65, 1.85, 0), GOLD, M.Metal, { Reflectance = 0.25 }),
	P("Block", V(0.18, 0.7, 0.18), V(0.65, 1.85, 0), GOLD, M.Metal, { Reflectance = 0.25 }),
	P("Cylinder", V(0.04, 0.9, 0.9), V(0, 2.31, 0), C(196, 140, 30), M.Metal, { Rotation = VERTICAL }),
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
define("JewelryBox", "Jewelry Box", 3, 9000, "Epic", jewelryBox)

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
define("DiamondNecklace", "Diamond Necklace", 3, 22000, "Legendary", necklace)

--------------------------------------------------------------------------------
-- Tier 4: The Mansion
--------------------------------------------------------------------------------
local function goldBar(x: number, y: number): PartSpec
	return P("Block", V(0.62, 0.36, 1.25), V(x, y, 0), GOLD, M.Metal, { Reflectance = 0.3 })
end
define("GoldBars", "Gold Bars", 4, 12000, "Common", {
	goldBar(-0.68, 0.18),
	goldBar(0, 0.18),
	goldBar(0.68, 0.18),
	goldBar(-0.34, 0.54),
	goldBar(0.34, 0.54),
	goldBar(0, 0.9),
})

local PORCELAIN = C(238, 240, 245)
local COBALT = C(32, 64, 160)
define("AncientVase", "Ancient Vase", 4, 15000, "Common", {
	P("Cylinder", V(0.3, 0.85, 0.85), V(0, 0.15, 0), COBALT, nil, { Rotation = VERTICAL }),
	P("Ball", V(1.7, 1.7, 1.7), V(0, 1.1, 0), PORCELAIN),
	P("Cylinder", V(0.28, 1.72, 1.72), V(0, 1.1, 0), COBALT, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.9, 0.62, 0.62), V(0, 2.2, 0), PORCELAIN, nil, { Rotation = VERTICAL }),
	P("Cylinder", V(0.16, 0.9, 0.9), V(0, 2.65, 0), COBALT, nil, { Rotation = VERTICAL }),
})

define("Masterpiece", "Masterpiece Painting", 4, 28000, "Rare", {
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
define("RoyalCrown", "Royal Crown", 4, 45000, "Epic", crown)

define("GiantDiamond", "Giant Diamond", 4, 120000, "Legendary", {
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

-- Cash per second this item earns while stored in a warehouse.
function Items.getIncome(itemId: string): number
	local def = byId[itemId]
	if not def then
		return 0
	end
	return math.max(1, math.floor(def.Value * Config.Economy.IncomeRatio + 0.5))
end

-- Picks a random item for a house of the given tier, weighted by rarity.
function Items.roll(tier: number, rng: Random): string
	local byRarity: { [string]: { ItemDef } } = {}
	local totalWeight = 0
	for _, def in list do
		if def.Tier == tier then
			local bucket = byRarity[def.Rarity]
			if not bucket then
				bucket = {}
				byRarity[def.Rarity] = bucket
				totalWeight += Items.Rarities[def.Rarity].Weight
			end
			table.insert(bucket, def)
		end
	end
	if totalWeight <= 0 then
		return list[1].Id
	end
	local roll = rng:NextNumber() * totalWeight
	for rarityName, bucket in byRarity do
		roll -= Items.Rarities[rarityName].Weight
		if roll <= 0 then
			return bucket[rng:NextInteger(1, #bucket)].Id
		end
	end
	-- Floating point safety net: return any item of this tier.
	for _, bucket in byRarity do
		return bucket[1].Id
	end
	return list[1].Id
end

return Items
