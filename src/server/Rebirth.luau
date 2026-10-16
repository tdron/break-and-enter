--!strict
--[[
	Rebirth
	-------
	Trade every speed point you have trained for a permanent production
	multiplier (treadmill training AND warehouse income, see Config.Rebirth).

	* The shrine beside the market hall (OpenRebirthPrompt) opens the client
	  window - the prompt itself is only a doorbell.
	* A rebirth costs Config.rebirthCost(count) speed points (1M, 1.75M, 3.06M, ...)
	  raises Profile.Rebirths by one, and sets your speed back to zero. The
	  multiplier itself is applied inside PlayerData (the treadmill's addSpeed
	  and the recalculateIncome totals), so this module only owns the trade.
	* All state on Remotes.Rebirth: "State" (or anything else) hands back the
	  player's rebirth info table, "Buy" attempts the rebirth.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local PlayerData = require(script.Parent.PlayerData)

local Rebirth = {}

-- One click per second per player is plenty for something this final.
local lastBuy: { [Player]: number } = {}

export type RebirthState = {
	Ok: boolean,
	Rebirths: number,
	Multiplier: number,
	NextMultiplier: number,
	Cost: number,
	SpeedPoints: number,
	CanAfford: boolean,
}

function Rebirth.state(player: Player): RebirthState
	local rebirths = PlayerData.getRebirths(player)
	local cost = Config.rebirthCost(rebirths)
	local points = PlayerData.getSpeedPoints(player)
	return {
		Ok = true,
		Rebirths = rebirths,
		Multiplier = Config.rebirthMultiplier(rebirths),
		NextMultiplier = Config.rebirthMultiplier(rebirths + 1),
		Cost = cost,
		SpeedPoints = points,
		CanAfford = points >= cost,
	}
end

function Rebirth.try(player: Player): (boolean, string)
	local session = PlayerData.get(player)
	if not session then
		return false, "Still loading your data..."
	end
	local now = os.clock()
	if (lastBuy[player] or 0) + 1.0 > now then
		return false, "Slow down!"
	end

	local rebirths = session.Profile.Rebirths
	local cost = Config.rebirthCost(rebirths)
	local points = PlayerData.getSpeedPoints(player)
	if points < cost then
		return false, string.format(
			"🔁 You need %s more speed! Keep running that treadmill.",
			Format.short(cost - points)
		)
	end

	-- The classic trade: everything you trained, for a permanent boost.
	lastBuy[player] = now
	session.Profile.Rebirths = rebirths + 1
	PlayerData.setSpeedPoints(player, 0)
	PlayerData.recalculateIncome(player) -- income now shows the new multiplier
	PlayerData.replicate(player)
	return true,
		string.format(
			"🔁 REBIRTH #%d! Everything you train and earn is x%s from now on — your speed starts from 0.",
			rebirths + 1,
			Format.decimal(Config.rebirthMultiplier(rebirths + 1), 2)
		)
end

local function addShrinePrompt()
	local map = Workspace:WaitForChild("Map")
	local shrine = map:FindFirstChild("RebirthShrine", true)
	if not (shrine and shrine:IsA("BasePart")) then
		warn("[Rebirth] No RebirthShrine part found in the map; the shrine is where players open the window.")
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "OpenRebirthPrompt"
	prompt.ActionText = "Rebirth"
	prompt.ObjectText = "🔁 REBIRTH SHRINE"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = Config.Rebirth.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = shrine
end

function Rebirth.onPlayerRemoving(player: Player)
	lastBuy[player] = nil
end

function Rebirth.init()
	local remote = ReplicatedStorage.Remotes.Rebirth
	remote.OnServerInvoke = function(player: Player, action: any)
		if action == "Buy" then
			local ok, message = Rebirth.try(player)
			return { Ok = ok, Message = message }
		end
		return Rebirth.state(player)
	end
	addShrinePrompt()
end

return Rebirth
