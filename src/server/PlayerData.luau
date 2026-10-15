--!strict
--[[
	PlayerData
	----------
	Owns every player's saved profile (cash, upgrades, speed, warehouse and
	trunk contents) plus their in-session state (items currently carried).

	Important numbers are mirrored onto Player attributes so the client UI can
	react to them without any extra remotes:
	  Cash, Income, Carried, CarriedList, BagCapacity, TrunkCount, TrunkCapacity,
	  StoredCount, StorageCapacity, SpeedLevel, SpeedXP, SpeedXPNeeded,
	  WalkSpeed, Level_<UpgradeId>

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
	SpeedLevel: number,
	SpeedXP: number,
	Stored: { string },
	Trunk: { string },
	TotalStolen: number,
	TotalEarned: number,
}

export type Leaderstats = {
	Cash: IntValue,
	Stolen: IntValue,
	Speed: IntValue,
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
		SpeedLevel = 0,
		SpeedXP = 0,
		Stored = {},
		Trunk = {},
		TotalStolen = 0,
		TotalEarned = 0,
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
	profile.SpeedLevel = math.floor(readNumber(raw.SpeedLevel, 0, 0, Config.Speed.MaxLevel))
	profile.SpeedXP = readNumber(raw.SpeedXP, 0, 0, 1e9)
	profile.Stored = readItemList(raw.Stored, Config.getUpgradeValue("Storage", profile.Levels.Storage))
	profile.Trunk = readItemList(raw.Trunk, Config.getUpgradeValue("Trunk", profile.Levels.Trunk))
	profile.TotalStolen = math.floor(readNumber(raw.TotalStolen, 0, 0, 1e12))
	profile.TotalEarned = math.floor(readNumber(raw.TotalEarned, 0, 0, 1e18))
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

	folder.Parent = player
	session.Leaderstats = { Cash = cash, Stolen = stolen, Speed = speed }
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

function PlayerData.getWalkSpeed(player: Player): number
	local session = sessions[player]
	local level = if session then session.Profile.SpeedLevel else 0
	return Config.walkSpeedForLevel(level)
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
	player:SetAttribute("SpeedLevel", profile.SpeedLevel)
	player:SetAttribute("SpeedXP", profile.SpeedXP)
	player:SetAttribute("SpeedXPNeeded", Config.xpForLevel(profile.SpeedLevel))
	player:SetAttribute("SpeedMaxed", profile.SpeedLevel >= Config.Speed.MaxLevel)
	player:SetAttribute("WalkSpeed", PlayerData.getWalkSpeed(player))
	for _, upgrade in Config.Upgrades do
		player:SetAttribute("Level_" .. upgrade.Id, profile.Levels[upgrade.Id])
	end
	player:SetAttribute("BagCapacity", PlayerData.getUpgradeValue(player, "Bag"))
	player:SetAttribute("TrunkCapacity", PlayerData.getUpgradeValue(player, "Trunk"))
	player:SetAttribute("StorageCapacity", PlayerData.getUpgradeValue(player, "Storage"))
	player:SetAttribute("Carried", #session.Carried)
	player:SetAttribute("CarriedList", table.concat(session.Carried, ","))
	player:SetAttribute("TrunkCount", #profile.Trunk)
	player:SetAttribute("StoredCount", #profile.Stored)

	local stats = session.Leaderstats
	if stats then
		stats.Stolen.Value = profile.TotalStolen
		stats.Speed.Value = PlayerData.getWalkSpeed(player)
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
	session.Income = total
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

function PlayerData.applyWalkSpeed(player: Player)
	local walkSpeed = PlayerData.getWalkSpeed(player)
	player:SetAttribute("WalkSpeed", walkSpeed)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid then
		humanoid.WalkSpeed = walkSpeed
	end
	local session = sessions[player]
	local stats = if session then session.Leaderstats else nil
	if stats then
		stats.Speed.Value = walkSpeed
	end
end

-- Adds treadmill XP. Returns how many speed levels were gained.
function PlayerData.addSpeedXP(player: Player, amount: number): number
	local session = sessions[player]
	if not session then
		return 0
	end
	local profile = session.Profile
	if profile.SpeedLevel >= Config.Speed.MaxLevel then
		profile.SpeedXP = 0
		return 0
	end
	profile.SpeedXP += amount
	local gained = 0
	while profile.SpeedLevel < Config.Speed.MaxLevel and profile.SpeedXP >= Config.xpForLevel(profile.SpeedLevel) do
		profile.SpeedXP -= Config.xpForLevel(profile.SpeedLevel)
		profile.SpeedLevel += 1
		gained += 1
	end
	if profile.SpeedLevel >= Config.Speed.MaxLevel then
		profile.SpeedXP = 0
	end
	player:SetAttribute("SpeedLevel", profile.SpeedLevel)
	player:SetAttribute("SpeedXP", profile.SpeedXP)
	player:SetAttribute("SpeedXPNeeded", Config.xpForLevel(profile.SpeedLevel))
	player:SetAttribute("SpeedMaxed", profile.SpeedLevel >= Config.Speed.MaxLevel)
	if gained > 0 then
		PlayerData.applyWalkSpeed(player)
	end
	return gained
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
		Version = 1,
		SavedAt = os.time(),
		Cash = profile.Cash,
		Levels = table.clone(profile.Levels),
		SpeedLevel = profile.SpeedLevel,
		SpeedXP = profile.SpeedXP,
		Stored = table.clone(profile.Stored),
		Trunk = table.clone(profile.Trunk),
		TotalStolen = profile.TotalStolen,
		TotalEarned = profile.TotalEarned,
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
