--!strict
--[[
	Hud
	---
	The always-on-screen interface, restyled after the current top games
	(Steal a Brainrot / Pet Simulator 99 / Adopt Me!):
	  * A gold gradient cash pill with an icon disc (top left), income chip
	    under it, and a glass stats panel (bag / warehouse / speed)
	  * A right-edge rail of big square gradient buttons (SHOP / STORAGE /
	    LOOT INDEX) with pop-bounce presses, the way Pet Sim 99 does it
	  * A cinematic night/daytime clock (top centre) with a phase progress bar
	  * A pulsing full-width alarm banner while a house's guards chase you
	  * A pill objective hint telling new players what to do next
	  * Floating treadmill gain numbers above the runner (owned by TreadmillController)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local DayNight = require(script.Parent.DayNight)
local UI = require(script.Parent.UI)

local Hud = {}

local player = Players.LocalPlayer
local Theme = UI.Theme

export type Callbacks = {
	OnShop: () -> (),
	OnStorage: () -> (),
	OnIndex: () -> (),
}

export type Elements = {
	IndexButton: TextButton,
}

local function getNumber(name: string, default: number): number
	local value = player:GetAttribute(name)
	return if type(value) == "number" then value else default
end

local function getString(name: string): string
	local value = player:GetAttribute(name)
	return if type(value) == "string" then value else ""
end

-- A stat row with a glossy icon chip on the left (the Pet Sim look).
local function makeStatRow(parent: Instance, y: number, icon: string, title: string, color: Color3, colorDark: Color3): TextLabel
	local row: Frame = UI.new("Frame", {
		Name = title,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(10, y),
		Size = UDim2.new(1, -20, 0, 32),
		Parent = parent,
	})
	UI.iconChip(row, icon, color, colorDark, 28, UDim2.fromOffset(0, 2))
	UI.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(38, 0),
		Size = UDim2.new(0.55, -38, 1, 0),
		Font = Theme.BoldFont,
		Text = title,
		TextColor3 = Theme.Text,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
		Parent = row,
	})
	local value: TextLabel = UI.new("TextLabel", {
		Name = "Value",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.45, 0, 1, 0),
		Font = Theme.TitleFont,
		Text = "0",
		TextColor3 = Theme.Text,
		TextSize = 22,
		TextXAlignment = Enum.TextXAlignment.Right,
		ZIndex = 3,
		Parent = row,
	})
	return value
end

-- A big square gradient button for the right-edge rail. The background carries
-- the accent colour; the label is crisp white Fredoka with NO text stroke (a
-- partial dark stroke muddies small text on a saturated background).
local function makeRailButton(parent: Instance, order: number, text: string, color: Color3, colorDark: Color3, callback: () -> ()): TextButton
	local button: TextButton = UI.new("TextButton", {
		Name = text,
		AutoButtonColor = true,
		BackgroundColor3 = color,
		Size = UDim2.fromOffset(132, 58),
		LayoutOrder = order,
		Font = Theme.TitleFont,
		Text = text,
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 19,
		ZIndex = 3,
		Parent = parent,
	}, {
		UI.corner(16),
		UI.stroke(Color3.new(1, 1, 1), 2.5, 0.25),
		UI.gloss(),
	})
	UI.bounce(button)
	button.Activated:Connect(function()
		UI.playSound(UI.Sounds.Click, 0.4, 1.4)
		callback()
	end)
	return button
end

function Hud.init(screen: ScreenGui, callbacks: Callbacks): Elements
	----------------------------------------------------------------------------
	-- Top-left cluster: cash pill + income chip + stats panel
	----------------------------------------------------------------------------
	local column: Frame = UI.new("Frame", {
		Name = "LeftColumn",
		AnchorPoint = Vector2.new(0, 0),
		Position = UDim2.fromOffset(14, 14),
		Size = UDim2.fromOffset(260, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = screen,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
		UI.scaled(),
	})

	----------------------------------------------------------------------------
	-- Cash pill (gold gradient — the Steal a Brainrot / Pet Sim counter)
	----------------------------------------------------------------------------
	local cashPanel: Frame = UI.new("Frame", {
		Name = "CashPanel",
		Size = UDim2.fromOffset(260, 76),
		BackgroundColor3 = Theme.Gold,
		LayoutOrder = 1,
		ZIndex = 2,
		Parent = column,
	}, {
		UI.shadow(18, 7),
		UI.corner(18),
		UI.stroke(Color3.new(1, 1, 1), 2.5, 0.2),
		UI.gradient(Theme.Gold, Theme.GoldDark),
	})
	UI.iconChip(cashPanel, "💰", Color3.new(1, 1, 1), Color3.fromRGB(255, 236, 180), 48, UDim2.fromOffset(12, 14))
	local cashLabel: TextLabel = UI.new("TextLabel", {
		Name = "Cash",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(72, 6),
		Size = UDim2.new(1, -82, 0, 40),
		Font = Theme.TitleFont,
		Text = "$0",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 34,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextStrokeTransparency = 0.5,
		ZIndex = 3,
		Parent = cashPanel,
	})
	-- Income sits in its own little white chip under the cash (keeps the gold readable).
	local incomeChip: Frame = UI.new("Frame", {
		Name = "IncomeChip",
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.3,
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -8),
		Size = UDim2.fromOffset(0, 24),
		AutomaticSize = Enum.AutomaticSize.X,
		ZIndex = 4,
		Parent = cashPanel,
	}, {
		UI.corner(12),
		UI.new("UIPadding", {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
		}),
	})
	local incomeLabel: TextLabel = UI.new("TextLabel", {
		Name = "Income",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, 0),
		Font = Theme.BoldFont,
		Text = "+$0 / sec",
		TextColor3 = Theme.GreenDark,
		TextSize = 16,
		ZIndex = 5,
		Parent = incomeChip,
	})

	----------------------------------------------------------------------------
	-- Stats panel (glass card with icon-chip rows; fixed height, manually placed
	-- rows — a UIListLayout would treat the Shadow frame as a list item)
	----------------------------------------------------------------------------
	local statsPanel: Frame = UI.new("Frame", {
		Name = "StatsPanel",
		Size = UDim2.fromOffset(260, 120),
		BackgroundColor3 = Theme.Panel,
		BackgroundTransparency = 0.12,
		LayoutOrder = 2,
		ZIndex = 2,
		Parent = column,
	}, {
		UI.shadow(16, 5),
		UI.corner(16),
		UI.stroke(Theme.Stroke, 1.5, 0.15),
		UI.bodyGradient(),
	})
	local bagValue = makeStatRow(statsPanel, 10, "🎒", "Loot Bag", Theme.Orange, Theme.OrangeDark)
	local storageValue = makeStatRow(statsPanel, 46, "📦", "Warehouse", Theme.Blue, Theme.BlueDark)
	local speedValue = makeStatRow(statsPanel, 82, "👟", "Speed", Theme.Cyan, Theme.CyanDark)

	----------------------------------------------------------------------------
	-- Right-edge button rail (Pet Sim 99 style)
	----------------------------------------------------------------------------
	local rail: Frame = UI.new("Frame", {
		Name = "ButtonsRail",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(132, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = screen,
	}, {
		UI.new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }),
		UI.scaled(),
	})
	makeRailButton(rail, 1, "🛒 SHOP", Theme.Orange, Theme.OrangeDark, callbacks.OnShop)
	makeRailButton(rail, 2, "📦 STORAGE", Theme.Green, Theme.GreenDark, callbacks.OnStorage)
	local indexButton = makeRailButton(rail, 3, "📖 LOOT INDEX", Theme.Purple, Theme.PurpleDark, callbacks.OnIndex)

	----------------------------------------------------------------------------
	-- Night / daytime clock (cinematic pill + phase progress bar)
	----------------------------------------------------------------------------
	local clock: Frame = UI.new("Frame", {
		Name = "Clock",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.fromOffset(330, 66),
		BackgroundColor3 = Theme.Night,
		BackgroundTransparency = 0.04,
		ZIndex = 2,
		Parent = screen,
	}, {
		UI.shadow(20, 5),
		UI.corner(20),
		UI.stroke(Color3.new(1, 1, 1), 2, 0.2),
		UI.gloss(),
		UI.scaled(),
	})
	local clockTitle: TextLabel = UI.new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 4),
		Size = UDim2.new(1, 0, 0, 30),
		Font = Theme.TitleFont,
		Text = "",
		TextColor3 = Theme.Text,
		TextSize = 26,
		ZIndex = 3,
		Parent = clock,
	})
	local clockHint: TextLabel = UI.new("TextLabel", {
		Name = "Hint",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.SubText,
		TextSize = 14,
		ZIndex = 3,
		Parent = clock,
	})
	local clockBarBack: Frame = UI.new("Frame", {
		Name = "Progress",
		BackgroundColor3 = Color3.fromRGB(94, 90, 122),
		BackgroundTransparency = 0.75,
		Position = UDim2.fromOffset(14, 55),
		Size = UDim2.new(1, -28, 0, 6),
		ZIndex = 3,
		Parent = clock,
	}, { UI.corner(3) })
	local clockBarFill: Frame = UI.new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Theme.Cyan,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 4,
		Parent = clockBarBack,
	}, { UI.corner(3) })

	----------------------------------------------------------------------------
	-- Alarm banner (99 Nights-style red alert, wide and pulsing)
	----------------------------------------------------------------------------
	local alarmBanner: Frame = UI.new("Frame", {
		Name = "AlarmBanner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 86),
		Size = UDim2.fromOffset(620, 70),
		BackgroundColor3 = Theme.Red,
		Visible = false,
		ZIndex = 4,
		Parent = screen,
	}, {
		UI.shadow(18, 7),
		UI.corner(18),
		UI.stroke(Color3.new(1, 1, 1), 3, 0.15),
		UI.gradient(Color3.new(1, 1, 1), Color3.fromRGB(190, 190, 190)),
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
		TextStrokeTransparency = 0.45,
		ZIndex = 5,
		Parent = alarmBanner,
	})
	local alarmHint: TextLabel = UI.new("TextLabel", {
		Name = "Hint",
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0, 0.58),
		Size = UDim2.fromScale(1, 0.4),
		Font = Theme.BoldFont,
		Text = "Get off the property before the guards catch you!",
		TextColor3 = Color3.fromRGB(255, 228, 228),
		TextSize = 16,
		ZIndex = 5,
		Parent = alarmBanner,
	})

	----------------------------------------------------------------------------
	-- Objective hint (bottom pill)
	----------------------------------------------------------------------------
	local objective: TextLabel = UI.new("TextLabel", {
		Name = "Objective",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(660, 42),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 0.08,
		Font = Theme.BoldFont,
		Text = "",
		TextColor3 = Theme.Text,
		TextSize = 17,
		TextWrapped = true,
		ZIndex = 2,
		Parent = screen,
	}, {
		UI.corner(21),
		UI.stroke(Theme.Stroke, 1.5, 0.15),
		UI.padding(6),
		UI.scaled(),
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
		local stored, storage = getNumber("StoredCount", 0), getNumber("StorageCapacity", 10)
		storageValue.Text = string.format("%d / %d", stored, storage)
		storageValue.TextColor3 = if stored >= storage then Theme.Orange else Theme.Text
		-- Speed is the player-facing stat; raw Humanoid studs-per-second is never shown here.
		speedValue.Text = Format.commas(getNumber("Speed", Config.speedStatForPoints(getNumber("SpeedPoints", 0))))
	end

	local function updateObjective()
		local carried, bag = getNumber("Carried", 0), getNumber("BagCapacity", 2)
		local text: string
		if getString("AlarmHouse") ~= "" then
			text = "🚨 Alarm! Run back up the street — defenders chase you to the yard mouth."
		elseif player:GetAttribute("DataLoaded") ~= true then
			text = "Loading your hideout..."
		elseif player:GetAttribute("Training") == true then
			text = "🏃 Training! You can go AFK, you'll keep getting faster. Press ESCAPE to hop off."
		elseif carried >= bag then
			text = "🎒 Bag full! Drop the loot on your warehouse's green DEPOSIT pad."
		elseif carried > 0 then
			text = "💰 Bring your loot to the green DEPOSIT pad in your warehouse (or keep stealing!)"
		elseif DayNight.isDaytime() then
			text = "☀️ Daytime: the owners are home and every house is locked. Upgrade or train until dark!"
		elseif getNumber("StoredCount", 0) == 0 then
			text = "🏠 Run down the street to a house, pick the lock and steal something!"
		else
			text = "🦝 Houses get harder down the street. Train on your treadmill to outrun the faster defenders!"
		end
		objective.Text = text
	end

	local function updateAlarm()
		local house = getString("AlarmHouse")
		alarmBanner.Visible = house ~= ""
		if house ~= "" then
			alarmText.Text = "🚨 ALARM AT THE " .. string.upper(house) .. "! 🚨"
			local guard = getString("AlarmGuard")
			alarmHint.Text = string.format("Get off the property before %s catch%s you!", if guard ~= "" then guard else "the guards", if guard ~= "" and string.sub(guard, -1) ~= "s" then "es" else "")
		end
	end

	for _, name in { "Income", "Carried", "BagCapacity", "StoredCount", "StorageCapacity", "Speed" } do
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
	local shownSeconds = -1
	local function updateClock(force: boolean?)
		local daytime = DayNight.isDaytime()
		local seconds = math.ceil(DayNight.getTimeLeft())
		if seconds == shownSeconds and not force then
			return
		end
		shownSeconds = seconds
		local countdown = string.format("%d:%02d", seconds // 60, seconds % 60)
		if daytime then
			clockTitle.Text = "☀️ DAYTIME · " .. countdown
			clockHint.Text = "Houses closed · restocking loot"
		else
			clockTitle.Text = "🌙 NIGHT · " .. countdown
			clockHint.Text = "Houses open · loot restocks at sunrise"
		end
		clock.BackgroundColor3 = if daytime then Theme.Day else Theme.Night
		-- Phase progress: how much of the night / daytime is still to come.
		local length = if daytime then Config.DayNight.DayLength else Config.DayNight.NightLength
		clockBarFill.Size = UDim2.fromScale(math.clamp(seconds / length, 0, 1), 1)
		clockBarFill.BackgroundColor3 = if daytime then Theme.GoldDark else Theme.CyanDark
	end
	Workspace:GetAttributeChangedSignal("Daytime"):Connect(function()
		updateClock(true)
		updateObjective()
	end)
	player:GetAttributeChangedSignal("Training"):Connect(updateObjective)
	player:GetAttributeChangedSignal("Cash"):Connect(function()
		targetCash = getNumber("Cash", 0)
	end)

	updateStats()
	updateObjective()
	updateAlarm()
	updateClock(true)

	local pulse = 0
	RunService.RenderStepped:Connect(function(dt: number)
		-- Count the cash up/down smoothly (and pop the panel when it moves).
		if displayedCash ~= targetCash then
			local difference = targetCash - displayedCash
			if math.abs(difference) < 1 then
				displayedCash = targetCash
			else
				displayedCash += difference * math.min(dt * 10, 1)
			end
			cashLabel.Text = Format.money(math.floor(displayedCash + 0.5))
		end
		-- Pulse the alarm banner.
		if alarmBanner.Visible then
			pulse += dt * 8
			alarmBanner.BackgroundColor3 = Color3.fromRGB(150 + math.floor(70 * math.abs(math.sin(pulse))), 20, 30)
		end
		updateClock()
	end)
	cashLabel.Text = Format.money(displayedCash)
	return { IndexButton = indexButton }
end

return Hud
