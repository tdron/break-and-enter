--!strict
--[[
	LootIndex
	---------
	The collection book: every stealable item in the game, grouped by the house
	it comes from, each with a little 3D picture. Items you haven't stolen yet
	are black silhouettes marked "???"; steal one and it's unlocked for good
	(the server saves the list and mirrors it in the "Discovered" attribute).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Items = require(ReplicatedStorage.Shared.Items)
local UI = require(script.Parent.UI)

local LootIndex = {}

local player = Players.LocalPlayer
local Theme = UI.Theme

type Card = {
	Item: Items.ItemDef,
	Frame: Frame,
	Picture: ViewportFrame,
	Name: TextLabel,
	Info: TextLabel,
	Unlocked: boolean,
}

type Section = {
	House: Config.HouseInfo,
	Count: TextLabel,
	Cards: { Card },
}

local window: Frame? = nil
local windowScale: UIScale? = nil
local progressLabel: TextLabel? = nil
local progressFill: Frame? = nil
local badge: TextLabel? = nil
local sections: { Section } = {}
local isOpen = false
local seen: { [string]: boolean } = {} -- discoveries already shown to the player
local unseen = 0
local baselined = false -- true once the saved collection has arrived (it never counts as "new")

local LOCKED_TINT = Color3.fromRGB(0, 0, 0)
local CARD_COLOR = Color3.fromRGB(36, 40, 62)

local function getDiscovered(): { [string]: boolean }
	local result: { [string]: boolean } = {}
	local value = player:GetAttribute("Discovered")
	if type(value) == "string" then
		for itemId in string.gmatch(value, "[^,]+") do
			result[itemId] = true
		end
	end
	return result
end

local function updateBadge()
	local label = badge
	if label then
		label.Visible = unseen > 0
		label.Text = if unseen > 9 then "9+" else tostring(unseen)
	end
end

local function makePicture(parent: Instance, def: Items.ItemDef): ViewportFrame
	-- UI.itemPicture strips the rarity aura, so the card shows the item itself.
	local picture = UI.itemPicture(parent, def.Id, UDim2.new(1, -12, 0, 92), UDim2.fromOffset(6, 6))
	picture.ImageColor3 = LOCKED_TINT
	return picture
end

local function setCard(card: Card, unlocked: boolean)
	card.Unlocked = unlocked
	local def = card.Item
	card.Picture.ImageColor3 = if unlocked then Color3.new(1, 1, 1) else LOCKED_TINT
	card.Picture.ImageTransparency = if unlocked then 0 else 0.15
	card.Name.Text = if unlocked then def.DisplayName else "???"
	card.Name.TextColor3 = if unlocked then Theme.Text else Theme.SubText
	card.Info.Text = if unlocked then string.format("%s · %s", def.Rarity, Format.money(def.Value)) else def.Rarity .. " · ???"
end

local function makeCard(parent: Instance, order: number, def: Items.ItemDef): Card
	local frame: Frame = UI.new("Frame", {
		Name = def.Id,
		BackgroundColor3 = CARD_COLOR,
		LayoutOrder = order,
		Parent = parent,
	}, {
		UI.corner(12),
		UI.stroke(Items.Rarities[def.Rarity].Color, 2, 0.55),
	})
	local picture = makePicture(frame, def)
	local name: TextLabel = UI.new("TextLabel", {
		Name = "ItemName",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(4, 101),
		Size = UDim2.new(1, -8, 0, 22),
		Font = Theme.TitleFont,
		Text = "???",
		TextColor3 = Theme.Text,
		TextScaled = true,
		Parent = frame,
	})
	local info: TextLabel = UI.new("TextLabel", {
		Name = "Info",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(4, 124),
		Size = UDim2.new(1, -8, 0, 18),
		Font = Theme.BoldFont,
		Text = def.Rarity,
		TextColor3 = Items.Rarities[def.Rarity].Color,
		TextSize = 14,
		Parent = frame,
	})
	local card: Card = { Item = def, Frame = frame, Picture = picture, Name = name, Info = info, Unlocked = false }
	setCard(card, false)
	return card
end

local function makeSection(parent: Instance, order: number, house: Config.HouseInfo): Section
	local tier = Config.HouseTiers[house.Tier]
	local guard = Config.Guards[house.Guard]
	local guardCount = if guard.Kind == "Drone" then 4 elseif house.Tier == 1 then 1 else 2
	local frame: Frame = UI.new("Frame", {
		Name = house.Id,
		BackgroundColor3 = Theme.PanelLight,
		BackgroundTransparency = 0.35,
		Size = UDim2.new(1, -10, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	}, {
		UI.corner(14),
		UI.padding(10),
		UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local header: Frame = UI.new("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 46),
		LayoutOrder = 1,
		Parent = frame,
	})
	UI.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -90, 0, 26),
		Font = Theme.TitleFont,
		Text = string.format("%s  %s", guard.Icon, string.upper(house.DisplayName)),
		TextColor3 = tier.Color,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = header,
	})
	UI.new("TextLabel", {
		Name = "Guard",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 26),
		Size = UDim2.new(1, -90, 0, 18),
		Font = Theme.BodyFont,
		Text = string.format(
			"%s%s %s · guarded by %s",
			string.rep("★", tier.Stars),
			string.rep("☆", 4 - tier.Stars),
			tier.Name,
			if guardCount == 1 then "a " .. guard.DisplayName else string.format("%d %ss", guardCount, guard.DisplayName)
		),
		TextColor3 = Theme.SubText,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = header,
	})
	local count: TextLabel = UI.new("TextLabel", {
		Name = "Count",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 6),
		Size = UDim2.fromOffset(90, 30),
		Font = Theme.TitleFont,
		Text = "0/0",
		TextColor3 = Theme.Gold,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = header,
	})
	local grid: Frame = UI.new("Frame", {
		Name = "Items",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = frame,
	}, {
		UI.new("UIGridLayout", {
			CellSize = UDim2.fromOffset(126, 146),
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	local cards: { Card } = {}
	for index, def in Items.forHouse(house.Id) do
		table.insert(cards, makeCard(grid, index, def))
	end
	return { House = house, Count = count, Cards = cards }
end

local function refresh()
	local discovered = getDiscovered()
	local found, total = 0, 0
	for _, section in sections do
		local houseFound = 0
		for _, card in section.Cards do
			local unlocked = discovered[card.Item.Id] == true
			if unlocked ~= card.Unlocked then
				setCard(card, unlocked)
			end
			if unlocked then
				houseFound += 1
			end
		end
		found += houseFound
		total += #section.Cards
		local complete = houseFound == #section.Cards and houseFound > 0
		section.Count.Text = string.format("%s%d/%d", if complete then "✅ " else "", houseFound, #section.Cards)
		section.Count.TextColor3 = if complete then Theme.Green else Theme.Gold
	end
	local label, fill = progressLabel, progressFill
	if label and fill then
		label.Text = string.format("%d / %d found", found, total)
		fill.Size = UDim2.fromScale(if total > 0 then found / total else 0, 1)
	end
	-- Count discoveries the player hasn't looked at yet (for the HUD badge).
	if isOpen or not baselined then
		seen = discovered
		unseen = 0
	else
		unseen = 0
		for itemId in discovered do
			if not seen[itemId] then
				unseen += 1
			end
		end
	end
	updateBadge()
end

function LootIndex.init(screen: ScreenGui)
	local scale = UI.scaled()
	local frame: Frame = UI.new("Frame", {
		Name = "LootIndex",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(760, 580),
		BackgroundColor3 = Theme.Panel,
		Visible = false,
		Parent = screen,
	}, {
		UI.corner(18),
		UI.stroke(Theme.Purple, 3, 0.1),
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
		Text = "📖 LOOT INDEX",
		TextColor3 = Theme.Purple,
		TextSize = 36,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	progressLabel = UI.new("TextLabel", {
		Name = "Progress",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -74, 0, 12),
		Size = UDim2.fromOffset(260, 28),
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Theme.Gold,
		TextSize = 24,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = frame,
	})
	local bar: Frame = UI.new("Frame", {
		Name = "ProgressBar",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -74, 0, 44),
		Size = UDim2.fromOffset(260, 10),
		BackgroundColor3 = Color3.fromRGB(16, 18, 28),
		Parent = frame,
	}, { UI.corner(5) })
	progressFill = UI.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Theme.Purple,
		Size = UDim2.fromScale(0, 1),
		Parent = bar,
	}, { UI.corner(5) })
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
		LootIndex.close()
	end)

	local list: ScrollingFrame = UI.new("ScrollingFrame", {
		Name = "List",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(16, 70),
		Size = UDim2.new(1, -28, 1, -112),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 8,
		ScrollBarImageColor3 = Theme.Purple,
		Parent = frame,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 12), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	for order, house in Config.Houses do
		table.insert(sections, makeSection(list, order, house))
	end

	UI.new("TextLabel", {
		Name = "Tip",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 20, 1, -8),
		Size = UDim2.new(1, -40, 0, 30),
		Font = Theme.BodyFont,
		Text = "💡 Every house has its own loot. Steal an item once to unlock it here forever. Rarer items show up less often!",
		TextColor3 = Theme.SubText,
		TextSize = 15,
		TextWrapped = true,
		Parent = frame,
	})

	-- Everything you'd discovered before this session counts as already seen. The server
	-- sets "Discovered" before "DataLoaded", so take the baseline once your data has loaded.
	local function takeBaseline()
		if not baselined and player:GetAttribute("DataLoaded") == true then
			seen = getDiscovered()
			baselined = true
		end
	end
	takeBaseline()
	player:GetAttributeChangedSignal("DataLoaded"):Connect(function()
		takeBaseline()
		refresh()
	end)
	player:GetAttributeChangedSignal("Discovered"):Connect(refresh)
	refresh()
end

-- Adds the little "NEW" counter to the HUD button that opens the index.
function LootIndex.attachBadge(button: GuiButton)
	badge = UI.new("TextLabel", {
		Name = "NewBadge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(1, -6, 0, 6),
		Size = UDim2.fromOffset(28, 28),
		BackgroundColor3 = Theme.Red,
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 16,
		Visible = false,
		ZIndex = 5,
		Parent = button,
	}, { UI.corner(14), UI.stroke(Color3.new(1, 1, 1), 2, 0) })
	updateBadge()
end

function LootIndex.open()
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

function LootIndex.close()
	local frame = window
	if not frame or not isOpen then
		return
	end
	isOpen = false
	frame.Visible = false
end

function LootIndex.toggle()
	if isOpen then
		LootIndex.close()
	else
		LootIndex.open()
	end
end

function LootIndex.isOpen(): boolean
	return isOpen
end

return LootIndex
