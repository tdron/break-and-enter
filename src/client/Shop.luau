--!strict
--[[
	Shop
	----
	The upgrade shop window. Opens from the HUD button or the shop counter in
	the hub. Purchases are validated by the server (Economy module).
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

local function describeValue(upgrade: Config.Upgrade, value: number): string
	if upgrade.Kind == "Unlock" then
		return if value >= 1 then "Unlocked" else "Locked"
	end
	return string.format(upgrade.Format, value)
end

local function refreshCard(card: Card)
	local upgrade = card.Upgrade
	local level = getNumber("Level_" .. upgrade.Id, 1)
	local maxLevel = #upgrade.Values
	local cash = getNumber("Cash", 0)

	if upgrade.Kind == "Unlock" then
		card.Level.Text = if level >= maxLevel then "OWNED" else "LOCKED"
		card.Value.Text = upgrade.Description
	else
		card.Level.Text = string.format("LV %d / %d", level, maxLevel)
		if level >= maxLevel then
			card.Value.Text = describeValue(upgrade, upgrade.Values[level]) .. "  (max)"
		else
			card.Value.Text = string.format(
				"%s  ➜  %s",
				describeValue(upgrade, upgrade.Values[level]),
				describeValue(upgrade, upgrade.Values[level + 1])
			)
		end
	end

	if level >= maxLevel then
		card.Button.Text = if upgrade.Kind == "Unlock" then "OWNED" else "MAXED"
		card.Button.BackgroundColor3 = Color3.fromRGB(70, 74, 96)
		card.Button.AutoButtonColor = false
	else
		local cost = upgrade.Costs[level + 1]
		card.Button.Text = Format.money(cost)
		card.Button.AutoButtonColor = true
		card.Button.BackgroundColor3 = if cash >= cost then Theme.Green else Color3.fromRGB(150, 60, 60)
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
		Size = UDim2.new(1, -8, 0, 92),
		LayoutOrder = order,
		Parent = parent,
	}, {
		UI.corner(12),
		UI.stroke(Theme.Stroke, 1, 0.3),
	})
	UI.new("TextLabel", {
		Name = "Icon",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.fromOffset(72, 72),
		Font = Theme.TitleFont,
		Text = upgrade.Icon,
		TextScaled = true,
		Parent = frame,
	})
	UI.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(92, 10),
		Size = UDim2.new(1, -260, 0, 28),
		Font = Theme.TitleFont,
		Text = upgrade.DisplayName,
		TextColor3 = Theme.Text,
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	local levelLabel: TextLabel = UI.new("TextLabel", {
		Name = "Level",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -164, 0, 12),
		Size = UDim2.fromOffset(110, 24),
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.Gold,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = frame,
	})
	local valueLabel: TextLabel = UI.new("TextLabel", {
		Name = "Value",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(92, 42),
		Size = UDim2.new(1, -260, 0, 40),
		Font = Theme.BodyFont,
		Text = "",
		TextColor3 = Theme.SubText,
		TextSize = 16,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = frame,
	})
	local button: TextButton = UI.new("TextButton", {
		Name = "Buy",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(140, 52),
		BackgroundColor3 = Theme.Green,
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 22,
		TextStrokeTransparency = 0.6,
		Parent = frame,
	}, {
		UI.corner(10),
	})
	UI.bounce(button)
	button.Activated:Connect(function()
		task.spawn(buy, upgrade)
	end)

	if upgrade.Kind ~= "Unlock" then
		-- Show the description under the title for normal upgrades via the tooltip-ish subtitle.
		UI.new("TextLabel", {
			Name = "Description",
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(92, 66),
			Size = UDim2.new(1, -260, 0, 20),
			Font = Theme.BodyFont,
			Text = upgrade.Description,
			TextColor3 = Color3.fromRGB(130, 136, 160),
			TextSize = 14,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Parent = frame,
		})
		valueLabel.Size = UDim2.new(1, -260, 0, 22)
	end

	return { Upgrade = upgrade, Level = levelLabel, Value = valueLabel, Button = button }
end

function Shop.init(screen: ScreenGui)
	local scale = UI.scaled()
	local frame: Frame = UI.new("Frame", {
		Name = "Shop",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(660, 560),
		BackgroundColor3 = Theme.Panel,
		Visible = false,
		Parent = screen,
	}, {
		UI.corner(18),
		UI.stroke(Theme.Gold, 3, 0.1),
		scale,
	})
	window = frame
	windowScale = scale

	UI.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(20, 10),
		Size = UDim2.new(1, -90, 0, 50),
		Font = Theme.TitleFont,
		Text = "🛒 UPGRADE SHOP",
		TextColor3 = Theme.Gold,
		TextSize = 36,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	local cashLabel: TextLabel = UI.new("TextLabel", {
		Name = "Cash",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -74, 0, 18),
		Size = UDim2.fromOffset(240, 36),
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Theme.Green,
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = frame,
	})
	local close: TextButton = UI.new("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 14),
		Size = UDim2.fromOffset(44, 44),
		BackgroundColor3 = Theme.Red,
		Font = Theme.TitleFont,
		Text = "X",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 26,
		Parent = frame,
	}, { UI.corner(10) })
	UI.bounce(close)
	close.Activated:Connect(function()
		Shop.close()
	end)

	local list: ScrollingFrame = UI.new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(16, 70),
		Size = UDim2.new(1, -28, 1, -116),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Gold,
		Parent = frame,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for index, upgrade in Config.Upgrades do
		table.insert(cards, makeCard(list, index, upgrade))
	end

	UI.new("TextLabel", {
		Name = "Tip",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -10),
		Size = UDim2.new(1, -40, 0, 30),
		Font = Theme.BodyFont,
		Text = "💡 Stored items earn cash every second. Run on Gym treadmills to outrun faster drones!",
		TextColor3 = Theme.SubText,
		TextSize = 15,
		TextWrapped = true,
		Parent = frame,
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
