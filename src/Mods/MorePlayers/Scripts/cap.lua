-- Lobby size. The multiplayer manager (BP_Manager_Multiplayer_C) carries
-- maxPlayers = 4; it goes into the session as the "maxPlayers" setting that
-- joiners compare against, and the host's player states kick anyone past it
-- (F_AutoKickIsRules). Raising that one number on the host lets 5..8 in.
-- The Steam session itself already allows 20 (absoluteMaxPlayerCount).
-- Raise-only: a game that allows more is left alone. Done when a manager is
-- constructed and again once a second, since a new manager appears on map
-- changes with the default of 4.

local M = {}

local MANAGER = "/Game/Gamework/BP_Manager_Multiplayer.BP_Manager_Multiplayer_C"

local ctx, log, CONFIG
local raised = 0
local lastSeen = nil -- the manager's current value, for the panel

local function raise(obj, why)
    local ok, err = pcall(function()
        if not obj:IsValid() then return end
        local cur = obj.maxPlayers
        if type(cur) ~= "number" then return end
        if cur < CONFIG.MAX_PLAYERS then
            obj.maxPlayers = CONFIG.MAX_PLAYERS
            raised = raised + 1
            log(string.format("lobby size %d -> %d (%s)", cur, CONFIG.MAX_PLAYERS, why))
            cur = CONFIG.MAX_PLAYERS
        end
        lastSeen = cur
    end)
    if not ok then log("lobby size: " .. tostring(err)) end
end

function M.init(c)
    ctx, log, CONFIG = c, c.log, c.CONFIG
    local ok, err = pcall(NotifyOnNewObject, MANAGER, function(obj)
        raise(obj, "new manager")
    end)
    if not ok then log("manager watch failed: " .. tostring(err)) end
    LoopInGameThreadWithDelay(1000, function()
        local mm = FindFirstOf("BP_Manager_Multiplayer_C")
        if mm and mm:IsValid() then raise(mm, "poll") else lastSeen = nil end
        return false
    end)
end

-- The manager's lobby size right now, or nil when there is no manager.
function M.current() return lastSeen end
function M.raisedCount() return raised end

return M
