--!strict
--[[
	Rebirth
	-------
	The rebirth window. Opens from the shrine beside the market hall; the
	purchase itself is validated on the server (server/Rebirth module).

	The card shows your current multiplier, the two things it boosts
	(treadmill training + warehouse income), the price of the next rebirth
	with a speed progress bar, and the "your speed starts from 0" warning.
	Everything is read straight from player attributes (Rebirths,
	SpeedPoints), with the costs mirrored from Config, so it refreshes
	the moment any training lands.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Notifications = require(script.Parent.Notifications)
local UI = require(script.Parent.UI)

local RebirthRemote = ReplicatedStorage.Remotes.Rebirth

local Rebirth = {}

local player = Players.LocalPlayer
local Theme = UI.Theme

local window: Frame? = nil
local windowScale: UIScale? = nil
local isOpen = false
local busy = false

local rebirthsChip: TextLabel? = nil
local powerChip: TextLabel? = nil
local treadmillLine: TextLabel? = nil
local coinsLine: TextLabel? = nil
local nextLine: TextLabel? = nil
local progressText: TextLabel? = nil
local progressFill: Frame? = nil
local buyButton: TextButton? = nil
local validNumber = function(name: string): number
	local value = player:GetAttribute(name)
	return if type(value) == "number" then value else 0
end

local function refresh()
	local rebirths = validNumber("Rebirths")
	local points = validNumber("SpeedPoints")
	local cost = Config.rebirthCost(rebirths)
	local multiplier = Config.rebirthMultiplier(rebirths)
	local nextMultiplier = Config.rebirthMultiplier(rebirths + 1)

	if rebirthsChip then
		rebirthsChip.Text = string.format("⚜ %d", rebirths)
	end
	if powerChip then
		powerChip.Text = string.format("x%s", Format.decimal(multiplier, 2))
	end
	if treadmillLine then
		treadmillLine.Text = string.format("🏃 Treadmill training  x%s", Format.decimal(multiplier, 2))
	end
	if coinsLine then
		coinsLine.Text = string.format("💰 Coins per second  x%s", Format.decimal(multiplier, 2))
	end
	if nextLine then
		nextLine.Text = string.format(
			"Rebirth #%d  x%s  ➜  x%s",
			rebirths + 1,
			Format.decimal(multiplier, 2),
			Format.decimal(nextMultiplier, 2)
		)
	end
	if progressText then
		progressText.Text = string.format("%s / %s speed", Format.short(points), Format.short(cost))
	end
	if progressFill then
		local ratio = math.clamp(points / math.max(cost, 1), 0, 1)
		progressFill.Size = UDim2.fromScale(ratio, 1)
		progressFill.Visible = ratio > 0.002
	end
	if buyButton then
		local affordable = points >= cost
		buyButton.Text = string.format("🔁 REBIRTH — %s SPEED", Format.short(cost))
		buyButton.BackgroundColor3 = if affordable then Theme.Green else Theme.SubText
		buyButton.AutoButtonColor = affordable
	end
end

local function buy()
	if busy then
		return
	end
	busy = true
	local ok, result = pcall(function()
		return RebirthRemote:InvokeServer("Buy")
	end)
	busy = false
	if ok and type(result) == "table" then
		local success = result.Ok == true
		Notifications.show(tostring(result.Message), if success then "success" else "error")
		if success then
			UI.playSound(UI.Sounds.LevelUp, 0.8, 1.25)
		end
	else
		Notifications.show("The shrine is busy, try again!", "error")
	end
	refresh()
end

local function statLine(parent: Instance, order: number): TextLabel
	return UI.new("TextLabel", {
		Name = "Line" .. order,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0.28, 0),
		Position = UDim2.fromScale(0, (order - 1) * 0.36),
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.Text,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = parent,
	})
end

function Rebirth.init(screen: ScreenGui)
	local scale = UI.scaled()
	local frame: Frame = UI.new("Frame", {
		Name = "Rebirth",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(560, 470),
		BackgroundColor3 = Theme.Panel,
		Visible = false,
		ZIndex = 2,
		Parent = screen,
	}, {
		UI.shadow(20, 10),
		UI.corner(20),
		UI.stroke(Theme.Purple, 2.5, 0.2),
		UI.bodyGradient(),
		scale,
	})
	window = frame
	windowScale = scale

	UI.titleBar(frame, "🔁", "REBIRTH SHRINE", Theme.Purple, Theme.PurpleDark, 58)
	local close = UI.closeButton(frame, UDim2.new(1, -10, 0, 8))
	close.Activated:Connect(function()
		Rebirth.close()
	end)

	-- The two chips at the top: rebirth count and the standing multiplier.
	local chips: Frame = UI.new("Frame", {
		Name = "Chips",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 70),
		Size = UDim2.new(1, -32, 0, 62),
		ZIndex = 3,
		Parent = frame,
	})
	local countChip: Frame = UI.new("Frame", {
		Name = "CountChip",
		BackgroundColor3 = Color3.fromRGB(238, 230, 250),
		Size = UDim2.fromScale(0.36, 1),
		ZIndex = 3,
		Parent = chips,
	}, { UI.corner(14), UI.stroke(Theme.Purple, 1.5, 0.3) })
	rebirthsChip = UI.new("TextLabel", {
		Name = "Rebirths",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Theme.TitleFont,
		Text = "⚜ 0",
		TextColor3 = Theme.PurpleDark,
		TextSize = 28,
		ZIndex = 4,
		Parent = countChip,
	})
	local multChip: Frame = UI.new("Frame", {
		Name = "MultChip",
		BackgroundColor3 = Theme.Purple,
		Size = UDim2.fromScale(0.6, 1),
		Position = UDim2.fromScale(0.4, 0),
		ZIndex = 3,
		Parent = chips,
	}, { UI.corner(14), UI.gradient(Theme.Purple, Theme.PurpleDark), UI.stroke(Color3.new(1, 1, 1), 2, 0.45) })
	powerChip = UI.new("TextLabel", {
		Name = "Power",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Theme.TitleFont,
		Text = "x1",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 34,
		ZIndex = 4,
		Parent = multChip,
	})

	-- What the multiplier buys you (plus the warning).
	local effects: Frame = UI.new("Frame", {
		Name = "Effects",
		BackgroundColor3 = Theme.PanelLight,
		Position = UDim2.fromOffset(16, 144),
		Size = UDim2.new(1, -32, 0, 116),
		ZIndex = 3,
		Parent = frame,
	}, { UI.corner(14), UI.cardGradient(), UI.stroke(Theme.Stroke, 1.5, 0.1) })
	local effectPad: Frame = UI.new("Frame", {
		Name = "Pad",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 8),
		Size = UDim2.new(1, -32, 1, -16),
		ZIndex = 3,
		Parent = effects,
	})
	treadmillLine = statLine(effectPad, 1)
	coinsLine = statLine(effectPad, 2)
	UI.new("TextLabel", {
		Name = "Warning",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0.28, 0),
		Position = UDim2.fromScale(0, 0.72),
		Font = Theme.BoldFont,
		Text = "⚠ Rebirthing sets your Speed back to 0!",
		TextColor3 = Theme.OrangeDark,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = effectPad,
	})

	-- The price of the next one, with a speed progress bar.
	local nextCard: Frame = UI.new("Frame", {
		Name = "Next",
		BackgroundColor3 = Theme.PanelLight,
		Position = UDim2.fromOffset(16, 272),
		Size = UDim2.new(1, -32, 0, 104),
		ZIndex = 3,
		Parent = frame,
	}, { UI.corner(14), UI.cardGradient(), UI.stroke(Theme.Stroke, 1.5, 0.1) })
	nextLine = UI.new("TextLabel", {
		Name = "NextRebirth",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 10),
		Size = UDim2.new(1, -32, 0, 24),
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Theme.Text,
		TextSize = 22,
		ZIndex = 4,
		Parent = nextCard,
	})
	local barBack: Frame = UI.new("Frame", {
		Name = "Progress",
		BackgroundColor3 = Color3.fromRGB(236, 231, 220),
		Position = UDim2.fromOffset(16, 44),
		Size = UDim2.new(1, -32, 0, 22),
		ZIndex = 4,
		Parent = nextCard,
	}, {
		UI.corner(11),
		UI.stroke(Color3.fromRGB(205, 198, 184), 1, 0),
	})
	progressFill = UI.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Theme.Purple,
		Size = UDim2.fromScale(0, 1),
		ZIndex = 5,
		Parent = barBack,
	}, { UI.corner(11), UI.gradient(Theme.Purple, Theme.PurpleDark) })
	progressText = UI.new("TextLabel", {
		Name = "ProgressText",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.Text,
		TextStrokeTransparency = 0.8,
		TextSize = 15,
		ZIndex = 6,
		Parent = barBack,
	})
	UI.new("TextLabel", {
		Name = "CostNote",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 72),
		Size = UDim2.new(1, -32, 0, 22),
		Font = Theme.BodyFont,
		Text = "The first rebirth costs 1M speed; every one after costs 4x more.",
		TextColor3 = Theme.SubText,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = nextCard,
	})

	buyButton = UI.new("TextButton", {
		Name = "Buy",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -14),
		Size = UDim2.new(1, -32, 0, 58),
		BackgroundColor3 = Theme.Green,
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 24,
		ZIndex = 4,
		Parent = frame,
	}, {
		UI.corner(14),
		UI.stroke(Color3.new(1, 1, 1), 2, 0.35),
		UI.gloss(),
	})
	UI.bounce(buyButton)
	buyButton.Activated:Connect(function()
		task.spawn(buy)
	end)

	player:GetAttributeChangedSignal("Rebirths"):Connect(refresh)
	player:GetAttributeChangedSignal("SpeedPoints"):Connect(refresh)
	refresh()
end

function Rebirth.open()
	local frame, scale = window, windowScale
	if not frame or not scale or isOpen then
		return
	end
	isOpen = true
	refresh()
	frame.Visible = true
	local target = UI.CurrentScale
	scale.Scale = target * 0.8
	UI.tween(scale, 0.18, { Scale = target }, Enum.EasingStyle.Back)
end

function Rebirth.close()
	local frame = window
	if not frame or not isOpen then
		return
	end
	isOpen = false
	frame.Visible = false
end

function Rebirth.toggle()
	if isOpen then
		Rebirth.close()
	else
		Rebirth.open()
	end
end

function Rebirth.isOpen(): boolean
	return isOpen
end

return Rebirth
