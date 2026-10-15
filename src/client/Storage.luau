--!strict
--[[
	Storage
	-------
	The warehouse storage window. Opens from any shelf prompt in your own warehouse
	(or from the HUD's STORAGE button) and lists everything on your shelves:

	  * TAKE  — unequips an item: it comes off the shelf and back into your bag.
	  * SELL  — sells it for cash on the spot.

	Nothing is taken for granted on the client: the server (Plots.storageList /
	Plots.take / Plots.sell, reached through the Storage remote) checks that the
	warehouse is really yours and that the bag has room.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Format = require(ReplicatedStorage.Shared.Format)
local Items = require(ReplicatedStorage.Shared.Items)
local Notifications = require(script.Parent.Notifications)
local UI = require(script.Parent.UI)

local StorageRemote = ReplicatedStorage.Remotes.Storage

local Storage = {}

local player = Players.LocalPlayer
local Theme = UI.Theme

local ROW_HEIGHT = 96
local CARD_COLOR = Color3.fromRGB(36, 40, 62)

local window: Frame? = nil
local windowScale: UIScale? = nil
local list: ScrollingFrame? = nil
local header: TextLabel? = nil
local empty: TextLabel? = nil
local isOpen = false
local busy = false

local function number(name: string, default: number): number
	local value = player:GetAttribute(name)
	return if type(value) == "number" then value else default
end

local function updateHeader()
	local label = header
	if label then
		label.Text = string.format(
			"📦 Shelves %d / %d   ·   🎒 Bag %d / %d   ·   💰 %s",
			number("StoredCount", 0),
			number("StorageCapacity", 0),
			number("Carried", 0),
			number("BagCapacity", 0),
			Format.money(number("Cash", 0))
		)
	end
	local hint = empty
	if hint then
		hint.Visible = #(list and list:GetChildren() or {}) == 0
	end
end

local function request(action: string?, itemId: string?): { [string]: any }?
	if busy then
		return nil
	end
	busy = true
	local ok, result = pcall(function()
		if action then
			return StorageRemote:InvokeServer(action, itemId)
		end
		return StorageRemote:InvokeServer("List")
	end)
	busy = false
	if not ok or type(result) ~= "table" then
		Notifications.show("The warehouse is busy, try again!", "error")
		return nil
	end
	return result
end

local function act(action: string, itemId: string)
	local result = request(action, itemId)
	if not result then
		return
	end
	if result.Ok then
		UI.playSound(UI.Sounds.Purchase, 0.5, if action == "Take" then 1.3 else 1.7)
	else
		UI.playSound(UI.Sounds.Error, 0.4, 1)
	end
	Notifications.show(tostring(result.Message), if result.Ok then "success" else "error")
	Storage.refresh()
end

local function makeRow(parent: Instance, order: number, itemId: string): Frame?
	local def = Items.get(itemId)
	if not def then
		return nil
	end
	local rarity = Items.getRarity(itemId)
	local color = if rarity then rarity.Color else Theme.SubText
	local frame: Frame = UI.new("Frame", {
		Name = itemId .. order,
		BackgroundColor3 = CARD_COLOR,
		Size = UDim2.new(1, -8, 0, ROW_HEIGHT),
		LayoutOrder = order,
		Parent = parent,
	}, {
		UI.corner(12),
		UI.stroke(color, 2, 0.55),
	})
	UI.itemPicture(frame, itemId, UDim2.fromOffset(84, 84), UDim2.fromOffset(6, 6))

	UI.new("TextLabel", {
		Name = "ItemName",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(100, 8),
		Size = UDim2.new(1, -320, 0, 26),
		Font = Theme.TitleFont,
		Text = def.DisplayName,
		TextColor3 = Theme.Text,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	UI.new("TextLabel", {
		Name = "Rarity",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(100, 34),
		Size = UDim2.new(1, -320, 0, 20),
		Font = Theme.BoldFont,
		Text = string.format("%s · from %s", def.Rarity, def.House),
		TextColor3 = color,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	UI.new("TextLabel", {
		Name = "Worth",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(100, 58),
		Size = UDim2.new(1, -320, 0, 24),
		Font = Theme.BoldFont,
		Text = string.format("💵 %s   ·   +%s / sec", Format.money(def.Value), Format.money(Items.getIncome(itemId))),
		TextColor3 = Theme.Green,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})

	local function button(name: string, text: string, x: number, color: Color3, callback: () -> ()): TextButton
		local button: TextButton = UI.new("TextButton", {
			Name = name,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, x, 0.5, 0),
			Size = UDim2.fromOffset(96, 46),
			BackgroundColor3 = color,
			Font = Theme.BoldFont,
			Text = text,
			TextColor3 = Color3.new(1, 1, 1),
			TextSize = 18,
			Parent = frame,
		}, { UI.corner(10) })
		UI.bounce(button)
		button.Activated:Connect(callback)
		return button
	end

	button("Take", "🎒 TAKE", -14, Theme.Blue, function()
		act("Take", itemId)
	end)
	button("Sell", "💰 " .. Format.money(Items.getSellValue(itemId)), -118, Theme.Green, function()
		act("Sell", itemId)
	end)
	return frame
end

-- Asks the server what is on the shelves and rebuilds the list.
function Storage.refresh()
	local frame, container = window, list
	if not frame or not container then
		return
	end
	local result = request(nil)
	container:ClearAllChildren()
	if result then
		for index, itemId in result.Items or {} do
			makeRow(container, index, itemId)
		end
	end
	updateHeader()
end

function Storage.init(screen: ScreenGui)
	local scale = UI.scaled()
	local frame: Frame = UI.new("Frame", {
		Name = "Storage",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(700, 520),
		BackgroundColor3 = Theme.Panel,
		Visible = false,
		Parent = screen,
	}, {
		UI.corner(18),
		UI.stroke(Theme.Blue, 3, 0.1),
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
		Text = "📦 WAREHOUSE STORAGE",
		TextColor3 = Theme.Blue,
		TextSize = 32,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	local headerLabel: TextLabel = UI.new("TextLabel", {
		Name = "Header",
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
	header = headerLabel
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
		Storage.close()
	end)

	local scrolling: ScrollingFrame = UI.new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(16, 80),
		Size = UDim2.new(1, -28, 1, -142),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Blue,
		Parent = frame,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	list = scrolling

	UI.new("TextLabel", {
		Name = "Empty",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(20, 110),
		Size = UDim2.new(1, -40, 0, 40),
		Font = Theme.BodyFont,
		Text = "Your shelves are empty — steal something and drop it on the green DEPOSIT pad.",
		TextColor3 = Theme.SubText,
		TextSize = 18,
		TextWrapped = true,
		Parent = frame,
	})
	empty = frame:FindFirstChild("Empty") :: TextLabel

	UI.new("TextLabel", {
		Name = "Tip",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -10),
		Size = UDim2.new(1, -40, 0, 34),
		Font = Theme.BodyFont,
		Text = "🎒 TAKE puts an item back in your bag (sell it at the 💰 SELL POINT, or stash it again).  "
			.. "💰 SELL pays cash on the spot and frees the shelf.",
		TextColor3 = Theme.SubText,
		TextSize = 15,
		TextWrapped = true,
		Parent = frame,
	})

	for _, name in { "StoredCount", "StorageCapacity", "Carried", "BagCapacity", "Cash" } do
		player:GetAttributeChangedSignal(name):Connect(updateHeader)
	end
	updateHeader()
end

function Storage.open()
	local frame, scale = window, windowScale
	if not frame or not scale or isOpen then
		return
	end
	isOpen = true
	frame.Visible = true
	local target = UI.CurrentScale
	scale.Scale = target * 0.8
	UI.tween(scale, 0.18, { Scale = target }, Enum.EasingStyle.Back)
	task.spawn(Storage.refresh)
end

function Storage.close()
	local frame = window
	if not frame or not isOpen then
		return
	end
	isOpen = false
	frame.Visible = false
end

function Storage.toggle()
	if isOpen then
		Storage.close()
	else
		Storage.open()
	end
end

function Storage.isOpen(): boolean
	return isOpen
end

return Storage
