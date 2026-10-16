--!strict
--[[
	Plots
	-----
	Every player gets their own warehouse (up to 6 per server). Stolen items
	dropped on the green DEPOSIT pad go onto the shelves, where each one earns
	cash every second. Owners can sell shelf items with a prompt.

	When the warehouse is full, depositing a better item automatically sells
	your cheapest item to make room (and cheaper loot is sold on the spot).

	Map layout expected (built by tools/build_place.py):
	  Workspace.Map.Warehouses.Plot<N>  (Model, attribute PlotIndex)
	    Spawn       SpawnLocation
	    DepositPad  Part
	    Dock        Part (loading dock zone, reserved)
	    Slots       Folder of Parts (attribute Index = shelf order)
	    Treadmill   Model (the owner's personal treadmill, see Treadmills.luau)
	    ...a TextLabel named "OwnerText" and one named "StatsText"
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Format = require(ReplicatedStorage.Shared.Format)
local ItemModels = require(ReplicatedStorage.Shared.ItemModels)
local Items = require(ReplicatedStorage.Shared.Items)
local Inventory = require(script.Parent.Inventory)
local Notify = require(script.Parent.Notify)
local PlayerData = require(script.Parent.PlayerData)

type Plot = {
	Index: number,
	Model: Model,
	Owner: Player?,
	Spawn: SpawnLocation?,
	DepositPad: BasePart,
	Dock: BasePart,
	Slots: { BasePart },
	SlotColors: { Color3 },
	Display: Folder,
	OwnerLabel: TextLabel?,
	StatsLabel: TextLabel?,
}

local LOCKED_SLOT_COLOR = Color3.fromRGB(120, 40, 40)

local Plots = {}

local plots: { Plot } = {}
local plotByPlayer: { [Player]: Plot } = {}
local hubSpawn: SpawnLocation? = nil
local touchCooldown: { [Player]: number } = {}

local function findTextLabel(container: Instance, name: string): TextLabel?
	local found = container:FindFirstChild(name, true)
	if found and found:IsA("TextLabel") then
		return found
	end
	return nil
end

local function playerFromHit(hit: BasePart): Player?
	local model = hit:FindFirstAncestorOfClass("Model")
	if not model then
		return nil
	end
	return Players:GetPlayerFromCharacter(model)
end

local function numberAttribute(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	return if type(value) == "number" then value else 0
end

local function resetVisuals(plot: Plot)
	plot.Display:ClearAllChildren()
	for index, slot in plot.Slots do
		slot.Color = plot.SlotColors[index]
		slot.Transparency = 0
	end
	if plot.OwnerLabel then
		plot.OwnerLabel.Text = "EMPTY WAREHOUSE"
	end
	if plot.StatsLabel then
		plot.StatsLabel.Text = "Waiting for a new owner..."
	end
end

function Plots.getPlot(player: Player): Plot?
	return plotByPlayer[player]
end

-- The player who owns the warehouse `model` (nil while it's free).
function Plots.getOwner(model: Instance): Player?
	for _, plot in plots do
		if plot.Model == model then
			return plot.Owner
		end
	end
	return nil
end

-- How many items the player's warehouse can hold right now.
function Plots.getCapacity(player: Player): number
	local capacity = PlayerData.getUpgradeValue(player, "Storage")
	local plot = plotByPlayer[player]
	if plot and #plot.Slots > 0 then
		capacity = math.min(capacity, #plot.Slots)
	end
	return capacity
end

-- Where the player should appear after respawning or getting busted.
function Plots.getSpawnCFrame(player: Player): CFrame?
	local plot = plotByPlayer[player]
	local spawnPart: BasePart? = if plot and plot.Spawn then plot.Spawn else hubSpawn
	if spawnPart then
		return spawnPart.CFrame + Vector3.new(0, spawnPart.Size.Y / 2 + 3, 0)
	end
	return nil
end

local function updateStats(plot: Plot, player: Player)
	local session = PlayerData.get(player)
	if not plot.StatsLabel or not session then
		return
	end
	plot.StatsLabel.Text = string.format(
		"📦 Shelves: %d / %d\n💵 Income: %s / sec\n🦝 Items stolen: %s",
		#session.Profile.Stored,
		Plots.getCapacity(player),
		Format.money(session.Income),
		Format.commas(session.Profile.TotalStolen)
	)
end

function Plots.sell(player: Player, itemId: string): (boolean, string)
	local session = PlayerData.get(player)
	local def = Items.get(itemId)
	if not session or not def then
		return false, "That item has gone missing."
	end
	local index = table.find(session.Profile.Stored, itemId)
	if not index then
		return false, "That item is no longer on your shelves."
	end
	table.remove(session.Profile.Stored, index)
	local value = Items.getSellValue(itemId)
	PlayerData.addCash(player, value)
	PlayerData.recalculateIncome(player)
	Plots.refresh(player)
	return true, string.format("💵 Sold %s for %s", def.DisplayName, Format.money(value))
end

-- Everything on the player's shelves, in shelf order (the storage window lists it).
function Plots.storageList(player: Player): { string }
	local session = PlayerData.get(player)
	if not session then
		return {}
	end
	local items: { string } = {}
	for _, itemId in session.Profile.Stored do
		table.insert(items, itemId)
	end
	return items
end

local function addStoragePrompt(plot: Plot, target: BasePart, objectText: string, itemId: string?)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ShelfPrompt"
	prompt.ActionText = "Manage storage"
	prompt.ObjectText = objectText
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 6
	prompt.RequiresLineOfSight = false
	if itemId then
		prompt:SetAttribute("ItemId", itemId)
	end
	if plot.Owner then
		-- The client hides owner-only prompts from everyone else.
		prompt:SetAttribute("OwnerUserId", plot.Owner.UserId)
	end
	prompt.Parent = target
	prompt.Triggered:Connect(function(who: Player)
		if who ~= plot.Owner then
			Notify.send(who, "That's someone else's warehouse.", "error")
		end
	end)
end

-- Takes an item back off the shelves and into the player's bag (the opposite of depositing).
function Plots.take(player: Player, itemId: string): (boolean, string)
	local session = PlayerData.get(player)
	local def = Items.get(itemId)
	if not session or not def then
		return false, "That item is no longer on your shelves."
	end
	local index = table.find(session.Profile.Stored, itemId)
	if not index then
		return false, "That item is no longer on your shelves."
	end
	local capacity = PlayerData.getUpgradeValue(player, "Bag")
	if #session.Carried >= capacity then
		return false, string.format("🎒 Your bag is full (%d items). Sell something or upgrade your bag first.", capacity)
	end
	table.remove(session.Profile.Stored, index)
	Inventory.addCarried(player, itemId)
	PlayerData.recalculateIncome(player)
	Plots.refresh(player)
	return true, string.format("🎒 Took %s off the shelf (now in your bag).", def.DisplayName)
end

-- Rebuilds the shelf display, locked-slot colours and the stats board.
function Plots.refresh(player: Player)
	local plot = plotByPlayer[player]
	local session = PlayerData.get(player)
	if not plot or not session then
		return
	end
	local capacity = Plots.getCapacity(player)
	plot.Display:ClearAllChildren()
	for index, slot in plot.Slots do
		if index <= capacity then
			slot.Color = plot.SlotColors[index]
			slot.Transparency = 0
		else
			slot.Color = LOCKED_SLOT_COLOR
			slot.Transparency = 0.6
		end
	end
	for index, itemId in session.Profile.Stored do
		local slot = plot.Slots[index]
		if not slot then
			break
		end
		local model = ItemModels.build(itemId)
		if model then
			local root = model.PrimaryPart
			model:PivotTo(slot.CFrame * CFrame.new(0, slot.Size.Y / 2, 0))
			local def = Items.get(itemId)
			if root and def then
				addStoragePrompt(plot, root, string.format("%s (+%s/s)", def.DisplayName, Format.money(Items.getIncome(itemId))),
					itemId)
			end
			model.Parent = plot.Display
		end
	end
	updateStats(plot, player)
	player:SetAttribute("StorageCapacity", capacity)
	player:SetAttribute("StoredCount", #session.Profile.Stored)
end

-- Puts items into the player's warehouse, selling overflow smartly.
function Plots.deposit(player: Player, items: { string })
	local session = PlayerData.get(player)
	if not session or #items == 0 then
		return
	end
	local stored = session.Profile.Stored
	local capacity = Plots.getCapacity(player)
	local storedCount, soldCount, soldValue = 0, 0, 0

	for _, itemId in items do
		if #stored < capacity then
			table.insert(stored, itemId)
			storedCount += 1
		else
			-- Warehouse full: swap out the cheapest stored item if the new one is better.
			local cheapestIndex, cheapestValue = 0, math.huge
			for index, storedId in stored do
				local value = Items.getValue(storedId)
				if value < cheapestValue then
					cheapestIndex, cheapestValue = index, value
				end
			end
			if cheapestIndex > 0 and Items.getValue(itemId) > cheapestValue then
				soldValue += Items.getSellValue(stored[cheapestIndex])
				stored[cheapestIndex] = itemId
				storedCount += 1
			else
				soldValue += Items.getSellValue(itemId)
			end
			soldCount += 1
		end
	end

	-- Keep the most valuable items at the front of the shelves.
	table.sort(stored, function(a: string, b: string)
		return Items.getValue(a) > Items.getValue(b)
	end)

	if soldValue > 0 then
		PlayerData.addCash(player, soldValue)
	end
	PlayerData.recalculateIncome(player)
	Plots.refresh(player)

	if storedCount > 0 then
		Notify.send(
			player,
			string.format(
				"📦 Stashed %d item%s! Income: %s/sec",
				storedCount,
				if storedCount == 1 then "" else "s",
				Format.money(session.Income)
			),
			"success"
		)
	end
	if soldCount > 0 then
		Notify.send(
			player,
			string.format(
				"🏭 Warehouse full! Sold %d item%s for %s (upgrade Warehouse Space!)",
				soldCount,
				if soldCount == 1 then "" else "s",
				Format.money(soldValue)
			),
			"money"
		)
	end
end

-- Sells a list of items straight away (used when a player has no warehouse).
function Plots.sellAll(player: Player, items: { string })
	local total = 0
	for _, itemId in items do
		total += Items.getSellValue(itemId)
	end
	if total > 0 then
		PlayerData.addCash(player, total)
		Notify.send(
			player,
			string.format("💵 Sold %d item%s for %s", #items, if #items == 1 then "" else "s", Format.money(total)),
			"money"
		)
	end
end

local function onDepositTouched(plot: Plot, hit: BasePart)
	local player = playerFromHit(hit)
	if not player then
		return
	end
	local now = os.clock()
	if (touchCooldown[player] or 0) > now then
		return
	end
	touchCooldown[player] = now + 0.75
	if Inventory.getCarriedCount(player) == 0 then
		return
	end
	if plotByPlayer[player] == nil then
		-- Every warehouse is taken: let plotless players cash in their loot here.
		Plots.sellAll(player, Inventory.takeCarried(player))
		return
	end
	if plot.Owner ~= player then
		touchCooldown[player] = now + 4
		local ownerName = if plot.Owner then plot.Owner.DisplayName .. "'s" else "an empty"
		Notify.send(player, "This is " .. ownerName .. " warehouse! Follow the 🏠 marker to yours.", "warning")
		return
	end
	Plots.deposit(player, Inventory.takeCarried(player))
end

function Plots.assign(player: Player): Plot?
	local existing = plotByPlayer[player]
	if existing then
		return existing
	end
	for _, plot in plots do
		if plot.Owner == nil then
			plot.Owner = player
			plotByPlayer[player] = plot
			player:SetAttribute("PlotIndex", plot.Index)
			if plot.Spawn then
				player.RespawnLocation = plot.Spawn
			end
			if plot.OwnerLabel then
				plot.OwnerLabel.Text = string.upper(player.DisplayName) .. "'S WAREHOUSE"
			end
			if plot.StatsLabel then
				plot.StatsLabel.Text = "Loading..."
			end
			return plot
		end
	end
	-- Server is full of warehouse owners: fall back to the hub spawn.
	if hubSpawn then
		player.RespawnLocation = hubSpawn
	end
	return nil
end

function Plots.release(player: Player)
	local plot = plotByPlayer[player]
	plotByPlayer[player] = nil
	touchCooldown[player] = nil
	if plot then
		plot.Owner = nil
		resetVisuals(plot)
	end
end

function Plots.init()
	local map = Workspace:WaitForChild("Map")
	local folder = map:WaitForChild("Warehouses")
	local spawnCandidate = map:FindFirstChild("HubSpawn", true)
	if spawnCandidate and spawnCandidate:IsA("SpawnLocation") then
		hubSpawn = spawnCandidate
	end

	local models: { Model } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("PlotIndex") ~= nil then
			table.insert(models, child)
		end
	end
	table.sort(models, function(a: Model, b: Model)
		return numberAttribute(a, "PlotIndex") < numberAttribute(b, "PlotIndex")
	end)

	for _, model in models do
		local slots: { BasePart } = {}
		local slotsFolder = model:FindFirstChild("Slots")
		if slotsFolder then
			for _, slot in slotsFolder:GetChildren() do
				if slot:IsA("BasePart") then
					table.insert(slots, slot)
				end
			end
			table.sort(slots, function(a: BasePart, b: BasePart)
				return numberAttribute(a, "Index") < numberAttribute(b, "Index")
			end)
		end

		local depositPad = model:FindFirstChild("DepositPad")
		local dock = model:FindFirstChild("Dock")
		if not (depositPad and depositPad:IsA("BasePart") and dock and dock:IsA("BasePart")) then
			warn("[Plots] " .. model:GetFullName() .. " is missing DepositPad/Dock")
			continue
		end
		local spawnLocation = model:FindFirstChild("Spawn")

		local display = Instance.new("Folder")
		display.Name = "Display"
		display.Parent = model

		local plot: Plot = {
			Index = numberAttribute(model, "PlotIndex"),
			Model = model,
			Owner = nil,
			Spawn = if spawnLocation and spawnLocation:IsA("SpawnLocation") then spawnLocation else nil,
			DepositPad = depositPad,
			Dock = dock,
			Slots = slots,
			SlotColors = {},
			Display = display,
			OwnerLabel = findTextLabel(model, "OwnerText"),
			StatsLabel = findTextLabel(model, "StatsText"),
		}
		for index, slot in slots do
			plot.SlotColors[index] = slot.Color
		end
		depositPad.Touched:Connect(function(hit: BasePart)
			onDepositTouched(plot, hit)
		end)
		resetVisuals(plot)
		table.insert(plots, plot)
	end

	if #plots == 0 then
		warn("[Plots] No warehouse plots found in Workspace.Map.Warehouses")
	end

	-- The storage window (client/Storage.luau): list the shelves, take an item back
	-- into the bag, or sell it. Only the warehouse's owner may do any of it.
	local storageRemote = ReplicatedStorage.Remotes.Storage
	storageRemote.OnServerInvoke = function(player: Player, action: any, itemId: any)
		local plot = plotByPlayer[player]
		if not plot then
			return { Ok = false, Message = "You don't have a warehouse on this server.", Items = {} }
		end
		if action == "List" then
			return { Ok = true, Items = Plots.storageList(player) }
		end
		if action == "Take" and type(itemId) == "string" then
			local ok, message = Plots.take(player, itemId)
			Notify.send(player, message, if ok then "success" else "error")
			return { Ok = ok, Message = message, Items = Plots.storageList(player) }
		end
		if action == "Sell" and type(itemId) == "string" then
			local ok, message = Plots.sell(player, itemId)
			Notify.send(player, message, if ok then "money" else "error")
			return { Ok = ok, Message = message, Items = Plots.storageList(player) }
		end
		return { Ok = false, Message = "Unknown storage action.", Items = Plots.storageList(player) }
	end
end

return Plots
