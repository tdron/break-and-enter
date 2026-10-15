--!strict
--[[
	DayNight
	--------
	Runs the heist clock (every number is in Config.DayNight):
	  * NIGHT (3½ min): every house is open for business.
	  * DAYTIME (30 s): the owners are home. Houses lock up, alarms end, anyone
	    still inside is shown the door, and EVERY house restocks its loot.
	    This is the only time loot comes back, once per 4-minute cycle.

	Clients read the phase from Workspace attributes to fade the sky and show a
	countdown:
	  Daytime      boolean
	  PhaseEndsAt  Workspace:GetServerTimeNow() when the current phase ends
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Notify = require(script.Parent.Notify)

local DayNight = {}

local daytime = false
local phaseEndsAt = 0
local listeners: { (isDaytime: boolean) -> () } = {}

function DayNight.isDaytime(): boolean
	return daytime
end

-- Seconds until the current phase ends.
function DayNight.getTimeLeft(): number
	return math.max(0, phaseEndsAt - Workspace:GetServerTimeNow())
end

-- Calls `callback(isDaytime)` every time the phase changes.
function DayNight.onChanged(callback: (isDaytime: boolean) -> ())
	table.insert(listeners, callback)
end

local function setPhase(isDaytime: boolean)
	daytime = isDaytime
	local length = if isDaytime then Config.DayNight.DayLength else Config.DayNight.NightLength
	phaseEndsAt = Workspace:GetServerTimeNow() + length
	Workspace:SetAttribute("Daytime", isDaytime)
	Workspace:SetAttribute("PhaseEndsAt", phaseEndsAt)
	for _, callback in listeners do
		task.spawn(callback, isDaytime)
	end
	if isDaytime then
		Notify.all(
			string.format(
				"☀️ Daytime! The owners are home, so every house is locked for %d seconds while the loot restocks.",
				Config.DayNight.DayLength
			),
			"warning"
		)
	else
		Notify.all("🌙 Night falls! Every house is fully restocked and open. Go steal!", "info")
	end
end

-- Skips straight to the next phase (handy for testing in Studio's command bar).
function DayNight.advance()
	setPhase(not daytime)
end

function DayNight.init()
	daytime = false
	phaseEndsAt = Workspace:GetServerTimeNow() + Config.DayNight.NightLength
	Workspace:SetAttribute("Daytime", false)
	Workspace:SetAttribute("PhaseEndsAt", phaseEndsAt)
	task.spawn(function()
		while true do
			-- Wake up a few times a second so DayNight.advance() can shift the schedule.
			task.wait(0.25)
			if Workspace:GetServerTimeNow() >= phaseEndsAt then
				setPhase(not daytime)
			end
		end
	end)
end

return DayNight
