--!strict
--[[
	Notifications
	-------------
	Player-facing toast popups are intentionally disabled. Gameplay feedback is
	kept in the persistent HUD and in the relevant shop/storage windows instead,
	so remote notification events never cover the play area.

	The module keeps the original API because the server and several UI actions
	still send informational results through it. Those calls are safely ignored.
]]

local Notifications = {}

function Notifications.init(_screen: ScreenGui)
	-- Deliberately no-op: do not create a popup container.
end

function Notifications.show(_text: string, _kind: string?)
	-- Deliberately no-op: player-facing toast popups have been removed.
end

return Notifications
