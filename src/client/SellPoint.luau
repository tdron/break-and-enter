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

local ROW_HEIGHT = 88

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
	local color = UI.rarityInk(def.Rarity)
	local frame: Frame = UI.new("Frame", {
		Name = def.Id .. order,
		BackgroundColor3 = Theme.PanelLight,
		Size = UDim2.new(1, -8, 0, ROW_HEIGHT),
		LayoutOrder = order,
		ZIndex = 3,
		Parent = parent,
	}, {
		UI.corner(14),
		UI.cardGradient(),
		UI.stroke(color, 2, 0.45),
	})
	-- Rarity accent bar down the left edge.
	UI.new("Frame", {
		Name = "Accent",
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 5, 1, -14),
		Position = UDim2.fromOffset(7, 7),
		ZIndex = 4,
		Parent = frame,
	}, { UI.corner(3) })
	UI.itemPicture(frame, def.Id, UDim2.fromOffset(76, 76), UDim2.fromOffset(18, 6))
	UI.new("TextLabel", {
		Name = "ItemName",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(104, 8),
		Size = UDim2.new(1, -316, 0, 24),
		Font = Theme.TitleFont,
		Text = def.DisplayName,
		TextColor3 = Theme.Text,
		TextSize = 20,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = frame,
	})
	UI.new("TextLabel", {
		Name = "Info",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(104, 34),
		Size = UDim2.new(1, -316, 0, 20),
		Font = Theme.BoldFont,
		Text = string.format("%s · 🎒 bag · %s", def.Rarity, Format.money(Items.getSellValue(def.Id))),
		TextColor3 = color,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = frame,
	})
	UI.new("TextLabel", {
		Name = "House",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(104, 56),
		Size = UDim2.new(1, -316, 0, 18),
		Font = Theme.BodyFont,
		Text = "from " .. def.House,
		TextColor3 = Theme.SubText,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = frame,
	})

	local button: TextButton = UI.new("TextButton", {
		Name = "Sell",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(124, 48),
		BackgroundColor3 = Theme.Green,
		Font = Theme.BoldFont,
		Text = "💰 " .. Format.money(Items.getSellValue(def.Id)),
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 18,

		ZIndex = 4,
		Parent = frame,
	}, {
		UI.corner(12),
		UI.gloss(),
		UI.stroke(Color3.new(1, 1, 1), 1.5, 0.45),
	})
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
		sellAll.BackgroundColor3 = if total > 0 then Theme.Green else Color3.fromRGB(168, 172, 190)
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
		Size = UDim2.fromOffset(720, 540),
		BackgroundColor3 = Theme.Panel,
		Visible = false,
		ZIndex = 2,
		Parent = screen,
	}, {
		UI.shadow(20, 10),
		UI.corner(20),
		UI.stroke(Theme.Green, 2.5, 0.2),
		UI.bodyGradient(),
		scale,
	})
	window = frame
	windowScale = scale

	UI.titleBar(frame, "🤑", "💰 SELL POINT", Theme.Green, Theme.GreenDark, 58)
	local close = UI.closeButton(frame, UDim2.new(1, -10, 0, 8))
	close.Activated:Connect(function()
		SellPoint.close()
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
	local cash: TextLabel = UI.new("TextLabel", {
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
	cashLabel = cash

	local baggage: TextLabel = UI.new("TextLabel", {
		Name = "Total",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(22, 64),
		Size = UDim2.new(1, -44, 0, 22),
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.SubText,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 4,
		Parent = frame,
	})
	totalLabel = baggage

	local scrolling: ScrollingFrame = UI.new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(16, 92),
		Size = UDim2.new(1, -28, 1, -200),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Green,
		ZIndex = 3,
		Parent = frame,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	list = scrolling

	local tipBar: Frame = UI.new("Frame", {
		Name = "TipBar",
		BackgroundColor3 = Theme.PanelTop,
		BackgroundTransparency = 0.35,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -116),
		Size = UDim2.new(1, -40, 0, 34),
		ZIndex = 3,
		Parent = frame,
	}, { UI.corner(12), UI.stroke(Color3.new(1, 1, 1), 1, 0.88) })
	local hint: TextLabel = UI.new("TextLabel", {
		Name = "Tip",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Font = Theme.BodyFont,
		Text = "",
		TextColor3 = Theme.SubText,
		TextSize = 14,
		TextWrapped = true,
		ZIndex = 4,
		Parent = tipBar,
	})
	tipLabel = hint
	UI.new("TextLabel", {
		Name = "Empty",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(24, 124),
		Size = UDim2.new(1, -48, 0, 40),
		Font = Theme.BodyFont,
		Text = "Your bag is empty. Rob a house, then bring the loot here for cash on the spot.",
		TextColor3 = Theme.SubText,
		TextSize = 18,
		TextWrapped = true,
		ZIndex = 4,
		Parent = frame,
	})
	empty = frame:FindFirstChild("Empty") :: TextLabel

	local all: TextButton = UI.new("TextButton", {
		Name = "SellAll",
		Position = UDim2.new(0, 20, 1, -72),
		Size = UDim2.new(1, -40, 0, 54),
		BackgroundColor3 = Theme.Green,
		Font = Theme.TitleFont,
		Text = "🤑 SELL EVERYTHING",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 24,

		ZIndex = 4,
		Parent = frame,
	}, {
		UI.corner(14),
		UI.gloss(),
		UI.stroke(Color3.new(1, 1, 1), 2, 0.35),
	})
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
