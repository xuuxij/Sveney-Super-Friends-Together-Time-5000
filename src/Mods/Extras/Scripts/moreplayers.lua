-- More Players panel: what the pack's MorePlayers mod is doing right now.
-- That mod runs in its own Lua state and publishes its state through UE4SS
-- shared variables once a second (see MorePlayers/Scripts/status.lua):
--   FFW_MP_tick     os.clock() of its last update; stale = the mod is not running
--   FFW_MP_players  players in the game, FFW_MP_cap / FFW_MP_capLive lobby size
--   FFW_MP_hp / FFW_MP_pace / FFW_MP_loot  multipliers against the 4-player values
--   FFW_MP_scaling, FFW_MP_colours, FFW_MP_pak, FFW_MP_host, FFW_MP_hooks
-- The player count shown is the live one from the game, so it never lags.

local M = {}

local READ_EVERY_S = 1
local STALE_S = 5                 -- no update for this long: the mod is not running
local SCALES_FROM = 5             -- lobbies of up to 4 are left as the game made them

local WIDTH, PAD, PITCH, TOP, EDIT_DX = 236, 14, 22, 32, 24
local MAX_ROWS = 9

local ctx, FFWUi, C, log
local nextRead = 0
local S = {}

local function shared(k)
    local ok, v = pcall(function() return ModRef:GetSharedVariable(k) end)
    if ok then return v end
    return nil
end

local function readState()
    local t = {}
    for _, k in ipairs({ "tick", "version", "players", "cap", "capLive", "host", "scaling", "hp", "pace", "loot", "colours", "pak", "hooks" }) do
        t[k] = shared("FFW_MP_" .. k)
    end
    S = t
end

local function running()
    return type(S.tick) == "number" and (FFWUi.now() - S.tick) < STALE_S
end

---------------------------------------------------------------------------
-- Rows
---------------------------------------------------------------------------
local function mult(v)
    v = tonumber(v) or 1
    local on = math.abs(v - 1) > 0.004
    return string.format("x%.2f", v), on and C.gold or C.dim, on
end

-- Each row: key (edit-mode switch), label, value, color, extra (off until switched on).
-- livePlayers: players in the game right now, or nil.
function M.rows(livePlayers)
    local rows = {}
    local scaled = false
    local function add(key, label, value, color, extra)
        rows[#rows + 1] = { key = key, label = label, value = value, color = color or C.text, extra = extra }
    end
    if not running() then return rows, "More Players is not running" end

    local cap = tonumber(S.cap) or 8
    local n = livePlayers or tonumber(S.players)
    if n == 0 then n = nil end
    local live = tonumber(S.capLive) or -1
    local capText = tostring(cap)
    if live >= 0 and live ~= cap then capText = string.format("%d (now %d)", cap, live) end
    add("players", "Players", (n and tostring(n) or "-") .. " / " .. capText)

    local scaling = tonumber(S.scaling) == 1
    if not scaling then
        add("hp", "Enemy health", "off", C.dim)
        add("pace", "Spawn pacing", "off", C.dim)
        add("loot", "Loot drops", "off", C.dim, true)
    else
        local hv, hc, hon = mult(S.hp)
        local pv, pcol, pon = mult(S.pace)
        local lv, lc, lon = mult(S.loot)
        scaled = hon or pon or lon
        add("hp", "Enemy health", hv, hc)
        add("pace", "Spawn pacing", pv, pcol)
        add("loot", "Loot drops", lv, lc, true)
    end
    local colours = tonumber(S.colours) == 1
    add("colours", "Extra colours", colours and "on" or "off", colours and C.text or C.dim, true)
    local pak = tonumber(S.pak) == 1
    add("pak", "Objective fixes", pak and "ok" or "MISSING", pak and C.text or C.gold, true)
    if tonumber(S.host) == 1 then add("host", "Hosting", "yes", C.text, true) end
    -- Says why everything reads x1.00 in a small lobby.
    if scaling and not scaled and n and n < SCALES_FROM then
        rows[#rows + 1] = { key = "hint", label = "Scaling starts at " .. SCALES_FROM .. " players", value = "", color = C.dim, labelColor = C.dim }
    end
    return rows
end

---------------------------------------------------------------------------
-- HUD (same look as the damage meter)
---------------------------------------------------------------------------
local function buildUi(p)
    local u = { panel = p, rows = {}, checks = {}, dx = 0 }
    u.bd = p:backdrop(WIDTH, TOP + PITCH + 8, 0.65, 0.35)
    FFWUi.setText(p:text(PAD, 8, 18, C.gold), "MORE PLAYERS")
    local inner = WIDTH - PAD * 2
    for i = 1, MAX_ROWS do
        local g = p:group(PAD, TOP + (i - 1) * PITCH)
        u.rows[i] = {
            group = g,
            label = g:text(0, 0, 17, C.soft, { width = inner, justify = 0, height = PITCH }),
            value = g:text(0, 0, 17, C.text, { width = inner, justify = 2, height = PITCH }),
        }
    end
    return u
end

local overlay

local function render(ui, rows, note)
    local editing = overlay:editing()
    local dx = editing and EDIT_DX or 0
    if ui.dx ~= dx then
        ui.dx = dx
        for i, w in ipairs(ui.rows) do ui.panel:move(w.group.slot, PAD + dx, TOP + (i - 1) * PITCH) end
    end
    local list = {}
    if note then
        list[1] = { row = { label = note, value = "", color = C.dim, labelColor = C.dim }, on = true }
    end
    for _, r in ipairs(rows) do
        local on = r.key == nil or overlay:itemShown(r.key, not r.extra)
        if on or editing then list[#list + 1] = { row = r, on = on } end
    end
    local n = math.min(#list, MAX_ROWS)
    local zones = {}
    for i = 1, MAX_ROWS do
        local w, e = ui.rows[i], list[i]
        local cb = ui.checks[i]
        if i > n then
            FFWUi.setShown(w.group, false)
            if cb then FFWUi.setShown(cb, false) end
        else
            local r = e.row
            FFWUi.setShown(w.group, true)
            FFWUi.setDim(w.group, not e.on)
            FFWUi.setText(w.label, r.label)
            FFWUi.setTextColor(w.label, r.labelColor or C.soft)
            FFWUi.setText(w.value, r.value)
            FFWUi.setTextColor(w.value, r.color)
            local boxed = editing and r.key ~= nil
            if boxed and not cb then
                cb = ui.panel:checkbox(PAD, TOP + (i - 1) * PITCH + 4)
                ui.checks[i] = cb
            end
            if cb then FFWUi.setShown(cb, boxed) end
            if boxed then
                FFWUi.setCheck(cb, e.on)
                zones[#zones + 1] = { key = r.key, default = not r.extra, x = 0, y = TOP + (i - 1) * PITCH, w = PAD + dx, h = PITCH }
            end
        end
    end
    overlay:setToggles(zones)
    local w, h = WIDTH + dx, TOP + math.max(n, 1) * PITCH + 8
    if ui.w ~= w or ui.h ~= h then
        ui.w, ui.h = w, h
        ui.panel:resizeBackdrop(ui.bd, w, h)
        overlay:setSize(w, h)
    end
end

---------------------------------------------------------------------------
-- Module interface
---------------------------------------------------------------------------
local function livePlayers(pc)
    local ok, n = pcall(function()
        local arr = pc:GetWorld().GameState.PlayerArray
        return #arr
    end)
    if ok and type(n) == "number" and n > 0 then return n end
    return nil
end

function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
    C = FFWUi.COLORS
    overlay = FFWUi.overlay({
        id = "MorePlayers", title = "MORE PLAYERS", z = 52,
        shown = true, pos = ctx.CONFIG.MORE_PLAYERS_POSITION,
        width = WIDTH, height = TOP + PITCH + 8,
        settings = ctx.MOD_DIR .. "/settings-moreplayers.txt",
        build = buildUi,
        refresh = function() M.tick(FFWUi.localController(), FFWUi.now()) end,
    })
    M.overlay = overlay
end

function M.tick(pc, t)
    if not pc then return end
    if t >= nextRead then
        nextRead = t + READ_EVERY_S
        readState()
    end
    local ui = overlay:update(pc, ctx.active(pc))
    if ui then
        local rows, note = M.rows(livePlayers(pc))
        render(ui, rows, note)
    end
end

function M.destroy()
    overlay:destroy()
end

function M.dump()
    readState()
    log(string.format("  more players: running=%s version=%s tick=%s now=%.1f hooks=%s", tostring(running()), tostring(S.version),
        tostring(S.tick), FFWUi.now(), tostring(S.hooks)))
    local rows, note = M.rows(livePlayers(FFWUi.localController()))
    if note then log("    " .. note) end
    for _, r in ipairs(rows) do log(string.format("    %-16s %s", r.label, r.value)) end
end

return M
