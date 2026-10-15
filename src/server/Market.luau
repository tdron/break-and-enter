--!strict
--[[
	Market
	------
	The sell point: the market stall in the middle of the yard, where loot is
	turned into cash on the spot instead of being shelved.

	  * Sells whatever the player is carrying (their bag).
	  * Also sells the car's trunk, but only while the car is parked at the stall.
	  * Pays Config.Economy.SellRatio of the item's value — the same as selling
	    straight off a warehouse shelf.

	The client window (client/SellPoint.luau) asks for the list, then sells by
	item or all at once; every sale is validated here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Items = require(ReplicatedStorage.Shared.Items)
local Inventory = require(script.Parent.Inventory)
local Notify = require(script.Parent.Notify)
local PlayerData = require(script.Parent.PlayerData)
local Vehicles = require(script.Parent.Vehicles)

type Sale = { ItemId: string, Source: string }

local Market = {}

local counter: BasePart? = nil

local BAG = "Bag"
local TRUNK = "Trunk"

-- Is the player's car parked close enough to the stall to unload its trunk?
local function carIsAtStall(player: Player): boolean
	local stall = counter
	local car = Vehicles.getCar(player)
	if not stall or not car then
		return false
	end
	local root = car.PrimaryPart or car:FindFirstChildWhichIsA("BasePart")
	if not root then
		return false
	end
	return (root.Position - stall.Position).Magnitude <= Config.Market.TrunkRange
end

-- Everything the player could sell right now.
function Market.list(player: Player): { Sale }
	local session = PlayerData.get(player)
	if not session then
		return {}
	end
	local sales: { Sale } = {}
	for _, itemId in session.Carried do
		table.insert(sales, { ItemId = itemId, Source = BAG })
	end
	if carIsAtStall(player) then
		for _, itemId in session.Profile.Trunk do
			table.insert(sales, { ItemId = itemId, Source = TRUNK })
		end
	end
	return sales
end

local function remove(list: { string }, itemId: string): boolean
	local index = table.find(list, itemId)
	if not index then
		return false
	end
	table.remove(list, index)
	return true
end

-- Sells one item. `source` is "Bag" or "Trunk"; the trunk needs the car at the stall.
function Market.sell(player: Player, itemId: string, source: string): (boolean, string)
	local session = PlayerData.get(player)
	local def = Items.get(itemId)
	if not session or not def then
		return false, "That item has gone missing."
	end
	local items = if source == TRUNK then session.Profile.Trunk else session.Carried
	if source == TRUNK and not carIsAtStall(player) then
		return false, "Park your car at the stall to sell what's in its trunk."
	end
	if not remove(items, itemId) then
		return false, string.format("No %s in your %s.", def.DisplayName, if source == TRUNK then "trunk" else "bag")
	end
	local value = Items.getSellValue(itemId)
	PlayerData.addCash(player, value)
	Inventory.refresh(player)
	if source == TRUNK then
		Vehicles.updateLabel(player)
	end
	return true, string.format("💵 Sold %s for %s", def.DisplayName, Format.money(value))
end

-- Sells everything the player brought to the stall. Returns (count, total).
function Market.sellAll(player: Player): (number, number)
	local total, count = 0, 0
	for _, sale in Market.list(player) do
		local ok = Market.sell(player, sale.ItemId, sale.Source)
		if ok then
			total += Items.getSellValue(sale.ItemId)
			count += 1
		end
	end
	return count, total
end

local function addPrompt()
	local map = Workspace:WaitForChild("Map")
	local found = map:FindFirstChild("SellCounter", true)
	if not (found and found:IsA("BasePart")) then
		warn("[Market] No SellCounter part found; the sell point is unavailable.")
		return
	end
	counter = found
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "OpenSellPrompt"
	prompt.ActionText = "Sell loot"
	prompt.ObjectText = "💰 SELL POINT"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = Config.Market.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = found
end

function Market.init()
	local remote = ReplicatedStorage.Remotes.Sell
	remote.OnServerInvoke = function(player: Player, action: any, itemId: any, source: any)
		if action == "List" then
			return {
				Ok = true,
				Sales = Market.list(player),
				TrunkReady = carIsAtStall(player),
				TrunkRange = Config.Market.TrunkRange,
			}
		end
		if action == "Sell" and type(itemId) == "string" then
			local ok, message = Market.sell(player, itemId, if source == TRUNK then TRUNK else BAG)
			if ok then
				Notify.send(player, message, "money")
			else
				Notify.send(player, message, "error")
			end
			return { Ok = ok, Message = message, TrunkReady = carIsAtStall(player) }
		end
		if action == "All" then
			local count, total = Market.sellAll(player)
			if count == 0 then
				return { Ok = false, Message = "You have nothing to sell — steal something first!", TrunkReady = carIsAtStall(player) }
			end
			Notify.send(player, string.format("💵 Sold %d item%s for %s!", count, if count == 1 then "" else "s",
				Format.money(total)), "money")
			return {
				Ok = true,
				Message = string.format("Sold %d for %s", count, Format.money(total)),
				Count = count,
				Value = total,
				TrunkReady = carIsAtStall(player),
			}
		end
		return { Ok = false, Message = "The trader doesn't understand that." }
	end
	addPrompt()
end

return Market
