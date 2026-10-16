--!strict
--[[
	Format
	------
	Number formatting helpers shared by the server (notifications, labels) and
	the client (HUD, shop).
]]

local Format = {}

local SUFFIXES = { "", "K", "M", "B", "T", "Qd", "Qn" }

-- 1234567 -> "1,234,567"
function Format.commas(value: number): string
	local negative = value < 0
	local digits = tostring(math.floor(math.abs(value)))
	local result = ""
	local count = 0
	for index = #digits, 1, -1 do
		result = string.sub(digits, index, index) .. result
		count += 1
		if count % 3 == 0 and index > 1 then
			result = "," .. result
		end
	end
	return (if negative then "-" else "") .. result
end

-- 1234567 -> "1.23M"
function Format.short(value: number): string
	local negative = value < 0
	local amount = math.abs(value)
	if amount < 1000 then
		return (if negative then "-" else "") .. tostring(math.floor(amount))
	end
	local index = 1
	while amount >= 1000 and index < #SUFFIXES do
		amount /= 1000
		index += 1
	end
	local text: string
	if amount >= 100 then
		text = string.format("%d", math.floor(amount))
	elseif amount >= 10 then
		text = string.format("%.1f", math.floor(amount * 10) / 10)
	else
		text = string.format("%.2f", math.floor(amount * 100) / 100)
	end
	if string.find(text, ".", 1, true) then
		text = string.gsub(text, "0+$", "")
		text = string.gsub(text, "%.$", "")
	end
	return (if negative then "-" else "") .. text .. SUFFIXES[index]
end

-- Money with commas for small amounts and suffixes for big ones.
function Format.money(value: number): string
	if math.abs(value) < 1000000 then
		return "$" .. Format.commas(value)
	end
	return "$" .. Format.short(value)
end

-- Compact decimals with the trailing zeros trimmed: 4 -> "4", 0.5 -> "0.5", 0.03125 -> "0.031".
function Format.decimal(value: number, places: number?): string
	local text = string.format("%." .. tostring(math.max(places or 3, 0)) .. "f", value)
	if string.find(text, ".", 1, true) then
		text = string.gsub(text, "0+$", "")
		text = string.gsub(text, "%.$", "")
	end
	return text
end

return Format
