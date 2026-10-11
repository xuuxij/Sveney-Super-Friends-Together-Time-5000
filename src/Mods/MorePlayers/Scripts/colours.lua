-- Player name colours. The game gives each player state a colour index
-- (playerColor, 0..N-1 in name order) and BPFL_Gameplay_C:F_GetPlayerColor
-- maps it to one of four colours with index % 4, so players 5..8 repeat
-- players 1..4. This runs after that function and gives indices 4..7 their
-- own colours. Only how names and pings look; nothing is replicated.

local M = {}

local HOOK = "/Game/Gamework/BPFL_Gameplay.BPFL_Gameplay_C:F_GetPlayerColor"

-- 0..3 are the game's: green, orange, red, blue.
local PALETTE = {
    { R = 1.00, G = 0.20, B = 1.00 }, -- 4 magenta
    { R = 1.00, G = 0.92, B = 0.15 }, -- 5 yellow
    { R = 0.15, G = 0.95, B = 1.00 }, -- 6 cyan
    { R = 1.00, G = 0.55, B = 0.75 }, -- 7 pink
}

local ctx, log, CONFIG
local hooked = false
local applied = 0
local seen = {} -- index -> true, to log each new one once

local function onColour(self, PlayerState, WorldContext, Color)
    local ok, err = pcall(function()
        if not CONFIG.COLOURS then return end
        local ps = PlayerState:get()
        if not ps:IsValid() then return end
        local idx = ps.playerColor
        if type(idx) ~= "number" or idx < 4 then return end
        local p = PALETTE[(idx - 4) % #PALETTE + 1]
        local c = Color:get()
        c.R, c.G, c.B, c.A = p.R, p.G, p.B, 1.0
        applied = applied + 1
        if not seen[idx] then
            seen[idx] = true
            log(string.format("player colour %d -> (%.2f %.2f %.2f)", idx, p.R, p.G, p.B))
        end
    end)
    if not ok then log("colour hook: " .. tostring(err)) end
end

function M.init(c)
    ctx, log, CONFIG = c, c.log, c.CONFIG
    if not CONFIG.COLOURS then return end
    local tries = 0
    local function tryHook()
        if hooked then return end
        tries = tries + 1
        local ok = pcall(RegisterHook, HOOK, onColour)
        if ok then
            hooked = true
            ctx.hooks.colours = true
            log("hooked " .. HOOK)
        elseif tries < 200 then
            ExecuteInGameThreadWithDelay(1500, tryHook)
        end
    end
    ExecuteInGameThreadWithDelay(1000, tryHook)
end

function M.state() return { hooked = hooked, applied = applied } end

return M
