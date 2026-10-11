-- Publishes what the mod is doing. Other mods run in their own Lua state, so
-- the Extras panel reads these UE4SS shared variables once a second:
--   FFW_MP_tick      os.clock() of the last update (stale = mod not running)
--   FFW_MP_version   mod version
--   FFW_MP_players   players in the game now (0 when unknown)
--   FFW_MP_cap       lobby size this mod asks for
--   FFW_MP_capLive   the manager's lobby size right now (-1 = no manager)
--   FFW_MP_host      1 when this machine is the host
--   FFW_MP_scaling   1 when scaling past 4 players is on
--   FFW_MP_hp / FFW_MP_pace / FFW_MP_loot   multipliers against the 4-player values
--   FFW_MP_colours   1 when extra name colours are on
--   FFW_MP_pak       1 when the pack's pak files are next to the game
--   FFW_MP_hooks     which hooks are in place, e.g. "scaling,colours"
-- Also writes one line to the log when the player count changes.

local M = {}

local ctx, log, CONFIG
local cap, scaling
local pakPresent = nil
local lastPlayers = nil
local lastLog = 0

local function set(k, v) pcall(function() ModRef:SetSharedVariable(k, v) end) end

local function checkPak()
    -- <game>/FarFarWest/Binaries/Win64/ue4ss/Mods/MorePlayers -> <game>/FarFarWest/Content/Paks/~mods
    local base = ctx.MOD_DIR .. "/../../../../../Content/Paks/~mods/" .. CONFIG.PAK_NAME
    for _, ext in ipairs({ ".utoc", ".ucas", ".pak" }) do
        local f = io.open(base .. ext, "rb")
        if not f then return false end
        f:close()
    end
    return true
end

local function tick()
    local n = ctx.playerCount() or 0
    local hp, pace, loot = scaling.multipliers(n)
    local hooks = {}
    for k in pairs(ctx.hooks) do hooks[#hooks + 1] = k end
    table.sort(hooks)
    if pakPresent == nil then
        pakPresent = checkPak()
        if not pakPresent then log("pak " .. CONFIG.PAK_NAME .. " not found next to the game: objectives past 4 players will misbehave") end
    end
    set("FFW_MP_tick", os.clock())
    set("FFW_MP_version", ctx.VERSION)
    set("FFW_MP_players", n)
    set("FFW_MP_cap", CONFIG.MAX_PLAYERS)
    set("FFW_MP_capLive", cap.current() or -1)
    set("FFW_MP_host", ctx.isHost() and 1 or 0)
    set("FFW_MP_scaling", CONFIG.SCALING and 1 or 0)
    set("FFW_MP_hp", hp)
    set("FFW_MP_pace", pace)
    set("FFW_MP_loot", loot)
    set("FFW_MP_colours", CONFIG.COLOURS and 1 or 0)
    set("FFW_MP_pak", pakPresent and 1 or 0)
    set("FFW_MP_hooks", table.concat(hooks, ","))
    if n ~= lastPlayers or os.clock() - lastLog > 300 then
        lastPlayers, lastLog = n, os.clock()
        local s = scaling.state()
        log(string.format("players %d, lobby size %s, host %s, health x%.2f, pacing x%.2f, loot x%.2f, hooks %s, pak %s, scaling calls %d/%d replaced",
            n, tostring(cap.current() or "-"), ctx.isHost() and "yes" or "no", hp, pace, loot, table.concat(hooks, ","), pakPresent and "ok" or "MISSING", s.replaced, s.calls))
    end
end

function M.init(c)
    ctx, log, CONFIG = c, c.log, c.CONFIG
    cap, scaling = require("cap"), require("scaling")
    LoopInGameThreadWithDelay(1000, function()
        local ok, err = pcall(tick)
        if not ok then log("status: " .. tostring(err)) end
        return false
    end)
end

return M
