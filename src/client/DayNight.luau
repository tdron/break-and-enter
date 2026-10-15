--!strict
--[[
	DayNight (client)
	-----------------
	Follows the server's heist clock (Workspace attributes Daytime and
	PhaseEndsAt, see server/DayNight) and fades the sky between the night and
	daytime lighting presets in Config.DayNight. The clock always moves
	forward, so night -> day is a sunrise and day -> night is a sunset.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)

local DayNight = {}

type Snapshot = Config.LightingPreset

local fadeFrom: Snapshot? = nil
local fadeTo: Snapshot = Config.DayNight.Night
local fadeStartedAt = 0
local fading = false

function DayNight.isDaytime(): boolean
	return Workspace:GetAttribute("Daytime") == true
end

-- Seconds until the current phase (night or daytime) ends.
function DayNight.getTimeLeft(): number
	local endsAt = Workspace:GetAttribute("PhaseEndsAt")
	if type(endsAt) ~= "number" then
		return 0
	end
	return math.max(0, endsAt - Workspace:GetServerTimeNow())
end

local function atmosphere(): Atmosphere?
	return Lighting:FindFirstChildOfClass("Atmosphere")
end

local function capture(): Snapshot
	local current = atmosphere()
	return {
		ClockTime = Lighting.ClockTime,
		Brightness = Lighting.Brightness,
		ExposureCompensation = Lighting.ExposureCompensation,
		Ambient = Lighting.Ambient,
		OutdoorAmbient = Lighting.OutdoorAmbient,
		FogColor = Lighting.FogColor,
		AtmosphereColor = if current then current.Color else fadeTo.AtmosphereColor,
		AtmosphereDecay = if current then current.Decay else fadeTo.AtmosphereDecay,
	}
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function apply(from: Snapshot, to: Snapshot, t: number)
	-- Always move the clock forward so the sun rises in the east and sets in the west.
	local forward = (to.ClockTime - from.ClockTime) % 24
	Lighting.ClockTime = (from.ClockTime + forward * t) % 24
	Lighting.Brightness = lerp(from.Brightness, to.Brightness, t)
	Lighting.ExposureCompensation = lerp(from.ExposureCompensation, to.ExposureCompensation, t)
	Lighting.Ambient = from.Ambient:Lerp(to.Ambient, t)
	Lighting.OutdoorAmbient = from.OutdoorAmbient:Lerp(to.OutdoorAmbient, t)
	Lighting.FogColor = from.FogColor:Lerp(to.FogColor, t)
	local current = atmosphere()
	if current then
		current.Color = from.AtmosphereColor:Lerp(to.AtmosphereColor, t)
		current.Decay = from.AtmosphereDecay:Lerp(to.AtmosphereDecay, t)
	end
end

local function targetPreset(): Snapshot
	return if DayNight.isDaytime() then Config.DayNight.Day else Config.DayNight.Night
end

local function startFade()
	fadeFrom = capture()
	fadeTo = targetPreset()
	fadeStartedAt = os.clock()
	fading = true
end

function DayNight.init()
	-- Jump straight to the current phase when you join, then fade on every change.
	fadeTo = targetPreset()
	apply(capture(), fadeTo, 1)
	Workspace:GetAttributeChangedSignal("Daytime"):Connect(startFade)
	RunService.RenderStepped:Connect(function()
		local from = fadeFrom
		if not fading or not from then
			return
		end
		local t = math.clamp((os.clock() - fadeStartedAt) / Config.DayNight.FadeTime, 0, 1)
		local eased = t * t * (3 - 2 * t)
		apply(from, fadeTo, eased)
		if t >= 1 then
			fading = false
		end
	end)
end

return DayNight
