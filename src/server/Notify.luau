--!strict
--[[
	Notify
	------
	Sends toast notifications to a player's screen.
	Kinds: "info", "success", "error", "money", "warning", "steal", "level"
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local NotifyEvent = ReplicatedStorage.Remotes.Notify

local Notify = {}

function Notify.send(player: Player, text: string, kind: string?)
	if player.Parent then
		NotifyEvent:FireClient(player, text, kind or "info")
	end
end

function Notify.all(text: string, kind: string?)
	NotifyEvent:FireAllClients(text, kind or "info")
end

return Notify
