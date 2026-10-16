--!strict
--[[
	Shop
	----
	The upgrade shop window. Opens from the HUD button or the shop counter in
	the hub. Purchases are validated by the server (Economy module).

	Styled like the top games' shop windows (Pet Sim 99 / Steal a Brainrot):
	a gradient title band with an icon chip, dark glass cards with rarity-style
	outlines, big green gradient BUY buttons and a soft drop shadow.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Notifications = require(script.Parent.Notifications)
local UI = require(script.Parent.UI)

local PurchaseRemote = ReplicatedStorage.Remotes.Purchase

local Shop = {}

local player = Players.LocalPlayer
local Theme = UI.Theme

type Card = {
	Upgrade: Config.Upgrade,
	Level: TextLabel,
	Value: TextLabel,
	Button: TextButton,
}

local window: Frame? = nil
local windowScale: UIScale? = nil
local cards: { Card } = {}
local busy = false
local isOpen = false

local function getNumber(name: string, default: number): number
	local value = player:GetAttribute(name)
	return if type(value) == "number" then value else default
end

local function describeValue(upgrade: Config.Upgrade, level: number): string
	return Config.describeUpgrade(upgrade.Id, level)
end

local function refreshCard(card: Card)
	local upgrade = card.Upgrade
	local level = getNumber("Level_" .. upgrade.Id, 1)
	local maxLevel = #upgrade.Values
	local cash = getNumber("Cash", 0)

	card.Level.Text = string.format("LV %d / %d", level, maxLevel)
	if level >= maxLevel then
		card.Value.Text = describeValue(upgrade, level) .. "  (max)"
	else
		card.Value.Text = string.format(
			"%s  ➜  %s",
			describeValue(upgrade, level),
			describeValue(upgrade, level + 1)
		)
	end

	if level >= maxLevel then
		card.Button.Text = "MAXED"
		card.Button.BackgroundColor3 = Color3.fromRGB(168, 172, 190)
		card.Button.AutoButtonColor = false
	else
		local cost = upgrade.Costs[level + 1]
		card.Button.Text = Format.money(cost)
		card.Button.AutoButtonColor = true
		card.Button.BackgroundColor3 = if cash >= cost then Theme.Green else Color3.fromRGB(172, 58, 62)
	end
end

local function refreshAll()
	for _, card in cards do
		refreshCard(card)
	end
end

local function buy(upgrade: Config.Upgrade)
	if busy then
		return
	end
	busy = true
	local ok, result = pcall(function()
		return PurchaseRemote:InvokeServer(upgrade.Id)
	end)
	busy = false
	if ok and type(result) == "table" then
		local success = result.Ok == true
		Notifications.show(tostring(result.Message), if success then "success" else "error")
		if success then
			UI.playSound(UI.Sounds.Purchase, 0.6, 1.8)
		end
	else
		Notifications.show("The shop is busy, try again!", "error")
	end
	refreshAll()
end

local function makeCard(parent: Instance, order: number, upgrade: Config.Upgrade): Card
	local frame: Frame = UI.new("Frame", {
		Name = upgrade.Id,
		BackgroundColor3 = Theme.PanelLight,
		Size = UDim2.new(1, -8, 0, 96),
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	}, {
		UI.corner(14),
		UI.cardGradient(),
		UI.stroke(Theme.Stroke, 1.5, 0.1),
	})
	-- Gold accent bar down the left edge.
	UI.new("Frame", {
		Name = "Accent",
		BackgroundColor3 = Theme.Gold,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 5, 1, -16),
		Position = UDim2.fromOffset(8, 8),
		ZIndex = 4,
		Parent = frame,
	}, { UI.corner(3), UI.gradient(Theme.Gold, Theme.GoldDark) })
	UI.iconChip(frame, upgrade.Icon, Theme.Gold, Theme.GoldDark, 64, UDim2.fromOffset(22, 16))
	UI.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(100, 10),
		Size = UDim2.new(1, -270, 0, 28),
		Font = Theme.TitleFont,
		Text = upgrade.DisplayName,
		TextColor3 = Theme.Text,
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = frame,
	})
	local levelChip: Frame = UI.new("Frame", {
		Name = "LevelChip",
		BackgroundColor3 = Color3.fromRGB(238, 233, 220),
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -164, 0, 12),
		Size = UDim2.fromOffset(106, 24),
		ZIndex = 4,
		Parent = frame,
	}, { UI.corner(12) })
	local levelLabel: TextLabel = UI.new("TextLabel", {
		Name = "Level",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.GoldDark,
		TextSize = 15,
		ZIndex = 5,
		Parent = levelChip,
	})
	local valueLabel: TextLabel = UI.new("TextLabel", {
		Name = "Value",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(100, 42),
		Size = UDim2.new(1, -270, 0, 24),
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.SubText,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = frame,
	})
	local button: TextButton = UI.new("TextButton", {
		Name = "Buy",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(140, 54),
		BackgroundColor3 = Theme.Green,
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 22,

		ZIndex = 4,
		Parent = frame,
	}, {
		UI.corner(12),
		UI.stroke(Color3.new(1, 1, 1), 2, 0.35),
		UI.gradient(Color3.new(1, 1, 1), Color3.fromRGB(185, 185, 185)),
	})
	UI.bounce(button)
	button.Activated:Connect(function()
		task.spawn(buy, upgrade)
	end)

	-- Description under the title.
	UI.new("TextLabel", {
		Name = "Description",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(100, 66),
		Size = UDim2.new(1, -270, 0, 20),
		Font = Theme.BodyFont,
		Text = upgrade.Description,
		TextColor3 = Theme.SubText,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ZIndex = 4,
		Parent = frame,
	})

	return { Upgrade = upgrade, Level = levelLabel, Value = valueLabel, Button = button }
end

function Shop.init(screen: ScreenGui)
	local scale = UI.scaled()
	local frame: Frame = UI.new("Frame", {
		Name = "Shop",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(680, 560),
		BackgroundColor3 = Theme.Panel,
		Visible = false,
		ZIndex = 2,
		Parent = screen,
	}, {
		UI.shadow(20, 10),
		UI.corner(20),
		UI.stroke(Theme.Gold, 2.5, 0.2),
		UI.bodyGradient(),
		scale,
	})
	window = frame
	windowScale = scale

	UI.titleBar(frame, "🛒", "UPGRADE SHOP", Theme.Gold, Theme.GoldDark, 58)
	local close = UI.closeButton(frame, UDim2.new(1, -10, 0, 8))
	close.Activated:Connect(function()
		Shop.close()
	end)
	-- Your cash, in a white chip inside the title band.
	local cashChip: Frame = UI.new("Frame", {
		Name = "CashChip",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.25,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -62, 0, 13),
		Size = UDim2.fromOffset(220, 32),
		ZIndex = 5,
		Parent = frame,
	}, { UI.corner(16), UI.stroke(Color3.new(1, 1, 1), 1.5, 0.5) })
	local cashLabel: TextLabel = UI.new("TextLabel", {
		Name = "Cash",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Theme.GreenDark,
		TextSize = 22,
		ZIndex = 6,
		Parent = cashChip,
	})

	local list: ScrollingFrame = UI.new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(16, 70),
		Size = UDim2.new(1, -28, 1, -120),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Gold,
		ZIndex = 3,
		Parent = frame,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for index, upgrade in Config.Upgrades do
		table.insert(cards, makeCard(list, index, upgrade))
	end

	local tipBar: Frame = UI.new("Frame", {
		Name = "TipBar",
		BackgroundColor3 = Theme.PanelTop,
		BackgroundTransparency = 0.35,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 16, 1, -12),
		Size = UDim2.new(1, -32, 0, 36),
		ZIndex = 3,
		Parent = frame,
	}, { UI.corner(12), UI.stroke(Color3.new(1, 1, 1), 1, 0.88) })
	UI.new("TextLabel", {
		Name = "Tip",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Theme.BodyFont,
		Text = "💡 Stored items earn cash every second. Run on your warehouse treadmill (even AFK!) to outrun faster defenders.",
		TextColor3 = Theme.SubText,
		TextSize = 14,
		TextWrapped = true,
		ZIndex = 4,
		Parent = tipBar,
	})

	local function updateCash()
		cashLabel.Text = "💰 " .. Format.money(getNumber("Cash", 0))
		if isOpen then
			refreshAll()
		end
	end
	player:GetAttributeChangedSignal("Cash"):Connect(updateCash)
	for _, upgrade in Config.Upgrades do
		player:GetAttributeChangedSignal("Level_" .. upgrade.Id):Connect(refreshAll)
	end
	updateCash()
	refreshAll()
end

function Shop.open()
	local frame, scale = window, windowScale
	if not frame or not scale or isOpen then
		return
	end
	isOpen = true
	refreshAll()
	frame.Visible = true
	local target = UI.CurrentScale
	scale.Scale = target * 0.8
	UI.tween(scale, 0.18, { Scale = target }, Enum.EasingStyle.Back)
end

function Shop.close()
	local frame = window
	if not frame or not isOpen then
		return
	end
	isOpen = false
	frame.Visible = false
end

function Shop.toggle()
	if isOpen then
		Shop.close()
	else
		Shop.open()
	end
end

function Shop.isOpen(): boolean
	return isOpen
end

return Shop
