--!strict
--[[
	Steal an Item — server entry point
	==================================
	Boots every gameplay module and wires up the player lifecycle.

	  PlayerData  saving/loading + attributes the UI reads
	  Inventory   the loot you're carrying
	  Plots       personal warehouses (storage = passive income)
	  DayNight    the 5½-minute heist clock (night = steal, daytime = houses closed + restock)
	  Houses      lockpicking, loot, alarms, chases, guard defenders, lasers
	  Treadmills  each warehouse's personal (AFK-able, upgradable) treadmill
	  Economy     income ticks + the upgrade shop
	  Market      the sell point stall in the yard (loot -> cash on the spot)
]]

local Players = game:GetService("Players")

local DayNight = require(script.DayNight)
local Economy = require(script.Economy)
local Houses = require(script.Houses)
local Inventory = require(script.Inventory)
local Market = require(script.Market)
local Notify = require(script.Notify)
local PlayerData = require(script.PlayerData)
local Plots = require(script.Plots)
local Rebirth = require(script.Rebirth)
local Treadmills = require(script.Treadmills)

Plots.init()
DayNight.init()
Houses.init()
Treadmills.init()
Economy.init()
Market.init()
Rebirth.init()
PlayerData.start()

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.WalkSpeed = PlayerData.getWalkSpeed(player)
	end
	Inventory.refresh(player)

	-- Safety net: if the player didn't spawn at their warehouse (e.g. they joined
	-- before their plot was assigned), move them there.
	local root = character:WaitForChild("HumanoidRootPart", 10)
	local target = Plots.getSpawnCFrame(player)
	if root and root:IsA("BasePart") and target and (root.Position - target.Position).Magnitude > 60 then
		task.wait(0.25)
		if character.Parent then
			character:PivotTo(target)
		end
	end
end

local function onPlayerAdded(player: Player)
	-- Assign a warehouse right away so the first spawn happens there.
	Plots.assign(player)
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)

	local session = PlayerData.load(player)
	if not player.Parent then
		PlayerData.release(player)
		return
	end

	Plots.refresh(player)
	Inventory.refresh(player)
	PlayerData.applyWalkSpeed(player)
	player:SetAttribute("DataLoaded", true)

	if not Plots.getPlot(player) then
		Notify.send(player, "All 6 warehouses are taken on this server. Drop loot on any DEPOSIT pad to sell it for cash.", "warning")
	end
	if not session.CanSave then
		Notify.send(player, "⚠️ " .. PlayerData.getSaveWarning(), "warning")
	end
	Notify.send(player, "Welcome to Steal an Item! 🦝 Rob houses, stash loot in your warehouse, get rich.", "info")
end

local function onPlayerRemoving(player: Player)
	Houses.onPlayerRemoving(player)
	Treadmills.onPlayerRemoving(player)
	Economy.onPlayerRemoving(player)
	Rebirth.onPlayerRemoving(player)
	Plots.release(player)
	PlayerData.release(player) -- saves (yields), so it goes last
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
