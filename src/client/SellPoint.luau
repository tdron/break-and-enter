--!strict
--[[
	SellPoint
	---------
	The trader's window at the yard's market stall. Opens from the stall's prompt
	and lists everything you could sell right now: the loot in your bag.

	One button sells a single item, the big button sells the lot. The server
	(Market.luau) decides what really gets sold and pays the cash.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Format = require(ReplicatedStorage.Shared.Format)
local Items = require(ReplicatedStorage.Shared.Items)
local Notifications = require(script.Parent.Notifications)
local UI = require(script.Parent.UI)

local SellRemote = ReplicatedStorage.Remotes.Sell

local SellPoint = {}

local player = Players.LocalPlayer
local Theme = UI.Theme

local ROW_HEIGHT = 84
local CARD_COLOR = Color3.fromRGB(36, 40, 62)

local window: Frame? = nil
local windowScale: UIScale? = nil
local list: ScrollingFrame? = nil
local cashLabel: TextLabel? = nil
local totalLabel: TextLabel? = nil
local empty: TextLabel? = nil
local tipLabel: TextLabel? = nil
local sellAll: TextButton? = nil
local isOpen = false
local busy = false
local lastSignature: string? = nil

local function number(name: string, default: number): number
	local value = player:GetAttribute(name)
	return if type(value) == "number" then value else default
end

local function request(action: string?, itemId: string?, source: string?): { [string]: any }?
	if busy then
		return nil
	end
	busy = true
	local ok, result = pcall(function()
		if action then
			return SellRemote:InvokeServer(action, itemId, source)
		end
		return SellRemote:InvokeServer("List")
	end)
	busy = false
	if not ok or type(result) ~= "table" then
		Notifications.show("The trader is busy, try again!", "error")
		return nil
	end
	return result
end

local function totalValue(sales: { any }): number
	local total = 0
	for _, sale in sales do
		total += Items.getSellValue(tostring(sale.ItemId))
	end
	return total
end

local function makeRow(parent: Instance, order: number, sale: any): Frame?
	local def = Items.get(tostring(sale.ItemId))
	if not def then
		return nil
	end
	local rarity = Items.getRarity(def.Id)
	local color = if rarity then rarity.Color else Theme.SubText
	local frame: Frame = UI.new("Frame", {
		Name = def.Id .. order,
		BackgroundColor3 = CARD_COLOR,
		Size = UDim2.new(1, -8, 0, ROW_HEIGHT),
		LayoutOrder = order,
		Parent = parent,
	}, {
		UI.corner(12),
		UI.stroke(color, 2, 0.55),
	})
	UI.itemPicture(frame, def.Id, UDim2.fromOffset(72, 72), UDim2.fromOffset(6, 6))
	UI.new("TextLabel", {
		Name = "ItemName",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(88, 8),
		Size = UDim2.new(1, -300, 0, 24),
		Font = Theme.TitleFont,
		Text = def.DisplayName,
		TextColor3 = Theme.Text,
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	UI.new("TextLabel", {
		Name = "Info",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(88, 32),
		Size = UDim2.new(1, -300, 0, 20),
		Font = Theme.BoldFont,
		Text = string.format("%s · 🎒 bag · %s", def.Rarity, Format.money(Items.getSellValue(def.Id))),
		TextColor3 = color,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	UI.new("TextLabel", {
		Name = "House",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(88, 52),
		Size = UDim2.new(1, -300, 0, 18),
		Font = Theme.BodyFont,
		Text = "from " .. def.House,
		TextColor3 = Theme.SubText,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})

	local button: TextButton = UI.new("TextButton", {
		Name = "Sell",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(120, 46),
		BackgroundColor3 = Theme.Green,
		Font = Theme.BoldFont,
		Text = "💰 " .. Format.money(Items.getSellValue(def.Id)),
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 18,
		Parent = frame,
	}, { UI.corner(10) })
	UI.bounce(button)
	button.Activated:Connect(function()
		local result = request("Sell", def.Id, tostring(sale.Source))
		if not result then
			return
		end
		UI.playSound(if result.Ok then UI.Sounds.Purchase else UI.Sounds.Error, 0.5, if result.Ok then 1.7 else 1)
		Notifications.show(tostring(result.Message), if result.Ok then "money" else "error")
		SellPoint.refresh()
	end)
	return frame
end

function SellPoint.refresh()
	local frame, container = window, list
	if not frame or not container then
		return
	end
	local result = request(nil)
	local sales: { any } = if result then result.Sales or {} else {}
	local bagCount = 0
	local parts = {}
	for index, sale in sales do
		bagCount += 1
		table.insert(parts, string.format("%d:%s", index, tostring(sale.ItemId)))
	end
	-- Only touch the rows when the list really changed.
	local signature = table.concat(parts, "|")
	if signature ~= lastSignature then
		lastSignature = signature
		container:ClearAllChildren()
		for index, sale in sales do
			makeRow(container, index, sale)
		end
	end

	local total = totalValue(sales)
	if cashLabel then
		cashLabel.Text = "💰 " .. Format.money(number("Cash", 0))
	end
	if totalLabel then
		if #sales == 0 then
			totalLabel.Text = "Nothing to sell — steal something first!"
		else
			totalLabel.Text = string.format("%d item%s in your bag · worth %s", bagCount,
				if bagCount == 1 then "" else "s", Format.money(total))
		end
	end
	if sellAll then
		sellAll.Text = if total > 0 then "🤑 SELL EVERYTHING (" .. Format.money(total) .. ")" else "🤑 NOTHING TO SELL"
		sellAll.BackgroundColor3 = if total > 0 then Theme.Green else Color3.fromRGB(70, 74, 96)
		sellAll.AutoButtonColor = total > 0
	end
	if empty then
		empty.Visible = #sales == 0
	end
	if tipLabel then
		tipLabel.Text = "💡 Shelf loot in your warehouse instead: stored items pay you every second."
	end
end

function SellPoint.init(screen: ScreenGui)
	local scale = UI.scaled()
	local frame: Frame = UI.new("Frame", {
		Name = "SellPoint",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(700, 540),
		BackgroundColor3 = Theme.Panel,
		Visible = false,
		Parent = screen,
	}, {
		UI.corner(18),
		UI.stroke(Theme.Green, 3, 0.1),
		scale,
	})
	window = frame
	windowScale = scale

	UI.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(20, 8),
		Size = UDim2.new(1, -90, 0, 44),
		Font = Theme.TitleFont,
		Text = "💰 SELL POINT",
		TextColor3 = Theme.Green,
		TextSize = 32,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	local cash: TextLabel = UI.new("TextLabel", {
		Name = "Cash",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -74, 0, 16),
		Size = UDim2.fromOffset(240, 32),
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Theme.Green,
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = frame,
	})
	cashLabel = cash
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
		SellPoint.close()
	end)

	local baggage: TextLabel = UI.new("TextLabel", {
		Name = "Total",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(22, 50),
		Size = UDim2.new(1, -44, 0, 24),
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.SubText,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	totalLabel = baggage

	local scrolling: ScrollingFrame = UI.new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(16, 80),
		Size = UDim2.new(1, -28, 1, -186),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Green,
		Parent = frame,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	list = scrolling

	local hint: TextLabel = UI.new("TextLabel", {
		Name = "Tip",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(22, 396),
		Size = UDim2.new(1, -44, 0, 22),
		Font = Theme.BodyFont,
		Text = "",
		TextColor3 = Theme.SubText,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	tipLabel = hint
	UI.new("TextLabel", {
		Name = "Empty",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(22, 120),
		Size = UDim2.new(1, -44, 0, 40),
		Font = Theme.BodyFont,
		Text = "Your bag is empty. Rob a house, then bring the loot here for cash on the spot.",
		TextColor3 = Theme.SubText,
		TextSize = 18,
		TextWrapped = true,
		Parent = frame,
	})
	empty = frame:FindFirstChild("Empty") :: TextLabel

	local all: TextButton = UI.new("TextButton", {
		Name = "SellAll",
		Position = UDim2.new(0, 20, 1, -74),
		Size = UDim2.new(1, -40, 0, 52),
		BackgroundColor3 = Theme.Green,
		Font = Theme.TitleFont,
		Text = "🤑 SELL EVERYTHING",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 24,
		Parent = frame,
	}, { UI.corner(12) })
	sellAll = all
	UI.bounce(all)
	all.Activated:Connect(function()
		local result = request("All")
		if not result then
			return
		end
		UI.playSound(if result.Ok then UI.Sounds.Purchase else UI.Sounds.Error, 0.6, if result.Ok then 1.9 else 1)
		Notifications.show(tostring(result.Message), if result.Ok then "money" else "error")
		SellPoint.refresh()
	end)

	player:GetAttributeChangedSignal("Cash"):Connect(function()
		if cash then
			cash.Text = "💰 " .. Format.money(number("Cash", 0))
		end
	end)
	for _, name in { "Carried" } do
		player:GetAttributeChangedSignal(name):Connect(function()
			task.spawn(SellPoint.refresh)
		end)
	end
	cash.Text = "💰 " .. Format.money(number("Cash", 0))
end

function SellPoint.open()
	local frame, scale = window, windowScale
	if not frame or not scale or isOpen then
		return
	end
	isOpen = true
	lastSignature = nil
	frame.Visible = true
	local target = UI.CurrentScale
	scale.Scale = target * 0.8
	UI.tween(scale, 0.18, { Scale = target }, Enum.EasingStyle.Back)
	task.spawn(SellPoint.refresh)
end

function SellPoint.close()
	local frame = window
	if not frame or not isOpen then
		return
	end
	isOpen = false
	frame.Visible = false
end

function SellPoint.toggle()
	if isOpen then
		SellPoint.close()
	else
		SellPoint.open()
	end
end

function SellPoint.isOpen(): boolean
	return isOpen
end

return SellPoint
