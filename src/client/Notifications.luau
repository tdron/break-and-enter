--!strict
--[[
	Notifications
	-------------
	Toast messages that slide in on the right side of the screen.
]]

local UI = require(script.Parent.UI)

local Notifications = {}

local MAX_TOASTS = 5
local LIFETIME = 4.5

local KIND_COLORS: { [string]: Color3 } = {
	info = UI.Theme.Blue,
	success = UI.Theme.Green,
	error = UI.Theme.Red,
	money = UI.Theme.Gold,
	warning = UI.Theme.Orange,
	steal = UI.Theme.Purple,
	level = UI.Theme.Cyan,
}

local container: Frame? = nil
local order = 0
local toasts: { Frame } = {}

function Notifications.init(screen: ScreenGui)
	container = UI.new("Frame", {
		Name = "Notifications",
		-- Top-centre, under the alarm banner (the top-right is where Roblox shows the leaderboard).
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 88),
		Size = UDim2.fromOffset(440, 400),
		BackgroundTransparency = 1,
		Parent = screen,
	}, {
		UI.new("UIListLayout", {
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
		}),
		UI.scaled(),
	})
end

local function playKindSound(kind: string)
	local sounds = UI.Sounds
	if kind == "steal" then
		UI.playSound(sounds.Steal, 0.6, 1.1)
	elseif kind == "money" or kind == "success" then
		UI.playSound(sounds.Deposit, 0.5, 1.5)
	elseif kind == "error" then
		UI.playSound(sounds.Error, 0.4, 1.2)
	elseif kind == "level" then
		UI.playSound(sounds.LevelUp, 0.5, 1.3)
	elseif kind == "warning" then
		UI.playSound(sounds.Click, 0.5, 0.8)
	end
end

local function removeToast(toast: Frame)
	local index = table.find(toasts, toast)
	if index then
		table.remove(toasts, index)
	end
	if toast.Parent then
		toast:Destroy()
	end
end

function Notifications.show(text: string, kind: string?)
	local parent = container
	if not parent then
		return
	end
	local kindName = kind or "info"
	local color = KIND_COLORS[kindName] or UI.Theme.Blue
	order += 1

	local label: TextLabel = UI.new("TextLabel", {
		Name = "Message",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(16, 0),
		Size = UDim2.new(1, -16, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = UI.Theme.BoldFont,
		Text = text,
		TextColor3 = UI.Theme.Text,
		TextSize = 17,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	})

	local toast: Frame = UI.new("Frame", {
		Name = "Toast",
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = UI.Theme.Panel,
		BackgroundTransparency = 0.05,
		LayoutOrder = order,
		Parent = parent,
	}, {
		UI.corner(10),
		UI.stroke(color, 2),
		UI.padding(10),
		UI.new("Frame", {
			Name = "Accent",
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Size = UDim2.new(0, 5, 1, 0),
		}, { UI.corner(3) }),
		label,
	})
	table.insert(toasts, toast)
	while #toasts > MAX_TOASTS do
		removeToast(toasts[1])
	end
	playKindSound(kindName)

	task.delay(LIFETIME, function()
		if not toast.Parent then
			return
		end
		UI.tween(toast, 0.35, { BackgroundTransparency = 1 })
		UI.tween(label, 0.35, { TextTransparency = 1 })
		local stroke = toast:FindFirstChildOfClass("UIStroke")
		if stroke then
			UI.tween(stroke, 0.35, { Transparency = 1 })
		end
		task.wait(0.4)
		removeToast(toast)
	end)
end

return Notifications
