--!strict
--[[
	Steal an Item — client entry point
	==================================
	Builds the HUD, shop, loot index, storage, sell point and effects, follows the
	day/night clock and listens to the server's remotes.
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
for _, name in { "Notify", "Busted", "Purchase", "Treadmill", "Storage", "Sell", "Rebirth" } do
	remotesFolder:WaitForChild(name)
end

local BustedScreen = require(script.BustedScreen)
local DayNight = require(script.DayNight)
local Hud = require(script.Hud)
local LootIndex = require(script.LootIndex)
local Notifications = require(script.Notifications)
local Rebirth = require(script.Rebirth)
local SellPoint = require(script.SellPoint)
local Shop = require(script.Shop)
local Storage = require(script.Storage)
local TreadmillController = require(script.TreadmillController)
local UI = require(script.UI)
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

Notifications.init(screen)
DayNight.init()
Shop.init(screen)
LootIndex.init(screen)
Rebirth.init(screen)
Storage.init(screen)
SellPoint.init(screen)

-- Only one window is ever open at a time.
local function closeWindows(keep: string?)
	if keep ~= "Shop" then
		Shop.close()
	end
	if keep ~= "Index" then
		LootIndex.close()
	end
	if keep ~= "Storage" then
		Storage.close()
	end
	if keep ~= "Sell" then
		SellPoint.close()
	end
	if keep ~= "Rebirth" then
		Rebirth.close()
	end
end

local hud = Hud.init(screen, {
	OnShop = function()
		closeWindows("Shop")
		Shop.toggle()
	end,
	OnStorage = function()
		closeWindows("Storage")
		Storage.toggle()
	end,
	OnIndex = function()
		closeWindows("Index")
		LootIndex.toggle()
	end,
})
LootIndex.attachBadge(hud.IndexButton)
BustedScreen.init(screen)
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
	closeWindows()
	BustedScreen.show(lostCount, lostValue, houseName, catcher)
end)

-- Prompts in the world open their window: the market stall's shop counter, the
-- trader's counter opposite it, the rebirth shrine, and the shelf prompts in your
-- own warehouse.
ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
	if who ~= player then
		return
	end
	if prompt.Name == "OpenShopPrompt" then
		closeWindows("Shop")
		Shop.open()
	elseif prompt.Name == "OpenSellPrompt" then
		closeWindows("Sell")
		SellPoint.open()
	elseif prompt.Name == "OpenRebirthPrompt" then
		closeWindows("Rebirth")
		Rebirth.open()
	elseif prompt.Name == "ShelfPrompt" then
		closeWindows("Storage")
		Storage.open()
	end
end)

-- Hide owner-only prompts (selling from someone else's shelves, upgrading their treadmill)
-- for everyone else.
ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
	local ownerUserId = prompt:GetAttribute("OwnerUserId")
	if ownerUserId ~= nil and ownerUserId ~= player.UserId then
		prompt.Enabled = false
	end
end)
