--!strict
--[[
	WalkCycle
	---------
	The deliberately choppy walk every defender with legs does while it is moving.

	A real walk gets a new pose every frame; this one only strikes a new pose
	Config.Walk.FramesPerSecond times a second and holds it in between, so the limbs click from
	one position to the next like stop-motion animation. The speed the body is *actually* moving
	(measured by Houses from its position, so shoving it against a wall stops the walk) sets how
	fast the stride cycles, within Config.Walk's limits.

	The limbs come from Guards (GuardModel.Limbs): each one is a Motor6D that swings a leg around
	the hip it was pinned to, and Base is the resting pose the leg stands in. A defender with no
	limbs (a drone that hovers, a car that rolls) simply has nothing to animate, so it is given no
	cycle at all.
]]

local Config = require(script.Parent.Config)

local WalkCycle = {}

export type Limb = {
	Joint: Motor6D, -- swings its part around the pivot (Part0 = the physics root)
	Base: CFrame, -- the joint's resting C0: the standing pose
	Phase: number, -- 0 or 0.5: the opposite leg of a pair is half a stride behind
}

export type Cycle = {
	Limbs: { Limb },
	Time: number, -- seconds piled up since the last pose was struck
	Phase: number, -- where in the stride we are (0..1 cycles)
	Moving: boolean, -- are the legs stepping right now?
	Poses: number, -- poses struck since it started moving (tests read this)
}

local TAU = math.pi * 2

-- Strides per second at this speed: the body covers Config.Walk.Stride studs per stride, so the
-- legs keep up with the ground it is covering - up to the point where that would look silly,
-- which is what MaxRate is for.
function WalkCycle.strideRate(speed: number): number
	local rate = math.abs(speed) / Config.Walk.Stride
	return math.clamp(rate, Config.Walk.MinRate, Config.Walk.MaxRate)
end

function WalkCycle.new(limbs: { Limb }): Cycle
	return {
		Limbs = limbs,
		Time = 0,
		Phase = 0,
		Moving = false,
		Poses = 0,
	}
end

-- Back to standing: every limb returns to the pose it was pinned in. That is the "not moving"
-- state, so it is also what a defender snapped back into place gets.
function WalkCycle.rest(cycle: Cycle)
	for _, limb in cycle.Limbs do
		limb.Joint.C0 = limb.Base
	end
	cycle.Time = 0
	cycle.Phase = 0
	cycle.Moving = false
end

-- One pose: every limb is placed by the same stride position at the same instant (the limbs
-- themselves are offset by their Phase, which is what makes the legs alternate). Because the
-- whole defender moves to the new pose in the same frame it reads as stop-motion rather than as
-- a leg wobbling on its own.
local function strike(cycle: Cycle)
	local swing = math.rad(Config.Walk.Swing)
	for _, limb in cycle.Limbs do
		local angle = math.sin((cycle.Phase + limb.Phase) * TAU) * swing
		limb.Joint.C0 = limb.Base * CFrame.Angles(angle, 0, 0)
	end
	cycle.Poses += 1
end

-- Called every frame: dt is the frame time, speed how fast the defender is really moving along
-- the ground (studs/s). Slower than Config.Walk.MoveThreshold counts as standing still.
function WalkCycle.update(cycle: Cycle, dt: number, speed: number)
	if #cycle.Limbs == 0 then
		return
	end
	if math.abs(speed) < Config.Walk.MoveThreshold then
		if cycle.Moving then
			WalkCycle.rest(cycle)
		end
		return
	end
	cycle.Moving = true
	cycle.Time += dt
	local frameTime = 1 / Config.Walk.FramesPerSecond
	local advance = WalkCycle.strideRate(speed) * frameTime
	-- A long stall (a hitch, or a defender teleported by the server) never unloads a burst of
	-- poses in one frame: it just catches up at the normal rate.
	local poses = math.min(math.floor(cycle.Time / frameTime), Config.Walk.MaxCatchUp)
	if poses < 1 then
		return
	end
	cycle.Time -= poses * frameTime
	for _ = 1, poses do
		cycle.Phase = (cycle.Phase + advance) % 1
		strike(cycle)
	end
end

return WalkCycle
