--!strict
--[[
	Hud
	---
	The always-on-screen interface:
	  * Cash + income (top left), inventory stats underneath
	  * SHOP and CAR buttons
	  * Alarm banner while drones are chasing you
	  * Objective hint telling new players what to do next
	  * Treadmill training bar (while you run on your treadmill) and car speedometer
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local UI = require(script.Parent.UI)
local VehicleController = require(script.Parent.VehicleController)

local Hud = {}

local player = Players.LocalPlayer
local Theme = UI.Theme

export type Callbacks = {
	OnShop: () -> (),
	OnSpawnCar: () -> (),
}

local function getNumber(name: string, default: number): number
	local value = player:GetAttribute(name)
	return if type(value) == "number" then value else default
end

local function getString(name: string): string
	local value = player:GetAttribute(name)
	return if type(value) == "string" then value else ""
end

local function makeStatRow(parent: Instance, order: number, icon: string, title: string): TextLabel
	local row: Frame = UI.new("Frame", {
		Name = title,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 26),
		LayoutOrder = order,
		Parent = parent,
	})
	UI.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Size = UDim2.new(0.6, 0, 1, 0),
		Font = Theme.BoldFont,
		Text = icon .. "  " .. title,
		TextColor3 = Theme.SubText,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = row,
	})
	local value: TextLabel = UI.new("TextLabel", {
		Name = "Value",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.4, 0, 1, 0),
		Font = Theme.TitleFont,
		Text = "0",
		TextColor3 = Theme.Text,
		TextSize = 19,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = row,
	})
	return value
end

local function makeButton(parent: Instance, order: number, text: string, color: Color3, callback: () -> ()): TextButton
	local button: TextButton = UI.new("TextButton", {
		Name = text,
		AutoButtonColor = true,
		BackgroundColor3 = color,
		Size = UDim2.fromOffset(132, 52),
		LayoutOrder = order,
		Font = Theme.TitleFont,
		Text = text,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 22,
		TextStrokeTransparency = 0.6,
		Parent = parent,
	}, {
		UI.corner(12),
		UI.stroke(Color3.new(1, 1, 1), 2, 0.6),
		UI.gradient(Color3.new(1, 1, 1), Color3.fromRGB(190, 190, 190)),
	})
	UI.bounce(button)
	button.Activated:Connect(function()
		UI.playSound(UI.Sounds.Click, 0.4, 1.4)
		callback()
	end)
	return button
end

function Hud.init(screen: ScreenGui, callbacks: Callbacks)
	----------------------------------------------------------------------------
	-- Left column (kept vertically centred so it never covers the chat window)
	----------------------------------------------------------------------------
	local column: Frame = UI.new("Frame", {
		Name = "LeftColumn",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 14, 0.5, 0),
		Size = UDim2.fromOffset(270, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = screen,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		UI.scaled(),
	})

	----------------------------------------------------------------------------
	-- Cash panel
	----------------------------------------------------------------------------
	local cashPanel: Frame = UI.new("Frame", {
		Name = "CashPanel",
		Size = UDim2.fromOffset(270, 78),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.1,
		LayoutOrder = 1,
		Parent = column,
	}, {
		UI.corner(14),
		UI.stroke(Theme.Gold, 2, 0.3),
	})
	local cashLabel: TextLabel = UI.new("TextLabel", {
		Name = "Cash",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 6),
		Size = UDim2.new(1, -28, 0, 40),
		Font = Theme.TitleFont,
		Text = "💰 $0",
		TextColor3 = Theme.Gold,
		TextSize = 34,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextStrokeTransparency = 0.7,
		Parent = cashPanel,
	})
	local incomeLabel: TextLabel = UI.new("TextLabel", {
		Name = "Income",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 46),
		Size = UDim2.new(1, -28, 0, 24),
		Font = Theme.BoldFont,
		Text = "+$0 / sec",
		TextColor3 = Theme.Green,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = cashPanel,
	})

	----------------------------------------------------------------------------
	-- Stats panel
	----------------------------------------------------------------------------
	local statsPanel: Frame = UI.new("Frame", {
		Name = "StatsPanel",
		Size = UDim2.fromOffset(270, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.15,
		LayoutOrder = 2,
		Parent = column,
	}, {
		UI.corner(14),
		UI.stroke(Theme.Stroke, 2, 0.4),
		UI.padding(10),
		UI.new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	local bagValue = makeStatRow(statsPanel, 1, "🎒", "Loot Bag")
	local trunkValue = makeStatRow(statsPanel, 2, "🧳", "Car Trunk")
	local storageValue = makeStatRow(statsPanel, 3, "📦", "Warehouse")
	local speedValue = makeStatRow(statsPanel, 4, "👟", "Walk Speed")

	----------------------------------------------------------------------------
	-- Buttons
	----------------------------------------------------------------------------
	local buttonColumn: Frame = UI.new("Frame", {
		Name = "Buttons",
		Size = UDim2.fromOffset(270, 52),
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Parent = column,
	}, {
		UI.new("UIListLayout", {
			Padding = UDim.new(0, 6),
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})
	makeButton(buttonColumn, 1, "🛒 SHOP", Color3.fromRGB(255, 176, 40), callbacks.OnShop)
	makeButton(buttonColumn, 2, "🚗 CAR", Color3.fromRGB(60, 150, 255), callbacks.OnSpawnCar)

	----------------------------------------------------------------------------
	-- Alarm banner
	----------------------------------------------------------------------------
	local alarmBanner: Frame = UI.new("Frame", {
		Name = "AlarmBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 14),
		Size = UDim2.fromOffset(560, 64),
		BackgroundColor3 = Color3.fromRGB(200, 20, 30),
		Visible = false,
		Parent = screen,
	}, {
		UI.corner(14),
		UI.stroke(Color3.new(1, 1, 1), 3, 0.2),
		UI.scaled(),
	})
	local alarmText: TextLabel = UI.new("TextLabel", {
		Name = "Text",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0.62),
		Font = Theme.TitleFont,
		Text = "🚨 ALARM! RUN! 🚨",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 30,
		TextStrokeTransparency = 0.5,
		Parent = alarmBanner,
	})
	UI.new("TextLabel", {
		Name = "Hint",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 0.6),
		Size = UDim2.fromScale(1, 0.38),
		Font = Theme.BoldFont,
		Text = "Get off the property before a security drone catches you!",
		TextColor3 = Color3.fromRGB(255, 225, 225),
		TextSize = 16,
		Parent = alarmBanner,
	})

	----------------------------------------------------------------------------
	-- Objective hint
	----------------------------------------------------------------------------
	local objective: TextLabel = UI.new("TextLabel", {
		Name = "Objective",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -18),
		Size = UDim2.fromOffset(640, 40),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.25,
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.Text,
		TextSize = 18,
		TextWrapped = true,
		Parent = screen,
	}, {
		UI.corner(12),
		UI.padding(6),
		UI.scaled(),
	})

	----------------------------------------------------------------------------
	-- Training bar
	----------------------------------------------------------------------------
	local trainingPanel: Frame = UI.new("Frame", {
		Name = "Training",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -70),
		Size = UDim2.fromOffset(440, 58),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.1,
		Visible = false,
		Parent = screen,
	}, {
		UI.corner(12),
		UI.stroke(Theme.Cyan, 2, 0.2),
		UI.scaled(),
	})
	local trainingTitle: TextLabel = UI.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 4),
		Size = UDim2.new(1, -140, 0, 24),
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Theme.Cyan,
		TextSize = 19,
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = trainingPanel,
	})
	local trainingRate: TextLabel = UI.new("TextLabel", {
		Name = "Rate",
		AnchorPoint = Vector2.new(1, 0),
		BackgroundTransparency = 1,
		Position = UDim2.new(1, -12, 0, 4),
		Size = UDim2.fromOffset(130, 24),
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.Gold,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Right,
		Parent = trainingPanel,
	})
	local barBack: Frame = UI.new("Frame", {
		BackgroundColor3 = Color3.fromRGB(16, 18, 28),
		Position = UDim2.fromOffset(12, 32),
		Size = UDim2.new(1, -24, 0, 16),
		Parent = trainingPanel,
	}, { UI.corner(8) })
	local barFill: Frame = UI.new("Frame", {
		BackgroundColor3 = Theme.Cyan,
		Size = UDim2.fromScale(0, 1),
		Parent = barBack,
	}, { UI.corner(8) })

	----------------------------------------------------------------------------
	-- Speedometer
	----------------------------------------------------------------------------
	local speedo: Frame = UI.new("Frame", {
		Name = "Speedometer",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -70),
		Size = UDim2.fromOffset(170, 86),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.1,
		Visible = false,
		Parent = screen,
	}, {
		UI.corner(14),
		UI.stroke(Theme.Blue, 2, 0.3),
		UI.scaled(),
	})
	local speedoValue: TextLabel = UI.new("TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 58),
		Font = Theme.TitleFont,
		Text = "0",
		TextColor3 = Theme.Text,
		TextSize = 48,
		Parent = speedo,
	})
	UI.new("TextLabel", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 54),
		Size = UDim2.new(1, 0, 0, 24),
		Font = Theme.BoldFont,
		Text = "MPH",
		TextColor3 = Theme.SubText,
		TextSize = 16,
		Parent = speedo,
	})

	----------------------------------------------------------------------------
	-- Updating
	----------------------------------------------------------------------------
	local displayedCash = getNumber("Cash", 0)
	local targetCash = displayedCash

	local function updateStats()
		incomeLabel.Text = "+" .. Format.money(getNumber("Income", 0)) .. " / sec"
		local carried, bag = getNumber("Carried", 0), getNumber("BagCapacity", 2)
		bagValue.Text = string.format("%d / %d", carried, bag)
		bagValue.TextColor3 = if carried >= bag then Theme.Red else Theme.Text
		trunkValue.Text = string.format("%d / %d", getNumber("TrunkCount", 0), getNumber("TrunkCapacity", 4))
		local stored, storage = getNumber("StoredCount", 0), getNumber("StorageCapacity", 10)
		storageValue.Text = string.format("%d / %d", stored, storage)
		storageValue.TextColor3 = if stored >= storage then Theme.Orange else Theme.Text
		speedValue.Text = tostring(getNumber("WalkSpeed", 16))
	end

	local function updateObjective()
		local carried, bag = getNumber("Carried", 0), getNumber("BagCapacity", 2)
		local trunk = getNumber("TrunkCount", 0)
		local text: string
		if getString("AlarmHouse") ~= "" then
			text = "🚨 Escape the property! Drones can't follow you past the fence."
		elseif player:GetAttribute("DataLoaded") ~= true then
			text = "Loading your hideout..."
		elseif player:GetAttribute("Training") == true then
			text = "🏃 Training! You can go AFK, you'll keep getting faster. Press ESCAPE to hop off."
		elseif carried >= bag then
			text = "🎒 Bag full! Load your car trunk [F] or drop the loot on your warehouse's green DEPOSIT pad."
		elseif carried > 0 then
			text = "💰 Bring your loot to the green DEPOSIT pad in your warehouse (or keep stealing!)"
		elseif trunk > 0 then
			text = "🧳 Park your car on your warehouse's yellow LOADING DOCK to unload the trunk."
		elseif getNumber("StoredCount", 0) == 0 then
			text = "🏠 Spawn your 🚗 CAR, drive to a house, pick the lock and steal something!"
		else
			text = "🦝 Steal fancier loot from bigger houses. Run on your warehouse treadmill to outrun their drones!"
		end
		objective.Text = text
	end

	local function updateAlarm()
		local house = getString("AlarmHouse")
		alarmBanner.Visible = house ~= ""
		if house ~= "" then
			alarmText.Text = "🚨 ALARM AT THE " .. string.upper(house) .. "! 🚨"
		end
	end

	local function updateTraining()
		local training = player:GetAttribute("Training") == true
		trainingPanel.Visible = training
		if training then
			local level = getNumber("SpeedLevel", 0)
			local treadmillLevel = getNumber("Level_Treadmill", 1)
			trainingRate.Text = string.format("Lv %d · ⚡ %d XP/s", treadmillLevel, Config.getUpgradeValue("Treadmill", treadmillLevel))
			if player:GetAttribute("SpeedMaxed") == true then
				trainingTitle.Text = string.format("🏃 MAX SPEED (%d)", Config.walkSpeedForLevel(level))
				UI.tween(barFill, 0.2, { Size = UDim2.fromScale(1, 1) })
			else
				local xp, needed = getNumber("SpeedXP", 0), math.max(getNumber("SpeedXPNeeded", 1), 1)
				trainingTitle.Text = string.format(
					"🏃 Speed %d ➜ %d",
					Config.walkSpeedForLevel(level),
					Config.walkSpeedForLevel(level + 1)
				)
				UI.tween(barFill, 0.2, { Size = UDim2.fromScale(math.clamp(xp / needed, 0, 1), 1) })
			end
		end
	end

	for _, name in { "Income", "Carried", "BagCapacity", "TrunkCount", "TrunkCapacity", "StoredCount", "StorageCapacity", "WalkSpeed" } do
		player:GetAttributeChangedSignal(name):Connect(function()
			updateStats()
			updateObjective()
		end)
	end
	player:GetAttributeChangedSignal("AlarmHouse"):Connect(function()
		updateAlarm()
		updateObjective()
	end)
	player:GetAttributeChangedSignal("DataLoaded"):Connect(updateObjective)
	player:GetAttributeChangedSignal("Training"):Connect(updateObjective)
	for _, name in { "Training", "SpeedXP", "SpeedLevel", "SpeedXPNeeded", "SpeedMaxed", "Level_Treadmill" } do
		player:GetAttributeChangedSignal(name):Connect(updateTraining)
	end
	player:GetAttributeChangedSignal("Cash"):Connect(function()
		targetCash = getNumber("Cash", 0)
	end)

	updateStats()
	updateObjective()
	updateAlarm()
	updateTraining()

	local pulse = 0
	RunService.RenderStepped:Connect(function(dt: number)
		-- Count the cash up/down smoothly.
		if displayedCash ~= targetCash then
			local difference = targetCash - displayedCash
			if math.abs(difference) < 1 then
				displayedCash = targetCash
			else
				displayedCash += difference * math.min(dt * 10, 1)
			end
			cashLabel.Text = "💰 " .. Format.money(math.floor(displayedCash + 0.5))
		end
		-- Pulse the alarm banner.
		if alarmBanner.Visible then
			pulse += dt * 8
			alarmBanner.BackgroundColor3 = Color3.fromRGB(150 + math.floor(70 * math.abs(math.sin(pulse))), 20, 30)
		end
		-- Speedometer
		speedo.Visible = VehicleController.Driving
		if VehicleController.Driving then
			speedoValue.Text = tostring(math.floor(VehicleController.Speed + 0.5))
		end
	end)
	cashLabel.Text = "💰 " .. Format.money(displayedCash)
end

return Hud
