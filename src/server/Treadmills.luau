--!strict
--[[
	Treadmills
	----------
	Every warehouse has its own treadmill out front. Walk onto yours and your
	character starts running by itself: there are no keys to hold, so you can
	go AFK and keep getting faster. ESCAPE (or Space) hops you off.

	Training hands out "speed" (see Config.Speed): every point is +4 studs/s of
	walk speed, which is how you outrun the faster security drones in the fancier
	houses. It never stops paying off - there is no speed cap - but you upgrade
	the treadmill itself (in the shop, or the prompt on its console) to train
	faster: every level doubles the speed gained and halves the wait between
	gains, so each level is four times as fast as the last.

	How a run works:
	  client  walks onto their own belt -> Remotes.Treadmill:InvokeServer("Start")
	  server  checks it's their treadmill and that they're standing on it, sets
	          the player's "Training" attribute and trains them every tick. No
	          input is needed, so AFK works. Training stops if they wander off,
	          die, sit down, lose their warehouse or leave.
	  client  ESCAPE / Space -> Remotes.Treadmill:InvokeServer("Stop")

	Map layout expected: Workspace.Map.Warehouses.Plot<N>.Treadmill (Model)
	  Belt        Part, the running surface
	  RunPoint    Part, where you run (its LookVector is the running direction)
	  ExitPoint   Part, where ESCAPE puts you (used by the client)
	  Console     Part, gets the "Upgrade" prompt
	  TreadmillText / TreadmillOwnerText  TextLabels on the console
	  Accent...   Parts recoloured to show the treadmill's level

	Attributes set on the Treadmill model for clients: OwnerUserId, Level, Running.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage.Shared.Config)
local Format = require(ReplicatedStorage.Shared.Format)
local Economy = require(script.Parent.Economy)
local Notify = require(script.Parent.Notify)
local PlayerData = require(script.Parent.PlayerData)
local Plots = require(script.Parent.Plots)

type Treadmill = {
	Model: Model,
	PlotModel: Model,
	RunPoint: BasePart,
	Accents: { BasePart },
	Prompt: ProximityPrompt?,
	LevelLabel: TextLabel?,
	OwnerLabel: TextLabel?,
	-- What the display currently shows, so it's only rewritten when something changes.
	Shown: string,
}

type Trainer = {
	Treadmill: Treadmill,
	AwayTime: number, -- seconds spent too far from the belt
	PendingPoints: number, -- speed gained since the last "Speed up!" toast
	LastToast: number,
}

local TICK = 0.25
-- "Start" is accepted from further away than Config.Treadmill.MaxDistance because the
-- server sees the character a little behind where the player's own screen has it.
local START_DISTANCE = 20
local AWAY_GRACE = 2 -- seconds you may spend off the belt before training stops
local TOAST_INTERVAL = 8 -- at most one "Speed up!" toast this often

local Treadmills = {}

local treadmills: { Treadmill } = {}
local trainers: { [Player]: Trainer } = {}

local function findTextLabel(container: Instance, name: string): TextLabel?
	local label = container:FindFirstChild(name, true)
	return if label and label:IsA("TextLabel") then label else nil
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- The treadmill outside the player's warehouse (nil if they don't have a warehouse).
local function treadmillFor(player: Player): Treadmill?
	local plot = Plots.getPlot(player)
	if not plot then
		return nil
	end
	for _, treadmill in treadmills do
		if treadmill.PlotModel == plot.Model then
			return treadmill
		end
	end
	return nil
end

-- Returns how far the player's character is from the treadmill, or nil if they
-- can't train right now (no character, dead, or sitting in a car).
local function distanceFrom(player: Player, treadmill: Treadmill): number?
	local character = player.Character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if not (humanoid and root and root:IsA("BasePart")) or humanoid.Health <= 0 or humanoid.SeatPart then
		return nil
	end
	return flatDistance(root.Position, treadmill.RunPoint.Position)
end

local function refreshDisplay(treadmill: Treadmill)
	local owner = Plots.getOwner(treadmill.PlotModel)
	local level = if owner then PlayerData.getUpgradeLevel(owner, "Treadmill") else 1
	local trainer = if owner then trainers[owner] else nil
	local running = trainer ~= nil and trainer.Treadmill == treadmill
	local ownerId = if owner then owner.UserId else 0
	local state = string.format("%d|%d|%s", ownerId, level, tostring(running))
	if treadmill.Shown == state then
		return
	end
	treadmill.Shown = state

	local model = treadmill.Model
	model:SetAttribute("OwnerUserId", ownerId)
	model:SetAttribute("Level", level)
	model:SetAttribute("Running", running)
	local color = Config.treadmillColor(level)
	for _, part in treadmill.Accents do
		part.Color = color
	end

	local rate = Config.treadmillText(level)
	if treadmill.LevelLabel then
		treadmill.LevelLabel.Text = if owner then string.format("LV %d\n⚡ %s", level, rate) else "EMPTY"
	end
	if treadmill.OwnerLabel then
		treadmill.OwnerLabel.Text = if owner then string.upper(owner.DisplayName) .. "'S TREADMILL" else "TREADMILL"
	end

	local prompt = treadmill.Prompt
	if prompt then
		local upgrade = Config.UpgradesById.Treadmill
		local maxed = level >= #upgrade.Costs
		prompt:SetAttribute("OwnerUserId", ownerId)
		prompt.ObjectText = string.format("Treadmill Lv %d (%s)", level, rate)
		prompt.ActionText = if maxed then "Maxed out!" else "Upgrade: " .. Format.money(upgrade.Costs[level + 1])
		prompt.Enabled = owner ~= nil and not maxed
	end
end

local function sendSpeedToast(player: Player, trainer: Trainer)
	local gained = trainer.PendingPoints
	if gained <= 0 then
		return
	end
	trainer.PendingPoints = 0
	trainer.LastToast = os.clock()
	Notify.send(
		player,
		string.format(
			"⚡ Speed up! +%d — Speed %s (%s studs/s)",
			gained,
			Format.commas(PlayerData.getSpeedStat(player)),
			Format.commas(PlayerData.getWalkSpeed(player))
		),
		"level"
	)
end

local function setTrainer(player: Player, trainer: Trainer?)
	if trainer then
		trainers[player] = trainer
	else
		trainers[player] = nil
	end
	player:SetAttribute("Training", trainer ~= nil)
	local treadmill = if trainer then trainer.Treadmill else treadmillFor(player)
	if treadmill then
		refreshDisplay(treadmill)
	end
end

-- Starts AFK training on the player's own treadmill. Returns (ok, reason).
function Treadmills.start(player: Player): (boolean, string)
	if trainers[player] then
		return true, ""
	end
	if not PlayerData.get(player) then
		return false, "Still loading your data..."
	end
	local treadmill = treadmillFor(player)
	if not treadmill then
		return false, "You need a warehouse to use a treadmill."
	end
	local distance = distanceFrom(player, treadmill)
	if not distance then
		return false, "You can't train right now."
	end
	if distance > START_DISTANCE then
		return false, "Walk onto your treadmill to train!"
	end
	setTrainer(player, { Treadmill = treadmill, AwayTime = 0, PendingPoints = 0, LastToast = 0 })
	return true, ""
end

-- Stops training (no-op if the player isn't training). `reason` is shown as a toast.
function Treadmills.stop(player: Player, reason: string?)
	local trainer = trainers[player]
	if not trainer then
		return
	end
	sendSpeedToast(player, trainer)
	setTrainer(player, nil)
	if reason and player.Parent then
		Notify.send(player, reason, "info")
	end
end

function Treadmills.isTraining(player: Player): boolean
	return trainers[player] ~= nil
end

local function train(player: Player, trainer: Trainer, dt: number)
	local treadmill = trainer.Treadmill
	if treadmillFor(player) ~= treadmill then
		Treadmills.stop(player)
		return
	end
	local distance = distanceFrom(player, treadmill)
	if not distance then
		Treadmills.stop(player)
		return
	end
	if distance > Config.Treadmill.MaxDistance then
		trainer.AwayTime += dt
		if trainer.AwayTime >= AWAY_GRACE then
			Treadmills.stop(player, "🏃 You left your treadmill, so training stopped.")
		end
		return
	end
	trainer.AwayTime = 0

	-- The treadmill's level sets how fast it trains: "amount every interval",
	-- doubling the amount and halving the interval with every level.
	local level = PlayerData.getUpgradeLevel(player, "Treadmill")
	local gained = PlayerData.addSpeed(player, Config.treadmillRate(level) * dt)
	if gained > 0 then
		trainer.PendingPoints += gained
	end
	if trainer.PendingPoints > 0 and os.clock() - trainer.LastToast >= TOAST_INTERVAL then
		sendSpeedToast(player, trainer)
	end
end

local function loop()
	local last = os.clock()
	while true do
		task.wait(TICK)
		local now = os.clock()
		local dt = math.min(now - last, 1) -- don't hand out a burst of speed after a server hitch
		last = now
		for player, trainer in trainers do
			if player.Parent then
				train(player, trainer, dt)
			else
				trainers[player] = nil
			end
		end
		-- Also picks up new owners, upgrades and players leaving.
		for _, treadmill in treadmills do
			refreshDisplay(treadmill)
		end
	end
end

local function addUpgradePrompt(treadmill: Treadmill, console: BasePart)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "UpgradeTreadmillPrompt"
	prompt.ActionText = "Upgrade"
	prompt.ObjectText = "Treadmill"
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt:SetAttribute("OwnerUserId", 0)
	prompt.Parent = console
	prompt.Triggered:Connect(function(player: Player)
		if Plots.getOwner(treadmill.PlotModel) ~= player then
			Notify.send(player, "That's not your treadmill! Yours is outside your own warehouse.", "error")
			return
		end
		local ok, message = Economy.purchase(player, "Treadmill")
		Notify.send(player, message, if ok then "success" else "error")
		refreshDisplay(treadmill)
	end)
	treadmill.Prompt = prompt
end

local function onRequest(player: Player, action: any): { Ok: boolean, Message: string }
	if action == "Start" then
		local ok, message = Treadmills.start(player)
		return { Ok = ok, Message = message }
	elseif action == "Stop" then
		Treadmills.stop(player)
		return { Ok = true, Message = "" }
	end
	return { Ok = false, Message = "Invalid request." }
end

function Treadmills.onPlayerRemoving(player: Player)
	trainers[player] = nil
end

function Treadmills.init()
	local map = Workspace:WaitForChild("Map")
	local folder = map:WaitForChild("Warehouses")
	for _, plotModel in folder:GetChildren() do
		local model = plotModel:FindFirstChild("Treadmill")
		if not (plotModel:IsA("Model") and model and model:IsA("Model")) then
			continue
		end
		local runPoint = model:FindFirstChild("RunPoint")
		if not (runPoint and runPoint:IsA("BasePart")) then
			warn("[Treadmills] Skipping " .. model:GetFullName() .. " (it has no RunPoint part)")
			continue
		end
		local accents: { BasePart } = {}
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and string.sub(descendant.Name, 1, 6) == "Accent" then
				table.insert(accents, descendant)
			end
		end
		local treadmill: Treadmill = {
			Model = model,
			PlotModel = plotModel,
			RunPoint = runPoint,
			Accents = accents,
			Prompt = nil,
			LevelLabel = findTextLabel(model, "TreadmillText"),
			OwnerLabel = findTextLabel(model, "TreadmillOwnerText"),
			Shown = "",
		}
		local console = model:FindFirstChild("Console")
		if console and console:IsA("BasePart") then
			addUpgradePrompt(treadmill, console)
		end
		table.insert(treadmills, treadmill)
		refreshDisplay(treadmill)
	end
	ReplicatedStorage.Remotes.Treadmill.OnServerInvoke = onRequest
	task.spawn(loop)
end

return Treadmills
