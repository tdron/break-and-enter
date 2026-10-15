--!strict
--[[
	Treadmills
	----------
	Run on a treadmill at the Gym to earn speed XP. Every speed level adds +1
	walk speed, which is how you outrun the faster security drones in the
	fancier houses. The Pro and Elite treadmills train much faster but must be
	unlocked in the shop.

	Map layout expected: Workspace.Map.Gym.Treadmills.<Model>
	  (attribute TreadmillType = "Basic" | "Pro" | "Elite", with a "Belt" part)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Notify = require(script.Parent.Notify)
local PlayerData = require(script.Parent.PlayerData)

type Treadmill = {
	Model: Model,
	Belt: BasePart,
	Settings: Config.Treadmill,
}

local TICK = 0.2

local Treadmills = {}

local treadmills: { Treadmill } = {}
local lockedNoticeAt: { [Player]: number } = {}
local maxedNoticeAt: { [Player]: number } = {}

local function isOnBelt(belt: BasePart, position: Vector3): boolean
	local relative = belt.CFrame:PointToObjectSpace(position)
	local half = belt.Size / 2
	return math.abs(relative.X) <= half.X + 0.3 and math.abs(relative.Z) <= half.Z + 0.3 and relative.Y >= 0 and relative.Y <= 6
end

local function isUnlocked(player: Player, treadmill: Treadmill): boolean
	local unlock = treadmill.Settings.Unlock
	return unlock == nil or PlayerData.getUpgradeLevel(player, unlock) >= 2
end

local function trainPlayer(player: Player): string
	local character = player.Character
	if not character or not PlayerData.get(player) then
		return ""
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not (root and root:IsA("BasePart") and humanoid) or humanoid.Health <= 0 or humanoid.SeatPart then
		return ""
	end

	for _, treadmill in treadmills do
		if isOnBelt(treadmill.Belt, root.Position) then
			local now = os.clock()
			if not isUnlocked(player, treadmill) then
				if (lockedNoticeAt[player] or 0) < now then
					lockedNoticeAt[player] = now + 4
					Notify.send(player, "🔒 The " .. treadmill.Settings.DisplayName .. " is locked. Unlock it in the Shop!", "error")
				end
				return ""
			end
			-- You have to actually run! Standing still lets the belt carry you backwards at belt
			-- speed, while running keeps you in place. Checking the velocity works even if
			-- MoveDirection isn't replicated to the server.
			local beltForward = treadmill.Belt.CFrame.LookVector
			local forwardSpeed = root.AssemblyLinearVelocity:Dot(beltForward)
			local running = humanoid.MoveDirection.Magnitude > 0.1
				or forwardSpeed > -treadmill.Settings.BeltSpeed * 0.5
			if not running then
				return ""
			end
			if player:GetAttribute("SpeedMaxed") == true then
				if (maxedNoticeAt[player] or 0) < now then
					maxedNoticeAt[player] = now + 10
					Notify.send(player, "⚡ You're already at MAX speed. Go rob the Mansion!", "level")
				end
				return ""
			end
			local gained = PlayerData.addSpeedXP(player, treadmill.Settings.XPPerSecond * TICK)
			if gained > 0 then
				Notify.send(
					player,
					string.format("⚡ Speed up! Your walk speed is now %d", PlayerData.getWalkSpeed(player)),
					"level"
				)
			end
			return treadmill.Settings.DisplayName
		end
	end
	return ""
end

local function loop()
	while true do
		task.wait(TICK)
		for _, player in Players:GetPlayers() do
			local training = trainPlayer(player)
			if player:GetAttribute("Training") ~= training then
				player:SetAttribute("Training", training)
			end
		end
	end
end

function Treadmills.onPlayerRemoving(player: Player)
	lockedNoticeAt[player] = nil
	maxedNoticeAt[player] = nil
end

function Treadmills.init()
	local map = Workspace:WaitForChild("Map")
	local gym = map:WaitForChild("Gym")
	local folder = gym:WaitForChild("Treadmills")
	for _, model in folder:GetChildren() do
		if model:IsA("Model") then
			local key = model:GetAttribute("TreadmillType")
			local settings = if type(key) == "string" then Config.Treadmills[key] else nil
			local belt = model:FindFirstChild("Belt")
			if settings and belt and belt:IsA("BasePart") then
				-- A moving conveyor: the belt pushes you backwards while you run forwards.
				belt.AssemblyLinearVelocity = -belt.CFrame.LookVector * settings.BeltSpeed
				table.insert(treadmills, { Model = model, Belt = belt, Settings = settings })
			else
				warn("[Treadmills] Skipping " .. model:GetFullName() .. " (missing TreadmillType or Belt)")
			end
		end
	end
	task.spawn(loop)
end

return Treadmills
