--!strict
--[[
	Steal an Item — client entry point
	==================================
	Builds the HUD, shop, loot index and effects, follows the day/night clock and
	listens to the server's remotes.
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
for _, name in { "Notify", "Busted", "Purchase", "SpawnCar", "Treadmill" } do
	remotesFolder:WaitForChild(name)
end

local BustedScreen = require(script.BustedScreen)
local DayNight = require(script.DayNight)
local Hud = require(script.Hud)
local LootIndex = require(script.LootIndex)
local Notifications = require(script.Notifications)
local Shop = require(script.Shop)
local TreadmillController = require(script.TreadmillController)
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
DayNight.init()
Shop.init(screen)
LootIndex.init(screen)
local hud = Hud.init(screen, {
	OnShop = function()
		LootIndex.close()
		Shop.toggle()
	end,
	OnSpawnCar = function()
		task.spawn(requestCar)
	end,
	OnIndex = function()
		Shop.close()
		LootIndex.toggle()
	end,
})
LootIndex.attachBadge(hud.IndexButton)
BustedScreen.init(screen)
VehicleController.init()
TreadmillController.init(screen)
WorldEffects.init()

updateScale()
local camera = Workspace.CurrentCamera
if camera then
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
end

Remotes.Notify.OnClientEvent:Connect(function(text: string, kind: string?)
	Notifications.show(text, kind)
end)

Remotes.Busted.OnClientEvent:Connect(function(lostCount: number, lostValue: number, houseName: string, catcher: string?)
	Shop.close()
	LootIndex.close()
	BustedScreen.show(lostCount, lostValue, houseName, catcher)
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
	if who == player and prompt.Name == "OpenShopPrompt" then
		LootIndex.close()
		Shop.open()
	end
end)

-- Hide owner-only prompts (selling from someone else's shelves, their car trunk, upgrading
-- their treadmill) for everyone else.
ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
	local ownerUserId = prompt:GetAttribute("OwnerUserId")
	if ownerUserId ~= nil and ownerUserId ~= player.UserId then
		prompt.Enabled = false
	end
end)
