--!strict
--[[
	UI
	--
	Tiny helpers for building the interface in code, plus the shared theme.

	The look borrows the UI language of the current top games (Steal a
	Brainrot, Pet Simulator 99, Adopt Me!, Blox Fruits): dark navy glass
	panels with vertical gradients, candy-bright accent colours, icon chips
	on every stat and button, soft drop shadows and pop-bounce animations.
	Everything is built from plain GuiObjects (no uploaded images), so the
	whole HUD survives being rebuilt by tools/build_place.py.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage.Shared.Config)
local ItemModels = require(ReplicatedStorage.Shared.ItemModels)

local UI = {}

UI.Theme = {
	-- Light, clean "Steal an Egg" look: cream/white panels, dark plum text,
	-- candy accent buttons with white labels and soft lavender borders.
	Panel = Color3.fromRGB(250, 247, 240), -- cream window body
	PanelTop = Color3.fromRGB(255, 255, 255),
	PanelLight = Color3.fromRGB(255, 255, 255), -- cards
	CardTop = Color3.fromRGB(246, 242, 233),
	Stroke = Color3.fromRGB(210, 204, 226),
	Text = Color3.fromRGB(46, 42, 62), -- "ink": dark plum, reads on cream
	SubText = Color3.fromRGB(120, 113, 140),
	-- Candy accents (light → dark pairs); white text on these pops.
	Gold = Color3.fromRGB(255, 205, 70),
	GoldDark = Color3.fromRGB(235, 152, 24),
	Green = Color3.fromRGB(84, 228, 140),
	GreenDark = Color3.fromRGB(30, 168, 92),
	Red = Color3.fromRGB(255, 74, 74),
	RedDark = Color3.fromRGB(196, 30, 44),
	Blue = Color3.fromRGB(86, 170, 255),
	BlueDark = Color3.fromRGB(38, 110, 220),
	Orange = Color3.fromRGB(255, 158, 56),
	OrangeDark = Color3.fromRGB(230, 108, 16),
	Purple = Color3.fromRGB(182, 118, 255),
	PurpleDark = Color3.fromRGB(126, 66, 235),
	Cyan = Color3.fromRGB(88, 226, 255),
	CyanDark = Color3.fromRGB(28, 148, 200),
	Pink = Color3.fromRGB(255, 120, 200),
	-- The clock's two moods: both light now (periwinkle cream / sunny cream).
	Night = Color3.fromRGB(226, 232, 255),
	NightDark = Color3.fromRGB(196, 206, 245),
	Day = Color3.fromRGB(255, 235, 165),
	DayDark = Color3.fromRGB(255, 208, 96),
	-- Fonts: FredokaOne (the Adopt Me! / brainrot look) for headlines.
	TitleFont = Enum.Font.FredokaOne,
	BodyFont = Enum.Font.BuilderSansMedium,
	BoldFont = Enum.Font.BuilderSansBold,
	-- Fake drop-shadow colour.
	Shadow = Color3.fromRGB(84, 76, 110),
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

-- gloss (white → near-white) adds a barely-there sheen on buttons while
-- keeping the accent colour vivid and white text bright.
function UI.gloss(): Instance
	return UI.gradient(Color3.new(1, 1, 1), Color3.fromRGB(250, 250, 250))
end

-- The standard window/card body: a vertical gradient from a lighter top to a
-- darker bottom. Top games tint their windows like this instead of flat fills.
function UI.bodyGradient(): Instance
	return UI.gradient(UI.Theme.PanelTop, UI.Theme.Panel)
end

function UI.cardGradient(): Instance
	return UI.gradient(UI.Theme.CardTop, UI.Theme.PanelLight)
end

-- A soft feathered drop shadow. Roblox has no real shadows for 2D UI, so top
-- games fake one with a dark copy of the frame a few pixels lower on a lower
-- ZIndex. Kept very subtle (the light theme wants clean, flat surfaces).
-- Give your frame ZIndex ≥ 2 and parent this inside it.
-- WARNING: a shadow is a GuiObject, so a UIListLayout / UIGridLayout will
-- arrange it like a sibling — never put one inside a layout-managed parent.
function UI.shadow(radius: number?, offset: number?): Frame
	local shadow: Frame = UI.new("Frame", {
		Name = "Shadow",
		BackgroundColor3 = UI.Theme.Shadow,
		BackgroundTransparency = 0.86,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, offset or 5),
		Size = UDim2.fromScale(1, 1),
		ZIndex = 1,
	}, { UI.corner(radius or 16) })
	return shadow
end

-- A circular glossy chip with an emoji on it — the Pet Sim / Adopt Me! motif
-- used on stat rows, window title bars and buttons everywhere.
function UI.iconChip(parent: Instance, icon: string, color: Color3, colorDark: Color3, size: number, position: UDim2?): Frame
	local chip: Frame = UI.new("Frame", {
		Name = "Icon",
		BackgroundColor3 = color,
		Position = position or UDim2.new(),
		Size = UDim2.fromOffset(size, size),
		ZIndex = 3,
		Parent = parent,
	}, {
		UI.corner(math.floor(size / 3)),
		UI.gradient(color, colorDark),
		UI.stroke(Color3.new(1, 1, 1), 1.5, 0.55),
	})
	UI.new("TextLabel", {
		Name = "Emoji",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Font = UI.Theme.TitleFont,
		Text = icon,
		TextSize = math.floor(size * 0.6),
		ZIndex = 4,
		Parent = chip,
	})
	return chip
end

-- A big round red close button (Adopt Me! style) with a bounce. The window
-- wires Activated itself; name stays "Close" because the tests look it up.
function UI.closeButton(parent: Instance, position: UDim2): TextButton
	local close: TextButton = UI.new("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = position,
		Size = UDim2.fromOffset(42, 42),
		BackgroundColor3 = UI.Theme.Red,
		Font = UI.Theme.TitleFont,
		Text = "X",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 24,
		ZIndex = 6,
		Parent = parent,
	}, {
		UI.corner(21),
		UI.gloss(),
		UI.stroke(Color3.new(1, 1, 1), 2, 0.35),
	})
	UI.bounce(close)
	return close
end

-- The coloured band at the top of a window (icon chip + big title). The title
-- TextLabel is returned so windows can keep their original "Title" naming.
function UI.titleBar(window: Frame, icon: string, text: string, color: Color3, colorDark: Color3, height: number): TextLabel
	local bar: Frame = UI.new("Frame", {
		Name = "TitleBar",
		BackgroundColor3 = color,
		Size = UDim2.new(1, 0, 0, height),
		ZIndex = 3,
		Parent = window,
	}, {
		UI.corner(18),
		UI.gradient(color, colorDark),
	})
	-- Square off the bottom of the band so only the top corners are round.
	UI.new("Frame", {
		Name = "SquareOff",
		BackgroundColor3 = colorDark,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0.5, 0),
		ZIndex = 3,
		Parent = bar,
	})
	UI.iconChip(bar, icon, Color3.new(1, 1, 1), Color3.fromRGB(225, 230, 245), height - 18, UDim2.fromOffset(14, 9))
	local title: TextLabel = UI.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(height + 12, 0),
		Size = UDim2.new(0.55, -(height + 12), 1, 0),
		Font = UI.Theme.TitleFont,
		Text = text,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 30,
		TextStrokeTransparency = 0.75,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = bar,
	})
	return title
end

-- Rarity colours readable ON the light theme. The bright Items.Rarities tones
-- are tuned for glowing auras in the dark world; on cream cards they wash out
-- (Common is literally near-white). These deeper inks stand in for text and
-- card outlines while auras and toasts keep the bright originals.
UI.RarityInk = {
	Common = Color3.fromRGB(150, 155, 172),
	Rare = Color3.fromRGB(36, 116, 235),
	Epic = Color3.fromRGB(158, 80, 225),
	Legendary = Color3.fromRGB(212, 142, 24),
}

function UI.rarityInk(rarityName: string): Color3
	return UI.RarityInk[rarityName] or UI.Theme.SubText
end

-- A UIScale that follows the global HUD scale.
function UI.scaled(): UIScale
	local scale = Instance.new("UIScale")
	scale.Scale = UI.CurrentScale
	table.insert(UI.Scales, scale)
	return scale
end

-- A little 3D picture of an item, framed to fit, for the Loot Index and the
-- storage / sell windows. Rarity auras are stripped, so the picture shows the
-- item itself (the card's outline carries the colour).
function UI.itemPicture(parent: Instance, itemId: string, size: UDim2, position: UDim2?): ViewportFrame
	local picture: ViewportFrame = UI.new("ViewportFrame", {
		Name = "Picture",
		BackgroundColor3 = Color3.fromRGB(235, 232, 244),
		Position = position or UDim2.fromOffset(6, 6),
		Size = size,
		Ambient = Color3.fromRGB(165, 165, 175),
		LightColor = Color3.fromRGB(255, 250, 240),
		LightDirection = Vector3.new(-0.6, -1, -0.8),
		Parent = parent,
	}, {
		UI.corner(10),
		UI.gradient(Color3.fromRGB(245, 243, 252), Color3.fromRGB(222, 218, 236)),
		UI.stroke(Color3.fromRGB(210, 204, 226), 1.5, 0.25),
	})
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

-- Makes a button grow a little when hovered and shrink when pressed — the
-- bouncy press every simulator button has.
function UI.bounce(button: GuiButton)
	local scale = Instance.new("UIScale")
	scale.Parent = button
	button.MouseEnter:Connect(function()
		UI.tween(scale, 0.12, { Scale = 1.07 }, Enum.EasingStyle.Back)
	end)
	button.MouseLeave:Connect(function()
		UI.tween(scale, 0.12, { Scale = 1 })
	end)
	button.MouseButton1Down:Connect(function()
		UI.tween(scale, 0.08, { Scale = 0.92 })
	end)
	button.MouseButton1Up:Connect(function()
		UI.tween(scale, 0.12, { Scale = 1.07 }, Enum.EasingStyle.Back)
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
