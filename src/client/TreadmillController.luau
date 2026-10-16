--!strict
--[[
	TreadmillController
	-------------------
	Your personal treadmill (outside your warehouse), client side:
	  * Walk onto the belt and your character starts running by itself. You're
	    held in place on the belt, your movement keys are switched off and the
	    run animation loops, so you can go AFK. The server hands out the speed.
	  * The ESCAPE button (keybind: Space, or A on a gamepad) hops you off
	    beside the treadmill. Walk back on to start running again.
	  * A floating "YOUR TREADMILL" sign helps you find it.

	The server (Treadmills.luau) decides whether you're really training. If it
	stops you (you died, got moved away, ...) you're hopped off here too.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Notifications = require(script.Parent.Notifications)
local UI = require(script.Parent.UI)

local TreadmillController = {}

local player = Players.LocalPlayer
local Theme = UI.Theme

local ESCAPE_ACTION = "StealAnItemTreadmillEscape"
local CONFIRM_TIMEOUT = 5 -- seconds to wait for the server to confirm before giving up
local HOLD_FORCE = 100000
local HOLD_TORQUE = 100000
local HINT_COOLDOWN = 6
-- Used if the character has no Animate script to borrow its run animation from.
local DEFAULT_RUN_R15 = "rbxassetid://507767714"
local DEFAULT_RUN_R6 = "rbxassetid://180426354"

type Mount = {
	Character: Model,
	Humanoid: Humanoid,
	Root: BasePart,
	Treadmill: Model,
	Constraints: { Instance },
	Track: AnimationTrack?,
	TrackSpeed: number,
	AutoRotate: boolean,
	JumpEnabled: boolean,
	Confirmed: boolean,
	StartedAt: number,
}

local mount: Mount? = nil
local mountCount = 0
local armed = true -- false after hopping off until you step off the belt
local cooldownUntil = 0
local hintAt = -math.huge
local controls: any = nil

local allTreadmills: { Model } = {}

local escapeFrame: Frame? = nil
local keyCap: TextLabel? = nil
local escapeLabel: TextLabel? = nil
local signGui: BillboardGui? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
-- Every warehouse's treadmill (found once the map has loaded).
local function getTreadmills(): { Model }
	if #allTreadmills > 0 then
		return allTreadmills
	end
	local map = Workspace:FindFirstChild("Map")
	local warehouses = if map then map:FindFirstChild("Warehouses") else nil
	if warehouses then
		for _, plot in warehouses:GetChildren() do
			local treadmill = plot:FindFirstChild("Treadmill")
			if treadmill and treadmill:IsA("Model") then
				table.insert(allTreadmills, treadmill)
			end
		end
	end
	return allTreadmills
end

local function getMyTreadmill(): Model?
	local index = player:GetAttribute("PlotIndex")
	if type(index) ~= "number" then
		return nil
	end
	local map = Workspace:FindFirstChild("Map")
	local warehouses = if map then map:FindFirstChild("Warehouses") else nil
	local plot = if warehouses then warehouses:FindFirstChild("Plot" .. index) else nil
	local treadmill = if plot then plot:FindFirstChild("Treadmill") else nil
	return if treadmill and treadmill:IsA("Model") then treadmill else nil
end

local function getPart(model: Model, name: string): BasePart?
	local part = model:FindFirstChild(name)
	return if part and part:IsA("BasePart") then part else nil
end

-- True when `position` (the character's root) is above the treadmill's belt.
local function isOnBelt(treadmill: Model, position: Vector3): boolean
	local belt = getPart(treadmill, "Belt")
	if not belt then
		return false
	end
	local relative = belt.CFrame:PointToObjectSpace(position)
	local half = belt.Size / 2
	return math.abs(relative.X) <= half.X + 0.25 and math.abs(relative.Z) <= half.Z and relative.Y >= 0 and relative.Y <= 7
end

local function treadmillLevel(): number
	local level = player:GetAttribute("Level_Treadmill")
	return if type(level) == "number" then level else 1
end

local function runAnimationSpeed(): number
	local settings = Config.Treadmill
	return settings.RunAnimSpeedBase + (treadmillLevel() - 1) * settings.RunAnimSpeedPerLevel
end

-- The default PlayerModule's controls, used to switch movement off while you run.
local function getControls(): any
	if controls ~= nil then
		return controls
	end
	local playerScripts = player:FindFirstChild("PlayerScripts")
	local module = if playerScripts then playerScripts:FindFirstChild("PlayerModule") else nil
	if module and module:IsA("ModuleScript") then
		local ok, result = pcall(function()
			return (require :: any)(module):GetControls()
		end)
		if ok then
			controls = result
		end
	end
	return controls
end

local function setControlsEnabled(enabled: boolean)
	local found = getControls()
	if found then
		pcall(function()
			if enabled then
				found:Enable()
			else
				found:Disable()
			end
		end)
	end
end

-- Borrows the character's own run animation (so animation packs work), with a fallback.
local function loadRunTrack(character: Model, humanoid: Humanoid): AnimationTrack?
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local animation: Animation? = nil
	local animate = character:FindFirstChild("Animate")
	local runFolder = if animate then animate:FindFirstChild("run") else nil
	if runFolder then
		animation = runFolder:FindFirstChildWhichIsA("Animation")
	end
	if not animation then
		local fallback = Instance.new("Animation")
		fallback.Name = "TreadmillRun"
		fallback.AnimationId = if humanoid.RigType == Enum.HumanoidRigType.R15 then DEFAULT_RUN_R15 else DEFAULT_RUN_R6
		animation = fallback
	end
	local ok, track = pcall(function()
		return animator:LoadAnimation(animation :: Animation)
	end)
	if not ok or not track then
		return nil
	end
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	return track
end

local function invokeServer(action: string): (boolean, string)
	local ok, result = pcall(function()
		return ReplicatedStorage.Remotes.Treadmill:InvokeServer(action)
	end)
	if ok and type(result) == "table" then
		return result.Ok == true, tostring(result.Message or "")
	end
	return false, "Couldn't reach the server. Try again!"
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
local function updateEscapeButton()
	local frame = escapeFrame
	if not frame then
		return
	end
	frame.Visible = mount ~= nil
	local cap, label = keyCap, escapeLabel
	if cap and label then
		local key = if UserInputService.KeyboardEnabled
			then "SPACE"
			elseif UserInputService.GamepadEnabled then "A"
			else nil
		cap.Visible = key ~= nil
		cap.Text = key or ""
		label.Size = if key then UDim2.new(1, -104, 1, 0) else UDim2.fromScale(1, 1)
	end
	if signGui then
		signGui.Enabled = mount == nil
	end
end

local function createEscapeButton(screen: ScreenGui)
	local frame: Frame = UI.new("Frame", {
		Name = "TreadmillEscape",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -140),
		Size = UDim2.fromOffset(280, 62),
		BackgroundTransparency = 1,
		Visible = false,
		Parent = screen,
	}, { UI.scaled() })
	local button: TextButton = UI.new("TextButton", {
		Name = "EscapeButton",
		AutoButtonColor = true,
		BackgroundColor3 = Theme.Red,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		ZIndex = 2,
		Parent = frame,
	}, {
		UI.corner(18),
		UI.stroke(Color3.new(1, 1, 1), 2.5, 0.25),
		UI.gloss(),
	})
	escapeLabel = UI.new("TextLabel", {
		Name = "Label",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(18, 0),
		Size = UDim2.new(1, -108, 1, 0),
		Font = Theme.TitleFont,
		Text = "ESCAPE",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 28,
		TextXAlignment = Enum.TextXAlignment.Left,
		ZIndex = 3,
		Parent = button,
	})
	keyCap = UI.new("TextLabel", {
		Name = "Key",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(84, 38),
		BackgroundColor3 = Color3.fromRGB(50, 10, 16),
		BackgroundTransparency = 0.15,
		Font = Theme.BoldFont,
		Text = "SPACE",
		TextColor3 = Color3.new(1, 1, 1),
		TextSize = 18,
		ZIndex = 3,
		Parent = button,
	}, {
		UI.corner(10),
		UI.stroke(Color3.new(1, 1, 1), 1.5, 0.35),
	})
	UI.bounce(button)
	button.Activated:Connect(function()
		UI.playSound(UI.Sounds.Click, 0.4, 1.4)
		TreadmillController.hopOff()
	end)
	escapeFrame = frame
end

-- "YOUR TREADMILL" sign over your own treadmill (hidden while you're on it).
local function attachSign()
	if signGui then
		signGui:Destroy()
		signGui = nil
	end
	local treadmill = getMyTreadmill()
	local belt = if treadmill then getPart(treadmill, "Belt") else nil
	if not belt then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "MyTreadmillSign"
	gui.Size = UDim2.fromOffset(230, 70)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 9, 0)
	gui.MaxDistance = 70
	gui.LightInfluence = 0
	gui.Adornee = belt
	gui.Parent = belt
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromScale(1, 0.58)
	title.Font = Theme.TitleFont
	title.Text = "🏃 YOUR TREADMILL"
	title.TextScaled = true
	title.TextColor3 = Theme.Cyan
	title.TextStrokeTransparency = 0.2
	title.Parent = gui
	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.BackgroundTransparency = 1
	subtitle.Position = UDim2.fromScale(0, 0.58)
	subtitle.Size = UDim2.fromScale(1, 0.42)
	subtitle.Font = Theme.BoldFont
	subtitle.Text = "Walk on to train speed (AFK works!)"
	subtitle.TextScaled = true
	subtitle.TextColor3 = Color3.new(1, 1, 1)
	subtitle.TextStrokeTransparency = 0.3
	subtitle.Parent = gui
	signGui = gui
	updateEscapeButton()
end

--------------------------------------------------------------------------------
-- Getting on and off
--------------------------------------------------------------------------------
local function onEscapeInput(_actionName: string, state: Enum.UserInputState, _input: InputObject): Enum.ContextActionResult?
	if state == Enum.UserInputState.Begin then
		TreadmillController.hopOff()
	end
	return Enum.ContextActionResult.Sink
end

-- Puts your character back to normal. `stepOff` moves you beside the treadmill.
local function release(stepOff: boolean)
	local current = mount
	if not current then
		return
	end
	mount = nil
	ContextActionService:UnbindAction(ESCAPE_ACTION)
	for _, instance in current.Constraints do
		instance:Destroy()
	end
	if current.Track then
		current.Track:Stop(0.2)
	end
	local humanoid = current.Humanoid
	humanoid.AutoRotate = current.AutoRotate
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, current.JumpEnabled)
	setControlsEnabled(true)

	local root = current.Root
	local exitPoint = getPart(current.Treadmill, "ExitPoint")
	local alive = current.Character.Parent ~= nil and humanoid.Health > 0 and humanoid.SeatPart == nil
	if stepOff and alive and exitPoint and root.Parent then
		local target = exitPoint.Position
		root.CFrame = CFrame.new(target.X, math.max(root.Position.Y, target.Y), target.Z) * exitPoint.CFrame.Rotation
		root.AssemblyLinearVelocity = Vector3.zero
	end

	armed = false
	cooldownUntil = os.clock() + Config.Treadmill.RemountCooldown
	updateEscapeButton()
	-- Always tell the server (it's a no-op there if it already stopped you).
	task.spawn(invokeServer, "Stop")
end

local function getOn(treadmill: Model, character: Model, humanoid: Humanoid, root: BasePart)
	local runPoint = getPart(treadmill, "RunPoint")
	if not runPoint then
		return
	end
	mountCount += 1
	local myMount = mountCount

	-- Hold the character over the middle of the belt, facing the console. Only
	-- sideways forces, so the humanoid still stands on the belt normally.
	local attachment = Instance.new("Attachment")
	attachment.Name = "TreadmillAttachment"
	attachment.Parent = root
	local hold = Instance.new("AlignPosition")
	hold.Name = "TreadmillHold"
	hold.Mode = Enum.PositionAlignmentMode.OneAttachment
	hold.Attachment0 = attachment
	hold.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	hold.ForceRelativeTo = Enum.ActuatorRelativeTo.World
	hold.MaxAxesForce = Vector3.new(HOLD_FORCE, 0, HOLD_FORCE)
	hold.MaxVelocity = 40
	hold.Responsiveness = 60
	hold.Position = Vector3.new(runPoint.Position.X, root.Position.Y, runPoint.Position.Z)
	hold.Parent = root
	local facing = Instance.new("AlignOrientation")
	facing.Name = "TreadmillFacing"
	facing.Mode = Enum.OrientationAlignmentMode.OneAttachment
	facing.Attachment0 = attachment
	facing.MaxTorque = HOLD_TORQUE
	facing.Responsiveness = 40
	facing.CFrame = runPoint.CFrame.Rotation
	facing.Parent = root

	local current: Mount = {
		Character = character,
		Humanoid = humanoid,
		Root = root,
		Treadmill = treadmill,
		Constraints = { hold, facing, attachment },
		Track = loadRunTrack(character, humanoid),
		TrackSpeed = runAnimationSpeed(),
		AutoRotate = humanoid.AutoRotate,
		JumpEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping),
		Confirmed = false,
		StartedAt = os.clock(),
	}
	mount = current

	humanoid.AutoRotate = false
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
	setControlsEnabled(false)
	if current.Track then
		current.Track:Play(0.25)
		current.Track:AdjustSpeed(current.TrackSpeed)
	end
	ContextActionService:BindActionAtPriority(
		ESCAPE_ACTION,
		onEscapeInput,
		false,
		Enum.ContextActionPriority.High.Value,
		Enum.KeyCode.Space,
		Enum.KeyCode.ButtonA
	)
	updateEscapeButton()

	task.spawn(function()
		local ok, message = invokeServer("Start")
		if mount ~= current or mountCount ~= myMount then
			return -- already hopped off
		end
		if not ok then
			release(false)
			Notifications.show(message ~= "" and message or "Couldn't start training. Try again!", "error")
		elseif player:GetAttribute("Training") == true then
			current.Confirmed = true
		end
	end)
end

-- Hops off the treadmill (what the ESCAPE button and Space do).
function TreadmillController.hopOff()
	release(true)
end

function TreadmillController.isRunning(): boolean
	return mount ~= nil
end

local function step()
	local current = mount
	local character = player.Character
	if current then
		local humanoid = current.Humanoid
		if current.Character ~= character or current.Root.Parent == nil or humanoid.Health <= 0 then
			release(false)
		elseif humanoid.SeatPart ~= nil or humanoid.Sit then
			release(false)
		elseif not current.Confirmed and os.clock() - current.StartedAt > CONFIRM_TIMEOUT then
			release(false)
			Notifications.show("Couldn't start training. Try again!", "error")
		else
			local speed = runAnimationSpeed()
			if current.Track and speed ~= current.TrackSpeed then
				current.TrackSpeed = speed
				current.Track:AdjustSpeed(speed)
			end
		end
		return
	end

	if not character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and root and root:IsA("BasePart")) or humanoid.Health <= 0 or humanoid.SeatPart ~= nil then
		return
	end

	local mine = getMyTreadmill()
	if not (mine and isOnBelt(mine, root.Position)) then
		armed = true -- stepped off: walking back on starts you running again
		local now = os.clock()
		if now - hintAt > HINT_COOLDOWN then
			for _, treadmill in getTreadmills() do
				if treadmill ~= mine and isOnBelt(treadmill, root.Position) then
					hintAt = now
					Notifications.show(
						if mine
							then "🏃 That's someone else's treadmill. Yours is outside your own warehouse!"
							else "🏃 You need a warehouse to have a treadmill.",
						"info"
					)
					break
				end
			end
		end
		return
	end
	if armed and os.clock() >= cooldownUntil and player:GetAttribute("DataLoaded") == true then
		getOn(mine, character, humanoid, root)
	end
end

function TreadmillController.init(screen: ScreenGui)
	createEscapeButton(screen)
	player:GetAttributeChangedSignal("PlotIndex"):Connect(attachSign)
	task.spawn(attachSign)

	player:GetAttributeChangedSignal("Training"):Connect(function()
		local current = mount
		if not current then
			return
		end
		if player:GetAttribute("Training") == true then
			current.Confirmed = true
		elseif current.Confirmed then
			release(false) -- the server stopped your training
		end
	end)
	player.CharacterAdded:Connect(function()
		release(false)
	end)
	RunService.Heartbeat:Connect(step)
end

return TreadmillController
