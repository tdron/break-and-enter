--!strict
--[[
	Houses
	------
	The heist part of the game:
	  * Locked doors you open with a "Pick Lock" prompt (harder houses take longer).
	  * Every house has its own set of loot (see Items) that spawns on furniture.
	  * Stealing anything trips the alarm: after a short wind-up the house's
	    defenders give chase. Who lives where is Config.Houses / Config.Guards:
	    a tuxedo cat, then a puppy, a labrador, a guard dog, the home owner, an
	    off-duty officer, a wizard, a T-Rex, security bots and finally the museum's
	    fleet of security cars. Get caught = BUSTED: you ragdoll where you were
	    caught instead of teleporting to the warehouse. Inside, the defender throws
	    you through the front door into the road; outside, it recovers your loot
	    and heads home with it.
	  * They do NOT give up at the property line any more: they chase you all the
	    way back down the street and turn around at the canyon mouth, so the yard
	    is the only safe place. While anybody is on a property (you or them)
	    everyone moves at the standard Roblox speed; the moment you are through
	    the front gate the real speeds apply — yours from the treadmill, theirs
	    from Config.Guards.Speed (and the late-game ones are very, very fast).
	  * The hardest houses also have blinking laser tripwires.
	  * Defenders are physical: each one drags a collider the size of its body around and is
	    stopped by walls, doors and furniture like anybody else. They get where they are going
	    by feeling for the wall first (Workspace:Blockcast) and stepping off their straight
	    line round it, and if an opening is too small for them - the T-Rex is 5.6 studs wide,
	    the cars 5.3 - they take the roomiest way past instead of grinding in the doorway.
	  * Anything with legs walks there: a deliberately choppy stop-motion cycle (see
	    WalkCycle / Config.Walk) driven by how fast the body is really moving, so a defender
	    pinned against a wall stops stepping instead of moonwalking on the spot. Hoverers
	    (drones), rollers (the museum's fleet) and the tracked security bots get nothing.
	  * DAYTIME (see DayNight): houses lock up, anyone inside is shown the door
	    and every house restocks. That's the only time loot comes back.

	Map layout expected (built by tools/map_builder.py):
	  Workspace.Map.Houses.<HouseId>  (Model named after its Config.Houses id; attributes Tier & DisplayName)
	    Zone        Part covering the whole property (invisible)
	    ItemSpots   Folder of Parts marking where loot appears
	    GuardDocks  Folder of Parts where the guards rest (pet beds / drone pads)
	    Doors       Folder of Models: a "Hinge" part + door parts (attribute OpenAngle)
	    Lasers      Folder of Parts (attribute Phase)
	    Route       Folder of invisible markers (Door, Hall, the room vias, Gate, Street) that a
	                defender walks between: the doorways, and the way in off the street, so that
	                one crossing the house goes through the openings rather than at the walls
	                around them.
	    Rooms       Invisible boxes over each room, attribute Via naming the Route node that is
	                that room's way out, so "get to the thing in the next room" is answered with
	                a doorway rather than a straight line at the wall between them.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Guards = require(ReplicatedStorage.Shared.Guards)
local WalkCycle = require(ReplicatedStorage.Shared.WalkCycle)
local ItemModels = require(ReplicatedStorage.Shared.ItemModels)
local Items = require(ReplicatedStorage.Shared.Items)
local DayNight = require(script.Parent.DayNight)
local Inventory = require(script.Parent.Inventory)
local Notify = require(script.Parent.Notify)
local PlayerData = require(script.Parent.PlayerData)

local BustedEvent = ReplicatedStorage.Remotes.Busted

type Spot = {
	Part: BasePart,
	Item: Model?,
	ItemId: string?,
}

-- A stable, serialisable description of the exact world spot from which a bag
-- item came. Inventory keeps this alongside each carried item until it is sold,
-- deposited, or reclaimed during a bust.
type ReturnedLoot = {
	ItemId: string,
	HouseId: string,
	SpotId: string,
}

type Guard = {
	Look: Guards.GuardModel,
	Root: BasePart,
	AlignPosition: AlignPosition,
	AlignOrientation: AlignOrientation,
	Home: CFrame, -- where the root rests
	Filter: RaycastParams, -- the cast filter: a defender never feels its own body with it
	ProbeParams: RaycastParams, -- the same, plus whatever the body is standing on or leaning on (see probe)
	Hidden: { any }, -- that list, one entry per thing hidden: resets itself on every look at the way ahead
	Flying: boolean,
	State: string, -- "Idle" | "Windup" | "Chase"
	ActivateAt: number,
	Bob: number, -- phase offset for the trotting bounce
	Trot: number, -- how bouncy this kind of defender is (cars don't bounce)
	Walk: WalkCycle.Cycle, -- the stop-motion legs (no limbs: nothing steps)
	LastPosition: Vector3, -- where the body was last frame, for measuring its real speed
	Move: Vector3?, -- the line it is currently walking, if the last look at the way ahead is
	MoveClear: number, -- still usable ... and how far that line is clear
	MoveDetour: boolean, -- the cached line is a step off the straight line, not the line itself
	Sight: number, -- seconds that look at the way ahead stays good for, before it looks again
	SlideSide: number, -- -1 / 0 / 1: the side it stepped off on, so it commits to a way round
	Blocked: number, -- looks in a row that found the straight line blocked (see wayAhead)
	ClearLooks: number, -- looks in a row that found it clear, before it stops leaning to a side
	Stuck: number, -- seconds it has wanted to move without actually moving
	Sidestep: number,
	Sidestepped: boolean,
	Pinned: number,
	LastWay: Vector3?,
	Way: Vector3?, -- the doorway or gate it is making for, until it is through it (see routeTo) -- seconds left of walking sideways rather than forwards
	RecoveredLoot: { ReturnedLoot }, -- returned only once this specific catcher reaches home
	RecoveredSack: BasePart?, -- visible proof that the road catcher took the loot
}

type Door = {
	Model: Model,
	Spot: Vector3, -- the hinge: where a defender walking home has to be to be let in
	Prompt: ProximityPrompt,
	Angle: NumberValue,
	Slam: Sound,
	OpenAngle: number,
	IsOpen: boolean,
	CloseAt: number,
}

type House = {
	Model: Model,
	Id: string,
	Name: string,
	LootHouse: string, -- whose loot table to roll from (normally Id)
	Tier: number,
	Settings: Config.HouseTier,
	GuardId: string,
	GuardInfo: Config.GuardInfo,
	ZoneCFrame: CFrame,
	ZoneHalfSize: Vector3,
	FrontInset: number, -- how far the front wall sits inside the property
	GuardSpeed: number, -- the defenders' speed once they are out on the street
	ChaseMaxX: number, -- chases never go further east than this house's own property
	Loot: Folder,
	Spots: { Spot },
	SpotById: { [string]: Spot },
	Guards: { Guard },
	Doors: { Door },
	Route: { [string]: Vector3 }, -- the doorways to thread (Rooms.<name>.Via names one; see routeTo)
	Rooms: { BasePart }, -- invisible boxes over the floors, named after the room they cover
	Via: { [string]: Vector3 }, -- the doorway out of each room, by room name
	Lasers: { BasePart },
	AlarmActive: boolean,
	LastOccupiedAt: number,
	Intruders: { [Player]: boolean },
}

type Thief = { Player: Player, Root: BasePart, Humanoid: Humanoid }

type MotorState = { Motor: Motor6D, Enabled: boolean }
type PartState = { Part: BasePart, CanCollide: boolean }
type Ragdoll = {
	Humanoid: Humanoid,
	Motors: { MotorState },
	Parts: { PartState },
	Constraints: { Instance },
	AutoRotate: boolean,
	PlatformStand: boolean,
	RequiresNeck: boolean,
}

local FEET_BELOW_ROOT = 3 -- a standard character's HumanoidRootPart floats this high above its feet
local CATCH_HEIGHT = 7 -- guards can't reach thieves this far above/below them
local SLEEPING = "💤"
local ALERT = "❗"
-- How much each kind of defender bounces while it runs (its size sets the catch radius).
local TROT = { Cat = 0.4, Dog = 0.4, Beast = 0.55, Human = 0.12, Wizard = 0.12, Robot = 0, Vehicle = 0 }

local Houses = {}

local houses: { House } = {}
local housesById: { [string]: House } = {}
-- Declared up here because the alarm opens the front door before the door code is defined.
local setDoorOpen: (door: Door, open: boolean, slam: boolean?) -> ()
local restoreRecoveredLoot: (loot: { ReturnedLoot }) -> number
local updateRecoveredSack: (guard: Guard) -> ()
local rng = Random.new()
local bustedUntil: { [Player]: number } = {}
local laserCooldown: { [Player]: number } = {}
local ragdolls: { [Model]: Ragdoll } = {}

local function playerFromHit(hit: BasePart): Player?
	local model = hit:FindFirstAncestorOfClass("Model")
	if not model then
		return nil
	end
	return Players:GetPlayerFromCharacter(model)
end

local function isInZone(house: House, position: Vector3): boolean
	local relative = house.ZoneCFrame:PointToObjectSpace(position)
	local half = house.ZoneHalfSize
	return math.abs(relative.X) <= half.X and math.abs(relative.Y) <= half.Y and math.abs(relative.Z) <= half.Z
end

-- A point on the ground, in the property's own coordinates: +Z points from the house out to the street.
local function lotPoint(house: House, localX: number, localZ: number): Vector3
	local half = house.ZoneHalfSize
	return house.ZoneCFrame:PointToWorldSpace(Vector3.new(localX, -half.Y + FEET_BELOW_ROOT, localZ))
end

-- Is this position still inside the building (rather than out in the front yard)?
local function insideHouse(house: House, position: Vector3): boolean
	return house.ZoneCFrame:PointToObjectSpace(position).Z < house.ZoneHalfSize.Z - house.FrontInset
end

-- Where a defender on the wrong side of the front door heads for: the middle of the doorway
-- itself. Everything a defender has to get through is on the house's centre line - the doorway,
-- the porch, the path and the gate in the fence - so asking for the doorway is asking for the one
-- line it can walk out (or in) on, rather than a diagonal at a door jamb it does not fit past.
-- Returns nil when there is no door in the way, or when the body is already in it.
local function throughTheDoor(house: House, from: Vector3, target: Vector3): Vector3?
	local wall = house.ZoneHalfSize.Z - house.FrontInset
	local here = house.ZoneCFrame:PointToObjectSpace(from).Z
	local there = house.ZoneCFrame:PointToObjectSpace(target).Z
	if (here < wall) == (there < wall) then
		return nil
	end
	-- A stud past the wall, on the far side: aiming there puts the body in the opening, and once
	-- it is in it the straight line to where it is really going goes through the opening too.
	local doorway = lotPoint(house, 0, (if here < wall then wall + 1 else wall - 1))
	if (Vector3.new(from.X - doorway.X, 0, from.Z - doorway.Z)).Magnitude <= 2.5 then
		return nil
	end
	return doorway
end

-- How far a chase can go: this house's own property, plus the street from the front door
-- all the way back west to the canyon mouth. Inside the yard (past the mouth) it is over.
local function inChaseArea(house: House, position: Vector3): boolean
	if isInZone(house, position) then
		return true
	end
	if position.X < Config.Alarm.SafeX or position.X > house.ChaseMaxX then
		return false
	end
	return math.abs(position.Z) <= Config.Alarm.LaneHalfWidth
end

-- Keeps a chasing defender inside that area (but it is free to roam its own property).
local function clampToChase(house: House, position: Vector3): Vector3
	if isInZone(house, position) then
		return position
	end
	return Vector3.new(
		math.clamp(position.X, Config.Alarm.SafeX, house.ChaseMaxX),
		position.Y,
		math.clamp(position.Z, -Config.Alarm.LaneHalfWidth, Config.Alarm.LaneHalfWidth)
	)
end

-- Inside a property everybody moves at the standard Roblox speed: a defender only gets to use
-- its listed speed once it is out on the street (and so does the thief, with whatever the
-- treadmill has given them).
local function chaseSpeed(house: House, position: Vector3): number
	return if Houses.isOnProperty(position) then Config.Alarm.InsideSpeed else house.GuardSpeed
end

-- Big defenders (the T-Rex, the cars) catch you with their body, not their centre point.
local function catchRadius(guard: Guard): number
	local size = guard.Look.Size
	return math.max(Config.Alarm.CatchRadius, math.max(size.X, size.Z) * 0.5)
end

local function isImmune(player: Player, now: number): boolean
	return (bustedUntil[player] or 0) > now
end

--------------------------------------------------------------------------------
-- Walking there without walking through things
--
-- A defender with a body cannot be dragged at a wall: it would scrape along it for ever, or jam
-- in a doorway it does not fit through. So each one works out its own way forward, a fraction of
-- a second at a time, out of one question asked of the engine - "how far can I go this way?" -
-- with a block cast shaped like the body:

--   * straight on while the way is clear,
--   * the first small turn off that line which opens up real ground when it is not, preferring
--     the side it already leaned to so it commits to a way round instead of dithering, and
--   * the roomiest line of all when it is boxed in (a wall it cannot walk round, a doorway too
--     narrow for it), which is also what slides a corner along a wall rather than into it.

-- The cast is shaped like the body, not its centre: the root's own collider, so a corner can no
-- more be walked through than the wall on either side of it.

local WAYPOINT_REACHED = 3 -- close enough to a doorway to count as through it
local WAYPOINT_THROUGH = 3 -- how far past a doorway to aim, so a body walks through instead of at it
local HALL_ROOM = "Hall" -- the room every other one opens off, and the way to the street
local RETURN_RADIUS = 2.5 -- close enough to its bed to be home again (studs)
local DOOR_RADIUS = 12 -- how close a defender walking home has to be for a door to be opened for it
local STEP_UP = 1.4 -- the tallest step (porch stairs, kerb) a defender walks up in one move
local PROBE_HEIGHT = 9 -- how high the floor probe starts above the body
local SIGHT_TIME = 0.12 -- seconds a look at the way ahead stays good before it looks again
local FLOOR_NORMAL = 0.7 -- a surface facing up at least this steeply is a floor to walk on, not a wall
local HEAD_ON = 0.75 -- how squarely a body has to be facing a surface it is touching to be stopped by it
local TOUCHING = 0.05 -- a hit nearer than this is something the body is already up against
local PROBE_TRIES = 4 -- things a look at the way ahead may discount before it gives up and says clear
local SIDESTEP_TIME = 0.4 -- how long a body that gets nowhere walks sideways for (see updateGuards)
local SIDESTEP_REACH = 2.5 -- how far it tries to walk sideways (studs)
local ROAD_Z = 20 -- the middle of the pavement: where a defender off the street walks back to
local OFF_ROAD = 6 -- and how far off it has to be before walking back is what it should be doing
-- (the gateway itself sits on the property line, so the trigger has to clear it)
local STUCK_SPEED = 4 -- slower than this and a defender is not walking, it is shuffling at something
local AIM_CLOSE = 1.5 -- being this close to where it was told to go is arrival, not being stuck
local PINNED_TIME = 1.5 -- standing still this long at one of its own doorways is wedged on the frame
local SQUEEZE_STEP = 2.0 -- and that much of a step is enough to be through it

local function distance_of(aim: Vector3, from: Vector3): number
	local flat = Vector3.new(aim.X - from.X, 0, aim.Z - from.Z)
	return flat.Magnitude
end

local function halfExtent(guard: Guard, direction: Vector3): number
	local size = guard.Root.Size
	return math.abs(direction.X) * size.X * 0.5
		+ math.abs(direction.Y) * size.Y * 0.5
		+ math.abs(direction.Z) * size.Z * 0.5
end

-- How far ahead a defender looks: further at speed (or it steps into the wall it just found),
-- capped so even a security car does not probe across the whole map.
-- The floor this defender is standing over, from a ray dropped straight down from above its head.
-- Something at hip height (a table it has walked under, a fence rail) is not a floor, so anything
-- higher than a step above its feet is ignored. Returns the height of the surface to stand on.
local function floorBelow(guard: Guard, position: Vector3): number?
	local origin = Vector3.new(position.X, position.Y + PROBE_HEIGHT, position.Z)
	local hit = Workspace:Raycast(origin, Vector3.new(0, -(PROBE_HEIGHT + STEP_UP + 4), 0), guard.Filter)
	if not hit then
		return nil
	end
	if hit.Position.Y > position.Y - guard.Look.RootHeight + STEP_UP then
		return nil
	end
	return hit.Position.Y
end

local function lookahead(speed: number): number
	return math.min(Config.Alarm.WallLookahead + speed * Config.Alarm.WallLookaheadPerSpeed, Config.Alarm.WallLookaheadMax)
end

-- One block cast from the body, in place, pointed where it wants to go. The guard's own model is
-- filtered out of it (its body starts inside that, and everything else it wears is CanQuery =
-- false), so what it feels is the world: walls, doors, furniture, and the other defenders.
-- Returns how many studs are clear, and the surface normal only when something is really there.
local function probe(guard: Guard, direction: Vector3, length: number, at: Vector3?): (number, Vector3?)
	if length <= 0 then
		return 0, nil
	end
	local root = guard.Root
	-- `at` asks the same question from a point along the way ("if I got that far, what then?").
	local base = if at then root.CFrame + (at - root.Position) else root.CFrame
	-- A cast reports the *nearest* thing it meets, and a body is always already touching things:
	-- the floor under its feet, the wall its shoulder is against. Anything it is touching comes
	-- back as a hit at no distance at all, and answering that would say "wedged" whichever way it
	-- was asked - including the ways it can plainly walk. So whatever it turns out to be leaning
	-- on or standing in is taken out of the cast and the cast is asked again; that is also the
	-- only way to look past it, because the floor under a body's feet is under them the whole way
	-- along the line.
	local hidden = guard.Hidden
	for index = #hidden, 2, -1 do
		hidden[index] = nil
	end
	for _ = 1, PROBE_TRIES do
		local hit = Workspace:Blockcast(base, root.Size, direction * length, guard.ProbeParams)
		if not hit then
			return length, nil
		end
		local normal = hit.Normal
		if normal.Magnitude < 0.5 then
			return length, nil
		end
		local distance = math.clamp(hit.Distance, 0, length)
		local touching = distance < TOUCHING
		local floor = normal.Y > FLOOR_NORMAL
		local glancing = direction:Dot(normal) > -HEAD_ON
		-- Something it can walk over rather than up against: a kerb, the garden path, the lip of
		-- a step, the rise onto a porch. Whichever face of it a cast reports, a surface low
		-- enough to stand on is not a wall - and that is the whole point of asking at any
		-- distance, because a body walking *at* a low step hits the step's face studs before it
		-- gets there, which reads as a wall and has it working its way along the edge instead of
		-- stepping up onto it.
		local underfoot = false
		local part = hit.Instance
		if part and part:IsA("BasePart") then
			underfoot = part.Position.Y + part.Size.Y * 0.5 <= root.Position.Y - guard.Look.RootHeight + STEP_UP
		end
		local walkOver = underfoot or (touching and (floor or glancing))
		if walkOver and hit.Instance then
			table.insert(hidden, hit.Instance)
			continue
		end
		-- Facing it squarely (or something genuinely in the way further along the line).
		return distance, normal
	end
	return length, nil
end

-- The name of the room this position is standing in, or nothing when it is not in one of them
-- (outside, or on its way through a doorway). See House.Rooms.
local function roomOf(house: House, position: Vector3): string?
	for _, roomPart in house.Rooms do
		local relative = roomPart.CFrame:PointToObjectSpace(position)
		local half = roomPart.Size / 2
		if math.abs(relative.X) <= half.X and math.abs(relative.Y) <= half.Y and math.abs(relative.Z) <= half.Z then
			return roomPart.Name
		end
	end
	return nil
end

-- Where a defender should head for to reach `aim` from where it is.
--
-- Out in the open that is simply the aim, and so is anything in the same room - furniture in the
-- way of something in the same room is just furniture, and the steering walks round it. But the
-- walls between rooms are another matter: every room in a house opens off the hall, and the hall
-- onto the street, so the way to anything in another room is out of this room's doorway
-- (Rooms.<name>.Via, put there by the map), down the hall, and in through the other room's. That
-- is a route a body can walk - and one that never asks it to find its way through a wall.
-- A few studs past a waypoint, on the line the body is walking: a doorway is something to go
-- *through*, and a body that stops dead in the middle of one - or clips a jamb coming at it
-- side-on - turns a clean walk through into a scrape along the frame. Aiming through it walks it
-- through. (For an opening the body is already level with, this is just a nudge along.)
local function throughPoint(from: Vector3, node: Vector3): Vector3
	local offset = Vector3.new(node.X - from.X, 0, node.Z - from.Z)
	if offset.Magnitude < 1e-3 then
		return node
	end
	return node + offset.Unit * WAYPOINT_THROUGH
end

local function routeTo(house: House, guard: Guard, aim: Vector3): Vector3
	local from = guard.Root.Position
	-- A waypoint it has already picked stays picked until it is through it. Asking the room boxes
	-- again every frame is what has a body standing in a doorway dithering between the room it
	-- just left and the one it is walking into, one stud either side of the line between them.
	local way = guard.Way
	if way and distance_of(way, from) > WAYPOINT_REACHED then
		return throughPoint(from, way)
	end
	guard.Way = nil

	local here, there = roomOf(house, from), roomOf(house, aim)
	-- A defender that has been shoved off the street - over the kerb, round a lamp post, along
	-- the pickets - walks back onto it before anything else. The road is the one stretch of
	-- ground every way in and out of a lot runs along, and a body working its way along a garden
	-- fence instead is how it ends up stuck in the corner of somebody's yard with its own gate
	-- on the far side of the fence.
	if here == nil and not Houses.isOnProperty(from) and math.abs(from.Z) - ROAD_Z > OFF_ROAD then
		local off = math.abs(from.Z) - ROAD_Z
		if off > OFF_ROAD then
			local road = Vector3.new(from.X, from.Y, if from.Z < 0 then -ROAD_Z else ROAD_Z)
			return Vector3.new(road.X, road.Y, road.Z)
		end
	end
	-- Off the lot and going back to it (or on it and going off): the way in and out is the garden
	-- gate - the one gap in the front fence, in the middle of the path. Walking at the house
	-- across the front fence, or at the street across it, is how a body ends up pacing along the
	-- pickets for ever: the gate is on the house's centre line, and so is everything else it has
	-- to get through, so the way in and out of a lot is one straight line through the gate.
	if here == nil then
		local gate = house.Route.Gate
		local leaving = Houses.isOnProperty(from) and not Houses.isOnProperty(aim)
		local coming = not Houses.isOnProperty(from) and Houses.isOnProperty(aim)
		-- The way in or out of a lot. Leaving is the gateway and then the street; coming home it
		-- is the other way round, so that the walk in is made along the fence and the turn
		-- through the gateway happens square in front of it rather than across the pickets.
		--
		-- Which of the two a body coming home is walking to is decided by where it is, not by
		-- which one it has most recently been near: "the far one" is what has a body stepping
		-- over its own marker and straight back out to the marker it just left, for ever. Past
		-- the pavement marker the gateway is the nearer of the two, and that is the sign that
		-- the approach is done with and the way in is through the gate.
		local street = house.Route.Street
		if leaving then
			if distance_of(gate, from) > WAYPOINT_REACHED then
				guard.Way = gate
				return throughPoint(from, gate)
			end
		elseif coming then
			local approaching = street
				and distance_of(gate, from) > distance_of(gate, street)
				and distance_of(street, from) > WAYPOINT_REACHED
			if approaching then
				guard.Way = street
				return throughPoint(from, street)
			end
			if distance_of(gate, from) > WAYPOINT_REACHED then
				guard.Way = gate
				return throughPoint(from, gate)
			end
		end
		-- Out of doors and going indoors (the bed in its own room, the quarry in one of ours):
		-- in through the front door first. Its marker stands in the middle of the doorway - the
		-- door leaf is one more thing to walk round, and a body aimed at the middle of the
		-- opening has the room to do it - and the marker for the hall, the room every doorway
		-- opens off, stands a few studs inside it.
		if there ~= nil then
			local door, hall = house.Route.Door, house.Route.Hall
			if door and distance_of(door, from) > WAYPOINT_REACHED then
				guard.Way = door
				return throughPoint(from, door)
			end
			if hall and distance_of(hall, from) > WAYPOINT_REACHED then
				guard.Way = hall
				return throughPoint(from, hall)
			end
		end
	end
	if here == there then
		return aim
	end
	local goal = throughTheDoor(house, from, aim) or aim
	-- A room: its own way out is the doorway onto the hall. From the hall, the way on is the
	-- doorway of the room it is heading for. Out of doors there is nothing to thread - the door
	-- in the front wall is the aim (see throughTheDoor).
	local room = if here == HALL_ROOM then there elseif here ~= nil then here else nil
	local via = if room then house.Via[room] else nil
	if via and distance_of(via, from) > WAYPOINT_REACHED then
		guard.Way = via
		return throughPoint(from, via)
	end
	return goal
end

local function aroundTheCorner(guard: Guard, from: Vector3, aim: Vector3, direction: Vector3): (Vector3?, number?)
	local reach = lookahead(guard.AlignPosition.MaxVelocity or 0)
	local side = if guard.SlideSide ~= 0 then guard.SlideSide else 1
	local bestAlong: number? = nil
	local bestWay: Vector3? = nil
	for _, turn in { side, -side } do
		local turned = CFrame.Angles(0, math.rad(90 * turn), 0) * direction
		local clear = select(1, probe(guard, turned, reach * 3))
		for _, along in { 3, 6, 10, 16 } do
			if along <= clear and (bestAlong == nil or along < bestAlong) then
				local point = from + turned * along
				local toGoal = Vector3.new(aim.X - point.X, 0, aim.Z - point.Z)
				local left = toGoal.Magnitude
				local towards = if left > 0.1 then toGoal / left else direction
				-- Stepping sideways is a way round something; stepping *away* from where it is
				-- going is how a body that just follows clear ground ends up deeper in a dead end
				-- (behind a fence, in somebody's front yard) with nothing but walls left.
				if turned:Dot(towards) < -0.05 then
					continue
				end
				-- And the point has to have a line on to the goal, looked at far enough ahead
				-- that the wall it is stepping round shows up in the answer.
				if left > 0.1 and not select(2, probe(guard, towards, math.min(left, math.max(reach * 2, 24)), point)) then
					bestAlong, bestWay = along, turned
				end
			end
		end
	end
	if bestWay and bestAlong then
		guard.SlideSide = if bestWay:Dot(CFrame.Angles(0, math.rad(90), 0) * direction) > 0 then 1 else -1
		return bestWay, bestAlong
	end
	return nil
end

-- Which line to walk. The expensive half of steering, so it is asked for a few times a second at
-- most (see steer): a clear look costs one cast, and working out a way round costs several.
--
-- When the straight line is blocked the defender first looks for a one-turn detour (above), and
-- failing that goes *round*: it turns off its line the same way every time - the side it first
-- found room on - until something opens up, which is how anything with a body works its way
-- along a wall and round the end of it. Turning back the way it came as soon as that looks clear
-- too is what has it dithering in corners instead of getting anywhere.
local TURNS = { 30, 50, 70, 90, 110, 130, 150 }
local GIVE_UP = 60 -- blocked looks in a row before it tries going round the other way instead
local COMMITTED = 3 -- clear looks in a row before it stops leaning to that side

local function wayAhead(guard: Guard, direction: Vector3, aim: Vector3, from: Vector3): (Vector3, number, number, boolean)
	local reach = lookahead(guard.AlignPosition.MaxVelocity or 0)
	local clear, blocked = probe(guard, direction, reach)
	if not blocked then
		guard.Blocked = 0
		guard.ClearLooks += 1
		if guard.ClearLooks >= COMMITTED then
			guard.SlideSide = 0
		end
		return direction, clear, distance_of(aim, from) + 1, false
	end

	guard.ClearLooks = 0
	local corner, along = aroundTheCorner(guard, from, aim, direction)
	if corner and along then
		-- Round the corner and straight at it from there: walk exactly that far, then look again.
		return corner, along, along, true
	end

	guard.Blocked += 1
	if guard.Blocked > GIVE_UP then
		-- Been trying to get round something for a while now: it is probably the wrong way round.
		guard.Blocked, guard.SlideSide = 0, -guard.SlideSide
	end
	if guard.SlideSide == 0 then
		-- First look at this obstacle: lean to whichever side has the more room on it.
		local right = select(1, probe(guard, CFrame.Angles(0, math.rad(30), 0) * direction, reach))
		local left = select(1, probe(guard, CFrame.Angles(0, math.rad(-30), 0) * direction, reach))
		guard.SlideSide = if right >= left then 1 else -1
	end

	for _, degrees in TURNS do
		local turned = CFrame.Angles(0, math.rad(degrees * guard.SlideSide), 0) * direction
		local turnedClear, turnedBlocked = probe(guard, turned, reach)
		if not turnedBlocked then
			return turned, turnedClear, distance_of(aim, from) + 1, true
		end
	end
	-- Everything up to facing the other way is blocked too (a doorway it does not fit, a wall it
	-- has walked into side-on): press on at where it is going and let the body slide along
	-- whatever it meets. Walking off on the roomiest line found - which is usually straight back
	-- the way it came - is how a defender ends up pacing the same stretch of fence for ever;
	-- the dodge for a body that really is pinned is in updateGuards.
	return direction, clear, distance_of(aim, from) + 1, true
end

-- Where to drag this defender this frame to get it closer to `aim`. Returns a point rather than a
-- direction: defenders are moved by an AlignPosition, so the thing they are told is a place to go.
local function steer(guard: Guard, aim: Vector3, followFloor: boolean): Vector3
	local from = guard.Root.Position
	local flat = Vector3.new(aim.X - from.X, 0, aim.Z - from.Z)
	local distance = flat.Magnitude
	if distance < 0.05 then
		return aim
	end
	local direction = flat / distance

	-- Walking a line it has already checked costs no casts at all, so a settled defender only
	-- feels for the way ahead when the line has gone stale or no longer points at where it is
	-- going. (The body itself is what stops it if the line has quietly run out.) Staleness is
	-- counted in game seconds by updateGuards rather than read off the clock, so a defender
	-- behaves the same however many frames a second the server manages.
	local line = guard.Move
	local way, clear, ceiling
	if guard.Sidestep > 0 then
		-- A body that wants to be somewhere and cannot get there (see updateGuards) walks
		-- sideways along whatever is stopping it for a moment instead of pushing at it. This is
		-- the way round an engine that reports nothing at all about the thing it is against.
		local left = CFrame.Angles(0, math.rad(90), 0) * direction
		local right = CFrame.Angles(0, math.rad(-90), 0) * direction
		local leftClear, leftBlocked = probe(guard, left, SIDESTEP_REACH)
		local rightClear, rightBlocked = probe(guard, right, SIDESTEP_REACH)
		local side = guard.SlideSide
		if side == 0 then
			-- Both sides are usually open along a wall, so the one to take is the one that ends up
			-- closer to where it is going - along the wall towards the door, not away from it.
			local leftward = distance_of(aim, from + left * SIDESTEP_REACH)
			local rightward = distance_of(aim, from + right * SIDESTEP_REACH)
			side = if leftward <= rightward then 1 else -1
		end
		-- Unless the side it wanted is shut, in which case the other one: the whole point of the
		-- walk sideways is to find the way round, and the way round is the one that opens up.
		if side > 0 and leftBlocked and not rightBlocked then
			side = -1
		elseif side < 0 and rightBlocked and not leftBlocked then
			side = 1
		end
		guard.SlideSide = side
		way = if side > 0 then left else right
		clear, ceiling = if side > 0 then leftClear else rightClear, SIDESTEP_REACH
	elseif line and guard.Sight > 0 and (guard.MoveDetour or line:Dot(direction) > 0.9) then
		way, clear, ceiling = line, guard.MoveClear, distance + 1
	else
		local turned
		way, clear, ceiling, turned = wayAhead(guard, direction, aim, from)
		-- A detour is a place to be, not a new goal: walk to it, then think again.
		guard.Move, guard.MoveClear, guard.Sight, guard.MoveDetour = way, clear, SIGHT_TIME, turned
		ceiling = if turned then math.min(ceiling, clear) else ceiling
	end

	local height = aim.Y
	if followFloor then
		local ahead = from + way * (halfExtent(guard, way) + 1.5)
		local floor = floorBelow(guard, from) or floorBelow(guard, ahead)
		if floor then
			height = math.min(math.max(floor + guard.Look.RootHeight, from.Y - STEP_UP), from.Y + STEP_UP)
		end
	end

	-- Never past what the last look said was clear, and never further than the goal needs.
	guard.LastWay = way
	local reach = math.min(clear, ceiling)
	return Vector3.new(from.X + way.X * reach, height, from.Z + way.Z * reach)
end

-- A defender going home cannot pick a lock: anything shut within reach of it is opened for it.
local function letThemIn(house: House, position: Vector3)
	if DayNight.isDaytime() then
		return -- the houses are locked up: nobody is let in during the day
	end
	for _, door in house.Doors do
		if not door.IsOpen and (door.Spot - position).Magnitude <= DOOR_RADIUS then
			setDoorOpen(door, true)
		end
	end
end

local function defendersComingHome(house: House): boolean
	for _, guard in house.Guards do
		if guard.State == "Return" then
			return true
		end
	end
	return false
end

-- Everything a defender does when it is not chasing you: the walk cycle follows whatever its body
-- is really doing (so being shoved into a wall stops the legs), and one on its way home is walked
-- there through the front door rather than teleported.
local function updateGuards(house: House, dt: number, now: number)
	for _, guard in house.Guards do
		local from = guard.Root.Position
		local moved = Vector3.new(from.X - guard.LastPosition.X, 0, from.Z - guard.LastPosition.Z).Magnitude
		guard.LastPosition = from
		WalkCycle.update(guard.Walk, dt, if dt > 0 then moved / dt else 0)
		guard.Sight = math.max(0, guard.Sight - dt)
		guard.Sidestep = math.max(0, guard.Sidestep - dt)

		-- Nobody walks on the spot. A defender that is being dragged somewhere and has not
		-- moved is up against something the casts will not tell us about, so it steps sideways
		-- along it for a moment - the way an animal that bumps into a wall works along it.
		-- Wedged on a door frame. The casts cannot always tell a body pressed into an opening
		-- from one pressed into the wall around it, and a defender that spends a second and a
		-- half standing in the same spot at one of its own house's doorways is on the frame
		-- rather than at anything real: it takes the step through and carries on.
		local seeking = (guard.AlignPosition.Position - from).Magnitude > AIM_CLOSE
		if seeking and (guard.State == "Chase" or guard.State == "Return") and moved < STUCK_SPEED * dt then
			guard.Pinned += dt
			if guard.Pinned >= PINNED_TIME then
				guard.Pinned = 0
				local near, nearDistance = nil, WAYPOINT_REACHED + 0.5
				for _, node in house.Route do
					local distance = distance_of(node, from)
					if distance < nearDistance then
						near, nearDistance = node, distance
					end
				end
				if near then
					-- Along the line it was walking, not at the marker: a body standing on the
					-- marker has no way to go but the way it was already going. The step is only
					-- taken if the far side of the frame is open, so this is walking through the
					-- doorway, never through the wall around it.
					local heading = guard.LastWay
					if heading == nil or heading.Magnitude < 0.5 then
						local offset = Vector3.new(near.X - from.X, 0, near.Z - from.Z)
						heading = if offset.Magnitude > 1e-3 then offset.Unit else nil
					end
					if heading then
						local ahead = from + heading * (halfExtent(guard, heading) + 0.5)
						if not select(2, probe(guard, heading, SQUEEZE_STEP, ahead)) then
							guard.Root.CFrame = guard.Root.CFrame + heading * SQUEEZE_STEP
							guard.LastPosition = guard.Root.Position
							guard.Move, guard.Sight, guard.Stuck, guard.LastWay = nil, 0, 0, nil
						end
					end
				end
			end
			guard.Stuck += dt
			if guard.Stuck >= SIDESTEP_TIME and guard.Sidestep <= 0 then
				guard.Stuck = 0
				if guard.Sidestepped then
					-- The last dodge went nowhere either: walk the other side of the obstacle.
					guard.SlideSide = -guard.SlideSide
				else
					-- Let the steering pick the side that gets it closer to where it is going.
					guard.SlideSide = 0
				end
				guard.Move, guard.Sight = nil, 0
				guard.MoveDetour = false
				guard.Sidestepped = true
				guard.Sidestep = SIDESTEP_TIME
			end
		else
			guard.Stuck = 0
			guard.Sidestepped = false
			guard.Pinned = 0
		end

		if guard.State ~= "Return" then
			continue
		end
		local home = guard.Home.Position
		-- It may have to get back through a wall to reach the bed: through the doorway first.
		local target = home
		if not guard.Flying then
			local hop = routeTo(house, guard, home)
			target = Vector3.new(hop.X, from.Y, hop.Z)
			if insideHouse(house, from) ~= insideHouse(house, home) then
				letThemIn(house, from)
			end
		end
		local homeward = Vector3.new(from.X - home.X, 0, from.Z - home.Z).Magnitude
		if homeward <= RETURN_RADIUS and math.abs(from.Y - home.Y) <= 2 then
			-- Home again. A road catcher only puts recovered pieces back once it has made the
			-- full retreat, so its loot sack tells the story all the way home.
			if #guard.RecoveredLoot > 0 then
				restoreRecoveredLoot(guard.RecoveredLoot)
				table.clear(guard.RecoveredLoot)
				updateRecoveredSack(guard)
			end
			guard.State = "Idle"
			guard.Move = nil
			guard.MoveDetour = false
			guard.AlignPosition.Position = guard.Home.Position
			guard.AlignOrientation.CFrame = guard.Home.Rotation
			guard.Look.Status.Text = if guard.Flying then "" else SLEEPING
			WalkCycle.rest(guard.Walk)
		else
			guard.AlignPosition.MaxVelocity = Config.Alarm.GuardReturnSpeed
			-- Not clamped to the chase lane: the way home leaves the street through the gate,
			-- which is past the lane, and routeTo is what keeps it off other people's property.
			local move = steer(guard, target, not guard.Flying)
			guard.AlignPosition.Position = move
			local heading = Vector3.new(move.X - from.X, 0, move.Z - from.Z)
			if heading.Magnitude > 0.05 then
				guard.AlignOrientation.CFrame = CFrame.lookAt(Vector3.zero, heading.Unit)
			end
		end
	end
end

-- "the Ginger Cat" / "the Pugs"
local function guardPhrase(house: House): string
	local name = house.GuardInfo.DisplayName
	return if #house.Guards == 1 then "the " .. name else "the " .. name .. "s"
end

-- Is this position on any house's property? (Used to stop cars spawning inside.)
function Houses.isOnProperty(position: Vector3): boolean
	for _, house in houses do
		if isInZone(house, position) then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Alarm
--------------------------------------------------------------------------------
local function triggerAlarm(house: House, culprit: Player?)
	local now = os.clock()
	house.LastOccupiedAt = now
	if house.AlarmActive or DayNight.isDaytime() then
		return
	end
	house.AlarmActive = true
	house.Model:SetAttribute("AlarmActive", true)
	for _, guard in house.Guards do
		guard.Way = nil
		guard.State = "Windup"
		guard.ActivateAt = now + house.Settings.AlarmWindup
		guard.Move, guard.Sight, guard.Stuck, guard.Sidestep = nil, 0, 0, 0
		guard.MoveDetour = false
		Guards.setAlert(guard.Look, house.GuardId, true)
		guard.Look.Status.Text = ALERT
		-- Drones rise up and animals jump out of bed during the wind-up, so players see them coming.
		guard.AlignPosition.Position = guard.Home.Position + Vector3.new(0, if guard.Flying then 1.5 else 0.6, 0)
	end
	-- They come out after you, so the way out is open.
	for _, door in house.Doors do
		if not door.IsOpen then
			setDoorOpen(door, true)
		end
	end
	if culprit then
		local phrase = guardPhrase(house)
		Notify.send(
			culprit,
			string.format(
				"🚨 ALARM! %s%s woke up! It moves at your speed in here — through the gate it runs at %s studs/s!",
				string.upper(string.sub(phrase, 1, 1)),
				string.sub(phrase, 2),
				Format.commas(house.GuardSpeed)
			),
			"warning"
		)
	end
end

local function clearIntruder(player: Player, house: House)
	house.Intruders[player] = nil
	if player.Parent and player:GetAttribute("AlarmHouse") == house.Name then
		player:SetAttribute("AlarmHouse", "")
		player:SetAttribute("AlarmGuard", "")
		player:SetAttribute("AlarmSpeed", 0)
	end
end

local function endAlarm(house: House, bedtime: boolean?)
	house.AlarmActive = false
	house.Model:SetAttribute("AlarmActive", false)
	for player in house.Intruders do
		clearIntruder(player, house)
	end
	for _, guard in house.Guards do
		guard.Move, guard.Sight, guard.Stuck, guard.Sidestep = nil, 0, 0, 0
		guard.MoveDetour = false
		guard.AlignPosition.MaxVelocity = Config.Alarm.GuardReturnSpeed
		Guards.setAlert(guard.Look, house.GuardId, false)
		if bedtime then
			-- Daytime: the owners are home and the doors lock behind them, so a defender that is
			-- still out on the street is called straight in to bed rather than left out all day.
			guard.State = "Idle"
			guard.AlignPosition.Position = guard.Home.Position
			guard.AlignOrientation.CFrame = guard.Home.Rotation
			WalkCycle.rest(guard.Walk)
			guard.Look.Status.Text = if guard.Flying then "" else SLEEPING
		else
			-- Home on foot (or on wheels, or hovering): a defender does not cheat back through
			-- the walls it just had to walk round. updateGuards walks it in.
			guard.Way = nil
			guard.State = "Return"
			guard.Look.Status.Text = ""
		end
	end
end

local function endRagdoll(character: Model)
	local ragdoll = ragdolls[character]
	if not ragdoll then
		return
	end
	ragdolls[character] = nil
	for _, state in ragdoll.Motors do
		if state.Motor.Parent then
			state.Motor.Enabled = state.Enabled
		end
	end
	for _, state in ragdoll.Parts do
		if state.Part.Parent then
			state.Part.CanCollide = state.CanCollide
		end
	end
	for _, constraint in ragdoll.Constraints do
		if constraint.Parent then
			constraint:Destroy()
		end
	end
	local humanoid = ragdoll.Humanoid
	if humanoid.Parent then
		humanoid.RequiresNeck = ragdoll.RequiresNeck
		humanoid.PlatformStand = ragdoll.PlatformStand
		humanoid.AutoRotate = ragdoll.AutoRotate
		pcall(function()
			humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end
	character:SetAttribute("Ragdolled", false)
end

-- Turn the character's non-root Motor6Ds into physical ball sockets briefly. Keeping the root
-- connected preserves the camera/ownership anchor while the visible body goes limp and flies.
local function beginRagdoll(character: Model, humanoid: Humanoid)
	if ragdolls[character] then
		return
	end
	local ragdoll: Ragdoll = {
		Humanoid = humanoid,
		Motors = {},
		Parts = {},
		Constraints = {},
		AutoRotate = humanoid.AutoRotate,
		PlatformStand = humanoid.PlatformStand,
		RequiresNeck = humanoid.RequiresNeck,
	}
	ragdolls[character] = ragdoll
	character:SetAttribute("Ragdolled", true)
	humanoid.RequiresNeck = false
	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	pcall(function()
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end)

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Name ~= "HumanoidRootPart" then
			table.insert(ragdoll.Parts, { Part = descendant, CanCollide = descendant.CanCollide })
			descendant.CanCollide = true
		elseif descendant:IsA("Motor6D") then
			local part0, part1 = descendant.Part0, descendant.Part1
			if part0 and part1 and part0.Name ~= "HumanoidRootPart" and part1.Name ~= "HumanoidRootPart" then
				table.insert(ragdoll.Motors, { Motor = descendant, Enabled = descendant.Enabled })
				local attachment0 = Instance.new("Attachment")
				attachment0.Name = "BustRagdollAttachment"
				attachment0.CFrame = descendant.C0
				attachment0.Parent = part0
				local attachment1 = Instance.new("Attachment")
				attachment1.Name = "BustRagdollAttachment"
				attachment1.CFrame = descendant.C1
				attachment1.Parent = part1
				local socket = Instance.new("BallSocketConstraint")
				socket.Name = "BustRagdollJoint"
				socket.Attachment0 = attachment0
				socket.Attachment1 = attachment1
				socket.LimitsEnabled = true
				socket.TwistLimitsEnabled = true
				socket.Parent = part0
				descendant.Enabled = false
				table.insert(ragdoll.Constraints, attachment0)
				table.insert(ragdoll.Constraints, attachment1)
				table.insert(ragdoll.Constraints, socket)
			end
		end
	end
	task.delay(Config.Alarm.BustRagdollTime, function()
		endRagdoll(character)
	end)
end

local function unseat(humanoid: Humanoid)
	if humanoid.SeatPart then
		local seatWeld = humanoid.SeatPart:FindFirstChild("SeatWeld")
		if seatWeld then
			seatWeld:Destroy()
		end
		humanoid.Sit = false
	end
end

updateRecoveredSack = function(guard: Guard)
	if guard.RecoveredSack then
		guard.RecoveredSack:Destroy()
		guard.RecoveredSack = nil
	end
	local count = #guard.RecoveredLoot
	if count == 0 then
		return
	end
	local sack = Instance.new("Part")
	sack.Name = "RecoveredLoot"
	sack.Shape = Enum.PartType.Ball
	sack.Size = Vector3.new(math.min(1 + count * 0.18, 2.8), math.min(1 + count * 0.18, 2.8), math.min(1 + count * 0.18, 2.8))
	sack.Color = Color3.fromRGB(150, 110, 62)
	sack.Material = Enum.Material.Fabric
	sack.CanCollide = false
	sack.CanQuery = false
	sack.CanTouch = false
	sack.Massless = true
	local weld = Instance.new("Weld")
	weld.Name = "RecoveredLootWeld"
	weld.Part0 = guard.Root
	weld.Part1 = sack
	weld.C0 = CFrame.new(0, guard.Root.Size.Y / 2 + sack.Size.Y / 2, guard.Root.Size.Z / 2)
	weld.Parent = sack
	local label = Instance.new("BillboardGui")
	label.Name = "RecoveredLabel"
	label.Size = UDim2.fromOffset(80, 28)
	label.StudsOffsetWorldSpace = Vector3.new(0, sack.Size.Y / 2 + 0.45, 0)
	label.MaxDistance = 65
	label.LightInfluence = 0
	label.Parent = sack
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Font = Enum.Font.BuilderSansBold
	text.Text = string.format("%d LOOT", count)
	text.TextColor3 = Color3.fromRGB(255, 220, 90)
	text.TextStrokeTransparency = 0.25
	text.TextScaled = true
	text.Parent = label
	sack.Parent = guard.Look.Model
	guard.RecoveredSack = sack
end

local function launch(root: BasePart, direction: Vector3, speed: number)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, 1)
	end
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	root.AssemblyLinearVelocity = flat.Unit * speed + Vector3.new(0, Config.Alarm.BustLaunchUpward, 0)
	root.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(-12, 12), rng:NextNumber(-12, 12))
end

local function throwThroughDoor(house: House, character: Model, humanoid: Humanoid, root: BasePart)
	local road = lotPoint(house, 0, house.ZoneHalfSize.Z + Config.Alarm.BustRoadMiddleOffset)
	local doorway = house.Route.Door or lotPoint(house, 0, house.ZoneHalfSize.Z - house.FrontInset + 1)
	local direction = Vector3.new(road.X - doorway.X, 0, road.Z - doorway.Z)
	if direction.Magnitude < 1e-3 then
		direction = house.ZoneCFrame.LookVector
	end
	-- Place the still-rigged character just inside the threshold, then make it limp and launch it
	-- along the front-path line. This guarantees the ejection uses the real front door rather than
	-- letting furniture or a back wall eat the impulse.
	local start = doorway - direction.Unit * 1.5
	character:PivotTo(CFrame.lookAt(start, start + direction))
	for _, door in house.Doors do
		setDoorOpen(door, true)
	end
	unseat(humanoid)
	beginRagdoll(character, humanoid)
	launch(root, direction, Config.Alarm.BustIndoorLaunchSpeed)
	task.delay(Config.Alarm.BustDoorSlamDelay, function()
		if not DayNight.isDaytime() then
			for _, door in house.Doors do
				setDoorOpen(door, false, true)
			end
		end
	end)
end

local function bust(player: Player, house: House, guard: Guard)
	local now = os.clock()
	if isImmune(player, now) then
		return
	end
	bustedUntil[player] = now + Config.Alarm.BustImmunity
	clearIntruder(player, house)

	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local caughtInside = root ~= nil and root:IsA("BasePart") and insideHouse(house, root.Position)

	local lost = Inventory.takeCarriedWithOrigins(player)
	local lostValue = 0
	local recovered: { ReturnedLoot } = {}
	for _, loot in lost do
		lostValue += Items.getValue(loot.ItemId)
		if loot.Origin then
			table.insert(recovered, {
				ItemId = loot.ItemId,
				HouseId = loot.Origin.HouseId,
				SpotId = loot.Origin.SpotId,
			})
		end
	end
	local catcher = (if #house.Guards == 1 then "The " else "A ") .. house.GuardInfo.DisplayName
	BustedEvent:FireClient(player, #lost, lostValue, house.Name, catcher, if caughtInside then "door" else "road")

	if caughtInside then
		restoreRecoveredLoot(recovered)
		if character and humanoid and root and root:IsA("BasePart") then
			throwThroughDoor(house, character, humanoid, root)
		end
	else
		for _, loot in recovered do
			table.insert(guard.RecoveredLoot, loot)
		end
		updateRecoveredSack(guard)
		if character and humanoid and root and root:IsA("BasePart") then
			unseat(humanoid)
			beginRagdoll(character, humanoid)
			launch(root, root.Position - guard.Root.Position, Config.Alarm.BustRoadLaunchSpeed)
		end
	end

	-- The successful catcher has the recovered bag on its back, then follows the normal physical
	-- home route. The original spots are refilled only when it gets there.
	endAlarm(house)
end

-- Where a guard heads to catch this position.
local function aimAt(guard: Guard, position: Vector3, now: number): Vector3
	if guard.Flying then
		return position + Vector3.new(0, Config.Alarm.DroneAimHeight, 0)
	end
	-- Animals run along the floor, with a little trotting bounce (cars and people keep their wheels on it).
	local feet = position.Y - FEET_BELOW_ROOT
	local bounce = if guard.Trot > 0 then math.abs(math.sin(now * 14 + guard.Bob)) * guard.Trot else 0
	return Vector3.new(position.X, feet + guard.Look.RootHeight + bounce, position.Z)
end

local function updateAlarm(house: House, thieves: { Thief }, now: number)
	local intruders: { Thief } = {}
	for _, thief in thieves do
		if inChaseArea(house, thief.Root.Position) and not isImmune(thief.Player, now) then
			table.insert(intruders, thief)
		end
	end

	-- Keep the "you're being chased" banner in sync.
	local present: { [Player]: boolean } = {}
	for _, thief in intruders do
		present[thief.Player] = true
		if not house.Intruders[thief.Player] then
			house.Intruders[thief.Player] = true
			thief.Player:SetAttribute("AlarmGuard", guardPhrase(house))
			thief.Player:SetAttribute("AlarmHouse", house.Name)
			thief.Player:SetAttribute("AlarmSpeed", house.GuardSpeed)
		end
	end
	for player in house.Intruders do
		if not present[player] then
			clearIntruder(player, house)
			if player.Parent and Inventory.getCarriedCount(player) > 0 and not isImmune(player, now) then
				Notify.send(player, "😎 You escaped with the loot! Now stash it in your warehouse.", "success")
			end
		end
	end

	if #intruders > 0 then
		house.LastOccupiedAt = now
	elseif now - house.LastOccupiedAt >= Config.Alarm.CalmDownTime then
		endAlarm(house)
		return
	end

	for _, guard in house.Guards do
		if guard.State == "Windup" and now >= guard.ActivateAt then
			guard.State = "Chase"
		end
		if guard.State == "Chase" then
			local target: Thief? = nil
			local bestDistance = math.huge
			local from = guard.Root.Position
			for _, thief in intruders do
				local offset = thief.Root.Position - from
				local distance = Vector3.new(offset.X, 0, offset.Z).Magnitude
				if distance < bestDistance then
					target, bestDistance = thief, distance
				end
			end
			if target then
				-- The way to it may be through the house: out of the room it is in, or in through
				-- the front door (see routeTo).
				local aimed = routeTo(house, guard, target.Root.Position)
				local aim = aimAt(guard, aimed, now)
				-- Its feet follow the aim (the thief's own height), not the floor: that is what
				-- carries the bounce, and inside a house the two are the same thing.
				local move = clampToChase(house, steer(guard, aim, false))
				guard.AlignPosition.Position = move
				-- The standard speed in the house, its real (often terrifying) speed outside.
				guard.AlignPosition.MaxVelocity = chaseSpeed(house, from)
				-- Face where it is really going: a defender that has to walk out of a doorway
				-- backwards should be walking out of it, not moonwalking round the corner.
				local heading = Vector3.new(move.X - from.X, 0, move.Z - from.Z)
				if heading.Magnitude > 0.05 then
					guard.AlignOrientation.CFrame = CFrame.lookAt(Vector3.zero, heading.Unit)
				end
				local height = math.abs(aimed.Y - from.Y)
				if bestDistance <= catchRadius(guard) and height <= CATCH_HEIGHT then
					bust(target.Player, house, guard)
				end
			end
		end
	end
end

local function getThieves(): { Thief }
	local thieves: { Thief } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart")
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
				table.insert(thieves, { Player = player, Root = root, Humanoid = humanoid })
			end
		end
	end
	return thieves
end

local function onHeartbeat(dt: number)
	local now = os.clock()
	local thieves = getThieves()

	-- Inside a property everyone is held at the standard Roblox speed (see PlayerData).
	for _, thief in thieves do
		PlayerData.setInsideHouse(thief.Player, Houses.isOnProperty(thief.Root.Position))
	end

	for _, house in houses do
		if house.AlarmActive then
			updateAlarm(house, thieves, now)
		end
		updateGuards(house, dt, now)
	end
end

--------------------------------------------------------------------------------
-- Loot
--------------------------------------------------------------------------------
local function makeItemLabel(def: Items.ItemDef, root: BasePart)
	local rarity = Items.Rarities[def.Rarity]
	local gui = Instance.new("BillboardGui")
	gui.Name = "ItemLabel"
	gui.Size = UDim2.fromOffset(180, 50)
	gui.StudsOffsetWorldSpace = Vector3.new(0, root.Size.Y / 2 + 1.2, 0)
	gui.MaxDistance = 28
	gui.LightInfluence = 0
	gui.Parent = root

	local name = Instance.new("TextLabel")
	name.Name = "ItemName"
	name.BackgroundTransparency = 1
	name.Size = UDim2.fromScale(1, 0.55)
	name.Font = Enum.Font.FredokaOne
	name.Text = def.DisplayName
	name.TextScaled = true
	name.TextColor3 = rarity.Color
	name.TextStrokeTransparency = 0.25
	name.Parent = gui

	local value = Instance.new("TextLabel")
	value.Name = "ItemValue"
	value.BackgroundTransparency = 1
	value.Position = UDim2.fromScale(0, 0.55)
	value.Size = UDim2.fromScale(1, 0.45)
	value.Font = Enum.Font.BuilderSansBold
	value.Text = string.format("%s • %s", Format.money(def.Value), def.Rarity)
	value.TextScaled = true
	value.TextColor3 = Color3.fromRGB(130, 255, 150)
	value.TextStrokeTransparency = 0.3
	value.Parent = gui
end

local onSteal: (house: House, spot: Spot, model: Model, player: Player) -> ()

local function setStealable(spot: Spot, stealable: boolean)
	local model = spot.Item
	local root = if model then model.PrimaryPart else nil
	local prompt = if root then root:FindFirstChild("StealPrompt") else nil
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = stealable
	end
end

local function spawnItem(house: House, spot: Spot, forcedItemId: string?)
	local itemId = forcedItemId or Items.roll(house.LootHouse, rng)
	local def = Items.get(itemId)
	local model = ItemModels.build(itemId)
	if not def or not model then
		return
	end
	model:PivotTo(spot.Part.CFrame)
	local root = model.PrimaryPart
	if root then
		makeItemLabel(def, root)
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "StealPrompt"
		prompt.ActionText = "Steal"
		prompt.ObjectText = string.format("%s (%s)", def.DisplayName, Format.money(def.Value))
		prompt.HoldDuration = Config.Stealing.HoldDuration
		prompt.MaxActivationDistance = Config.Stealing.PromptDistance
		prompt.RequiresLineOfSight = false
		prompt.Enabled = not DayNight.isDaytime()
		prompt.Parent = root
		prompt.Triggered:Connect(function(player: Player)
			onSteal(house, spot, model, player)
		end)
	end
	model.Parent = house.Loot
	spot.Item = model
	spot.ItemId = itemId
end

-- Fresh loot on every spot (the old leftovers are taken away).
local function restock(house: House)
	for _, spot in house.Spots do
		local old = spot.Item
		if old then
			old:Destroy()
		end
		spot.Item = nil
		spot.ItemId = nil
		spawnItem(house, spot)
	end
end

-- Recreate recovered loot with its original id on its original marker, never by rolling a new
-- item. If daytime has already restocked that marker, it is already safely occupied and must not
-- be duplicated.
restoreRecoveredLoot = function(loot: { ReturnedLoot }): number
	local restored = 0
	for _, entry in loot do
		local house = housesById[entry.HouseId]
		local spot = if house then house.SpotById[entry.SpotId] else nil
		if house and spot and spot.Item == nil then
			spawnItem(house, spot, entry.ItemId)
			if spot.Item then
				restored += 1
			end
		end
	end
	return restored
end

onSteal = function(house: House, spot: Spot, model: Model, player: Player)
	local itemId = spot.ItemId
	if spot.Item ~= model or not itemId or not model.Parent then
		return
	end
	if DayNight.isDaytime() or isImmune(player, os.clock()) then
		return
	end
	local ok, reason = Inventory.addCarried(player, itemId, {
		HouseId = house.Id,
		SpotId = spot.Part.Name,
	})
	if not ok then
		Notify.send(player, reason or "You can't carry that right now.", "error")
		return
	end
	spot.Item = nil
	spot.ItemId = nil
	model:Destroy()
	PlayerData.addStolen(player, 1)

	local def = Items.get(itemId)
	if def then
		Notify.send(
			player,
			string.format(
				"🦝 Stole %s (%s)! Bag: %d/%d",
				def.DisplayName,
				Format.money(def.Value),
				Inventory.getCarriedCount(player),
				PlayerData.getUpgradeValue(player, "Bag")
			),
			"steal"
		)
		if PlayerData.discover(player, itemId) then
			Notify.send(
				player,
				string.format(
					"📖 New item discovered: %s! (%d/%d in your Loot Index)",
					def.DisplayName,
					PlayerData.getDiscoveredCount(player),
					#Items.List
				),
				"level"
			)
		end
	end
	triggerAlarm(house, player)
end

--------------------------------------------------------------------------------
-- Guards
--------------------------------------------------------------------------------
local function buildGuard(house: House, dock: BasePart): Guard
	local flying = house.GuardInfo.Kind == "Drone"
	local base = if flying
		then CFrame.new(dock.Position + Vector3.new(0, Config.Alarm.DroneDockHeight, 0)) * dock.CFrame.Rotation
		else CFrame.new(dock.Position + Vector3.new(0, dock.Size.Y / 2, 0)) * dock.CFrame.Rotation
	local look = Guards.build(house.GuardId, base)
	local model = look.Model
	model:SetAttribute("Kind", house.GuardInfo.Kind)
	model:SetAttribute("Breed", house.GuardInfo.DisplayName)
	local root = look.Root
	look.Status.Text = if flying then "" else SLEEPING

	local filter = RaycastParams.new()
	filter.FilterType = Enum.RaycastFilterType.Exclude
	filter.FilterDescendantsInstances = { look.Model }
	-- The way-ahead cast keeps the same list and pushes what it is discounting onto the end of it,
	-- so nothing is allocated per look (which matters: defenders look several times a frame).
	local hidden: { any } = { look.Model }
	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Exclude
	probeParams.FilterDescendantsInstances = hidden

	local attachment = Instance.new("Attachment")
	attachment.Name = "GuardAttachment"
	attachment.Parent = root

	local alignPosition = Instance.new("AlignPosition")
	alignPosition.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPosition.Attachment0 = attachment
	alignPosition.Position = root.Position
	alignPosition.MaxForce = 1000000
	alignPosition.MaxVelocity = Config.Alarm.GuardReturnSpeed
	alignPosition.Responsiveness = 80
	alignPosition.Parent = root

	local alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Attachment0 = attachment
	alignOrientation.CFrame = root.CFrame.Rotation
	alignOrientation.MaxTorque = 1000000
	alignOrientation.Responsiveness = 40
	alignOrientation.Parent = root

	model.Parent = house.Model
	pcall(function()
		root:SetNetworkOwner(nil)
	end)

	return {
		Look = look,
		Root = root,
		AlignPosition = alignPosition,
		AlignOrientation = alignOrientation,
		Home = root.CFrame,
		Filter = filter,
		ProbeParams = probeParams,
		Hidden = hidden,
		Flying = flying,
		State = "Idle",
		ActivateAt = 0,
		Bob = rng:NextNumber() * math.pi * 2,
		Trot = TROT[house.GuardInfo.Kind] or 0.4,
		Walk = WalkCycle.new(look.Limbs),
		LastPosition = root.Position,
		Move = nil,
		MoveClear = 0,
		MoveDetour = false,
		Sight = 0,
		SlideSide = 0,
		Blocked = 0,
		ClearLooks = 0,
		Stuck = 0,
		Sidestep = 0,
		Sidestepped = false,
		Pinned = 0,
		LastWay = nil,
		Way = nil,
		RecoveredLoot = {},
		RecoveredSack = nil,
	}
end

--------------------------------------------------------------------------------
-- Doors
--------------------------------------------------------------------------------
setDoorOpen = function(door: Door, open: boolean, slam: boolean?)
	door.IsOpen = open
	if open then
		door.Prompt.Enabled = false
		door.CloseAt = os.clock() + Config.Doors.StayOpenTime
		TweenService:Create(door.Angle, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Value = door.OpenAngle,
		}):Play()
	else
		local duration = if slam then 0.18 else 0.9
		TweenService:Create(door.Angle, TweenInfo.new(duration, Enum.EasingStyle.Quad, if slam then Enum.EasingDirection.In else Enum.EasingDirection.InOut), {
			Value = 0,
		}):Play()
		if slam then
			door.Slam:Play()
		end
		task.delay(duration, function()
			if not door.IsOpen and not DayNight.isDaytime() then
				door.Prompt.Enabled = true
			end
		end)
	end
end

local function setupDoor(house: House, doorModel: Model): Door?
	local hinge = doorModel:FindFirstChild("Hinge")
	if not (hinge and hinge:IsA("BasePart")) then
		warn("[Houses] Door " .. doorModel:GetFullName() .. " has no Hinge part")
		return nil
	end
	local hingeCFrame = hinge.CFrame
	local pieces: { { Part: BasePart, Offset: CFrame } } = {}
	local panel: BasePart? = nil
	for _, descendant in doorModel:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= hinge then
			table.insert(pieces, { Part = descendant, Offset = hingeCFrame:ToObjectSpace(descendant.CFrame) })
			if panel == nil or descendant.Size.Magnitude > panel.Size.Magnitude then
				panel = descendant
			end
		end
	end
	if not panel then
		return nil
	end

	local angle = Instance.new("NumberValue")
	angle.Name = "OpenAngle"
	angle.Value = 0
	angle.Parent = doorModel
	angle:GetPropertyChangedSignal("Value"):Connect(function()
		local base = hingeCFrame * CFrame.Angles(0, math.rad(angle.Value), 0)
		for _, doorPiece in pieces do
			doorPiece.Part.CFrame = base * doorPiece.Offset
		end
	end)

	local openAngle = doorModel:GetAttribute("OpenAngle")
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "LockpickPrompt"
	prompt.ActionText = "Pick Lock"
	prompt.ObjectText = house.Name
	prompt.HoldDuration = house.Settings.LockpickTime
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Enabled = not DayNight.isDaytime()
	prompt.Parent = panel

	local slam = Instance.new("Sound")
	slam.Name = "SlamSound"
	slam.SoundId = Config.Sounds.DoorSlam
	slam.Volume = 1.35
	slam.RollOffMode = Enum.RollOffMode.InverseTapered
	slam.RollOffMinDistance = 4
	slam.RollOffMaxDistance = 70
	slam.Parent = panel

	local door: Door = {
		Model = doorModel,
		Spot = hingeCFrame.Position,
		Prompt = prompt,
		Angle = angle,
		Slam = slam,
		OpenAngle = if type(openAngle) == "number" then openAngle else -95,
		IsOpen = false,
		CloseAt = 0,
	}
	prompt.Triggered:Connect(function(player: Player)
		if door.IsOpen then
			return
		end
		if DayNight.isDaytime() then
			Notify.send(player, "☀️ The owners are home! Come back when it's dark.", "error")
			return
		end
		setDoorOpen(door, true)
		Notify.send(player, "🔓 Lock picked! Grab the loot... the alarm trips when you steal.", "info")
	end)
	return door
end

local function anyoneOnProperty(house: House): boolean
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if root and root:IsA("BasePart") and isInZone(house, root.Position) then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Lasers
--------------------------------------------------------------------------------
local function setupLaser(house: House, laser: BasePart)
	laser.CanCollide = false
	laser.CanQuery = false
	laser.Touched:Connect(function(hit: BasePart)
		if laser.Transparency >= 1 or DayNight.isDaytime() then
			return
		end
		local player = playerFromHit(hit)
		if not player then
			return
		end
		local now = os.clock()
		if (laserCooldown[player] or 0) > now or isImmune(player, now) then
			return
		end
		laserCooldown[player] = now + 2
		if not house.AlarmActive then
			local phrase = guardPhrase(house)
			Notify.send(
				player,
				string.format(
					"🔴 You tripped a laser! %s%s %s awake!",
					string.upper(string.sub(phrase, 1, 1)),
					string.sub(phrase, 2),
					if #house.Guards == 1 then "is" else "are"
				),
				"warning"
			)
			triggerAlarm(house, nil)
		end
	end)
	table.insert(house.Lasers, laser)
end

local function updateLasers()
	local cycle = Config.Lasers.OnTime + Config.Lasers.OffTime
	local now = os.clock()
	local daytime = DayNight.isDaytime()
	for _, house in houses do
		for _, laser in house.Lasers do
			local phase = laser:GetAttribute("Phase")
			local offset = if type(phase) == "number" then phase else 0
			local on = not daytime and (now + offset) % cycle < Config.Lasers.OnTime
			local transparency = if on then 0.2 else 1
			if laser.Transparency ~= transparency then
				laser.Transparency = transparency
				laser.CanTouch = on
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Daytime: lock up, show everyone out, restock
--------------------------------------------------------------------------------
-- A spot on the pavement just outside the property, facing the street.
local function exitCFrame(house: House): CFrame
	local half = house.ZoneHalfSize
	local front = house.ZoneCFrame * CFrame.new(0, -half.Y + FEET_BELOW_ROOT, half.Z + 6)
	return front * CFrame.Angles(0, math.pi, 0)
end

local function showEveryoneOut()
	for _, thief in getThieves() do
		local seated = thief.Humanoid.SeatPart ~= nil
		for _, house in houses do
			if not seated and isInZone(house, thief.Root.Position) then
				local character = thief.Player.Character
				if character then
					character:PivotTo(exitCFrame(house))
				end
				Notify.send(thief.Player, "☀️ The owners came home! You slipped out just in time (and kept your loot).", "warning")
				break
			end
		end
	end
end

local function onDaytime()
	showEveryoneOut()
	for _, house in houses do
		if house.AlarmActive then
			endAlarm(house, true)
		end
		for _, door in house.Doors do
			door.Prompt.Enabled = false
			if door.IsOpen then
				setDoorOpen(door, false)
			end
		end
		restock(house)
		house.Model:SetAttribute("Open", false)
	end
end

local function onNightfall()
	for _, house in houses do
		for _, door in house.Doors do
			if not door.IsOpen then
				door.Prompt.Enabled = true
			end
		end
		for _, spot in house.Spots do
			setStealable(spot, true)
		end
		house.Model:SetAttribute("Open", true)
	end
end

--------------------------------------------------------------------------------
-- Setup & loops
--------------------------------------------------------------------------------
local function setupHouse(model: Model)
	local zone = model:FindFirstChild("Zone")
	if not (zone and zone:IsA("BasePart")) then
		warn("[Houses] " .. model:GetFullName() .. " has no Zone part, skipping")
		return
	end
	local info = Config.getHouse(model.Name)
	local tierAttribute = model:GetAttribute("Tier")
	local tier = math.clamp(
		if info then info.Tier elseif type(tierAttribute) == "number" then tierAttribute else 1,
		1,
		#Config.HouseTiers
	)
	local displayName = model:GetAttribute("DisplayName")
	local guardId = if info then info.Guard else "TuxedoCat"
	local guardInfo = Config.Guards[guardId] or Config.Guards.TuxedoCat

	-- Houses added by hand in Studio borrow the loot of a listed house of the same tier.
	local lootHouse = model.Name
	if #Items.forHouse(lootHouse) == 0 then
		for _, other in Config.Houses do
			if other.Tier == tier then
				lootHouse = other.Id
				break
			end
		end
	end

	local loot = Instance.new("Folder")
	loot.Name = "Loot"
	loot.Parent = model

	-- The map marks where the front wall sits inside the property; fall back to the Config default.
	local inset = zone:GetAttribute("FrontInset")
	local half = zone.Size / 2
	-- How far east a chase is allowed to go: the east edge of this house's own lot.
	local maxX = -math.huge
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			maxX = math.max(maxX, zone.CFrame:PointToWorldSpace(Vector3.new(sx * half.X, 0, sz * half.Z)).X)
		end
	end

	local house: House = {
		Model = model,
		Id = model.Name,
		Name = if type(displayName) == "string" then displayName elseif info then info.DisplayName else model.Name,
		LootHouse = lootHouse,
		Tier = tier,
		Settings = Config.HouseTiers[tier],
		GuardId = guardId,
		GuardInfo = guardInfo,
		ZoneCFrame = zone.CFrame,
		ZoneHalfSize = half,
		FrontInset = if type(inset) == "number" then inset else Config.Alarm.HouseFrontInset,
		GuardSpeed = guardInfo.Speed,
		ChaseMaxX = maxX + 4,
		Loot = loot,
		Spots = {},
		SpotById = {},
		Guards = {},
		Doors = {},
		Route = {},
		Rooms = {},
		Via = {},
		Lasers = {},
		AlarmActive = false,
		LastOccupiedAt = 0,
		Intruders = {},
	}
	model:SetAttribute("AlarmActive", false)
	model:SetAttribute("Open", not DayNight.isDaytime())

	local spots = model:FindFirstChild("ItemSpots")
	if spots then
		for _, part in spots:GetChildren() do
			if part:IsA("BasePart") then
				local spot: Spot = { Part = part, Item = nil, ItemId = nil }
				table.insert(house.Spots, spot)
				house.SpotById[part.Name] = spot
				spawnItem(house, spot)
			end
		end
	end

	local docks = model:FindFirstChild("GuardDocks")
	if docks then
		for _, dock in docks:GetChildren() do
			if dock:IsA("BasePart") then
				table.insert(house.Guards, buildGuard(house, dock))
			end
		end
	end

	local route = model:FindFirstChild("Route")
	if route then
		for _, node in route:GetChildren() do
			if node:IsA("BasePart") then
				-- The markers sit on the floor; the aim maths measures a character's root part, so
				-- lift each one the standard root height - the same place a thief standing there
				-- would be - and everything downstream reads them the same way.
				house.Route[node.Name] = node.Position + Vector3.new(0, FEET_BELOW_ROOT, 0)
			end
		end
	end

	local rooms = model:FindFirstChild("Rooms")
	if rooms then
		for _, roomPart in rooms:GetChildren() do
			if roomPart:IsA("BasePart") then
				table.insert(house.Rooms, roomPart)
				local via = roomPart:GetAttribute("Via")
				local node = if type(via) == "string" then house.Route[via] else nil
				if node then
					house.Via[roomPart.Name] = node
				end
			end
		end
	end

	local doors = model:FindFirstChild("Doors")
	if doors then
		for _, doorModel in doors:GetChildren() do
			if doorModel:IsA("Model") then
				local door = setupDoor(house, doorModel)
				if door then
					table.insert(house.Doors, door)
				end
			end
		end
	end

	local lasers = model:FindFirstChild("Lasers")
	if lasers then
		for _, laser in lasers:GetChildren() do
			if laser:IsA("BasePart") then
				setupLaser(house, laser)
			end
		end
	end

	table.insert(houses, house)
	housesById[house.Id] = house
end

local function doorLoop()
	while true do
		task.wait(1)
		local now = os.clock()
		for _, house in houses do
			for _, door in house.Doors do
				if door.IsOpen and now >= door.CloseAt then
					if anyoneOnProperty(house) or defendersComingHome(house) then
						door.CloseAt = now + 5 -- never slam a door on someone
					else
						setDoorOpen(door, false)
					end
				end
			end
		end
	end
end

function Houses.onPlayerRemoving(player: Player)
	bustedUntil[player] = nil
	laserCooldown[player] = nil
	Inventory.forgetPlayer(player)
	for _, house in houses do
		house.Intruders[player] = nil
	end
end

function Houses.init()
	local map = Workspace:WaitForChild("Map")
	local folder = map:WaitForChild("Houses")
	for _, model in folder:GetChildren() do
		if model:IsA("Model") then
			setupHouse(model)
		end
	end
	DayNight.onChanged(function(isDaytime: boolean)
		if isDaytime then
			onDaytime()
		else
			onNightfall()
		end
	end)
	RunService.Heartbeat:Connect(onHeartbeat)
	RunService.Heartbeat:Connect(updateLasers)
	task.spawn(doorLoop)
end

return Houses
