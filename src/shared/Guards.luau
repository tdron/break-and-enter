--!strict
--[[
	Guards
	------
	3D models for every house defender, built from plain parts (no meshes):
	  * a tuxedo cat in Maple Cottage, then a puppy, a labrador and a guard dog,
	  * the owners themselves: a home owner, an off-duty officer and a wizard,
	  * a T-Rex, a squad of security bots and the museum's fleet of security cars.

	Which guard lives where is set by Config.Houses / Config.Guards; this module
	only knows what they look like. Model conventions (like Items):
	  * animals: origin = the ground under the middle of the body, front = -Z
	  * drones: origin = the middle of the drone (they hover)
	Eyes are kept separate so the server can make them glow red during an alarm.

	Defenders are physical: the root is a real collider (a box around the body, so a T-Rex is
	not forever snagged on its tail and a car not on its nose) and it is what the world pushes
	back against, so nothing walks through a wall any more. Everything else is welded decoration.

	The kinds that walk get their legs pinned at build time (Limbs): each one is a Motor6D
	swinging a leg around its own hip, which WalkCycle then poses in stops. Hoverers (drones),
	tracked robots and cars are given no limbs at all.
]]

local Config = require(script.Parent.Config)
local WalkCycle = require(script.Parent.WalkCycle)

export type PartSpec = {
	Shape: Enum.PartType,
	Size: Vector3,
	Position: Vector3,
	Rotation: Vector3?, -- degrees, applied like CFrame.Angles
	Color: Color3,
	Material: Enum.Material?,
	Transparency: number?,
}

export type Look = {
	Parts: { PartSpec },
	Eyes: { Vector3 },
	EyeSize: number,
	EyeColor: Color3, -- while the guard is calm
	EyeGlows: boolean, -- cat eyes shine in the dark, dog eyes don't
}

export type GuardModel = {
	Model: Model,
	Root: BasePart, -- the physics body (AlignPosition/AlignOrientation go here; it collides)
	Eyes: { BasePart },
	Limbs: { WalkCycle.Limb }, -- the pinned legs, empty for anything that hovers or rolls
	Light: PointLight?, -- drones carry a red searchlight
	Status: TextLabel, -- "💤" / "❗" bubble above the guard
	RootHeight: number, -- how far the root's centre sits above the guard's origin
	Size: Vector3, -- bounds of the visible parts (how big the guard is)
	Kind: string,
}

local Guards = {}

Guards.AlertEyeColor = Color3.fromRGB(255, 40, 40)

local V = Vector3.new
local C = Color3.fromRGB
local M = Enum.Material
local BALL, BLOCK, CYLINDER = Enum.PartType.Ball, Enum.PartType.Block, Enum.PartType.Cylinder

local function P(shape: Enum.PartType, size: Vector3, position: Vector3, color: Color3, material: Enum.Material?, rotation: Vector3?): PartSpec
	return {
		Shape = shape,
		Size = size,
		Position = position,
		Rotation = rotation,
		Color = color,
		Material = material or M.SmoothPlastic,
	}
end

--------------------------------------------------------------------------------
-- Cats (the cottages)
--------------------------------------------------------------------------------
type CatColors = {
	Fur: Color3,
	Chest: Color3,
	Muzzle: Color3,
	Paws: Color3,
	Ears: Color3,
	Tail: Color3,
	Stripes: Color3?,
	Eyes: Color3,
}

local PINK = C(255, 160, 180)

local function cat(colors: CatColors): Look
	local fur = M.Fabric
	local parts: { PartSpec } = {
		P(BLOCK, V(0.8, 0.66, 1.5), V(0, 0.88, 0.1), colors.Fur, fur),
		P(BALL, V(0.78, 0.78, 0.78), V(0, 0.92, -0.55), colors.Chest, fur),
		P(BALL, V(0.8, 0.8, 0.8), V(0, 0.86, 0.75), colors.Fur, fur),
		P(BALL, V(0.8, 0.8, 0.8), V(0, 1.48, -0.85), colors.Fur, fur),
		P(BALL, V(0.38, 0.38, 0.38), V(0, 1.34, -1.16), colors.Muzzle, fur),
		P(BALL, V(0.11, 0.11, 0.11), V(0, 1.44, -1.33), PINK),
		-- Tail curving up behind
		P(BLOCK, V(0.17, 0.17, 1.1), V(0, 1.42, 1.38), colors.Tail, fur, V(-55, 0, 0)),
		P(BALL, V(0.22, 0.22, 0.22), V(0, 1.86, 1.68), colors.Tail, fur),
	}
	for _, side in { -1, 1 } do
		-- Ears: a square turned 45° pokes a triangle out of the head
		table.insert(parts, P(BLOCK, V(0.26, 0.26, 0.1), V(side * 0.22, 1.84, -0.82), colors.Ears, fur, V(0, 0, 45)))
		table.insert(parts, P(BLOCK, V(0.15, 0.15, 0.04), V(side * 0.22, 1.83, -0.88), PINK, nil, V(0, 0, 45)))
		-- Legs and paws
		for _, z in { -0.5, 0.68 } do
			table.insert(parts, P(BLOCK, V(0.22, 0.62, 0.22), V(side * 0.24, 0.31, z), colors.Fur, fur))
			table.insert(parts, P(BLOCK, V(0.25, 0.12, 0.3), V(side * 0.24, 0.06, z - 0.04), colors.Paws, fur))
		end
		-- Whiskers
		table.insert(parts, P(BLOCK, V(0.5, 0.025, 0.025), V(side * 0.3, 1.36, -1.22), C(250, 250, 250), nil, V(0, side * 12, side * 8)))
		table.insert(parts, P(BLOCK, V(0.5, 0.025, 0.025), V(side * 0.3, 1.3, -1.22), C(250, 250, 250), nil, V(0, side * 12, -side * 6)))
	end
	local stripes = colors.Stripes
	if stripes then
		for _, z in { -0.3, 0.1, 0.5 } do
			table.insert(parts, P(BLOCK, V(0.84, 0.1, 0.18), V(0, 1.17, z), stripes, fur))
		end
		table.insert(parts, P(BLOCK, V(0.3, 0.08, 0.1), V(0, 1.86, -0.92), stripes, fur))
	end
	return {
		Parts = parts,
		Eyes = { V(-0.17, 1.56, -1.18), V(0.17, 1.56, -1.18) },
		EyeSize = 0.17,
		EyeColor = colors.Eyes,
		EyeGlows = true,
	}
end

--------------------------------------------------------------------------------
-- Dogs (every other house) — one builder, tuned per breed
--------------------------------------------------------------------------------
type DogOptions = {
	Scale: number,
	LegLength: number,
	BodyLength: number,
	BodyHeight: number,
	BodyWidth: number,
	Head: Vector3, -- width, height, length
	Snout: number, -- snout length (pugs are flat-faced)
	Ears: string, -- "Pointy" | "Big" | "Floppy"
	Tail: string, -- "Long" | "Up" | "Curly" | "Stub" | "Docked"
	Fur: Color3,
	Chest: Color3,
	Paws: Color3,
	SnoutColor: Color3,
	EarColor: Color3,
	Collar: Color3,
	Saddle: Color3?, -- German Shepherd back
	Spots: Color3?, -- Dalmatian spots
	Brows: Color3?, -- Doberman tan eyebrows
}

local NOSE = C(26, 22, 22)

local function dog(o: DogOptions): Look
	local s = o.Scale
	local fur = M.Fabric
	local legH = o.LegLength * s
	local bodyL, bodyH, bodyW = o.BodyLength * s, o.BodyHeight * s, o.BodyWidth * s
	local bodyY = legH + bodyH / 2
	local front, back = -bodyL / 2, bodyL / 2
	local headW, headH, headL = o.Head.X * s, o.Head.Y * s, o.Head.Z * s
	local headY = bodyY + bodyH * 0.55 + headH * 0.45
	local headZ = front - headL * 0.25
	local snoutL = o.Snout * s
	local snoutZ = headZ - headL / 2 - snoutL / 2
	local snoutY = headY - headH * 0.2
	local legW = 0.26 * s

	local parts: { PartSpec } = {
		P(BLOCK, V(bodyW, bodyH, bodyL), V(0, bodyY, 0), o.Fur, fur),
		P(BLOCK, V(bodyW * 0.92, bodyH * 0.85, 0.3 * s), V(0, bodyY - bodyH * 0.02, front - 0.08 * s), o.Chest, fur),
		-- Neck + head
		P(BLOCK, V(bodyW * 0.7, bodyH * 0.9, 0.55 * s), V(0, bodyY + bodyH * 0.4, front + 0.1 * s), o.Fur, fur, V(-25, 0, 0)),
		P(BLOCK, V(headW, headH, headL), V(0, headY, headZ), o.Fur, fur),
		P(BLOCK, V(headW * 0.62, headH * 0.5, math.max(snoutL, 0.08 * s)), V(0, snoutY, snoutZ), o.SnoutColor, fur),
		P(BALL, V(0.18 * s, 0.18 * s, 0.18 * s), V(0, snoutY + headH * 0.18, snoutZ - snoutL / 2 - 0.02 * s), NOSE),
		P(BLOCK, V(headW * 0.4, 0.05 * s, 0.05 * s), V(0, snoutY - headH * 0.2, snoutZ - snoutL / 2 + 0.01), NOSE),
		-- Collar with a tag
		P(BLOCK, V(bodyW * 0.78, 0.14 * s, 0.6 * s), V(0, bodyY + bodyH * 0.45, front + 0.05 * s), o.Collar, nil, V(-25, 0, 0)),
		P(BALL, V(0.16 * s, 0.16 * s, 0.16 * s), V(0, bodyY + bodyH * 0.25, front - 0.24 * s), C(255, 200, 60), M.Metal),
	}

	-- Legs and paws
	for _, side in { -1, 1 } do
		for _, z in { front + legW * 0.8, back - legW * 0.8 } do
			local x = side * (bodyW / 2 - legW / 2)
			table.insert(parts, P(BLOCK, V(legW, legH + 0.1 * s, legW), V(x, (legH + 0.1 * s) / 2, z), o.Fur, fur))
			table.insert(parts, P(BLOCK, V(legW + 0.04 * s, 0.14 * s, legW + 0.12 * s), V(x, 0.07 * s, z - 0.05 * s), o.Paws, fur))
		end
	end

	-- Ears
	local headTop = headY + headH / 2
	for _, side in { -1, 1 } do
		if o.Ears == "Floppy" then
			table.insert(parts, P(BLOCK, V(0.12 * s, headH * 0.75, headL * 0.45), V(side * (headW / 2 + 0.05 * s), headY - headH * 0.05, headZ + headL * 0.1), o.EarColor, fur))
		elseif o.Ears == "Big" then
			table.insert(parts, P(BLOCK, V(0.34 * s, 0.5 * s, 0.08 * s), V(side * headW * 0.36, headTop + 0.18 * s, headZ + headL * 0.1), o.EarColor, fur, V(0, 0, -side * 28)))
		else -- Pointy
			table.insert(parts, P(BLOCK, V(0.2 * s, 0.42 * s, 0.1 * s), V(side * headW * 0.3, headTop + 0.17 * s, headZ + headL * 0.15), o.EarColor, fur, V(0, 0, -side * 10)))
		end
	end

	-- Tail
	local rumpY = bodyY + bodyH * 0.3
	if o.Tail == "Long" then
		table.insert(parts, P(BLOCK, V(0.16 * s, 0.16 * s, 0.9 * s), V(0, rumpY - 0.29 * s, back + 0.34 * s), o.Fur, fur, V(40, 0, 0)))
	elseif o.Tail == "Up" then
		table.insert(parts, P(BLOCK, V(0.14 * s, 0.14 * s, 0.75 * s), V(0, rumpY + 0.28 * s, back + 0.24 * s), o.Fur, fur, V(-50, 0, 0)))
	elseif o.Tail == "Curly" then
		table.insert(parts, P(BALL, V(0.38 * s, 0.38 * s, 0.38 * s), V(0, bodyY + bodyH / 2 + 0.08 * s, back - 0.12 * s), o.Fur, fur))
	elseif o.Tail == "Stub" then
		table.insert(parts, P(BALL, V(0.24 * s, 0.24 * s, 0.24 * s), V(0, rumpY, back + 0.06 * s), o.Chest, fur))
	else -- Docked
		table.insert(parts, P(BLOCK, V(0.13 * s, 0.13 * s, 0.32 * s), V(0, rumpY + 0.1 * s, back + 0.1 * s), o.Fur, fur, V(-45, 0, 0)))
	end

	-- Markings
	local saddle = o.Saddle
	if saddle then
		table.insert(parts, P(BLOCK, V(bodyW + 0.04 * s, bodyH * 0.45, bodyL * 0.72), V(0, bodyY + bodyH * 0.3, 0.12 * s), saddle, fur))
	end
	local spots = o.Spots
	if spots then
		local spotSize = 0.2 * s
		local function spot(position: Vector3)
			table.insert(parts, P(BALL, V(spotSize, spotSize, spotSize), position, spots, fur))
		end
		for _, side in { -1, 1 } do
			local x = side * bodyW / 2
			spot(V(x, bodyY + 0.12 * s, -0.45 * s))
			spot(V(x, bodyY - 0.15 * s, 0.15 * s))
			spot(V(x, bodyY + 0.18 * s, 0.6 * s))
			spot(V(side * headW / 2, headY + 0.08 * s, headZ + 0.1 * s))
			spot(V(side * (bodyW / 2 - legW / 2) + side * legW / 2, legH * 0.6, front + legW * 0.8))
		end
		spot(V(0.15 * s, bodyY + bodyH / 2, -0.2 * s))
		spot(V(-0.2 * s, bodyY + bodyH / 2, 0.42 * s))
	end
	local brows = o.Brows
	if brows then
		for _, side in { -1, 1 } do
			table.insert(parts, P(BALL, V(0.1 * s, 0.1 * s, 0.1 * s), V(side * headW * 0.24, headY + headH * 0.3, headZ - headL / 2 - 0.01), brows))
		end
	end

	local eyeZ = headZ - headL / 2 - 0.02 * s
	return {
		Parts = parts,
		Eyes = { V(-headW * 0.24, headY + headH * 0.12, eyeZ), V(headW * 0.24, headY + headH * 0.12, eyeZ) },
		EyeSize = 0.15 * s,
		EyeColor = C(40, 26, 20),
		EyeGlows = false,
	}
end

--------------------------------------------------------------------------------
-- People: the home owner, the off-duty officer and the wizard
--------------------------------------------------------------------------------
type HumanOptions = {
	Scale: number,
	Skin: Color3,
	Shirt: Color3,
	Trousers: Color3,
	Shoes: Color3,
	Hair: Color3,
	HairStyle: string, -- "Short" | "Bun" | "Bald" | "Cap" | "Pointed"
	Hat: Color3?, -- cap / pointed hat colour
	Beard: Color3?, -- wizard beard
	Badge: Color3?, -- police badge on the chest
	Prop: string?, -- "Pan" | "Torch" | "Wand"
	Robe: boolean?, -- a long robe instead of a shirt and trousers
	EyeColor: Color3,
	GlowingEyes: boolean?,
}

local function human(o: HumanOptions): Look
	local s = o.Scale
	local parts: { PartSpec } = {}
	local eyes: { Vector3 } = {}
	local function add(spec: PartSpec)
		table.insert(parts, spec)
	end

	local lower = if o.Robe then o.Shirt else o.Trousers
	-- Legs, feet
	for _, side in { -1, 1 } do
		add(P(BLOCK, V(0.62 * s, 2.05 * s, 0.72 * s), V(side * 0.4 * s, 1.02 * s, 0), lower))
		add(P(BLOCK, V(0.76 * s, 0.3 * s, 1.08 * s), V(side * 0.4 * s, 0.15 * s, -0.12 * s), o.Shoes))
	end
	-- Torso (a robe flares out into a wide skirt instead)
	if o.Robe then
		add(P(BLOCK, V(2.0 * s, 1.5 * s, 1.3 * s), V(0, 1.75 * s, 0), o.Shirt))
		add(P(BLOCK, V(2.2 * s, 0.5 * s, 1.45 * s), V(0, 0.3 * s, 0), o.Shirt))
		add(P(BLOCK, V(1.5 * s, 1.6 * s, 1.0 * s), V(0, 3.15 * s, 0), o.Shirt))
	else
		add(P(BLOCK, V(1.5 * s, 1.8 * s, 0.95 * s), V(0, 3.0 * s, 0), o.Shirt))
		add(P(BLOCK, V(1.56 * s, 0.24 * s, 1.0 * s), V(0, 3.84 * s, 0), o.Trousers))
	end
	local badge = o.Badge
	if badge then
		add(P(BLOCK, V(0.34 * s, 0.34 * s, 0.1 * s), V(-0.36 * s, 3.4 * s, -0.5 * s), badge, M.Metal))
		add(P(BLOCK, V(1.5 * s, 0.16 * s, 0.06 * s), V(0, 3.05 * s, -0.49 * s), C(30, 34, 44), nil, V(0, 0, 12)))
	end
	-- Arms, hands
	for _, side in { -1, 1 } do
		add(P(BLOCK, V(0.46 * s, 1.6 * s, 0.58 * s), V(side * 1.04 * s, 2.95 * s, 0), o.Shirt))
		add(P(BALL, V(0.5 * s, 0.36 * s, 0.58 * s), V(side * 1.04 * s, 2.05 * s, 0), o.Skin))
	end
	-- Head
	add(P(BALL, V(1.0 * s, 1.06 * s, 1.0 * s), V(0, 4.5 * s, 0), o.Skin))
	add(P(BALL, V(0.22 * s, 0.2 * s, 0.22 * s), V(0, 4.4 * s, -0.5 * s), o.Skin))
	add(P(BLOCK, V(0.42 * s, 0.1 * s, 0.14 * s), V(0, 4.2 * s, -0.46 * s), C(150, 92, 86)))
	table.insert(eyes, V(-0.23 * s, 4.56 * s, -0.45 * s))
	table.insert(eyes, V(0.23 * s, 4.56 * s, -0.45 * s))
	-- Brows
	for _, side in { -1, 1 } do
		add(P(BLOCK, V(0.34 * s, 0.1 * s, 0.16 * s), V(side * 0.23 * s, 4.71 * s, -0.44 * s), o.Hair))
	end
	-- Hair (and hats)
	local hat = o.Hat
	if o.HairStyle == "Short" then
		add(P(BLOCK, V(1.08 * s, 0.34 * s, 1.08 * s), V(0, 4.98 * s, 0.02 * s), o.Hair))
		add(P(BLOCK, V(1.08 * s, 0.6 * s, 0.3 * s), V(0, 4.66 * s, 0.42 * s), o.Hair))
	elseif o.HairStyle == "Bun" then
		add(P(BLOCK, V(1.08 * s, 0.3 * s, 1.08 * s), V(0, 4.96 * s, 0.02 * s), o.Hair))
		add(P(BALL, V(0.62 * s, 0.62 * s, 0.62 * s), V(0, 5.05 * s, 0.5 * s), o.Hair))
	elseif o.HairStyle == "Bald" then
		for _, side in { -1, 1 } do
			add(P(BLOCK, V(0.16 * s, 0.4 * s, 0.72 * s), V(side * 0.5 * s, 4.66 * s, 0.1 * s), o.Hair))
		end
	elseif o.HairStyle == "Cap" then
		local cap = hat or o.Hair
		add(P(BLOCK, V(1.1 * s, 0.32 * s, 1.1 * s), V(0, 5.0 * s, 0.02 * s), cap))
		add(P(BLOCK, V(1.02 * s, 0.14 * s, 0.6 * s), V(0, 4.88 * s, -0.55 * s), cap))
		add(P(BALL, V(0.2 * s, 0.2 * s, 0.2 * s), V(0, 4.9 * s, -0.56 * s), C(230, 190, 60), M.Metal))
	elseif o.HairStyle == "Pointed" then
		local cone = hat or o.Hair
		add(P(CYLINDER, V(0.16 * s, 2.15 * s, 2.15 * s), V(0, 4.98 * s, 0.04 * s), cone, nil, V(0, 0, 90)))
		add(P(BLOCK, V(1.05 * s, 0.55 * s, 1.05 * s), V(0, 5.3 * s, 0.06 * s), cone))
		add(P(BLOCK, V(0.74 * s, 0.5 * s, 0.74 * s), V(0, 5.78 * s, 0.12 * s), cone))
		add(P(BLOCK, V(0.46 * s, 0.44 * s, 0.46 * s), V(0, 6.2 * s, 0.18 * s), cone))
		add(P(BLOCK, V(0.2 * s, 0.4 * s, 0.2 * s), V(0, 6.56 * s, 0.24 * s), cone))
		add(P(BALL, V(0.24 * s, 0.24 * s, 0.24 * s), V(0, 6.78 * s, 0.27 * s), C(255, 236, 140), M.Neon))
	end
	local beard = o.Beard
	if beard then
		add(P(BLOCK, V(0.74 * s, 0.85 * s, 0.36 * s), V(0, 4.02 * s, -0.32 * s), beard))
		add(P(BLOCK, V(0.56 * s, 0.16 * s, 0.18 * s), V(0, 4.28 * s, -0.5 * s), beard))
		add(P(BLOCK, V(0.3 * s, 0.7 * s, 0.16 * s), V(0, 4.3 * s, -0.42 * s), beard))
	end
	-- Something to wave at a thief
	local prop = o.Prop
	if prop == "Pan" then
		add(P(CYLINDER, V(0.9 * s, 0.36 * s, 0.36 * s), V(1.04 * s, 2.5 * s, -0.2 * s), C(214, 178, 120), M.Wood, V(0, 0, 90)))
		add(P(BLOCK, V(0.16 * s, 0.5 * s, 0.16 * s), V(1.04 * s, 1.9 * s, -0.2 * s), C(160, 128, 84), M.Wood))
	elseif prop == "Torch" then
		add(P(CYLINDER, V(0.66 * s, 0.4 * s, 0.4 * s), V(1.04 * s, 2.15 * s, -0.34 * s), C(40, 44, 52), M.Metal, V(0, 0, 90)))
		local lens = P(BALL, V(0.4 * s, 0.4 * s, 0.4 * s), V(1.04 * s, 2.55 * s, -0.34 * s), C(255, 238, 170), M.Neon)
		add(lens)
		table.insert(eyes, lens.Position)
	elseif prop == "Wand" then
		add(P(CYLINDER, V(0.9 * s, 0.12 * s, 0.12 * s), V(1.04 * s, 2.5 * s, -0.25 * s), C(92, 62, 40), M.Wood, V(0, 0, 90)))
		local tip = P(BALL, V(0.32 * s, 0.32 * s, 0.32 * s), V(1.04 * s, 2.98 * s, -0.2 * s), C(150, 240, 255), M.Neon)
		add(tip)
		table.insert(eyes, tip.Position)
	end

	return {
		Parts = parts,
		Eyes = eyes,
		EyeSize = 0.17 * s,
		EyeColor = o.EyeColor,
		EyeGlows = o.GlowingEyes == true,
	}
end

--------------------------------------------------------------------------------
-- The T-Rex
--------------------------------------------------------------------------------
local function trex(): Look
	local hide = C(96, 138, 78)
	local belly = C(196, 190, 140)
	local dark = C(62, 96, 54)
	local claw = C(238, 232, 208)
	local parts: { PartSpec } = {
		-- Legs
		P(BLOCK, V(1.5, 3.6, 1.9), V(-0.95, 1.8, 0.2), hide),
		P(BLOCK, V(1.5, 3.6, 1.9), V(0.95, 1.8, 0.2), hide),
		P(BLOCK, V(1.8, 0.62, 2.7), V(-0.95, 0.31, -0.35), hide),
		P(BLOCK, V(1.8, 0.62, 2.7), V(0.95, 0.31, -0.35), hide),
		-- Body, with a pale belly and a darker back
		P(BLOCK, V(2.9, 3.2, 4.6), V(0, 4.1, 0.4), hide, nil, V(-6, 0, 0)),
		P(BLOCK, V(2.4, 2.1, 4.1), V(0, 3.4, 0.2), belly, nil, V(-6, 0, 0)),
		P(BALL, V(3.0, 2.9, 2.9), V(0, 4.0, 2.1), hide),
		-- Tail
		P(BLOCK, V(2.3, 2.1, 2.4), V(0, 4.6, 3.9), hide, nil, V(22, 0, 0)),
		P(BLOCK, V(1.5, 1.4, 2.2), V(0, 5.3, 5.6), hide, nil, V(30, 0, 0)),
		P(BLOCK, V(0.85, 0.8, 1.8), V(0, 5.9, 7.0), dark, nil, V(36, 0, 0)),
		-- Neck and head
		P(BLOCK, V(1.9, 2.2, 1.9), V(0, 5.5, -1.6), hide, nil, V(-24, 0, 0)),
		P(BLOCK, V(2.05, 1.95, 3.3), V(0, 6.4, -3.3), hide, nil, V(-8, 0, 0)),
		P(BLOCK, V(1.75, 0.7, 2.5), V(0, 5.6, -3.1), dark, nil, V(10, 0, 0)),
		P(BLOCK, V(1.6, 0.6, 1.1), V(0, 7.0, -2.2), hide),
		-- Arms
		P(BLOCK, V(0.5, 1.5, 0.55), V(-1.55, 3.6, -1.4), hide, nil, V(40, 0, 0)),
		P(BLOCK, V(0.5, 1.5, 0.55), V(1.55, 3.6, -1.4), hide, nil, V(40, 0, 0)),
		-- Back plates
		P(BLOCK, V(0.5, 0.75, 0.6), V(0, 5.9, -0.7), dark),
		P(BLOCK, V(0.5, 0.9, 0.6), V(0, 6.1, 0.4), dark),
		P(BLOCK, V(0.5, 0.75, 0.6), V(0, 6.0, 1.5), dark),
		P(BLOCK, V(0.45, 0.6, 0.5), V(0, 5.6, 2.6), dark),
	}
	-- Toes and claws
	for _, side in { -1, 1 } do
		for _, offset in { -0.5, 0, 0.5 } do
			table.insert(parts, P(BLOCK, V(0.36, 0.36, 0.7), V(side * 0.95 + offset, 0.34, -1.6), claw))
		end
		table.insert(parts, P(BLOCK, V(0.3, 0.4, 0.6), V(side * 1.55, 2.9, -1.9), claw))
	end
	-- Teeth
	for _, side in { -1.1, -0.55, 0, 0.55, 1.1 } do
		table.insert(parts, P(BLOCK, V(0.24, 0.42, 0.2), V(side * 0.5, 5.95, -4.35), claw))
	end
	local eyes = { V(-0.62, 6.75, -4.0), V(0.62, 6.75, -4.0) }
	local look: Look = {
		Parts = parts,
		Eyes = eyes,
		EyeSize = 0.34,
		EyeColor = C(240, 226, 90),
		EyeGlows = true,
	}
	return look
end

--------------------------------------------------------------------------------
-- Security bot
--------------------------------------------------------------------------------
local function securityBot(): Look
	local shell = C(196, 202, 214)
	local dark = C(52, 58, 70)
	local parts: { PartSpec } = {
		P(CYLINDER, V(1.7, 0.55, 0.55), V(-0.44, 0.85, 0), dark, M.Metal, V(0, 0, 90)),
		P(CYLINDER, V(1.7, 0.55, 0.55), V(0.44, 0.85, 0), dark, M.Metal, V(0, 0, 90)),
		P(BLOCK, V(0.9, 0.26, 1.25), V(-0.44, 0.13, -0.16), dark, M.Metal),
		P(BLOCK, V(0.9, 0.26, 1.25), V(0.44, 0.13, -0.16), dark, M.Metal),
		P(BLOCK, V(1.75, 1.95, 1.2), V(0, 2.75, 0), shell, M.Metal),
		P(BLOCK, V(1.2, 0.55, 0.14), V(0, 2.35, -0.62), dark, M.Metal),
		P(BLOCK, V(0.5, 0.42, 0.12), V(0, 3.3, -0.62), C(90, 220, 255), M.Neon),
		P(BALL, V(0.56, 0.56, 0.56), V(-1.0, 3.4, 0), shell, M.Metal),
		P(BALL, V(0.56, 0.56, 0.56), V(1.0, 3.4, 0), shell, M.Metal),
		P(BLOCK, V(0.42, 1.6, 0.48), V(-1.06, 2.6, 0), shell, M.Metal),
		P(BLOCK, V(0.42, 1.6, 0.48), V(1.06, 2.6, 0), shell, M.Metal),
		P(BLOCK, V(0.52, 0.42, 0.58), V(-1.06, 1.7, 0), dark, M.Metal),
		P(BLOCK, V(0.52, 0.42, 0.58), V(1.06, 1.7, 0), dark, M.Metal),
		P(CYLINDER, V(0.34, 0.42, 0.42), V(0, 3.9, 0), dark, M.Metal, V(0, 0, 90)),
		P(BLOCK, V(1.1, 0.9, 1.0), V(0, 4.45, 0), shell, M.Metal),
		P(BLOCK, V(0.55, 0.22, 0.3), V(-0.9, 4.05, 0), C(255, 170, 60), M.Neon),
		P(CYLINDER, V(0.7, 0.09, 0.09), V(0, 5.2, 0.22), dark, M.Metal, V(0, 0, 90)),
	}
	local visor = P(BLOCK, V(0.94, 0.34, 0.14), V(0, 4.5, -0.55), C(255, 70, 60), M.Neon)
	table.insert(parts, visor)
	local antenna = P(BALL, V(0.24, 0.24, 0.24), V(0, 5.5, 0.22), C(255, 70, 60), M.Neon)
	table.insert(parts, antenna)
	return {
		Parts = parts,
		Eyes = { visor.Position, antenna.Position },
		EyeSize = 0.3,
		EyeColor = C(255, 70, 60),
		EyeGlows = true,
	}
end

--------------------------------------------------------------------------------
-- Security car (the museum's fleet)
--------------------------------------------------------------------------------
local function securityCar(): Look
	local body = C(28, 32, 44)
	local stripe = C(240, 240, 240)
	local glass = C(30, 46, 66)
	local parts: { PartSpec } = {
		-- Chassis and skirts
		P(BLOCK, V(4.7, 0.95, 9.6), V(0, 1.15, 0), body),
		P(BLOCK, V(4.9, 0.28, 1.0), V(0, 0.62, -4.9), C(20, 22, 28)),
		P(BLOCK, V(4.9, 0.28, 1.0), V(0, 0.62, 4.9), C(20, 22, 28)),
		-- Bonnet and boot
		P(BLOCK, V(4.55, 0.5, 3.0), V(0, 1.72, -3.1), body),
		P(BLOCK, V(4.55, 0.5, 2.6), V(0, 1.72, 3.3), body),
		-- Cabin and glass
		P(BLOCK, V(4.25, 1.15, 4.5), V(0, 2.35, 0.1), body),
		P(BLOCK, V(4.0, 0.95, 0.18), V(0, 2.4, -2.22), glass),
		P(BLOCK, V(4.0, 0.9, 0.18), V(0, 2.4, 2.42), glass),
		P(BLOCK, V(0.18, 0.9, 3.6), V(-2.16, 2.4, 0.1), glass),
		P(BLOCK, V(0.18, 0.9, 3.6), V(2.16, 2.4, 0.1), glass),
		P(BLOCK, V(4.5, 0.28, 4.7), V(0, 3.0, 0.1), C(18, 20, 26)),
		-- Livery: a white stripe and a gold number plate
		P(BLOCK, V(4.78, 0.4, 9.62), V(0, 1.35, 0), stripe),
		P(BLOCK, V(1.5, 0.4, 0.12), V(0, 1.0, -4.84), C(255, 214, 90), M.Neon),
		P(BLOCK, V(0.9, 0.3, 0.12), V(-1.9, 1.0, 4.84), C(255, 255, 255), M.SmoothPlastic),
		-- Wheels
		P(CYLINDER, V(0.8, 2.3, 2.3), V(-2.3, 1.15, -3.0), C(18, 18, 22), M.Rubber),
		P(CYLINDER, V(0.8, 2.3, 2.3), V(2.3, 1.15, -3.0), C(18, 18, 22), M.Rubber),
		P(CYLINDER, V(0.8, 2.3, 2.3), V(-2.3, 1.15, 3.0), C(18, 18, 22), M.Rubber),
		P(CYLINDER, V(0.8, 2.3, 2.3), V(2.3, 1.15, 3.0), C(18, 18, 22), M.Rubber),
		-- Light bar (the eyes: it flashes red when the alarm goes off)
		P(BLOCK, V(1.9, 0.18, 0.7), V(0, 3.2, -0.4), C(24, 26, 32), M.Metal),
	}
	local redLight = P(BLOCK, V(0.85, 0.26, 0.6), V(-0.5, 3.35, -0.4), C(255, 60, 60), M.Neon)
	local blueLight = P(BLOCK, V(0.85, 0.26, 0.6), V(0.5, 3.35, -0.4), C(70, 140, 255), M.Neon)
	local headlightLeft = P(BALL, V(0.5, 0.5, 0.4), V(-1.5, 1.55, -4.8), C(255, 248, 210), M.Neon)
	local headlightRight = P(BALL, V(0.5, 0.5, 0.4), V(1.5, 1.55, -4.8), C(255, 248, 210), M.Neon)
	table.insert(parts, redLight)
	table.insert(parts, blueLight)
	table.insert(parts, headlightLeft)
	table.insert(parts, headlightRight)
	return {
		Parts = parts,
		Eyes = { headlightLeft.Position, headlightRight.Position, redLight.Position, blueLight.Position },
		EyeSize = 0.42,
		EyeColor = C(255, 248, 210),
		EyeGlows = true,
	}
end

--------------------------------------------------------------------------------
-- The roster (keys match Config.Guards)
--------------------------------------------------------------------------------
local WHITE = C(246, 246, 244)

local looks: { [string]: Look } = {
	TuxedoCat = cat({
		Fur = C(30, 30, 34),
		Chest = WHITE,
		Muzzle = WHITE,
		Paws = WHITE,
		Ears = C(30, 30, 34),
		Tail = C(30, 30, 34),
		Eyes = C(245, 220, 60),
	}),
	Puppy = dog({
		Scale = 0.68,
		LegLength = 0.62,
		BodyLength = 1.7,
		BodyHeight = 0.85,
		BodyWidth = 0.85,
		Head = V(1.05, 1.0, 0.95),
		Snout = 0.34,
		Ears = "Floppy",
		Tail = "Stub",
		Fur = C(226, 196, 148),
		Chest = C(246, 228, 196),
		Paws = C(246, 228, 196),
		SnoutColor = C(232, 206, 166),
		EarColor = C(196, 162, 116),
		Collar = C(255, 120, 60),
	}),
	Labrador = dog({
		Scale = 1.15,
		LegLength = 1.0,
		BodyLength = 2.2,
		BodyHeight = 0.95,
		BodyWidth = 0.9,
		Head = V(0.85, 0.85, 0.9),
		Snout = 0.5,
		Ears = "Floppy",
		Tail = "Long",
		Fur = C(222, 172, 92),
		Chest = C(238, 200, 130),
		Paws = C(238, 200, 130),
		SnoutColor = C(196, 148, 78),
		EarColor = C(196, 148, 78),
		Collar = C(60, 130, 230),
		Saddle = C(200, 146, 70),
	}),
	GuardDog = dog({
		Scale = 1.35,
		LegLength = 1.05,
		BodyLength = 2.1,
		BodyHeight = 1.0,
		BodyWidth = 0.95,
		Head = V(0.9, 0.9, 0.95),
		Snout = 0.55,
		Ears = "Pointy",
		Tail = "Docked",
		Fur = C(58, 44, 36),
		Chest = C(176, 116, 60),
		Paws = C(176, 116, 60),
		SnoutColor = C(40, 30, 26),
		EarColor = C(58, 44, 36),
		Collar = C(190, 40, 40),
		Brows = C(176, 116, 60),
	}),
	HomeOwner = human({
		Scale = 1.05,
		Skin = C(238, 196, 158),
		Shirt = C(122, 172, 236),
		Trousers = C(72, 92, 152),
		Shoes = C(122, 86, 62),
		Hair = C(182, 182, 188),
		HairStyle = "Bun",
		Prop = "Pan",
		EyeColor = C(64, 82, 110),
	}),
	OffDutyOfficer = human({
		Scale = 1.08,
		Skin = C(206, 158, 116),
		Shirt = C(46, 66, 120),
		Trousers = C(38, 44, 62),
		Shoes = C(28, 28, 32),
		Hair = C(60, 48, 40),
		HairStyle = "Cap",
		Hat = C(38, 52, 96),
		Badge = C(238, 200, 90),
		Prop = "Torch",
		EyeColor = C(70, 110, 170),
	}),
	Wizard = human({
		Scale = 1.12,
		Skin = C(226, 186, 156),
		Shirt = C(96, 66, 178),
		Trousers = C(66, 46, 130),
		Shoes = C(48, 36, 78),
		Hair = C(232, 232, 236),
		HairStyle = "Pointed",
		Hat = C(88, 58, 168),
		Beard = C(234, 234, 238),
		Robe = true,
		Prop = "Wand",
		EyeColor = C(120, 220, 255),
		GlowingEyes = true,
	}),
	TRex = trex(),
	SecurityBot = securityBot(),
	SecurityCar = securityCar(),
}


--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------
local function newPart(model: Model, name: string, shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.Parent = model
	return part
end

local function rotation(degrees: Vector3?): CFrame
	if not degrees then
		return CFrame.identity
	end
	return CFrame.Angles(math.rad(degrees.X), math.rad(degrees.Y), math.rad(degrees.Z))
end

local function statusBubble(root: BasePart, height: number): TextLabel
	local gui = Instance.new("BillboardGui")
	gui.Name = "Status"
	gui.Size = UDim2.fromOffset(60, 60)
	gui.StudsOffsetWorldSpace = Vector3.new(0, height, 0)
	gui.MaxDistance = 70
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.Parent = root
	local label = Instance.new("TextLabel")
	label.Name = "Icon"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.FredokaOne
	label.Text = ""
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.4
	label.Parent = gui
	return label
end

local function weldAll(model: Model, root: BasePart, pinned: { [BasePart]: boolean })
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part ~= root and not pinned[part] then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part
		end
	end
end

local function weldTo(part0: BasePart, part1: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = part0
	weld.Part1 = part1
	weld.Parent = part1
end

--------------------------------------------------------------------------------
-- Physics body and legs
--------------------------------------------------------------------------------
-- The box a defender bumps into the world with: as wide and as tall as it looks, but *round* in
-- plan (the same box whichever way it is facing). Height is never capped - the box is centred on
-- the model, so shortening it would lift the defender off the floor.
--
-- Round in plan matters: a body that is 3 studs long and 1 wide sweeps its length through a wall
-- every time it turns on the spot next to one, and a defender pinned inside a wall cannot be
-- trusted to walk anywhere. Round, turning on the spot changes nothing, so a defender can always
-- turn wherever it can stand - which is what lets it line itself up with a doorway.
local COLLIDER_CAP = V(4.0, math.huge, 4.0)
local COLLIDER_CAPS: { [string]: Vector3 } = {
	Cat = V(1.1, math.huge, 1.1),
	Dog = V(2.8, math.huge, 2.8),
	Human = V(2.4, math.huge, 2.4),
	Wizard = V(2.6, math.huge, 2.6),
	Beast = V(3.6, math.huge, 3.6), -- the tail is 13 studs long; the body it walks with is not
	Robot = V(2.6, math.huge, 2.6),
	Vehicle = V(4.0, math.huge, 4.0),
	Drone = V(2.4, math.huge, 2.4),
}

local function colliderSize(bounds: Vector3, kind: string): Vector3
	local cap = COLLIDER_CAPS[kind] or COLLIDER_CAP
	local width = math.clamp(bounds.X, 0.4, cap.X)
	return V(width, bounds.Y, math.clamp(width, 0.4, cap.Z))
end

-- Only the kinds that walk are given legs. A drone hovers, the security bots run on tracks and
-- the cars on wheels: animating any of those would look plain wrong, so they keep rigid parts.
local WALKING = { Cat = true, Dog = true, Human = true, Wizard = true, Beast = true }
local GROUND_MARGIN = 0.09 -- how close to the floor a part has to sit to count as a foot
-- One paw or foot per stride, opposite legs half a stride apart (so a four-legged trot is
-- front-left/back-right together, which is what a real dog does).
local TROT_PHASES = { 0, 0.5, 0.5, 0 }

type LimbCluster = {
	X: number,
	Z: number,
	Top: number,
	Index: number, -- the part the joint drives: the leg itself, not the paw
	Members: { number },
}

-- Finds the limbs by looking for the parts that stand on the floor and grouping them into feet.
-- Returns nothing when the parts under the body are not legs (they are one blob, like the
-- wizard's robe, or there is only one of them) - those defenders just keep sliding.
local function findLimbs(home: CFrame, root: BasePart, look: Look, visual: { BasePart }, size: Vector3, kind: string): { WalkCycle.Limb }
	local limbs: { WalkCycle.Limb } = {}
	if not WALKING[kind] then
		return limbs
	end
	local ground = math.huge
	for _, spec in look.Parts do
		ground = math.min(ground, spec.Position.Y - spec.Size.Y / 2)
	end
	local radius = math.clamp(size.X * 0.22, 0.32, 0.9)
	local clusters: { LimbCluster } = {}
	for index, spec in look.Parts do
		if spec.Position.Y - spec.Size.Y / 2 <= ground + GROUND_MARGIN then
			local cluster: LimbCluster? = nil
			local closest = radius
			for _, other in clusters do
				local gap = (Vector3.new(other.X, 0, other.Z) - Vector3.new(spec.Position.X, 0, spec.Position.Z)).Magnitude
				if gap <= closest then
					cluster, closest = other, gap
				end
			end
			if cluster then
				local count = #cluster.Members
				cluster.X = (cluster.X * count + spec.Position.X) / (count + 1)
				cluster.Z = (cluster.Z * count + spec.Position.Z) / (count + 1)
				table.insert(cluster.Members, index)
				if spec.Position.Y + spec.Size.Y / 2 > cluster.Top then
					cluster.Top = spec.Position.Y + spec.Size.Y / 2
					cluster.Index = index
				end
			else
				table.insert(clusters, {
					X = spec.Position.X,
					Z = spec.Position.Z,
					Top = spec.Position.Y + spec.Size.Y / 2,
					Index = index,
					Members = { index },
				})
			end
		end
	end
	if #clusters < 2 then
		return limbs
	end
	table.sort(clusters, function(a, b)
		if a.Z ~= b.Z then
			return a.Z < b.Z -- front legs (-Z) first
		end
		return a.X < b.X
	end)
	for order, cluster in clusters do
		local part = visual[cluster.Index]
		if part then
			-- The pivot: the hip the leg swings around, turning with the guard.
			local pivot = home * CFrame.new(Vector3.new(cluster.X, cluster.Top, cluster.Z))
			local joint = Instance.new("Motor6D")
			joint.Name = "Leg" .. order
			joint.Part0 = root
			joint.Part1 = part
			joint.C0 = root.CFrame:Inverse() * pivot
			joint.C1 = part.CFrame:Inverse() * pivot
			joint.Parent = part
			local phase = TROT_PHASES[order] or ((order - 1) % 2) * 0.5
			table.insert(limbs, { Joint = joint, Base = joint.C0, Phase = phase })
			for _, member in cluster.Members do
				local other = visual[member]
				if other and other ~= part then
					weldTo(part, other)
				end
			end
		end
	end
	return limbs
end

local function buildDrone(home: CFrame): GuardModel
	local model = Instance.new("Model")
	model.Name = "Guard"
	local body = newPart(model, "Body", BALL, V(2.2, 2.2, 2.2), home, C(46, 48, 56), M.Metal)
	body.Massless = false
	body.CanCollide = true -- the rotors are decoration, but the drone itself is solid
	local eye = newPart(model, "Eye", BALL, V(0.95, 0.95, 0.95), home * CFrame.new(0, 0, -0.75), C(70, 200, 255), M.Neon)
	newPart(model, "Ring", CYLINDER, V(0.25, 3.7, 3.7), home * CFrame.new(0, 0.35, 0) * CFrame.Angles(0, 0, math.rad(90)), C(28, 28, 32), M.Metal)
	for _, offset in { V(1.3, 0.75, 1.3), V(-1.3, 0.75, 1.3), V(1.3, 0.75, -1.3), V(-1.3, 0.75, -1.3) } do
		newPart(model, "Rotor", CYLINDER, V(0.12, 1.4, 1.4), home * CFrame.new(offset) * CFrame.Angles(0, 0, math.rad(90)), C(205, 205, 215), M.SmoothPlastic)
	end
	newPart(model, "Antenna", BLOCK, V(0.12, 0.9, 0.12), home * CFrame.new(0, 1.35, 0.35), C(28, 28, 32), M.Metal)

	local light = Instance.new("PointLight")
	light.Color = Guards.AlertEyeColor
	light.Range = 14
	light.Brightness = 3
	light.Enabled = false
	light.Parent = eye

	weldAll(model, body, {})
	model.PrimaryPart = body
	return {
		Model = model,
		Root = body,
		Eyes = { eye },
		Limbs = {}, -- it hovers; there is nothing to step with
		Light = light,
		Status = statusBubble(body, 2.4),
		RootHeight = 0,
		Size = V(2.2, 2.2, 2.2),
		Kind = "Drone",
	}
end

-- What a guard looks like (nil for drones, which are built separately).
function Guards.getLook(guardId: string): Look?
	return looks[guardId]
end

-- Builds a guard model (unanchored, welded, non-colliding) at `home`.
-- For animals `home` is the ground point they stand on; for drones it's where they hover.
function Guards.build(guardId: string, home: CFrame): GuardModel
	local info = Config.Guards[guardId]
	local look = looks[guardId]
	if not info or info.Kind == "Drone" or not look then
		return buildDrone(home)
	end

	local model = Instance.new("Model")
	model.Name = "Guard"

	-- Bounds of the visible parts (ignoring rotation; close enough for the physics root).
	local minCorner = V(math.huge, math.huge, math.huge)
	local maxCorner = -minCorner
	for _, spec in look.Parts do
		local half = spec.Size / 2
		minCorner = minCorner:Min(spec.Position - half)
		maxCorner = maxCorner:Max(spec.Position + half)
	end
	local size = maxCorner - minCorner
	local center = (maxCorner + minCorner) / 2

	-- The body it is allowed to be stopped by: a box over the visible parts, on the floor.
	local root = newPart(model, "Root", BLOCK, colliderSize(size, info.Kind), home * CFrame.new(center), C(255, 255, 255), M.SmoothPlastic)
	root.Transparency = 1
	root.CanCollide = true
	root.Massless = false

	local visual: { BasePart } = {}
	for index, spec in look.Parts do
		visual[index] = newPart(model, "Piece" .. index, spec.Shape, spec.Size, home * CFrame.new(spec.Position) * rotation(spec.Rotation), spec.Color, spec.Material or M.SmoothPlastic)
	end
	local eyes: { BasePart } = {}
	for _, position in look.Eyes do
		local eye = newPart(model, "Eye", BALL, V(look.EyeSize, look.EyeSize, look.EyeSize), home * CFrame.new(position), look.EyeColor, if look.EyeGlows then M.Neon else M.SmoothPlastic)
		table.insert(eyes, eye)
	end

	local limbs = findLimbs(home, root, look, visual, size, info.Kind)
	local pinned: { [BasePart]: boolean } = {}
	for _, limb in limbs do
		local part = limb.Joint.Part1
		if part then
			pinned[part] = true
		end
	end
	weldAll(model, root, pinned)
	model.PrimaryPart = root
	return {
		Model = model,
		Root = root,
		Eyes = eyes,
		Limbs = limbs,
		Light = nil,
		Status = statusBubble(root, size.Y / 2 + 1.4),
		RootHeight = center.Y,
		Size = size,
		Kind = info.Kind,
	}
end

-- Calm / alert eye colours.
function Guards.setAlert(guard: GuardModel, guardId: string, alert: boolean)
	local look = looks[guardId]
	for _, eye in guard.Eyes do
		if alert then
			eye.Color = Guards.AlertEyeColor
			eye.Material = M.Neon
		elseif look then
			eye.Color = look.EyeColor
			eye.Material = if look.EyeGlows then M.Neon else M.SmoothPlastic
		else
			eye.Color = C(70, 200, 255)
			eye.Material = M.Neon
		end
	end
	local light = guard.Light
	if light then
		light.Enabled = alert
	end
end

return Guards
