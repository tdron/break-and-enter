--!strict
--[[
	Steal an Item — client entry point
	==================================
	Builds the HUD, shop and effects, and listens to the server's remotes.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- Make sure the shared modules and remotes have replicated before using them.
local sharedFolder = ReplicatedStorage:WaitForChild("Shared")
for _, name in { "Config", "Items", "ItemModels", "Format" } do
	sharedFolder:WaitForChild(name)
end
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
for _, name in { "Notify", "Busted", "Purchase", "SpawnCar" } do
	remotesFolder:WaitForChild(name)
end

local BustedScreen = require(script.BustedScreen)
local Hud = require(script.Hud)
local Notifications = require(script.Notifications)
local Shop = require(script.Shop)
local UI = require(script.UI)
local VehicleController = require(script.VehicleController)
local WorldEffects = require(script.WorldEffects)

local Remotes = ReplicatedStorage.Remotes

local screen = Instance.new("ScreenGui")
screen.Name = "StealAnItemHUD"
screen.ResetOnSpawn = false
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = playerGui

-- Scale the whole HUD down on small screens (phones) and up a bit on big ones.
local function updateScale()
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	local viewport = camera.ViewportSize
	UI.setScale(math.clamp(math.min(viewport.X / 1280, viewport.Y / 760), 0.55, 1.1))
end

local spawnBusy = false
local function requestCar()
	if spawnBusy then
		return
	end
	spawnBusy = true
	local ok, result = pcall(function()
		return Remotes.SpawnCar:InvokeServer()
	end)
	spawnBusy = false
	if ok and type(result) == "table" then
		Notifications.show(tostring(result.Message), if result.Ok == true then "success" else "error")
	else
		Notifications.show("Couldn't reach your mechanic. Try again!", "error")
	end
end

Notifications.init(screen)
Shop.init(screen)
Hud.init(screen, {
	OnShop = Shop.toggle,
	OnSpawnCar = function()
		task.spawn(requestCar)
	end,
})
BustedScreen.init(screen)
VehicleController.init()
WorldEffects.init()

updateScale()
local camera = Workspace.CurrentCamera
if camera then
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

Remotes.Notify.OnClientEvent:Connect(function(text: string, kind: string?)
	Notifications.show(text, kind)
end)

Remotes.Busted.OnClientEvent:Connect(function(lostCount: number, lostValue: number, houseName: string)
	Shop.close()
	BustedScreen.show(lostCount, lostValue, houseName)
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
	if who == player and prompt.Name == "OpenShopPrompt" then
		Shop.open()
	end
end)

-- Hide owner-only prompts (selling from someone else's shelves, their car trunk) for everyone else.
ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
	local ownerUserId = prompt:GetAttribute("OwnerUserId")
	if ownerUserId ~= nil and ownerUserId ~= player.UserId then
		prompt.Enabled = false
	end
end)
