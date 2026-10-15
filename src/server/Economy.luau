--!strict
--[[
	Economy
	-------
	* Pays every player their warehouse income once per second.
	* Handles upgrade purchases from the shop (validated on the server).
	* Adds the "Browse Upgrades" prompt to the shop counter in the hub.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local PlayerData = require(script.Parent.PlayerData)
local Plots = require(script.Parent.Plots)
local Vehicles = require(script.Parent.Vehicles)

local Economy = {}

local lastPurchase: { [Player]: number } = {}

local function applyUpgrade(player: Player, upgradeId: string)
	PlayerData.replicate(player)
	if upgradeId == "Storage" then
		Plots.refresh(player)
	elseif upgradeId == "Engine" then
		Vehicles.onEngineUpgraded(player)
	elseif upgradeId == "Trunk" then
		Vehicles.updateLabel(player)
	end
	-- "Treadmill": Treadmills notices the new level by itself (its console updates every tick).
end

function Economy.purchase(player: Player, upgradeId: any): (boolean, string)
	if type(upgradeId) ~= "string" then
		return false, "Invalid upgrade."
	end
	local upgrade = Config.UpgradesById[upgradeId]
	if not upgrade then
		return false, "Unknown upgrade."
	end
	local session = PlayerData.get(player)
	if not session then
		return false, "Still loading your data..."
	end
	local now = os.clock()
	if (lastPurchase[player] or 0) + 0.2 > now then
		return false, "Slow down!"
	end
	lastPurchase[player] = now

	local level = session.Profile.Levels[upgradeId] or 1
	if level >= #upgrade.Values then
		return false, upgrade.DisplayName .. " is already maxed out!"
	end
	local cost = upgrade.Costs[level + 1]
	if not PlayerData.trySpend(player, cost) then
		return false, string.format("You need %s more cash!", Format.money(cost - session.Profile.Cash))
	end
	session.Profile.Levels[upgradeId] = level + 1
	applyUpgrade(player, upgradeId)

	return true,
		string.format(
			"%s %s upgraded to level %d (%s)!",
			upgrade.Icon,
			upgrade.DisplayName,
			level + 1,
			string.format(upgrade.Format, upgrade.Values[level + 1])
		)
end

local function addShopPrompt()
	local map = Workspace:WaitForChild("Map")
	local counter = map:FindFirstChild("ShopCounter", true)
	if not (counter and counter:IsA("BasePart")) then
		warn("[Economy] No ShopCounter part found; the shop is still available from the HUD button.")
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "OpenShopPrompt"
	prompt.ActionText = "Browse Upgrades"
	prompt.ObjectText = "Upgrade Shop"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = counter
end

local function incomeLoop()
	while true do
		task.wait(1)
		for _, player in Players:GetPlayers() do
			local session = PlayerData.get(player)
			if session and session.Income > 0 then
				PlayerData.addCash(player, session.Income)
			end
		end
	end
end

function Economy.onPlayerRemoving(player: Player)
	lastPurchase[player] = nil
end

function Economy.init()
	ReplicatedStorage.Remotes.Purchase.OnServerInvoke = function(player: Player, upgradeId: any)
		local ok, message = Economy.purchase(player, upgradeId)
		return { Ok = ok, Message = message }
	end
	addShopPrompt()
	task.spawn(incomeLoop)
end

return Economy
