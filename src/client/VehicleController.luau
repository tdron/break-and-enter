--!strict
--[[
	VehicleController
	-----------------
	Drives your getaway car while you sit in its DriverSeat. The server gives
	the driver network ownership, so the car responds instantly.

	Controls: W/S or Up/Down = throttle, A/D or Left/Right = steer
	(gamepads and the mobile thumbstick work too, through the default
	Roblox vehicle controls that fill in VehicleSeat.ThrottleFloat/SteerFloat).

	It's an arcade hover car: a raycast keeps it floating at a fixed height
	above whatever is below it, and a LinearVelocity pushes it around.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local VehicleController = {
	Driving = false,
	Speed = 0,
}

local player = Players.LocalPlayer
local currentSeat: VehicleSeat? = nil
local yaw = 0
local speed = 0

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true
rayParams.IgnoreWater = true

local function yawOf(cf: CFrame): number
	local look = cf.LookVector
	return math.atan2(-look.X, -look.Z)
end

local function approach(current: number, target: number, maxDelta: number): number
	if math.abs(target - current) <= maxDelta then
		return target
	end
	return current + math.sign(target - current) * maxDelta
end

local function stopDriving()
	currentSeat = nil
	speed = 0
	VehicleController.Driving = false
	VehicleController.Speed = 0
end

local function step(dt: number)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local seat = if humanoid then humanoid.SeatPart else nil
	if not (character and seat and seat:IsA("VehicleSeat") and seat.Name == "DriverSeat") then
		if currentSeat then
			stopDriving()
		end
		return
	end

	local car = seat.Parent
	if not (car and car:IsA("Model")) then
		return
	end
	local chassis = car.PrimaryPart
	if not chassis then
		return
	end
	local drive = chassis:FindFirstChild("Drive")
	local orient = chassis:FindFirstChild("Orient")
	if not (drive and drive:IsA("LinearVelocity") and orient and orient:IsA("AlignOrientation")) then
		return
	end

	if currentSeat ~= seat then
		currentSeat = seat
		yaw = yawOf(chassis.CFrame)
		speed = 0
		rayParams.FilterDescendantsInstances = { car, character }
	end

	local settings = Config.Vehicle
	local maxSpeedAttribute = car:GetAttribute("MaxSpeed")
	local maxSpeed = if type(maxSpeedAttribute) == "number" then maxSpeedAttribute else 45
	local throttle = seat.ThrottleFloat
	local steer = seat.SteerFloat

	-- Don't keep "imaginary" speed after crashing into something.
	local forward = CFrame.Angles(0, yaw, 0).LookVector
	local actual = chassis.AssemblyLinearVelocity:Dot(forward)
	if math.abs(speed) > math.abs(actual) + 8 then
		speed = actual + math.sign(speed) * 8
	end

	local target = 0
	if throttle > 0 then
		target = throttle * maxSpeed
	elseif throttle < 0 then
		target = throttle * maxSpeed * settings.ReverseFactor
	end
	local rate = settings.Acceleration
	if throttle == 0 then
		rate = settings.Coast
	elseif math.abs(speed) > 1 and math.sign(throttle) ~= math.sign(speed) then
		rate = settings.Braking
	end
	speed = approach(speed, target, rate * dt)

	-- Steering gets stronger as you speed up (and flips when reversing, like a real car).
	local turnFactor = math.clamp(math.abs(speed) / 14, 0, 1)
	local direction = if speed >= 0 then 1 else -1
	yaw -= steer * settings.TurnRate * turnFactor * direction * dt
	local rotation = CFrame.Angles(0, yaw, 0)
	orient.CFrame = rotation
	forward = rotation.LookVector

	-- Hover a fixed height above the ground.
	local origin = chassis.Position
	local hit = Workspace:Raycast(origin + Vector3.new(0, 2, 0), Vector3.new(0, -(settings.HoverHeight + 16), 0), rayParams)
	local verticalSpeed: number
	if hit then
		local desiredY = hit.Position.Y + settings.HoverHeight
		verticalSpeed = math.clamp((desiredY - origin.Y) * 8, -60, 35)
	else
		verticalSpeed = math.max(chassis.AssemblyLinearVelocity.Y - Workspace.Gravity * dt, -90)
	end

	drive.VectorVelocity = forward * speed + Vector3.new(0, verticalSpeed, 0)
	VehicleController.Driving = true
	VehicleController.Speed = math.abs(speed)
end

function VehicleController.init()
	RunService.Heartbeat:Connect(step)
end

return VehicleController
