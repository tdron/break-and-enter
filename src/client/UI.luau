--!strict
--[[
	UI
	--
	Tiny helpers for building the interface in code, plus the shared theme.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local ItemModels = require(ReplicatedStorage.Shared.ItemModels)

local UI = {}

UI.Theme = {
	Panel = Color3.fromRGB(28, 30, 46),
	PanelLight = Color3.fromRGB(44, 48, 72),
	Stroke = Color3.fromRGB(70, 76, 110),
	Text = Color3.fromRGB(245, 245, 250),
	SubText = Color3.fromRGB(170, 176, 200),
	Gold = Color3.fromRGB(255, 200, 60),
	Green = Color3.fromRGB(80, 220, 120),
	Red = Color3.fromRGB(255, 75, 75),
	Blue = Color3.fromRGB(70, 160, 255),
	Orange = Color3.fromRGB(255, 145, 40),
	Purple = Color3.fromRGB(185, 115, 255),
	Cyan = Color3.fromRGB(80, 230, 255),
	TitleFont = Enum.Font.FredokaOne,
	BodyFont = Enum.Font.BuilderSansMedium,
	BoldFont = Enum.Font.BuilderSansBold,
}

-- Every UIScale created through UI.scaled(), so the HUD can resize for small screens.
UI.Scales = {} :: { UIScale }
UI.CurrentScale = 1

-- Creates an instance, applies properties, and parents children.
function UI.new(className: string, props: { [string]: any }?, children: { any }?): any
	local instance = Instance.new(className)
	local parent: Instance? = nil
	if props then
		for key, value in props do
			if key == "Parent" then
				parent = value
			else
				(instance :: any)[key] = value
			end
		end
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function UI.corner(radius: number?): Instance
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius or 10)
	return corner
end

function UI.stroke(color: Color3?, thickness: number?, transparency: number?): Instance
	local stroke = Instance.new("UIStroke")
	stroke.Color = color or UI.Theme.Stroke
	stroke.Thickness = thickness or 2
	stroke.Transparency = transparency or 0
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	return stroke
end

function UI.padding(pixels: number): Instance
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, pixels)
	padding.PaddingBottom = UDim.new(0, pixels)
	padding.PaddingLeft = UDim.new(0, pixels)
	padding.PaddingRight = UDim.new(0, pixels)
	return padding
end

function UI.gradient(top: Color3, bottom: Color3): Instance
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(top, bottom)
	gradient.Rotation = 90
	return gradient
end

-- A UIScale that follows the global HUD scale.
function UI.scaled(): UIScale
	local scale = Instance.new("UIScale")
	scale.Scale = UI.CurrentScale
	table.insert(UI.Scales, scale)
	return scale
end

-- A little 3D picture of an item, framed to fit, for the Loot Index and the storage / sell windows.
-- Rarity auras are stripped, so the picture shows the item itself (the card's outline carries the colour).
function UI.itemPicture(parent: Instance, itemId: string, size: UDim2, position: UDim2?): ViewportFrame
	local picture: ViewportFrame = UI.new("ViewportFrame", {
		Name = "Picture",
		BackgroundColor3 = Color3.fromRGB(56, 62, 92),
		Position = position or UDim2.fromOffset(6, 6),
		Size = size,
		Ambient = Color3.fromRGB(165, 165, 175),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.6, -1, -0.8),
		Parent = parent,
	}, { UI.corner(10) })
	local camera = Instance.new("Camera")
	camera.FieldOfView = 34
	camera.Parent = picture
	picture.CurrentCamera = camera

	local model = ItemModels.build(itemId)
	if model then
		for _, child in model:GetChildren() do
			if child.Name == "Aura" or child.Name == "AuraGlow" then
				child:Destroy()
			end
		end
		model:PivotTo(CFrame.new())
		model.Parent = picture
	end

	-- Frame the whole item, seen from the front, a little from the right and above.
	local itemSize, center = ItemModels.getBounds(itemId)
	local radius = math.max(itemSize.Magnitude / 2, 0.5)
	local distance = radius / math.sin(math.rad(camera.FieldOfView / 2)) * 1.02
	local direction = Vector3.new(0.5, 0.42, -1).Unit
	camera.CFrame = CFrame.lookAt(center + direction * distance, center)
	return picture
end

function UI.setScale(value: number)
	UI.CurrentScale = value
	for _, scale in UI.Scales do
		scale.Scale = value
	end
end

function UI.tween(instance: Instance, seconds: number, goal: { [string]: any }, style: Enum.EasingStyle?, direction: Enum.EasingDirection?): Tween
	local tween = TweenService:Create(
		instance,
		TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out),
		goal
	)
	tween:Play()
	return tween
end

-- Makes a button grow a little when hovered and shrink when pressed.
function UI.bounce(button: GuiButton)
	local scale = Instance.new("UIScale")
	scale.Parent = button
	button.MouseEnter:Connect(function()
		UI.tween(scale, 0.12, { Scale = 1.06 })
	end)
	button.MouseLeave:Connect(function()
		UI.tween(scale, 0.12, { Scale = 1 })
	end)
	button.MouseButton1Down:Connect(function()
		UI.tween(scale, 0.08, { Scale = 0.94 })
	end)
	button.MouseButton1Up:Connect(function()
		UI.tween(scale, 0.12, { Scale = 1.06 })
	end)
end

local soundCache: { [string]: Sound } = {}

function UI.playSound(soundId: string, volume: number?, pitch: number?)
	local key = string.format("%s|%.2f", soundId, pitch or 1)
	local sound = soundCache[key]
	if not sound then
		local newSound = Instance.new("Sound")
		newSound.SoundId = soundId
		newSound.PlaybackSpeed = pitch or 1
		newSound.Parent = SoundService
		soundCache[key] = newSound
		sound = newSound
	end
	sound.Volume = volume or 0.5
	sound:Play()
end

UI.Sounds = Config.Sounds

return UI
