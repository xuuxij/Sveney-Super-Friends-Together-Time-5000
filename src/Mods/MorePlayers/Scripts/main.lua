-- MorePlayers: lobbies of up to 8 (the game stops at 4), written for our pack.
-- What it does, each part in its own file next to this one:
--   cap.lua      raises the lobby size on the multiplayer manager (host) so a
--                5th..8th player is let in instead of kicked
--   scaling.lua  continues the game's own player-count scaling past 4 players:
--                enemy health keeps climbing on the designers' line, spawn
--                pacing gets a little faster per extra player, loot stays at
--                the 4-player rate
--   magnet.lua   the gold magnet objective reads a 5-entry table by player
--                count; past 4 it uses the 4-player entry
--   colours.lua  players 5..8 get their own name colours instead of repeating
--                players 1..4
--   status.lua   publishes what the mod is doing for the Extras panel
-- The objectives that break at 5+ players (TNT, totem, pillar, shredder, laser,
-- drill, sigil, ...) are fixed by the pack's own pak (ZZZ_SveneySuperFriendsTogetherTime5000_P), not here.
-- Settings: settings.txt next to Scripts (made with defaults on first run).

local MOD_VERSION = "1.0.0"

local MOD_DIR = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]Scripts[/\\][^/\\]+$")) or "."

local function log(msg) print("[MorePlayers] " .. msg .. "\n") end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
local DEFAULTS = {
    { "MAX_PLAYERS", "8", "lobby size, 4..8" },
    { "SCALING", "1", "1 = enemies keep scaling past 4 players, 0 = 5+ players play like 4" },
    { "HEALTH", "auto", "enemy health per extra player: auto = the game's own line (about +22% at 5), or a factor like 1.15" },
    { "PACING", "0.90", "enemy spawn delay factor per extra player (lower = more enemies)" },
    { "LOOT", "hold", "drop rate per kill past 4 players: hold = the 4-player rate, auto = the game's line (gets stingy fast)" },
    { "COLOURS", "1", "1 = players 5..8 get their own name colours" },
}

local SETTINGS_FILE = MOD_DIR .. "/settings.txt"

local function readSettings()
    local t = {}
    for _, d in ipairs(DEFAULTS) do t[d[1]] = d[2] end
    local f = io.open(SETTINGS_FILE, "r")
    if not f then
        local w = io.open(SETTINGS_FILE, "w")
        if w then
            w:write("; MorePlayers settings. Only the host's copy matters for the lobby size and the enemies.\n")
            for _, d in ipairs(DEFAULTS) do w:write(string.format("%s=%s   ; %s\n", d[1], d[2], d[3])) end
            w:close()
        end
        return t
    end
    for line in f:lines() do
        local k, v = line:match("^%s*([%u_]+)%s*=%s*([^;]-)%s*$")
        if k and v and v ~= "" and t[k] ~= nil then t[k] = v end
    end
    f:close()
    return t
end

local S = readSettings()
local maxPlayers = math.floor(tonumber(S.MAX_PLAYERS) or 8)
if maxPlayers < 4 then maxPlayers = 4 elseif maxPlayers > 8 then maxPlayers = 8 end

local CONFIG = {
    MAX_PLAYERS = maxPlayers,
    SCALING = S.SCALING ~= "0",
    HEALTH = S.HEALTH,                       -- "auto" or a number
    PACING = tonumber(S.PACING) or 0.90,
    LOOT = S.LOOT,                           -- "hold" or "auto"
    COLOURS = S.COLOURS ~= "0",
    PAK_NAME = "ZZZ_SveneySuperFriendsTogetherTime5000_P",
    DEV_LOG = false,                         -- dev only: log every hook call
}
if CONFIG.PACING < 0.5 then CONFIG.PACING = 0.5 elseif CONFIG.PACING > 1 then CONFIG.PACING = 1 end

---------------------------------------------------------------------------
-- Shared with the parts
---------------------------------------------------------------------------
local function try(f)
    local ok, v = pcall(f)
    if ok then return v end
    return nil
end

local pcCache, pcNext = nil, 0
local function localController()
    if pcCache and try(function() return pcCache:IsValid() end) then return pcCache end
    pcCache = nil
    if os.clock() < pcNext then return nil end
    pcNext = os.clock() + 2
    local all = FindAllOf("PlayerController")
    if all then
        for _, c in ipairs(all) do
            if c:IsValid() and c:IsLocalPlayerController() then pcCache = c break end
        end
    end
    return pcCache
end

-- Players in the game right now (the game's own PlayerArray), or nil.
local function playerCount()
    local pc = localController()
    if not pc then return nil end
    return try(function()
        local n = #pc:GetWorld().GameState.PlayerArray
        if type(n) == "number" and n > 0 then return n end
        return nil
    end)
end

local function isHost()
    local pc = localController()
    return pc ~= nil and try(function() return pc:HasAuthority() end) == true
end

local ctx = {
    VERSION = MOD_VERSION, CONFIG = CONFIG, MOD_DIR = MOD_DIR, log = log, try = try,
    localController = localController, playerCount = playerCount, isHost = isHost,
    hooks = {}, -- name -> true once a hook is in place (shown in the panel)
}

local cap = require("cap")
local scaling = require("scaling")
local magnet = require("magnet")
local colours = require("colours")
local status = require("status")

cap.init(ctx)
scaling.init(ctx)
magnet.init(ctx)
colours.init(ctx)
status.init(ctx)

log(string.format("v%s loaded: lobby size %d, scaling %s (health %s, pacing x%.2f per extra player, loot %s), colours %s",
    MOD_VERSION, CONFIG.MAX_PLAYERS, CONFIG.SCALING and "on" or "off", tostring(CONFIG.HEALTH), CONFIG.PACING, CONFIG.LOOT,
    CONFIG.COLOURS and "on" or "off"))

-- Ctrl+F5 in the Extras mod dumps its own state; ours goes to the log once a minute from status.lua.
