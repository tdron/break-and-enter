--!strict
--[[
	BustedScreen
	------------
	The big red "BUSTED!" flash when a house guard (cat, dog or drone) catches you.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Format = require(ReplicatedStorage.Shared.Format)
local UI = require(script.Parent.UI)

local BustedScreen = {}

local overlay: Frame? = nil
local title: TextLabel? = nil
local subtitle: TextLabel? = nil
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
	})
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

function BustedScreen.show(lostCount: number, lostValue: number, houseName: string, catcher: string?)
	local frame, titleLabel, subtitleLabel = overlay, title, subtitle
	if not frame or not titleLabel or not subtitleLabel then
		return
	end
	showId += 1
	local myId = showId

	local who = catcher or "A guard"
	subtitleLabel.Text = if lostCount > 0
		then string.format(
			"%s at the %s caught you! You dropped %d item%s worth %s.",
			who,
			houseName,
			lostCount,
			if lostCount == 1 then "" else "s",
			Format.money(lostValue)
		)
		else string.format("%s at the %s caught you! Good thing your bag was empty.", who, houseName)

	frame.Visible = true
	frame.BackgroundTransparency = 0.25
	titleLabel.TextTransparency = 0
	subtitleLabel.TextTransparency = 0
	titleLabel.Rotation = -8
	UI.tween(titleLabel, 0.35, { Rotation = 0 }, Enum.EasingStyle.Back)
	UI.playSound(UI.Sounds.Busted, 0.8, 1)

	task.delay(2.6, function()
		if showId ~= myId then
			return
		end
		UI.tween(frame, 0.5, { BackgroundTransparency = 1 })
		UI.tween(titleLabel, 0.5, { TextTransparency = 1 })
		UI.tween(subtitleLabel, 0.5, { TextTransparency = 1 })
		task.wait(0.55)
		if showId == myId then
			frame.Visible = false
		end
	end)
end

return BustedScreen
