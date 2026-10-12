-- Extras: the small things our group wanted, in one mod.
--   More Players panel  what the More Players mod is doing right now
--   Speedometer         your speed as a number and a car-style dial
--   Auto dash           hold the dash button and you dash again each time you land
--   Muzzle flash        can be switched off
--   Kill streaks        MULTI KILL, MEGA KILL ... called out to the whole team
--   Clear zone          markers, pings and icons fade inside a circle around
--                       the crosshair, so you see what you aim at
--   Teammate hits       the teammate your shot lands on flashes in a colour
--                       you pick, your hit marker takes that colour and an
--                       error sound plays
--   Minigun spin sound  a volume slider and a mute box for the barrel whine
--   F9                  edit mode (shared with the other panels): move and
--                       resize the panels, and an OPTIONS list to switch each
--                       of the above on or off
--   Ctrl+F5             write what every part is doing to UE4SS.log
-- Each part lives in its own file next to this one.

local MOD_VERSION = "1.2.0"

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
local clearzone = require("clearzone")
local friendlyfire = require("friendlyfire")
local spinsound = require("spinsound")

---------------------------------------------------------------------------
-- Options (edit mode only)
---------------------------------------------------------------------------
-- panel: the row shows / hides that panel. Otherwise key is a switch read by a part.
-- slider: the row also has a 0..100 slider, kept under that name (default: where
-- it starts, 100 if not given; format: how its value is written, "70%" if not given).
-- swatches: the row is a choice of colours ({ name, rgb } each), with no
-- switch; the number of the picked one is kept under key.
-- changed runs (game thread) when the switch, the slider or the pick changes.
local OPTIONS = {
    { label = "Speedometer", hint = "your speed, as a dial and a number", panel = function() return speedometer.overlay end },
    { label = "More Players panel", hint = "lobby size and enemy scaling right now", panel = function() return moreplayers.overlay end },
    { key = "autodash", label = "Auto dash", hint = "keep dash held to dash again on every landing" },
    { key = "muzzle", label = "Muzzle flash", hint = "off: your own gun's flash no longer blocks your aim" },
    { key = "announcer", label = "Kill streaks", hint = "kills in a row: big text + sound, 25+ to team chat" },
    { key = "clearzone", label = "Clear zone at crosshair", hint = "markers fade inside the ring: drag for its size",
        slider = "clearzonepx", default = 50, format = function(pct) return (pct * 6) .. " px" end,
        changed = function(pc) clearzone.changed(pc) end },
    { key = "ffglow", label = "Teammate hit glow", hint = "a teammate you hit flashes in your colour" },
    { key = "ffmarker", label = "Teammate hit marker", hint = "your hit marker turns that colour too",
        changed = function(pc) friendlyfire.preview(pc, "marker") end },
    { key = "ffsound", label = "Teammate hit sound", hint = "a short error buzz when you hit a teammate",
        changed = function(pc) friendlyfire.preview(pc, "sound") end },
    { key = "ffcolor", label = "Teammate hit colour", hint = "for the glow and the hit marker: click one",
        swatches = friendlyfire.COLORS, changed = function(pc) friendlyfire.preview(pc, "marker") end },
    { key = "spinsound", label = "Minigun spin sound", hint = "the barrel whine of every minigun: untick to mute",
        slider = "spinvol", off = "MUTED", changed = function(pc) spinsound.changed(pc) end },
}

local OPT = { width = 400, pad = 16, top = 50, pitch = 44, slider = 28, swatchW = 30, swatchH = 18, swatchPitch = 37 }

-- Top of every row; a row with a slider or swatches is taller.
local function optionRows()
    local ys, y = {}, OPT.top
    for i, o in ipairs(OPTIONS) do
        ys[i] = y
        y = y + OPT.pitch + ((o.slider or o.swatches) and OPT.slider or 0)
    end
    return ys, y + 6
end

local options -- overlay, made below
local pendingChange = {} -- option key -> its switch was clicked (set on the input thread)

local function sliderPercent(o)
    local pct = tonumber(options:value(o.slider, o.default or 100)) or 100
    return math.max(0, math.min(100, math.floor(pct + 0.5)))
end

local function swatchIndex(o)
    local i = math.floor(tonumber(options:value(o.key, 1)) or 1)
    if o.swatches[i] then return i end
    return 1
end

local function optionOn(o)
    if o.panel then return o.panel().cfg.shown end
    return options:itemShown(o.key, true)
end

local function buildOptions(p)
    local u = { panel = p, checks = {}, states = {}, sliders = {}, seen = {}, swatches = {} }
    local ys, h = optionRows()
    p:backdrop(OPT.width, h, 0.85, 0.5)
    FFWUi.setText(p:text(OPT.pad, 8, 28, C.gold), "OPTIONS")
    local zones = {}
    for i, o in ipairs(OPTIONS) do
        local y = ys[i]
        if not o.swatches then u.checks[i] = p:checkbox(OPT.pad, y + 5) end
        FFWUi.setText(p:text(OPT.pad + 26, y - 2, 20, C.text), o.label)
        u.states[i] = p:text(0, y - 1, 18, C.gold, { width = OPT.width - OPT.pad, justify = 2, height = 24 })
        FFWUi.setText(p:text(OPT.pad + 26, y + 20, 14, C.soft, { font = "text" }), o.hint)
        local zone = { key = o.key or ("panel:" .. o.label), x = 0, y = y - 2, w = OPT.width, h = OPT.pitch }
        if o.swatches then
            -- Nothing to switch in the row itself: a click there moves the panel as anywhere else.
            zone = nil
            u.swatches[i] = {}
            local sx, sy = OPT.pad + 26, y + OPT.pitch - 2
            for j, c in ipairs(o.swatches) do
                local x = sx + (j - 1) * OPT.swatchPitch
                u.swatches[i][j] = p:box(x, sy, OPT.swatchW, OPT.swatchH, C.dim)
                p:box(x + 2, sy + 2, OPT.swatchW - 4, OPT.swatchH - 4, c.rgb)
                zones[#zones + 1] = {
                    key = "swatch:" .. o.key .. ":" .. j, x = x - 3, y = sy - 4, w = OPT.swatchPitch, h = OPT.slider,
                    toggle = function()
                        options.cfg.values[o.key] = j
                        options:_save()
                        pendingChange[o.key] = true
                    end,
                }
            end
        elseif o.panel then
            zone.toggle = function() o.panel():toggle() end
        elseif o.key == "announcer" then
            zone.toggle = function()
                local on = not options:itemShown(o.key, true)
                options.cfg.items[o.key] = on
                options:_save()
                if on then announcer.preview() end
            end
        elseif o.changed then
            zone.toggle = function()
                options.cfg.items[o.key] = not options:itemShown(o.key, true)
                options:_save()
                pendingChange[o.key] = true
            end
        end
        zones[#zones + 1] = zone
        if o.slider then
            local sx, sy, sw = OPT.pad + 26, y + OPT.pitch - 2, OPT.width - OPT.pad * 2 - 26
            u.sliders[i] = p:slider(sx, sy, sw, 18, 0.05)
            u.seen[i] = sliderPercent(o)
            FFWUi.moveSlider(u.sliders[i], u.seen[i] / 100)
            -- The engine's slider takes these clicks: they must not pick the panel up.
            zones[#zones + 1] = { key = "slider:" .. o.slider, x = 0, y = sy - 4, w = OPT.width, h = OPT.slider, toggle = function() end }
        end
    end
    u.zones = zones
    return u
end

-- Follows the sliders the player is dragging; a part hears of a change at once.
local function pollSliders(ui, pc)
    for i, o in ipairs(OPTIONS) do
        local s = ui.sliders[i]
        local v = s and FFWUi.sliderValue(s)
        if v then
            local pct = math.floor(v * 100 + 0.5)
            FFWUi.setSlider(s, pct / 100)
            if pct ~= ui.seen[i] then
                ui.seen[i] = pct
                options:setValue(o.slider, pct)
                o.changed(pc)
            end
        end
    end
end

local function renderOptions(ui, pc)
    for i, o in ipairs(OPTIONS) do
        local on = optionOn(o)
        local state, stateColor = on and "ON" or (o.off or "OFF"), on and C.gold or C.dim
        if o.swatches then
            local picked = swatchIndex(o)
            for j, frame in ipairs(ui.swatches[i]) do FFWUi.setBoxColor(frame, j == picked and C.text or C.dim) end
            state, stateColor = o.swatches[picked].name, o.swatches[picked].rgb
        else
            FFWUi.setCheck(ui.checks[i], on)
        end
        if o.slider then
            if on then state = o.format and o.format(sliderPercent(o)) or (sliderPercent(o) .. "%") end
            FFWUi.setDim(ui.sliders[i], not on)
        end
        FFWUi.setText(ui.states[i], state)
        FFWUi.setTextColor(ui.states[i], stateColor)
        if pendingChange[o.key] then
            pendingChange[o.key] = nil
            o.changed(pc)
        end
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
    -- A slider or a colour pick from the OPTIONS list.
    value = function(key, default) return options:value(key, default) end,
    -- There is something to draw: in a game, or the dev preview.
    active = function(pc) return CONFIG.DEV_SHOW or FFWUi.inGame(pc) end,
    editing = function() return options:editing() end,
}

moreplayers.init(ctx)
speedometer.init(ctx)
autodash.init(ctx)
muzzle.init(ctx)
announcer.init(ctx)
clearzone.init(ctx)
friendlyfire.init(ctx)
spinsound.init(ctx)

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
    id = "Options", title = "OPTIONS", z = 55, editOnly = true, interactive = true,
    shown = false, pos = CONFIG.OPTIONS_POSITION,
    width = OPT.width, height = select(2, optionRows()),
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
    clearzone.destroy()
    clearzone.reset()
    spinsound.reset()
    friendlyfire.reset()
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
    clearzone.tick(pc, t, inGame)
    friendlyfire.tick(pc, t, inGame)
    spinsound.tick(pc, t)
    local ui = options:update(pc, ctx.active(pc))
    if ui then renderOptions(ui, pc) end
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
        clearzone.reset()
        friendlyfire.reset()
    end
    autodash.tick(pc, t, FFWUi.inGame(pc))
    speedometer.tick(pc, t)
    announcer.fastTick(pc, t)
    friendlyfire.fastTick(pc, t)
    clearzone.fastTick(pc, t)
    if options:editing() then -- the sliders follow the mouse on every frame
        local ui = options:update(pc, ctx.active(pc))
        if ui then pollSliders(ui, pc) end
    end
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
    for _, o in ipairs(OPTIONS) do
        log(string.format("  option %-20s %s", o.label, o.swatches and o.swatches[swatchIndex(o)].name or (optionOn(o) and "on" or "off")))
    end
    for _, part in ipairs({ moreplayers, speedometer, autodash, muzzle, announcer, clearzone, friendlyfire, spinsound }) do
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
