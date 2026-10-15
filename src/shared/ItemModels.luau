--!strict
--[[
	ItemModels
	----------
	Turns an item definition from the Items module into a real Model made of
	anchored, non-colliding parts. The model's pivot is the bottom-centre of
	the item, so `model:PivotTo(surfaceCFrame)` sets it neatly on a surface.
]]

local Config = require(script.Parent.Config)
local Items = require(script.Parent.Items)

local ItemModels = {}

local SHAPES: { [string]: Enum.PartType } = {
	Block = Enum.PartType.Block,
	Ball = Enum.PartType.Ball,
	Cylinder = Enum.PartType.Cylinder,
	Wedge = Enum.PartType.Wedge,
}

-- Rotates a vector exactly like CFrame.Angles(rx, ry, rz) would (degrees in, R = Rx * Ry * Rz).
local function rotate(v: Vector3, degrees: Vector3): Vector3
	local rx, ry, rz = math.rad(degrees.X), math.rad(degrees.Y), math.rad(degrees.Z)
	local x, y, z = v.X, v.Y, v.Z
	x, y = x * math.cos(rz) - y * math.sin(rz), x * math.sin(rz) + y * math.cos(rz)
	x, z = x * math.cos(ry) + z * math.sin(ry), -x * math.sin(ry) + z * math.cos(ry)
	y, z = y * math.cos(rx) - z * math.sin(rx), y * math.sin(rx) + z * math.cos(rx)
	return Vector3.new(x, y, z)
end

-- Bounding box (size, centre) of an item model, taking part rotations into account.
function ItemModels.getBounds(itemId: string): (Vector3, Vector3)
	local def = Items.get(itemId)
	if not def then
		return Vector3.one, Vector3.new(0, 0.5, 0)
	end
	local minCorner = Vector3.new(math.huge, math.huge, math.huge)
	local maxCorner = -minCorner
	for _, spec in def.Parts do
		local half = spec.Size / 2
		local rotation = spec.Rotation
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local corner = Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)
					local point = spec.Position + (if rotation then rotate(corner, rotation) else corner)
					minCorner = minCorner:Min(point)
					maxCorner = maxCorner:Max(point)
				end
			end
		end
	end
	return maxCorner - minCorner, (maxCorner + minCorner) / 2
end

function ItemModels.build(itemId: string): Model?
	local def = Items.get(itemId)
	if not def then
		warn("[ItemModels] Unknown item id: " .. tostring(itemId))
		return nil
	end

	local model = Instance.new("Model")
	model.Name = def.Id
	model:SetAttribute("ItemId", def.Id)
	if Items.hasAura(itemId) then
		model:SetAttribute("Glowing", true)
	end

	-- An invisible root part the size of the item. Prompts and labels attach to it.
	local size, center = ItemModels.getBounds(itemId)
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(math.max(size.X, 1), math.max(size.Y, 1), math.max(size.Z, 1))
	root.CFrame = CFrame.new(center)
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanTouch = false
	root.CanQuery = false
	root.CastShadow = false
	root.Parent = model
	model.PrimaryPart = root

	for index, spec in def.Parts do
		local part = Instance.new("Part")
		part.Name = "Piece" .. index
		part.Shape = SHAPES[spec.Shape] or Enum.PartType.Block
		part.Size = spec.Size
		local cf = CFrame.new(spec.Position)
		local rotation = spec.Rotation
		if rotation then
			cf *= CFrame.Angles(math.rad(rotation.X), math.rad(rotation.Y), math.rad(rotation.Z))
		end
		part.CFrame = cf
		part.Color = spec.Color
		part.Material = spec.Material or Enum.Material.SmoothPlastic
		part.Transparency = spec.Transparency or 0
		part.Reflectance = spec.Reflectance or 0
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		local light = spec.Light
		if light then
			local pointLight = Instance.new("PointLight")
			pointLight.Color = light.Color
			pointLight.Range = light.Range
			pointLight.Brightness = light.Brightness
			pointLight.Parent = part
		end
		part.Parent = model
	end

	-- Put the pivot at the bottom-centre (the model was built around the origin).
	model.WorldPivot = CFrame.new()

	-- Rare loot glows: an Epic or Legendary item gets a shell plus an outline in its rarity's colour.
	local rarity = Items.getRarity(itemId)
	if rarity and rarity.Order >= Config.Aura.MinOrder then
		local aura = Config.Aura
		local widest = math.max(size.X, size.Y, size.Z)
		local shell = Instance.new("Part")
		shell.Name = "Aura"
		shell.Shape = Enum.PartType.Ball
		shell.Size = Vector3.one * math.max(widest * aura.Size, 1.6)
		shell.CFrame = CFrame.new(center)
		shell.Color = rarity.Color
		shell.Material = Enum.Material.Neon
		shell.Transparency = aura.Transparency
		shell.Anchored = true
		shell.CanCollide = false
		shell.CanQuery = false
		shell.CanTouch = false
		shell.CastShadow = false
		shell:SetAttribute("AuraSize", shell.Size.X) -- the client pulses around this size
		shell.Parent = model
		-- The client animates the shell's glow (see client/WorldEffects.luau).
		local glow = Instance.new("Highlight")
		glow.Name = "AuraGlow"
		glow.FillColor = rarity.Color
		glow.FillTransparency = aura.FillTransparency
		glow.OutlineColor = rarity.Color
		glow.OutlineTransparency = aura.OutlineTransparency
		glow.DepthMode = Enum.HighlightDepthMode.Occluded
		glow.Parent = model
	end
	return model
end

return ItemModels
