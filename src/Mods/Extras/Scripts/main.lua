-- Extras: the small things our group wanted, in one mod.
--   More Players panel  what the More Players mod is doing right now
--   Speedometer         your speed as a number and a car-style dial
--   Auto dash           hold the dash button and you dash again each time you land
--   Muzzle flash        can be switched off
--   Kill streaks        MULTI KILL, MEGA KILL ... called out to the whole team
--   F9                  edit mode (shared with the other panels): move and
--                       resize the panels, and an OPTIONS list to switch each
--                       of the above on or off
--   Ctrl+F5             write what every part is doing to UE4SS.log
-- Each part lives in its own file next to this one.

local MOD_VERSION = "1.0.0"

local CONFIG = {
    REFRESH_MS = 16,         -- landing checks and the dial needle
    SLOW_S = 0.25,           -- everything else
    DUMP_KEY = Key.F5,       -- with Ctrl
    -- Default spots. F9 in game moves them; each panel remembers its own.
    -- The right edge is free of the game's HUD: More Players above the middle,
    -- the speedometer below it (mirroring the damage meter on the left). The
    -- options open mid-screen.
    MORE_PLAYERS_POSITION = { ax = 1, ay = 0.5, x = -36, y = -110 },
    SPEEDOMETER_POSITION = { ax = 1, ay = 0.5, x = -36, y = 130 },
    OPTIONS_POSITION = { ax = 0.5, ay = 0.5, x = 0, y = 60 },
    ANNOUNCER_Y = 190,       -- from the top of the screen, centred
    DIAL_START = 2000,       -- top of the dial until you go faster
    DEV_SHOW = false,        -- dev only: draw everything outside gameplay, with sample values
    DEV_LOG = false,         -- dev only: log every auto-dash attempt
    DEV_EDIT = false,        -- dev only: open edit mode by itself shortly after start
    DEV_HOLD = false,        -- dev only: act as if the dash button is held
}

-- Settings files sit next to this mod's Scripts folder, whatever the working directory is.
local MOD_DIR = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]Scripts[/\\][^/\\]+$")) or "."

local FFWUi = require("FFWUi")
local log = FFWUi.logger("Extras")
local C = FFWUi.COLORS

local moreplayers = require("moreplayers")
local speedometer = require("speedometer")
local autodash = require("autodash")
local muzzle = require("muzzle")
local announcer = require("announcer")

---------------------------------------------------------------------------
-- Options (edit mode only)
---------------------------------------------------------------------------
-- panel: the row shows / hides that panel. Otherwise key is a switch read by a part.
local OPTIONS = {
    { label = "Speedometer", hint = "your speed, as a dial and a number", panel = function() return speedometer.overlay end },
    { label = "More Players panel", hint = "lobby size and enemy scaling right now", panel = function() return moreplayers.overlay end },
    { key = "autodash", label = "Auto dash", hint = "keep dash held to dash again on every landing" },
    { key = "muzzle", label = "Muzzle flash", hint = "off: your own gun's flash no longer blocks your aim" },
    { key = "announcer", label = "Kill streaks", hint = "kills in a row: big text + sound, 25+ to team chat" },
}

local OPT = { width = 400, pad = 16, top = 50, pitch = 44 }

local options -- overlay, made below

local function optionOn(o)
    if o.panel then return o.panel().cfg.shown end
    return options:itemShown(o.key, true)
end

local function buildOptions(p)
    local u = { panel = p, checks = {}, states = {} }
    local h = OPT.top + #OPTIONS * OPT.pitch + 6
    p:backdrop(OPT.width, h, 0.85, 0.5)
    FFWUi.setText(p:text(OPT.pad, 8, 28, C.gold), "OPTIONS")
    local zones = {}
    for i, o in ipairs(OPTIONS) do
        local y = OPT.top + (i - 1) * OPT.pitch
        u.checks[i] = p:checkbox(OPT.pad, y + 5)
        FFWUi.setText(p:text(OPT.pad + 26, y - 2, 20, C.text), o.label)
        u.states[i] = p:text(0, y - 1, 18, C.gold, { width = OPT.width - OPT.pad, justify = 2, height = 24 })
        FFWUi.setText(p:text(OPT.pad + 26, y + 20, 14, C.soft, { font = "text" }), o.hint)
        local zone = { key = o.key or ("panel:" .. o.label), x = 0, y = y - 2, w = OPT.width, h = OPT.pitch }
        if o.panel then
            zone.toggle = function() o.panel():toggle() end
        elseif o.key == "announcer" then
            zone.toggle = function()
                local on = not options:itemShown(o.key, true)
                options.cfg.items[o.key] = on
                options:_save()
                if on then announcer.preview() end
            end
        end
        zones[i] = zone
    end
    u.zones = zones
    return u
end

local function renderOptions(ui)
    for i, o in ipairs(OPTIONS) do
        local on = optionOn(o)
        FFWUi.setCheck(ui.checks[i], on)
        FFWUi.setText(ui.states[i], on and "ON" or "OFF")
        FFWUi.setTextColor(ui.states[i], on and C.gold or C.dim)
    end
    options:setToggles(ui.zones)
end

---------------------------------------------------------------------------
-- Shared with the parts
---------------------------------------------------------------------------
local ctx = {
    FFWUi = FFWUi, log = log, CONFIG = CONFIG, MOD_DIR = MOD_DIR,
    -- A switch from the OPTIONS list; everything starts switched on.
    option = function(key) return options:itemShown(key, true) end,
    -- There is something to draw: in a game, or the dev preview.
    active = function(pc) return CONFIG.DEV_SHOW or FFWUi.inGame(pc) end,
    editing = function() return options:editing() end,
}

moreplayers.init(ctx)
speedometer.init(ctx)
autodash.init(ctx)
muzzle.init(ctx)
announcer.init(ctx)

local slowTick -- forward: edit-mode clicks redraw straight away

-- No options file yet: this player has never seen the extras, so say once
-- that they exist and where to switch them.
local SETTINGS_FILE = MOD_DIR .. "/settings-options.txt"
local firstRun = true
do
    local f = io.open(SETTINGS_FILE, "r")
    if f then
        firstRun = false
        f:close()
    end
end

options = FFWUi.overlay({
    id = "Options", title = "OPTIONS", z = 55, editOnly = true,
    shown = false, pos = CONFIG.OPTIONS_POSITION,
    width = OPT.width, height = OPT.top + #OPTIONS * OPT.pitch + 6,
    settings = SETTINGS_FILE,
    build = buildOptions,
    refresh = function() if slowTick then slowTick(FFWUi.localController(), FFWUi.now()) end end,
})

---------------------------------------------------------------------------
-- Ticks
---------------------------------------------------------------------------
local function destroyUi()
    moreplayers.destroy()
    speedometer.destroy()
    announcer.destroy()
    options:destroy()
end

FFWUi.beforeMapLoad(destroyUi)

local currentWorld = nil
local nextSlow, nextSample = 0, 0

function slowTick(pc, t)
    if not pc then return end
    local inGame = FFWUi.inGame(pc)
    if firstRun and inGame then
        firstRun = false
        announcer.notice("EXTRAS ADDED", "F9: speedometer, auto dash, kill streaks and more on / off", 8)
        options:_save()
    end
    moreplayers.tick(pc, t)
    muzzle.tick(pc, t, inGame)
    announcer.tick(pc, t, inGame)
    local ui = options:update(pc, ctx.active(pc))
    if ui then renderOptions(ui) end
    if CONFIG.DEV_SHOW and t >= nextSample then -- dev: a sample announcement now and then
        nextSample = t + 9
        announcer.preview()
    end
end

local function tick()
    local pc = FFWUi.localController()
    if not pc then return end
    local t = FFWUi.now()
    local world = pc:GetWorld()
    if not world or not world:IsValid() then return end
    local key = world:GetAddress()
    if key ~= currentWorld then
        currentWorld = key
        destroyUi()
        speedometer.reset()
        muzzle.reset()
        announcer.reset()
    end
    autodash.tick(pc, t, FFWUi.inGame(pc))
    speedometer.tick(pc, t)
    announcer.fastTick(pc, t)
    if t >= nextSlow then
        nextSlow = t + CONFIG.SLOW_S
        slowTick(pc, t)
    end
end

---------------------------------------------------------------------------
-- Ctrl+F5: what every part is doing
---------------------------------------------------------------------------
local function dump()
    log("---- extras dump v" .. MOD_VERSION .. " ----")
    for _, o in ipairs(OPTIONS) do log(string.format("  option %-20s %s", o.label, optionOn(o) and "on" or "off")) end
    for _, part in ipairs({ moreplayers, speedometer, autodash, muzzle, announcer }) do
        local ok, err = pcall(part.dump)
        if not ok then log("  dump error: " .. tostring(err)) end
    end
    log("---- end dump ----")
end

RegisterKeyBind(CONFIG.DUMP_KEY, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(dump)
        if not ok then log("dump failed: " .. tostring(err)) end
    end)
end)

log("v" .. MOD_VERSION .. " loaded")

ExecuteInGameThreadWithDelay(3000, function()
    local lastErr = nil
    LoopInGameThreadWithDelay(CONFIG.REFRESH_MS, function()
        local ok, err = pcall(tick)
        if not ok and tostring(err) ~= lastErr then
            lastErr = tostring(err)
            log("tick error: " .. lastErr)
        end
    end)
    if CONFIG.DEV_EDIT then
        ExecuteInGameThreadWithDelay(25000, function() pcall(FFWUi.setLayout, true) end)
    end
end)
