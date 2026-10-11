-- Player-count scaling past 4 players.
-- Everything the game scales by player count goes through one Blueprint
-- function, BPFL_FunctionLibrary_C:F_GetCurveByNumberOfPlayers(curve):
-- it clamps the player count to 1..4 and reads a curve asset at that point:
--   C_PlayerAmount_EnemyLife          1 -> x1.0   4 -> x3.0   (enemy and boss health, F_AutoScaleLife)
--   C_PlayerAmount_EnemySpawnRate     1 -> x1.1   4 -> x0.3   (delay between storm-event spawns)
--   C_PlayerAmount_EnemyLootDropRate  1 -> x1.0   4 -> x0.5   (drop chance per kill)
--   C_PlayerAmount_LootChests         1 -> 50     4 -> 60
-- So with 5+ players vanilla keeps the 4-player values. This hook runs after
-- that function and, with more than 4 players, replaces its result:
--   health   HEALTH=auto: the curve's own line continued (3.0 + 0.667 per extra player),
--            or a factor per extra player (HEALTH=1.15: 3.0 x 1.15^(n-4))
--   pacing   the 4-player delay x PACING per extra player (0.90: 8 players spawn 1.5x as fast as 4)
--   loot     LOOT=hold: the 4-player rate; LOOT=auto: the line continued, floored at a quarter of it
--   chests   the 4-player value
-- Continuing the spawn-rate line itself would reach zero delay at 5 players,
-- and the loot line goes negative at 8, hence the gentler rules.

local M = {}

local HOOK = "/Game/Gamework/BPFL_FunctionLibrary.BPFL_FunctionLibrary_C:F_GetCurveByNumberOfPlayers"
local CURVES = {
    ["C_PlayerAmount_EnemyLife"] = "health",
    ["C_PlayerAmount_EnemySpawnRate"] = "pacing",
    ["C_PlayerAmount_EnemyLootDropRate"] = "loot",
    ["C_PlayerAmount_LootChests"] = "chests",
}
-- Fallback shape of each curve (1 player, 4 players) if the asset cannot be read.
local SHAPE = { health = { 1.0, 3.0 }, pacing = { 1.1, 0.3 }, loot = { 1.0, 0.5 }, chests = { 50, 60 } }

local ctx, log, CONFIG
local hooked = false
local calls, replaced = 0, 0
local last = {} -- kind -> { n = players, value = result, base = 4-player value }

local function v34(curve, kind)
    local v3, v4 = ctx.try(function() return curve:GetFloatValue(3.0), curve:GetFloatValue(4.0) end)
    if type(v3) ~= "number" or type(v4) ~= "number" then
        local s = SHAPE[kind]
        v4 = s[2]
        v3 = s[1] + (s[2] - s[1]) * 2 / 3
    end
    return v3, v4
end

-- The value for n players (n > 4) given the curve's 3- and 4-player values.
function M.valueFor(kind, n, v3, v4)
    local extra = n - 4
    if kind == "health" then
        local f = tonumber(CONFIG.HEALTH)
        if f then return v4 * f ^ extra end
        return v4 + (v4 - v3) * extra
    elseif kind == "pacing" then
        return v4 * CONFIG.PACING ^ extra
    elseif kind == "loot" then
        if CONFIG.LOOT == "auto" then return math.max(v4 + (v4 - v3) * extra, v4 * 0.25) end
        return v4
    end
    return v4
end

local function onCurve(self, Curve, Ctx, Value)
    calls = calls + 1
    local ok, err = pcall(function()
        if not CONFIG.SCALING then return end
        local n = ctx.playerCount()
        if not n or n <= 4 then return end
        local curve = Curve:get()
        if not curve:IsValid() then return end
        local kind = CURVES[curve:GetFName():ToString()]
        if not kind then return end
        local v3, v4 = v34(curve, kind)
        local v = M.valueFor(kind, n, v3, v4)
        local prev = last[kind]
        Value:set(v)
        replaced = replaced + 1
        last[kind] = { n = n, value = v, base = v4 }
        if CONFIG.DEV_LOG or not prev or prev.n ~= n then
            log(string.format("%s with %d players: %.3f (4 players: %.3f)", kind, n, v, v4))
        end
    end)
    if not ok then log("scaling hook: " .. tostring(err)) end
end

function M.init(c)
    ctx, log, CONFIG = c, c.log, c.CONFIG
    -- The function library loads early, but not before this mod; retry until it is there.
    local tries = 0
    local function tryHook()
        if hooked then return end
        tries = tries + 1
        local ok = pcall(RegisterHook, HOOK, onCurve)
        if ok then
            hooked = true
            ctx.hooks.scaling = true
            log("hooked " .. HOOK)
        elseif tries >= 200 then
            log("could not hook " .. HOOK .. "; enemies past 4 players scale as with 4")
        else
            ExecuteInGameThreadWithDelay(1500, tryHook)
        end
    end
    ExecuteInGameThreadWithDelay(1000, tryHook)
end

-- Multipliers relative to the 4-player values for n players, for the panel.
function M.multipliers(n)
    if not CONFIG.SCALING or not n or n <= 4 then return 1, 1, 1 end
    local function mult(kind)
        local l = last[kind]
        if l and l.n == n and l.base and l.base ~= 0 then return l.value / l.base end
        local s = SHAPE[kind]
        local v4 = s[2]
        local v3 = s[1] + (s[2] - s[1]) * 2 / 3
        return M.valueFor(kind, n, v3, v4) / v4
    end
    return mult("health"), mult("pacing"), mult("loot")
end

function M.state() return { hooked = hooked, calls = calls, replaced = replaced } end

return M
