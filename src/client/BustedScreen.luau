--!strict
--[[
	BustedScreen
	------------
	The big red "BUSTED!" flash when a house guard (cat, dog or drone) catches
	you — a full-screen red vignette and a scale-popping headline while the
	server ragdolls the thief and returns recovered loot to its source spot.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Format = require(ReplicatedStorage.Shared.Format)
local UI = require(script.Parent.UI)

local BustedScreen = {}

local overlay: Frame? = nil
local title: TextLabel? = nil
local subtitle: TextLabel? = nil
local titleScale: UIScale? = nil
local bars: { Frame } = {}
local showId = 0

function BustedScreen.init(screen: ScreenGui)
	local frame: Frame = UI.new("Frame", {
		Name = "Busted",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(170, 0, 20),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 50,
		Parent = screen,
	}, {
		-- Vignette feel: darker at the edges, hottest behind the headline.
		UI.gradient(Color3.fromRGB(60, 0, 10), Color3.new(1, 1, 1)),
	})
	-- Police-light bars sliding in from the top and bottom.
	local topBar: Frame = UI.new("Frame", {
		Name = "TopBar",
		BackgroundColor3 = Color3.fromRGB(120, 0, 14),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0.16, 0),
		ZIndex = 50,
		Parent = frame,
	})
	local bottomBar: Frame = UI.new("Frame", {
		Name = "BottomBar",
		BackgroundColor3 = Color3.fromRGB(120, 0, 14),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0.16, 0),
		ZIndex = 50,
		Parent = frame,
	})
	bars = { topBar, bottomBar }
	title = UI.new("TextLabel", {
		Name = "Title",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.5, 0.42),
		Size = UDim2.fromScale(0.8, 0.2),
		Font = UI.Theme.TitleFont,
		Text = "BUSTED!",
		TextColor3 = Color3.new(1, 1, 1),
		TextScaled = true,
		TextStrokeTransparency = 0,
		TextStrokeColor3 = Color3.fromRGB(80, 0, 0),
		ZIndex = 51,
		Parent = frame,
	})
	local scale = Instance.new("UIScale")
	scale.Name = "Pop"
	scale.Parent = title
	titleScale = scale
	subtitle = UI.new("TextLabel", {
		Name = "Subtitle",
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(0.5, 0.54),
		Size = UDim2.fromScale(0.8, 0.07),
		Font = UI.Theme.BoldFont,
		Text = "",
		TextColor3 = Color3.fromRGB(255, 230, 230),
		TextScaled = true,
		TextStrokeTransparency = 0.4,
		ZIndex = 51,
		Parent = frame,
	})
	overlay = frame
end

function BustedScreen.show(lostCount: number, lostValue: number, houseName: string, catcher: string?, outcome: string?)
	local frame, titleLabel, subtitleLabel = overlay, title, subtitle
	if not frame or not titleLabel or not subtitleLabel then
		return
	end
	showId += 1
	local myId = showId

	local who = catcher or "A guard"
	local location = if outcome == "door" then "threw you through the front door" elseif outcome == "road" then "caught you on the road" else "caught you"
	local recovery = if outcome == "door" then "and returned them to their original loot spots." else "and is returning them to their original loot spots."
	subtitleLabel.Text = if lostCount > 0
		then string.format(
			"%s at the %s %s! It recovered %d item%s worth %s %s",
			who,
			houseName,
			location,
			lostCount,
			if lostCount == 1 then "" else "s",
			Format.money(lostValue),
			recovery
		)
		else string.format("%s at the %s %s! Good thing your bag was empty.", who, houseName, location)

	frame.Visible = true
	frame.BackgroundTransparency = 0.25
	for _, bar in bars do
		bar.BackgroundTransparency = 0.55
	end
	titleLabel.TextTransparency = 0
	subtitleLabel.TextTransparency = 0
	titleLabel.Rotation = -8
	UI.tween(titleLabel, 0.35, { Rotation = 0 }, Enum.EasingStyle.Back)
	-- The headline pops in from small to oversized, then settles.
	local pop = titleScale
	if pop then
		pop.Scale = 0.5
		UI.tween(pop, 0.4, { Scale = 1 }, Enum.EasingStyle.Back)
	end
	UI.playSound(UI.Sounds.Busted, 0.8, 1)

	task.delay(2.6, function()
		if showId ~= myId then
			return
		end
		UI.tween(frame, 0.5, { BackgroundTransparency = 1 })
		for _, bar in bars do
			UI.tween(bar, 0.5, { BackgroundTransparency = 1 })
		end
		UI.tween(titleLabel, 0.5, { TextTransparency = 1 })
		UI.tween(subtitleLabel, 0.5, { TextTransparency = 1 })
		task.wait(0.55)
		if showId == myId then
			frame.Visible = false
		end
	end)
end

return BustedScreen
