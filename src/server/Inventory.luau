--!strict
--[[
	Inventory
	---------
	Tracks the loot a player is carrying on foot (reclaimed to its original world
	spot if a guard busts you) and the loot stashed in the warehouse (saved). Also
	shows a loot sack on the player's back that grows with every item they carry.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Items = require(ReplicatedStorage.Shared.Items)
local PlayerData = require(script.Parent.PlayerData)

export type LootOrigin = {
	HouseId: string,
	SpotId: string,
}

export type CarriedLoot = {
	ItemId: string,
	Origin: LootOrigin?,
}

type OriginSlot = {
	Origin: LootOrigin?,
}

local Inventory = {}

-- Origins deliberately live alongside PlayerData's string-only bag. A bag can also contain an
-- item taken back off a warehouse shelf, which has no active world-loot origin. Keeping one slot
-- per carried item preserves the precise source of fresh thefts without changing the existing
-- inventory/UI format.
local carriedOrigins: { [Player]: { OriginSlot } } = {}

local SACK_COLOR = Color3.fromRGB(150, 110, 62)

local function updateSack(player: Player, count: number)
	local character = player.Character
	if not character then
		return
	end
	local existing = character:FindFirstChild("LootSack")
	if count <= 0 then
		if existing then
			existing:Destroy()
		end
		return
	end

	local torso = (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")) :: BasePart?
	if not torso then
		return
	end

	local sack: Part
	if existing and existing:IsA("Part") then
		sack = existing
	else
		if existing then
			existing:Destroy()
		end
		sack = Instance.new("Part")
		sack.Name = "LootSack"
		sack.Shape = Enum.PartType.Ball
		sack.Material = Enum.Material.Fabric
		sack.Color = SACK_COLOR
		sack.CanCollide = false
		sack.CanQuery = false
		sack.CanTouch = false
		sack.Massless = true
		sack.TopSurface = Enum.SurfaceType.Smooth
		sack.BottomSurface = Enum.SurfaceType.Smooth

		local knot = Instance.new("Part")
		knot.Name = "Knot"
		knot.Size = Vector3.new(0.5, 0.5, 0.5)
		knot.Color = Color3.fromRGB(110, 78, 40)
		knot.Material = Enum.Material.Fabric
		knot.CanCollide = false
		knot.CanQuery = false
		knot.CanTouch = false
		knot.Massless = true
		knot.TopSurface = Enum.SurfaceType.Smooth
		knot.BottomSurface = Enum.SurfaceType.Smooth
		knot.Parent = sack

		local knotWeld = Instance.new("Weld")
		knotWeld.Name = "KnotWeld"
		knotWeld.Part0 = sack
		knotWeld.Part1 = knot
		knotWeld.Parent = knot

		local weld = Instance.new("Weld")
		weld.Name = "SackWeld"
		weld.Part0 = torso
		weld.Part1 = sack
		weld.Parent = sack

		local dollar = Instance.new("BillboardGui")
		dollar.Name = "Dollar"
		dollar.Size = UDim2.fromScale(1.2, 1.2)
		dollar.LightInfluence = 0
		dollar.MaxDistance = 80
		dollar.Parent = sack
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.Font = Enum.Font.FredokaOne
		label.Text = "$"
		label.TextScaled = true
		label.TextColor3 = Color3.fromRGB(255, 220, 90)
		label.TextStrokeTransparency = 0.2
		label.Parent = dollar

		sack.Parent = character
	end

	local diameter = math.min(1.4 + count * 0.22, 3.8)
	sack.Size = Vector3.new(diameter, diameter, diameter)

	local weld = sack:FindFirstChild("SackWeld")
	if weld and weld:IsA("Weld") then
		weld.Part0 = torso
		weld.C0 = CFrame.new(0, 0.3, torso.Size.Z / 2 + diameter / 2 - 0.35)
	end
	local knot = sack:FindFirstChild("Knot")
	local knotWeld = if knot then knot:FindFirstChild("KnotWeld") else nil
	if knotWeld and knotWeld:IsA("Weld") then
		knotWeld.C0 = CFrame.new(0, diameter / 2, 0)
	end
end

-- Pushes inventory numbers to attributes and refreshes the loot sack.
function Inventory.refresh(player: Player)
	local session = PlayerData.get(player)
	if not session then
		return
	end
	player:SetAttribute("Carried", #session.Carried)
	player:SetAttribute("CarriedList", table.concat(session.Carried, ","))
	updateSack(player, #session.Carried)
end

function Inventory.getCarriedCount(player: Player): number
	local session = PlayerData.get(player)
	return if session then #session.Carried else 0
end

function Inventory.getCarriedValue(player: Player): number
	local session = PlayerData.get(player)
	if not session then
		return 0
	end
	local total = 0
	for _, itemId in session.Carried do
		total += Items.getValue(itemId)
	end
	return total
end

-- Tries to put an item in the player's bag. Loot taken from a world spot carries its source
-- identity, while warehouse items deliberately pass nil because they are no longer tied to a live
-- loot spot.
function Inventory.addCarried(player: Player, itemId: string, origin: LootOrigin?): (boolean, string?)
	local session = PlayerData.get(player)
	if not session then
		return false, "Still loading your data..."
	end
	local capacity = PlayerData.getUpgradeValue(player, "Bag")
	if #session.Carried >= capacity then
		return false, "🎒 Your bag is full! Bring the loot to your warehouse."
	end
	table.insert(session.Carried, itemId)
	local origins = carriedOrigins[player]
	if not origins then
		origins = {}
		carriedOrigins[player] = origins
	end
	table.insert(origins, { Origin = origin })
	Inventory.refresh(player)
	return true, nil
end

-- Removes one bag item and its matching provenance. Market sales use this instead of mutating the
-- session array directly, so an item sold before a bust can never be returned a second time.
function Inventory.removeCarried(player: Player, itemId: string): boolean
	local session = PlayerData.get(player)
	if not session then
		return false
	end
	local index = table.find(session.Carried, itemId)
	if not index then
		return false
	end
	table.remove(session.Carried, index)
	local origins = carriedOrigins[player]
	if origins then
		table.remove(origins, index)
	end
	Inventory.refresh(player)
	return true
end

-- Empties the bag with the optional source for every item intact. Only the house-catch flow needs
-- these records; deposits and sales use takeCarried below and intentionally discard them.
function Inventory.takeCarriedWithOrigins(player: Player): { CarriedLoot }
	local session = PlayerData.get(player)
	if not session then
		return {}
	end
	local items = session.Carried
	local origins = carriedOrigins[player]
	local carried: { CarriedLoot } = {}
	for index, itemId in items do
		local slot = if origins then origins[index] else nil
		table.insert(carried, { ItemId = itemId, Origin = if slot then slot.Origin else nil })
	end
	session.Carried = {}
	carriedOrigins[player] = nil
	Inventory.refresh(player)
	return carried
end

-- Empties the bag and returns item IDs for callers that only need to deposit or sell them.
function Inventory.takeCarried(player: Player): { string }
	local carried = Inventory.takeCarriedWithOrigins(player)
	local items: { string } = {}
	for _, loot in carried do
		table.insert(items, loot.ItemId)
	end
	return items
end

function Inventory.forgetPlayer(player: Player)
	carriedOrigins[player] = nil
end

return Inventory
