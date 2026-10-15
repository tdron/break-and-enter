--!strict
--[[
	Guards
	------
	3D models for every house guard, built from plain parts (no meshes):
	  * a cat in each of the four cottages,
	  * a different dog breed in every other house,
	  * the Grand Mansion's flying security drones.

	Which guard lives where is set by Config.Houses / Config.Guards; this module
	only knows what they look like. Model conventions (like Items):
	  * animals: origin = the ground under the middle of the body, front = -Z
	  * drones: origin = the middle of the drone (they hover)
	Eyes are kept separate so the server can make them glow red during an alarm.
]]

local Config = require(script.Parent.Config)

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
	Root: BasePart, -- invisible physics body (AlignPosition/AlignOrientation go here)
	Eyes: { BasePart },
	Light: PointLight?, -- drones carry a red searchlight
	Status: TextLabel, -- "💤" / "❗" bubble above the guard
	RootHeight: number, -- how far the root's centre sits above the guard's origin
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
-- The roster (keys match Config.Guards)
--------------------------------------------------------------------------------
local WHITE = C(246, 246, 244)
local BLACK = C(32, 30, 30)

local looks: { [string]: Look } = {
	GingerCat = cat({
		Fur = C(232, 140, 58),
		Chest = C(244, 196, 140),
		Muzzle = C(250, 226, 190),
		Paws = C(244, 196, 140),
		Ears = C(232, 140, 58),
		Tail = C(232, 140, 58),
		Stripes = C(186, 96, 34),
		Eyes = C(130, 235, 80),
	}),
	TuxedoCat = cat({
		Fur = C(30, 30, 34),
		Chest = WHITE,
		Muzzle = WHITE,
		Paws = WHITE,
		Ears = C(30, 30, 34),
		Tail = C(30, 30, 34),
		Eyes = C(245, 220, 60),
	}),
	SiameseCat = cat({
		Fur = C(240, 226, 202),
		Chest = C(246, 236, 218),
		Muzzle = C(88, 60, 44),
		Paws = C(88, 60, 44),
		Ears = C(88, 60, 44),
		Tail = C(88, 60, 44),
		Eyes = C(80, 170, 255),
	}),
	GreyTabby = cat({
		Fur = C(150, 150, 158),
		Chest = C(206, 206, 212),
		Muzzle = C(226, 226, 230),
		Paws = C(206, 206, 212),
		Ears = C(150, 150, 158),
		Tail = C(150, 150, 158),
		Stripes = C(96, 96, 104),
		Eyes = C(245, 180, 40),
	}),
	Chihuahua = dog({
		Scale = 0.62,
		LegLength = 0.9,
		BodyLength = 1.7,
		BodyHeight = 0.8,
		BodyWidth = 0.75,
		Head = V(0.95, 0.88, 0.8),
		Snout = 0.26,
		Ears = "Big",
		Tail = "Up",
		Fur = C(226, 186, 130),
		Chest = C(246, 226, 192),
		Paws = C(246, 226, 192),
		SnoutColor = C(236, 206, 160),
		EarColor = C(226, 186, 130),
		Collar = C(255, 90, 170),
	}),
	Pug = dog({
		Scale = 0.75,
		LegLength = 0.72,
		BodyLength = 1.6,
		BodyHeight = 1.0,
		BodyWidth = 1.0,
		Head = V(0.98, 0.92, 0.76),
		Snout = 0.14,
		Ears = "Floppy",
		Tail = "Curly",
		Fur = C(222, 192, 142),
		Chest = C(230, 204, 158),
		Paws = C(222, 192, 142),
		SnoutColor = C(44, 38, 36),
		EarColor = C(44, 38, 36),
		Collar = C(60, 130, 230),
	}),
	Corgi = dog({
		Scale = 0.85,
		LegLength = 0.42,
		BodyLength = 2.1,
		BodyHeight = 0.85,
		BodyWidth = 0.86,
		Head = V(0.82, 0.76, 0.76),
		Snout = 0.42,
		Ears = "Big",
		Tail = "Stub",
		Fur = C(226, 146, 62),
		Chest = WHITE,
		Paws = WHITE,
		SnoutColor = WHITE,
		EarColor = C(226, 146, 62),
		Collar = C(220, 40, 60),
	}),
	Dalmatian = dog({
		Scale = 1.1,
		LegLength = 1.0,
		BodyLength = 2.0,
		BodyHeight = 0.8,
		BodyWidth = 0.75,
		Head = V(0.7, 0.72, 0.8),
		Snout = 0.5,
		Ears = "Floppy",
		Tail = "Long",
		Fur = WHITE,
		Chest = WHITE,
		Paws = WHITE,
		SnoutColor = WHITE,
		EarColor = BLACK,
		Collar = C(220, 40, 40),
		Spots = BLACK,
	}),
	GermanShepherd = dog({
		Scale = 1.25,
		LegLength = 0.95,
		BodyLength = 2.1,
		BodyHeight = 0.85,
		BodyWidth = 0.8,
		Head = V(0.72, 0.72, 0.8),
		Snout = 0.55,
		Ears = "Pointy",
		Tail = "Long",
		Fur = C(200, 140, 72),
		Chest = C(214, 160, 92),
		Paws = C(214, 160, 92),
		SnoutColor = C(44, 36, 30),
		EarColor = C(44, 36, 30),
		Collar = C(40, 120, 60),
		Saddle = C(44, 36, 30),
	}),
	Doberman = dog({
		Scale = 1.25,
		LegLength = 1.1,
		BodyLength = 2.0,
		BodyHeight = 0.8,
		BodyWidth = 0.7,
		Head = V(0.62, 0.68, 0.86),
		Snout = 0.62,
		Ears = "Pointy",
		Tail = "Docked",
		Fur = C(36, 30, 30),
		Chest = C(170, 92, 42),
		Paws = C(170, 92, 42),
		SnoutColor = C(170, 92, 42),
		EarColor = C(36, 30, 30),
		Collar = C(200, 200, 210),
		Brows = C(170, 92, 42),
	}),
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

local function weldAll(model: Model, root: BasePart)
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and part ~= root then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = part
			weld.Parent = part
		end
	end
end

local function buildDrone(home: CFrame): GuardModel
	local model = Instance.new("Model")
	model.Name = "Guard"
	local body = newPart(model, "Body", BALL, V(2.2, 2.2, 2.2), home, C(46, 48, 56), M.Metal)
	body.Massless = false
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

	weldAll(model, body)
	model.PrimaryPart = body
	return {
		Model = model,
		Root = body,
		Eyes = { eye },
		Light = light,
		Status = statusBubble(body, 2.4),
		RootHeight = 0,
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

	local root = newPart(model, "Root", BLOCK, V(math.max(size.X, 0.5), math.max(size.Y, 0.5), math.max(size.Z, 0.5)), home * CFrame.new(center), C(255, 255, 255), M.SmoothPlastic)
	root.Transparency = 1
	root.Massless = false

	for index, spec in look.Parts do
		newPart(model, "Piece" .. index, spec.Shape, spec.Size, home * CFrame.new(spec.Position) * rotation(spec.Rotation), spec.Color, spec.Material or M.SmoothPlastic)
	end
	local eyes: { BasePart } = {}
	for _, position in look.Eyes do
		local eye = newPart(model, "Eye", BALL, V(look.EyeSize, look.EyeSize, look.EyeSize), home * CFrame.new(position), look.EyeColor, if look.EyeGlows then M.Neon else M.SmoothPlastic)
		table.insert(eyes, eye)
	end

	weldAll(model, root)
	model.PrimaryPart = root
	return {
		Model = model,
		Root = root,
		Eyes = eyes,
		Light = nil,
		Status = statusBubble(root, size.Y / 2 + 1.4),
		RootHeight = center.Y,
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
