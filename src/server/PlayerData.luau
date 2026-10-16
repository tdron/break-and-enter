--!strict
--[[
	PlayerData
	----------
	Owns every player's saved profile (cash, upgrades, speed, warehouse and
	trunk contents) plus their in-session state (items currently carried).

	Important numbers are mirrored onto Player attributes so the client UI can
	react to them without any extra remotes:
  Cash, Income, Carried, CarriedList, BagCapacity,
  StoredCount, StorageCapacity, Speed, SpeedPoints, SpeedProgress,
  Rebirths (production multiplier is x1 + x0.5 per rebirth: see Config.Rebirth),
  InHouse, Level_<UpgradeId>, Discovered (comma-separated item ids for the Loot
  Index).

  The physical Humanoid.WalkSpeed is server-controlled and deliberately is not
  replicated as a Player attribute: the player-facing Speed stat is the only
  speed number shown to players.

	Saving uses DataStoreService. When the place is unpublished or Studio API
	access is off, the game still works but progress is session-only.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Items = require(ReplicatedStorage.Shared.Items)

export type Profile = {
	Cash: number,
	Levels: { [string]: number },
	SpeedPoints: number, -- trained display-speed; whole points raise the 5x Speed stat
	Rebirths: number, -- completed rebirths; drives the production multiplier (see Config.Rebirth)
	Stored: { string },
	TotalStolen: number,
	TotalEarned: number,
	Discovered: { string }, -- every item this player has ever stolen (the Loot Index)
}

export type Leaderstats = {
	Cash: IntValue,
	Stolen: IntValue,
	Speed: IntValue,
	Rebirths: IntValue,
}

export type Session = {
	Player: Player,
	Profile: Profile,
	Carried: { string },
	Income: number,
	CanSave: boolean,
	Loaded: boolean,
	Leaderstats: Leaderstats?,
}

local STORE_NAME = "StealAnItem_PlayerData_v1"
local MAX_LOAD_ATTEMPTS = 3

local PlayerData = {}

local sessions: { [Player]: Session } = {}
-- Players standing on someone's property: everyone moves at the standard Roblox
-- speed in there, so their treadmill speed is held back until they are back out.
local insideHouse: { [Player]: boolean? } = {}
local store: DataStore? = nil
local saveWarning = "Progress will not be saved in this session."

if game.PlaceId == 0 then
	saveWarning = "This place isn't published yet, so progress won't be saved. (Publish it and enable Studio API access to test saving.)"
else
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		saveWarning = "DataStores are unavailable, so progress won't be saved this session."
		warn("[PlayerData] Could not open DataStore: " .. tostring(result))
	end
end

local function dataKey(player: Player): string
	return "Player_" .. player.UserId
end

local function defaultProfile(): Profile
	local levels: { [string]: number } = {}
	for _, upgrade in Config.Upgrades do
		levels[upgrade.Id] = 1
	end
	return {
		Cash = Config.Economy.StartingCash,
		Levels = levels,
		SpeedPoints = 0,
		Rebirths = 0,
		Stored = {},
		TotalStolen = 0,
		TotalEarned = 0,
		Discovered = {},
	}
end

local function readNumber(value: any, fallback: number, minimum: number, maximum: number): number
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.clamp(value, minimum, maximum)
end

local function readItemList(value: any, limit: number): { string }
	local result: { string } = {}
	if type(value) ~= "table" then
		return result
	end
	for _, itemId in value do
		if #result >= limit then
			break
		end
		if type(itemId) == "string" and Items.get(itemId) then
			table.insert(result, itemId)
		end
	end
	return result
end

-- Turns whatever came out of the DataStore into a valid profile.
local function sanitize(raw: any): Profile
	local profile = defaultProfile()
	if type(raw) ~= "table" then
		return profile
	end
	profile.Cash = math.floor(readNumber(raw.Cash, profile.Cash, 0, 1e15))
	if type(raw.Levels) == "table" then
		for _, upgrade in Config.Upgrades do
			profile.Levels[upgrade.Id] = math.floor(readNumber(raw.Levels[upgrade.Id], 1, 1, #upgrade.Values))
		end
		-- Older saves unlocked Pro/Elite treadmills at the Gym; turn those into treadmill levels.
		if raw.Levels.Treadmill == nil then
			if raw.Levels.EliteTreadmill == 2 then
				profile.Levels.Treadmill = 6
			elseif raw.Levels.ProTreadmill == 2 then
				profile.Levels.Treadmill = 3
			end
		end
	end
	-- Version 1 stored points under the old 1 point = 4 studs/s rule. Version 2
	-- counts display-speed points instead, where Speed is always 5x studs/s.
	-- Convert old saves so players keep exactly the same physical movement speed.
	local version = math.floor(readNumber(raw.Version, 0, 0, 1e9))
	local legacyLevel = readNumber(raw.SpeedLevel, 0, 0, 1e9)
	local savedPoints = readNumber(raw.SpeedPoints, -1, -1, 1e15)
	if savedPoints >= 0 then
		profile.SpeedPoints = if version >= 2 then savedPoints else savedPoints * 20
	else
		-- Very old saves used one SpeedLevel per extra stud/s.
		profile.SpeedPoints = legacyLevel * Config.Speed.DisplayMultiplier
	end
	profile.Rebirths = math.floor(readNumber(raw.Rebirths, 0, 0, 1e12)) -- rebirths never cap out
	profile.Stored = readItemList(raw.Stored, Config.getUpgradeValue("Storage", profile.Levels.Storage))
	-- The getaway car (and its trunk) is gone. Anything an old save still had in the trunk is
	-- moved onto the warehouse shelves so nobody loses loot; the overflow is written off.
	local legacyTrunk = readItemList(raw.Trunk, 0)
	for _, itemId in legacyTrunk do
		if #profile.Stored < Config.getUpgradeValue("Storage", profile.Levels.Storage) then
			table.insert(profile.Stored, itemId)
		end
	end
	profile.TotalStolen = math.floor(readNumber(raw.TotalStolen, 0, 0, 1e12))
	profile.TotalEarned = math.floor(readNumber(raw.TotalEarned, 0, 0, 1e18))
	-- Saves from before the Loot Index count the items they already own as discovered.
	local discovered = if type(raw.Discovered) == "table" then raw.Discovered else nil
	local source = discovered or table.move(legacyTrunk, 1, #legacyTrunk, #profile.Stored + 1, table.clone(profile.Stored))
	local seen: { [string]: boolean } = {}
	for _, itemId in readItemList(source, #Items.List * 4) do
		if not seen[itemId] then
			seen[itemId] = true
			table.insert(profile.Discovered, itemId)
		end
	end
	return profile
end

local function createLeaderstats(player: Player, session: Session)
	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"

	local cash = Instance.new("IntValue")
	cash.Name = "Cash"
	cash.Parent = folder

	local stolen = Instance.new("IntValue")
	stolen.Name = "Stolen"
	stolen.Parent = folder

	local speed = Instance.new("IntValue")
	speed.Name = "Speed"
	speed.Parent = folder

	local rebirths = Instance.new("IntValue")
	rebirths.Name = "Rebirths"
	rebirths.Parent = folder

	folder.Parent = player
	session.Leaderstats = { Cash = cash, Stolen = stolen, Speed = speed, Rebirths = rebirths }
end

--------------------------------------------------------------------------------
-- Session access
--------------------------------------------------------------------------------
function PlayerData.get(player: Player): Session?
	local session = sessions[player]
	if session and session.Loaded then
		return session
	end
	return nil
end

function PlayerData.getSaveWarning(): string
	return saveWarning
end

function PlayerData.getUpgradeLevel(player: Player, upgradeId: string): number
	local session = sessions[player]
	if not session then
		return 1
	end
	return session.Profile.Levels[upgradeId] or 1
end

function PlayerData.getUpgradeValue(player: Player, upgradeId: string): number
	return Config.getUpgradeValue(upgradeId, PlayerData.getUpgradeLevel(player, upgradeId))
end

-- Trained speed points (a float: the treadmill trickles them in).
function PlayerData.getSpeedPoints(player: Player): number
	local session = sessions[player]
	return if session then session.Profile.SpeedPoints else 0
end

-- The player-facing Speed stat shown by the HUD, leaderboard and treadmill.
-- It is always five times the real movement speed in studs/s.
function PlayerData.getSpeedStat(player: Player): number
	return Config.speedStatForPoints(PlayerData.getSpeedPoints(player))
end

function PlayerData.getWalkSpeed(player: Player): number
	return Config.walkSpeedForPoints(PlayerData.getSpeedPoints(player))
end

-- Completed rebirths (0 for a fresh player): the production multiplier is on Config.
function PlayerData.getRebirths(player: Player): number
	local session = sessions[player]
	return if session then session.Profile.Rebirths else 0
end

--------------------------------------------------------------------------------
-- Replication to the client (attributes + leaderstats)
--------------------------------------------------------------------------------
function PlayerData.replicateCash(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	player:SetAttribute("Cash", session.Profile.Cash)
	local stats = session.Leaderstats
	if stats then
		stats.Cash.Value = session.Profile.Cash
	end
end

function PlayerData.replicate(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	local profile = session.Profile

	PlayerData.replicateCash(player)
	player:SetAttribute("Income", session.Income)
	player:SetAttribute("SpeedPoints", profile.SpeedPoints)
	player:SetAttribute("SpeedProgress", profile.SpeedPoints - math.floor(profile.SpeedPoints))
	player:SetAttribute("Speed", Config.speedStatForPoints(profile.SpeedPoints))
	-- Remove the old replicated physical-speed attribute for players joining a
	-- server that was updated in place.
	player:SetAttribute("WalkSpeed", nil)
	player:SetAttribute("Rebirths", profile.Rebirths)
	for _, upgrade in Config.Upgrades do
		player:SetAttribute("Level_" .. upgrade.Id, profile.Levels[upgrade.Id])
	end
	player:SetAttribute("BagCapacity", PlayerData.getUpgradeValue(player, "Bag"))
	player:SetAttribute("StorageCapacity", PlayerData.getUpgradeValue(player, "Storage"))
	player:SetAttribute("Carried", #session.Carried)
	player:SetAttribute("CarriedList", table.concat(session.Carried, ","))
	player:SetAttribute("StoredCount", #profile.Stored)
	player:SetAttribute("Discovered", table.concat(profile.Discovered, ","))

	local stats = session.Leaderstats
	if stats then
		stats.Stolen.Value = profile.TotalStolen
		stats.Speed.Value = Config.speedStatForPoints(profile.SpeedPoints)
		stats.Rebirths.Value = profile.Rebirths
	end
end

--------------------------------------------------------------------------------
-- Cash, income, stats
--------------------------------------------------------------------------------
function PlayerData.addCash(player: Player, amount: number)
	local session = sessions[player]
	if not session or amount <= 0 then
		return
	end
	local whole = math.floor(amount)
	session.Profile.Cash += whole
	session.Profile.TotalEarned += whole
	PlayerData.replicateCash(player)
end

function PlayerData.trySpend(player: Player, amount: number): boolean
	local session = sessions[player]
	if not session or amount < 0 or session.Profile.Cash < amount then
		return false
	end
	session.Profile.Cash -= amount
	PlayerData.replicateCash(player)
	return true
end

function PlayerData.recalculateIncome(player: Player): number
	local session = sessions[player]
	if not session then
		return 0
	end
	local total = 0
	for _, itemId in session.Profile.Stored do
		total += Items.getIncome(itemId)
	end
	-- Rebirths multiply warehouse income (x1.5 at one rebirth, x3 at five).
	session.Income = total * Config.rebirthMultiplier(session.Profile.Rebirths)
	player:SetAttribute("Income", total)
	player:SetAttribute("StoredCount", #session.Profile.Stored)
	return total
end

function PlayerData.addStolen(player: Player, count: number)
	local session = sessions[player]
	if not session then
		return
	end
	session.Profile.TotalStolen += count
	local stats = session.Leaderstats
	if stats then
		stats.Stolen.Value = session.Profile.TotalStolen
	end
end

-- Records a stolen item in the player's Loot Index. Returns true the first time.
function PlayerData.discover(player: Player, itemId: string): boolean
	local session = sessions[player]
	if not session or not Items.get(itemId) or table.find(session.Profile.Discovered, itemId) then
		return false
	end
	table.insert(session.Profile.Discovered, itemId)
	player:SetAttribute("Discovered", table.concat(session.Profile.Discovered, ","))
	return true
end

function PlayerData.getDiscoveredCount(player: Player): number
	local session = sessions[player]
	return if session then #session.Profile.Discovered else 0
end

function PlayerData.applyWalkSpeed(player: Player)
	local walkSpeed = PlayerData.getWalkSpeed(player)
	-- This is intentionally assigned only to the Humanoid. Replicating it as a
	-- Player attribute exposed the true studs-per-second value next to the
	-- player-facing (5×) Speed stat.
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid then
		-- Inside a house the thief moves at the same standard speed as the defenders.
		humanoid.WalkSpeed = if insideHouse[player] then math.min(walkSpeed, Config.Alarm.InsideSpeed) else walkSpeed
	end
	local session = sessions[player]
	local stats = if session then session.Leaderstats else nil
	if stats then
		-- Keep the leaderboard aligned with the HUD's player-facing Speed value,
		-- not the smaller physical studs-per-second value.
		stats.Speed.Value = PlayerData.getSpeedStat(player)
	end
end

-- Called by Houses when a player steps onto (or off) a house's property.
function PlayerData.setInsideHouse(player: Player, inside: boolean)
	if (insideHouse[player] == true) == inside then
		return
	end
	insideHouse[player] = if inside then true else nil
	player:SetAttribute("InHouse", inside)
	PlayerData.applyWalkSpeed(player)
end

function PlayerData.isInsideHouse(player: Player): boolean
	return insideHouse[player] == true
end

-- Adds treadmill training. Returns how many whole speed points were gained.
function PlayerData.addSpeed(player: Player, points: number): number
	local session = sessions[player]
	if not session or points <= 0 then
		return 0
	end
	local profile = session.Profile
	-- Rebirths multiply treadmill training too.
	points = points * Config.rebirthMultiplier(profile.Rebirths)
	local before = math.floor(profile.SpeedPoints)
	profile.SpeedPoints += points
	local after = math.floor(profile.SpeedPoints)
	player:SetAttribute("SpeedPoints", profile.SpeedPoints)
	player:SetAttribute("SpeedProgress", profile.SpeedPoints - after)
	player:SetAttribute("Speed", Config.speedStatForPoints(profile.SpeedPoints))
	if after > before then
		PlayerData.applyWalkSpeed(player)
	end
	return after - before
end

-- Bash back to zero (or any value) in one go: the rebirth trade spends every trained point.
function PlayerData.setSpeedPoints(player: Player, points: number)
	local session = sessions[player]
	if not session then
		return
	end
	local profile = session.Profile
	profile.SpeedPoints = math.max(0, points)
	player:SetAttribute("SpeedPoints", profile.SpeedPoints)
	player:SetAttribute("SpeedProgress", profile.SpeedPoints - math.floor(profile.SpeedPoints))
	player:SetAttribute("Speed", Config.speedStatForPoints(profile.SpeedPoints))
	PlayerData.applyWalkSpeed(player)
end

--------------------------------------------------------------------------------
-- Loading & saving
--------------------------------------------------------------------------------
function PlayerData.load(player: Player): Session
	local session: Session = {
		Player = player,
		Profile = defaultProfile(),
		Carried = {},
		Income = 0,
		CanSave = false,
		Loaded = false,
		Leaderstats = nil,
	}
	sessions[player] = session

	local dataStore = store
	if dataStore then
		local key = dataKey(player)
		local success: boolean, result: any = false, nil
		for attempt = 1, MAX_LOAD_ATTEMPTS do
			success, result = pcall(function()
				return dataStore:GetAsync(key)
			end)
			if success then
				break
			end
			warn(string.format("[PlayerData] Load attempt %d for %s failed: %s", attempt, player.Name, tostring(result)))
			local message = tostring(result)
			if string.find(message, "403") or string.find(message, "Studio") then
				-- API access is disabled in Studio: retrying won't help.
				saveWarning = "Studio API access is off, so progress won't be saved. (Game Settings > Security > Enable Studio Access to API Services)"
				break
			end
			if attempt < MAX_LOAD_ATTEMPTS then
				task.wait(attempt * 1.5)
			end
		end
		if success then
			session.Profile = sanitize(result)
			session.CanSave = true
		else
			-- Never overwrite real saved data with a blank profile.
			session.CanSave = false
		end
	end

	session.Loaded = true
	createLeaderstats(player, session)
	PlayerData.recalculateIncome(player)
	PlayerData.replicate(player)
	return session
end

function PlayerData.save(player: Player): boolean
	local session = sessions[player]
	local dataStore = store
	if not session or not session.Loaded or not session.CanSave or not dataStore then
		return false
	end
	local profile = session.Profile
	local payload = {
		Version = 2,
		SavedAt = os.time(),
		Cash = profile.Cash,
		Levels = table.clone(profile.Levels),
		SpeedPoints = profile.SpeedPoints,
		Rebirths = profile.Rebirths,
		Stored = table.clone(profile.Stored),
		TotalStolen = profile.TotalStolen,
		TotalEarned = profile.TotalEarned,
		Discovered = table.clone(profile.Discovered),
	}
	local ok, err = pcall(function()
		dataStore:UpdateAsync(dataKey(player), function(_old: any)
			return payload
		end)
	end)
	if not ok then
		warn(string.format("[PlayerData] Failed to save %s: %s", player.Name, tostring(err)))
	end
	return ok
end

-- Saves and forgets a player (call when they leave).
function PlayerData.release(player: Player)
	insideHouse[player] = nil
	if sessions[player] then
		PlayerData.save(player)
		sessions[player] = nil
	end
end

function PlayerData.start()
	-- Autosave
	task.spawn(function()
		while true do
			task.wait(Config.Economy.AutosaveInterval)
			for player in sessions do
				task.spawn(PlayerData.save, player)
			end
		end
	end)

	-- Save everyone when the server shuts down.
	game:BindToClose(function()
		if not store then
			return
		end
		local pending = 0
		for player in sessions do
			pending += 1
			task.spawn(function()
				PlayerData.save(player)
				pending -= 1
			end)
		end
		local deadline = os.clock() + 25
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

return PlayerData
