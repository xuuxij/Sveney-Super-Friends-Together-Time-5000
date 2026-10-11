-- DamageMeter: shows your damage over time on the HUD.
--   DPS      rolling average over the last WINDOW_SECONDS
--   Total    damage dealt on the current map
--   Kills    enemies killed on the current map
--   Peak     best one-second damage on the current map
--   All time kills and damage over every session (totals.txt)
--   Graph    damage per second for the last GRAPH_SECONDS
-- DPS/Total/Peak/Graph come from the game's damage-number popup
-- (BP_Pool_Damages_C:F_ShowDamages), so they count exactly what you see.
-- Kills and the all-time totals come from the game's own run leaderboard
-- (PlayerState.playerRuntimeLeaderboardLocal), the numbers its end screen uses.
-- Ctrl+F7 logs both sources to UE4SS.log.

local MOD_VERSION = "1.3.0"

local CONFIG = {
    WINDOW_SECONDS = 3,      -- DPS averaging window
    GRAPH_SECONDS = 30,      -- bars in the graph, one per second
    REFRESH_MS = 200,        -- HUD refresh rate
    TOGGLE_KEY = Key.F7,     -- show / hide (remembered); F9 edits place, size and rows
    RESET_KEY = Key.F8,      -- zero this map's counters (all-time totals stay)
    -- Default spot: left edge, just below the middle. F9 in game moves it;
    -- the new spot is saved in settings.txt next to this mod.
    POSITION = { ax = 0, ay = 0.5, x = 36, y = 110 },
    WRITE_HISTORY = true,    -- append a line per map to history.csv
    DEV_SIMULATE = false,    -- dev only: fake hits so the HUD can be checked at the menu
}

local SHOW_DAMAGES_FN = "/Game/Interfaces/BP_Pool_Damages.BP_Pool_Damages_C:F_ShowDamages"
-- history.csv and settings.txt sit next to this mod's Scripts folder, whatever the working directory is.
local MOD_DIR = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]Scripts[/\\][^/\\]+$")) or "."
local HISTORY_FILE = MOD_DIR .. "/history.csv"
local TOTALS_FILE = MOD_DIR .. "/totals.txt"

-- FS_PlayerRuntimeLeaderboard fields keep their Blueprint GUID suffixes.
local LB = {
    kills = "enemies_2_9973937A40A8847C477EFABB3A8ED2FB",
    deaths = "deaths_6_E827D02A4AC7FB19897FA9ADB3064FDC",
    spells = "spells_8_C39DCED7499CDBCE346B7087F1CB363E",
    shots = "shots_10_C6AE8BC44D8C7912EAC7E699B1AF3667",
    revives = "revives_13_9BCA79464C7F7ABF257AF885998B9569",
    itemDamages = "itemDamages_37_459AA0EF4C7AEA0A0B4EEA816F22EDCB",
    itemKills = "itemKills_43_CBE876614A89C77F9C985AB017057128",
}

local FFWUi = require("FFWUi")
local log = FFWUi.logger("DamageMeter")
local now = FFWUi.now

---------------------------------------------------------------------------
-- Stats
---------------------------------------------------------------------------
local stats = {}
local run = { addr = nil, last = nil, base = nil, rebase = true }

local function resetStats()
    stats.start = now()
    stats.hits = {}          -- { t, dmg } inside the DPS window
    stats.buckets = {}       -- second index -> damage
    stats.total = 0
    stats.peak = 0
    stats.count = 0
    stats.lastHit = nil
    run.rebase = true        -- map kills count from here
end
resetStats()

local function record(dmg)
    if dmg <= 0 then return end
    local t = now()
    stats.hits[#stats.hits + 1] = { t, dmg }
    local sec = math.floor(t - stats.start)
    stats.buckets[sec] = (stats.buckets[sec] or 0) + dmg
    stats.total = stats.total + dmg
    stats.count = stats.count + 1
    stats.lastHit = t
end

local function currentDps(t)
    local cutoff = t - CONFIG.WINDOW_SECONDS
    local hits, sum, keep = stats.hits, 0, {}
    for i = 1, #hits do
        if hits[i][1] >= cutoff then
            keep[#keep + 1] = hits[i]
            sum = sum + hits[i][2]
        end
    end
    stats.hits = keep
    -- Ramp in for the first seconds so a single hit is not divided by the full window.
    local span = math.min(CONFIG.WINDOW_SECONDS, math.max(1, t - stats.start))
    return sum / span
end

local function updatePeak(t)
    -- Only completed seconds count, so the peak never shows a half-filled second.
    local sec = math.floor(t - stats.start) - 1
    local v = stats.buckets[sec]
    if v and v > stats.peak then stats.peak = v end
end

local function fmt(n)
    local s = tostring(math.floor(n + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- 9,999 / 123.4K / 5.6M, for the all-time line.
local function fmtShort(n)
    local function one(v, unit) return (string.format("%.1f", v):gsub("%.0$", "")) .. unit end
    if n < 10000 then return fmt(n) end
    if n < 1e6 then return one(n / 1e3, "K") end
    if n < 1e9 then return one(n / 1e6, "M") end
    return one(n / 1e9, "B")
end

---------------------------------------------------------------------------
-- Kills and all-time totals, from the game's run leaderboard
---------------------------------------------------------------------------
local totals = { kills = 0, damage = 0, since = nil, dirty = false, savedAt = 0 }

local function loadTotals()
    local f = io.open(TOTALS_FILE, "r")
    if not f then return end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k == "kills" or k == "damage" then totals[k] = tonumber(v) or 0 end
        if k == "since" then totals.since = v end
    end
    f:close()
end
loadTotals()

local function saveTotals(force)
    if not totals.dirty or (not force and now() - totals.savedAt < 15) then return end
    local ok, err = pcall(function()
        local f = io.open(TOTALS_FILE, "w")
        if not f then return end
        totals.since = totals.since or os.date("!%Y-%m-%d")
        f:write("# All-time totals kept by the damage meter. Delete this file to start over.\n")
        f:write(string.format("kills=%d\ndamage=%d\nsince=%s\n", math.floor(totals.kills), math.floor(totals.damage), totals.since))
        f:close()
    end)
    totals.dirty, totals.savedAt = false, now()
    if not ok then log("totals write failed: " .. tostring(err)) end
end

local function readRun(pc)
    local ok, r = pcall(function()
        local ps = pc.PlayerState
        local lb = ps.playerRuntimeLeaderboardLocal
        local dmg = 0
        lb[LB.itemDamages]:ForEach(function(_, v) dmg = dmg + (tonumber(v:get()) or 0) end)
        return { kills = lb[LB.kills], damage = dmg, addr = ps:GetAddress() }
    end)
    if ok and r and type(r.kills) == "number" then return r end
    return nil
end

-- Adds whatever the game's counters gained since the last look to the
-- all-time totals. A player state seen for the first time only sets the
-- starting point; a counter going down means the game reset it.
local function trackRun(pc)
    local r = readRun(pc)
    if not r then return end
    if r.addr ~= run.addr then
        run.addr, run.last = r.addr, r
        run.base = run.rebase and { kills = r.kills, damage = r.damage } or { kills = 0, damage = 0 }
        run.rebase = false
        return
    end
    if run.rebase then
        run.base, run.rebase = { kills = r.kills, damage = r.damage }, false
    end
    for _, k in ipairs({ "kills", "damage" }) do
        local d = r[k] - run.last[k]
        if d < 0 then d, run.base[k] = r[k], 0 end
        if d > 0 then
            totals[k] = totals[k] + d
            totals.dirty = true
        end
    end
    run.last = r
end

local function mapKills()
    if not run.last or not run.base then return nil end
    return math.max(0, run.last.kills - run.base.kills)
end

local HISTORY_HEADER = "date,map,seconds,total,avg_dps,peak_1s,hits,kills"

-- Files from before kills were tracked get the new column name in their header.
local function upgradeHistoryHeader()
    local f = io.open(HISTORY_FILE, "r")
    if not f then return end
    local content = f:read("a")
    f:close()
    local first = content:match("^[^\n]*")
    if first == "date,map,seconds,total,avg_dps,peak_1s,hits" then
        local out = io.open(HISTORY_FILE, "w")
        if out then
            out:write(HISTORY_HEADER .. content:sub(#first + 1))
            out:close()
        end
    end
end

local function writeHistory(mapName)
    local k = mapKills() or 0
    -- Simulated hits (dev) never go into the player's history.
    if not CONFIG.WRITE_HISTORY or CONFIG.DEV_SIMULATE or (stats.total <= 0 and k <= 0) then return end
    local duration = math.max(1, (stats.lastHit or now()) - stats.start)
    local ok, err = pcall(function()
        upgradeHistoryHeader()
        local f = io.open(HISTORY_FILE, "a")
        if not f then return end
        if f:seek("end") == 0 then
            f:write(HISTORY_HEADER .. "\n")
        end
        f:write(string.format("%s,%s,%d,%d,%d,%d,%d,%d\n", os.date("!%Y-%m-%d %H:%M:%SZ"), mapName or "?",
            math.floor(duration), math.floor(stats.total), math.floor(stats.total / duration),
            math.floor(stats.peak), stats.count, k))
        f:close()
    end)
    if not ok then log("history write failed: " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- HUD (styled like the game's: gold label, white numbers, dark holder)
---------------------------------------------------------------------------
local C = FFWUi.COLORS
local BAR = { R = 1.0, G = 0.499, B = 0.0, A = 0.9 }
local BAR_NOW = { R = 1.0, G = 0.8, B = 0.25, A = 1.0 }
local TRACK = { R = 0.0, G = 0.0, B = 0.0, A = 0.3 }

local LAYOUT = { width = 236, pad = 14, graphHeight = 40, editDx = 24 }

-- Rows that can be switched off in edit mode (F9), top to bottom.
local ITEMS = {
    { key = "dps", height = 44 },
    { key = "total", height = 22 },
    { key = "kills", height = 22 },
    { key = "peak", height = 22 },
    { key = "alltime", height = 22 },
    { key = "graph", height = 52 },
}

local tick -- forward: edit-mode clicks redraw straight away

local function buildUi(p)
    local L = LAYOUT
    local u = { panel = p, bars = {}, groups = {}, checks = {} }
    u.bd = p:backdrop(L.width, 100, 0.65, 0.35)
    FFWUi.setText(p:text(L.pad, 8, 18, C.gold), "DAMAGE")
    local g = u.groups
    g.dps = p:group(L.pad, 0)
    u.dps = g.dps:text(0, -2, 32, C.text)
    g.total = p:group(L.pad, 0)
    u.total = g.total:text(0, 0, 18, C.soft)
    g.kills = p:group(L.pad, 0)
    u.kills = g.kills:text(0, 0, 18, C.soft)
    g.peak = p:group(L.pad, 0)
    u.peak = g.peak:text(0, 0, 18, C.soft)
    g.alltime = p:group(L.pad, 0)
    u.alltime = g.alltime:text(0, 0, 18, C.gold)

    g.graph = p:group(L.pad, 0)
    local n, gap = CONFIG.GRAPH_SECONDS, 2
    local barW = math.max(2, math.floor((L.width - L.pad * 2 + gap) / n) - gap)
    g.graph:box(0, 6, n * (barW + gap) - gap, L.graphHeight, TRACK)
    for i = 1, n do
        local x = (i - 1) * (barW + gap)
        local b = g.graph:box(x, 6 + L.graphHeight - 1, barW, 1, C.clear)
        b.x, b.w, b.h = x, barW, 1
        u.bars[i] = b
    end

    for _, it in ipairs(ITEMS) do u.checks[it.key] = p:checkbox(L.pad, 0) end
    return u
end

local overlay = FFWUi.overlay({
    id = "DamageMeter", title = "DAMAGE METER", keyName = "F7", z = 50,
    toggleKey = CONFIG.TOGGLE_KEY, shown = true, pos = CONFIG.POSITION,
    width = LAYOUT.width, height = 222,
    settings = MOD_DIR .. "/settings.txt",
    banner = true,
    build = buildUi,
    refresh = function() if tick then tick() end end,
})

-- Stacks the rows that are switched on; in edit mode every row shows, with a
-- tick box, and the switched-off ones are faded.
local function layoutUi(ui)
    local editing = overlay:editing()
    local sig = tostring(editing)
    for _, it in ipairs(ITEMS) do sig = sig .. (overlay:itemShown(it.key) and "1" or "0") end
    if sig == ui.sig then return end
    ui.sig = sig
    local L = LAYOUT
    local dx = editing and L.editDx or 0
    local y, zones = 30, {}
    for _, it in ipairs(ITEMS) do
        local on = overlay:itemShown(it.key)
        local g, cb = ui.groups[it.key], ui.checks[it.key]
        FFWUi.setShown(g, on or editing)
        FFWUi.setShown(cb, editing)
        if on or editing then
            ui.panel:move(g.slot, L.pad + dx, y)
            FFWUi.setDim(g, not on)
            ui.panel:move(cb.slot, L.pad, y + math.floor((it.height - 14) / 2))
            FFWUi.setCheck(cb, on)
            zones[#zones + 1] = { key = it.key, x = 0, y = y, w = L.pad + dx, h = it.height }
            y = y + it.height
        end
    end
    local w, h = L.width + dx, y + 8
    ui.panel:resizeBackdrop(ui.bd, w, h)
    overlay:setToggles(editing and zones or {})
    overlay:setSize(w, h)
end

local function refreshUi(ui, t)
    layoutUi(ui)
    FFWUi.setText(ui.dps, fmt(currentDps(t)) .. " DPS")
    FFWUi.setText(ui.total, "Total  " .. fmt(stats.total))
    local k = mapKills()
    FFWUi.setText(ui.kills, "Kills  " .. (k and fmt(k) or "-"))
    FFWUi.setText(ui.peak, "Peak  " .. fmt(stats.peak) .. " /s")
    FFWUi.setText(ui.alltime, "All time  " .. fmtShort(totals.kills) .. " kills  " .. fmtShort(totals.damage))

    local L = LAYOUT
    local cur = math.floor(t - stats.start)
    local n = CONFIG.GRAPH_SECONDS
    local maxV = 1
    for i = 0, n - 1 do
        local v = stats.buckets[cur - i]
        if v and v > maxV then maxV = v end
    end
    for i = 1, n do
        local v = stats.buckets[cur - (n - i)] or 0
        local bar = ui.bars[i]
        local h = math.max(1, math.floor(L.graphHeight * v / maxV + 0.5))
        if h ~= bar.h then
            ui.panel:move(bar.slot, bar.x, 6 + L.graphHeight - h, bar.w, h)
            bar.h = h
        end
        FFWUi.setBoxColor(bar, (v <= 0) and C.clear or ((i == n) and BAR_NOW or BAR))
    end
end

local function destroyUi()
    overlay:destroy()
end

FFWUi.beforeMapLoad(destroyUi)

---------------------------------------------------------------------------
-- World tracking: new map = new counters + fresh widget
---------------------------------------------------------------------------
local currentWorld = nil
local currentMap = nil

function tick()
    local t = now()
    local pc = FFWUi.localController()
    if not pc then return end
    local world = pc:GetWorld()
    if not world or not world:IsValid() then return end
    local key = world:GetAddress()
    if key ~= currentWorld then
        if currentWorld ~= nil then
            writeHistory(currentMap)
            log(string.format("map %s finished: total %d, peak %d/s, %d hits, %s kills", tostring(currentMap),
                math.floor(stats.total), math.floor(stats.peak), stats.count, tostring(mapKills())))
            saveTotals(true)
        end
        currentWorld = key
        local ok, name = pcall(function() return world:GetFName():ToString() end)
        currentMap = ok and name or "?"
        resetStats()
        destroyUi()
    end

    updatePeak(t)
    trackRun(pc)
    saveTotals(false)

    local ui = overlay:update(pc, CONFIG.DEV_SIMULATE or FFWUi.inGame(pc))
    if ui then refreshUi(ui, t) end
end

---------------------------------------------------------------------------
-- Hooks
---------------------------------------------------------------------------
local hooked = false

local function tryHook()
    if hooked then return true end
    local fn = StaticFindObject(SHOW_DAMAGES_FN)
    if not fn or not fn:IsValid() then
        pcall(function() LoadAsset("/Game/Interfaces/BP_Pool_Damages.BP_Pool_Damages") end)
        fn = StaticFindObject(SHOW_DAMAGES_FN)
    end
    if not fn or not fn:IsValid() then return false end
    local ok, err = pcall(function()
        RegisterHook(SHOW_DAMAGES_FN, function(self, location, color, damages)
            local okv, v = pcall(function() return damages:get() end)
            if okv and type(v) == "number" then record(v) end
        end)
    end)
    if ok then
        hooked = true
        log("hooked " .. SHOW_DAMAGES_FN)
    else
        log("hook failed: " .. tostring(err))
    end
    return hooked
end

---------------------------------------------------------------------------
-- Ctrl+F7: both damage sources side by side, for checking the numbers
---------------------------------------------------------------------------
local function dump()
    local pc = FFWUi.localController()
    log("---- damage dump v" .. MOD_VERSION .. " ----")
    log(string.format("  popups: map total=%d hits=%d peak=%d/s", math.floor(stats.total), stats.count, math.floor(stats.peak)))
    log(string.format("  map kills=%s  all time: kills=%d damage=%d since %s", tostring(mapKills()),
        math.floor(totals.kills), math.floor(totals.damage), tostring(totals.since)))
    if not pc then log("  no local controller") return end
    for _, which in ipairs({ "playerRuntimeLeaderboardLocal", "playerRuntimeLeaderboardReplicated" }) do
        local ok, err = pcall(function()
            local lb = pc.PlayerState[which]
            local parts = {}
            for _, f in ipairs({ "kills", "deaths", "spells", "shots", "revives" }) do
                parts[#parts + 1] = f .. "=" .. tostring(lb[LB[f]])
            end
            log("  " .. which .. ": " .. table.concat(parts, " "))
            lb[LB.itemDamages]:ForEach(function(k, v) log("    damage " .. k:get():ToString() .. " = " .. tostring(v:get())) end)
            lb[LB.itemKills]:ForEach(function(k, v) log("    kills  " .. k:get():ToString() .. " = " .. tostring(v:get())) end)
        end)
        if not ok then log("  " .. which .. ": " .. tostring(err)) end
    end
    log("---- end dump ----")
end

RegisterKeyBind(CONFIG.TOGGLE_KEY, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(dump)
        if not ok then log("dump failed: " .. tostring(err)) end
    end)
end)

RegisterKeyBind(CONFIG.RESET_KEY, function()
    ExecuteInGameThread(function()
        resetStats()
        log("counters reset")
    end)
end)

log("v" .. MOD_VERSION .. " loaded")

ExecuteInGameThreadWithDelay(3000, function()
    if not tryHook() then
        local handle
        handle = LoopInGameThreadWithDelay(2000, function()
            if tryHook() then CancelDelayedAction(handle) end
        end)
    end
    local lastErr = nil
    LoopInGameThreadWithDelay(CONFIG.REFRESH_MS, function()
        local ok, err = pcall(tick)
        if not ok and tostring(err) ~= lastErr then
            lastErr = tostring(err)
            log("tick error: " .. lastErr)
        end
    end)
    if CONFIG.DEV_SIMULATE then
        ExecuteInGameThreadWithDelay(5000, FFWUi.devReport)
        LoopInGameThreadWithDelay(150, function()
            if math.random() < 0.7 then record(math.random(20, 180)) end
        end)
    end
end)
