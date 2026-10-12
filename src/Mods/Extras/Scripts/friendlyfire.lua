-- Teammate hits: when one of your shots lands on a teammate, that teammate
-- flashes in a colour you pick, your hit marker takes the same colour and a
-- short error sound plays. Your own screen only.
-- The game lets players hurt each other (half damage, at most 25 a hit) and
-- shows the shooter its usual hit marker: white, or red for a critical hit.
-- The shooter's own game asks whatever a shot landed on for a hit marker
-- (F_HitMarkerRequest), and a player answers with the plain white one. UE4SS
-- runs our hook right after that answer, on the same frame, so the marker is
-- recoloured before it is drawn. Nothing needs undoing: the game sets the
-- marker's colour itself on every hit.
-- The glow uses two things every player already has: the body material's
-- GhostEmit colour (what makes a dead player's ghost shine blue) and the
-- lamp the Shine Bright joker lights. Both are set for the flash and put
-- back as they were.
-- The sound is not one the game keeps in memory, and loading it from inside
-- the hook froze the game. So the hook only notes what is wanted; the next
-- tick (a frame later) loads the sound if need be, plays it and runs the flash.

local UEHelpers = require("UEHelpers")

local M = {}

-- The colours on offer, in OPTIONS order; the first is the one you start with.
-- (Red is also the game's critical-hit marker.)
M.COLORS = {
    { name = "BLUE", rgb = { R = 0.0, G = 0.45, B = 1.0, A = 1.0 } },
    { name = "CYAN", rgb = { R = 0.0, G = 1.0, B = 1.0, A = 1.0 } },
    { name = "GREEN", rgb = { R = 0.1, G = 1.0, B = 0.1, A = 1.0 } },
    { name = "YELLOW", rgb = { R = 1.0, G = 0.85, B = 0.0, A = 1.0 } },
    { name = "ORANGE", rgb = { R = 1.0, G = 0.35, B = 0.0, A = 1.0 } },
    { name = "RED", rgb = { R = 1.0, G = 0.05, B = 0.05, A = 1.0 } },
    { name = "PINK", rgb = { R = 1.0, G = 0.1, B = 0.6, A = 1.0 } },
    { name = "PURPLE", rgb = { R = 0.55, G = 0.15, B = 1.0, A = 1.0 } },
    { name = "WHITE", rgb = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 } },
}

local HIT_FN = "/Game/Player/BP_Player.BP_Player_C:F_HitMarkerRequest"
local SOUND = "/Game/Levels/Assets/Area41/S_RotatingSymbol_Error.S_RotatingSymbol_Error" -- a 0.3 s buzz
local VOLUME = 0.6        -- about as loud as the game's own hit tick
local SOUND_EVERY_S = 0.5 -- a minigun lands many hits a second
local GLOW_EMIT = 20      -- how strongly the body shines in the colour
local GLOW_LAMP = 9000    -- the lamp while flashing (the joker's own glow is about 3000)
local LAMP_PER_LEVEL = 3000 -- the game's lamp strength per chromaLightLevel
local GLOW_S = 0.7        -- flashing goes on this long after the last hit
local GLOW_CYCLE_S, GLOW_ON_S = 0.34, 0.2 -- under three flashes a second

local ctx, FFWUi, log
local hooked, hookNextTry = false, 0
local nextSound, soundAsked = 0, false
local glowing = {}        -- teammate's address -> { pawn, since, till, on, mat, emit, lamp }
local diag = { hits = 0, tints = 0, sounds = 0, flashes = 0, err = nil }

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function valid(o)
    return o ~= nil and type(o) == "userdata" and try(function() return o:IsValid() end) == true
end

-- The colour picked in OPTIONS.
function M.color()
    local i = math.floor(tonumber(ctx.value("ffcolor", 1)) or 1)
    return M.COLORS[i] or M.COLORS[1]
end

-- The HUD is looked up on every use: it goes away with its map.
local function hud()
    local ui = try(function() return UEHelpers.GetGameInstance().refUiPlayer end)
    if valid(ui) then return ui end
    return nil
end

local function tint()
    local ui = hud()
    local img = ui and try(function() return ui.HitImage end)
    if not valid(img) then return end
    if pcall(function() img:SetColorAndOpacity(M.color().rgb) end) then diag.tints = diag.tints + 1 end
end

-- Tick only (it may load the sound).
local function play(pc)
    local snd = FFWUi.asset(SOUND)
    if not snd then
        diag.err = "sound not found"
        return
    end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    -- context, sound, volume, pitch, start time, concurrency, owner, UI sound
    local ok, err = pcall(function() gs:PlaySound2D(pc, snd, VOLUME, 1.0, 0.0, nil, nil, true) end)
    if not ok then
        ok, err = pcall(function()
            local none = CreateInvalidObject()
            gs:PlaySound2D(pc, snd, VOLUME, 1.0, 0.0, none, none, true)
        end)
    end
    if ok then diag.sounds = diag.sounds + 1 else diag.err = "sound: " .. tostring(err) end
end

local function bodyMaterial(mesh)
    local m = mesh:GetMaterial(0)
    if valid(m) then return m end
    return nil
end

-- Lights a teammate up in the picked colour, remembering what was there.
local function glowOn(g)
    local mesh, lamp = g.pawn.HeroSkeletal, g.pawn.ChromaticLight
    local m = bodyMaterial(mesh)
    -- A body material we have not coloured (the first flash, or the game put
    -- a new one on since): note its own shine before changing it.
    if m and m:GetAddress() ~= g.mat then
        local c = m:K2_GetVectorParameterValue(FName("GhostEmit"))
        g.emit = { X = c.R, Y = c.G, Z = c.B }
    end
    local c = M.color().rgb
    mesh:SetVectorParameterValueOnMaterials(FName("GhostEmit"), { X = c.R * GLOW_EMIT, Y = c.G * GLOW_EMIT, Z = c.B * GLOW_EMIT })
    m = bodyMaterial(mesh)
    g.mat = m and m:GetAddress() or nil
    if valid(lamp) then
        if not g.lamp then
            local lc = lamp.LightColor
            g.lamp = { R = lc.R / 255, G = lc.G / 255, B = lc.B / 255, A = 1.0 }
        end
        lamp:SetLightColor(c, true)
        lamp:SetIntensity(GLOW_LAMP)
    end
end

-- Back to the teammate's own look. A body material the game has replaced in
-- the meantime (a death turns it into the ghost's) is left alone.
local function glowOff(g)
    local mesh, lamp = g.pawn.HeroSkeletal, g.pawn.ChromaticLight
    local m = bodyMaterial(mesh)
    if g.emit and m and m:GetAddress() == g.mat then
        mesh:SetVectorParameterValueOnMaterials(FName("GhostEmit"), g.emit)
    end
    if valid(lamp) and g.lamp then
        lamp:SetLightColor(g.lamp, false)
        lamp:SetIntensity((tonumber(g.pawn.chromaLightLevel) or 0) * LAMP_PER_LEVEL)
    end
end

-- Switches each flashing teammate on and off.
local function flash(t)
    for addr, g in pairs(glowing) do
        local ok, err = pcall(function()
            if not valid(g.pawn) then error("gone") end
            local on = t < g.till and ((t - g.since) % GLOW_CYCLE_S) < GLOW_ON_S
            if on == g.on then return end
            g.on = on
            if on then
                glowOn(g)
                diag.flashes = diag.flashes + 1
            else
                glowOff(g)
            end
        end)
        if not ok and not tostring(err):find("gone") then diag.err = "glow: " .. tostring(err) end
        if not ok or t >= g.till then glowing[addr] = nil end
    end
end

-- Runs for every shot of yours that lands on a player. Nothing is loaded here.
local function onPlayerHit(self)
    local marker, sound, glow = ctx.option("ffmarker"), ctx.option("ffsound"), ctx.option("ffglow")
    if not (marker or sound or glow) then return end
    local pc = FFWUi.localController()
    if not pc then return end
    local hit, mine = self:get(), try(function() return pc.Pawn end)
    if valid(mine) and hit:GetAddress() == mine:GetAddress() then return end -- your own blast reached you
    diag.hits = diag.hits + 1
    local t = FFWUi.now()
    if marker then tint() end
    if glow then
        local addr = hit:GetAddress()
        local g = glowing[addr]
        if g then g.till = t + GLOW_S else glowing[addr] = { pawn = hit, since = t, till = t + GLOW_S, on = false } end
    end
    if sound and t >= nextSound then
        nextSound = t + SOUND_EVERY_S
        soundAsked = true
    end
end

local function tryHook(t)
    if hooked or t < hookNextTry then return end
    hookNextTry = t + 2
    if not valid(StaticFindObject(HIT_FN)) then return end
    local ok, err = pcall(function()
        RegisterHook(HIT_FN, function(self)
            local okh, e = pcall(onPlayerHit, self)
            if not okh then diag.err = "hit: " .. tostring(e) end
        end)
    end)
    hooked = ok
    if ok then log("teammate hits: hooked " .. HIT_FN) else diag.err = "hook: " .. tostring(err) end
end

-- An option was switched in edit mode (game thread): show what it does.
-- what: "marker" flashes the hit marker in the picked colour, "sound" plays the error sound.
function M.preview(pc, what)
    if what == "marker" and ctx.option("ffmarker") then
        local ui = hud()
        if ui and pcall(function() ui:F_HitMarker(false, false) end) then tint() end
    elseif what == "sound" and ctx.option("ffsound") and pc then
        play(pc)
    end
end

function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
end

function M.fastTick(pc, t)
    if soundAsked then
        soundAsked = false
        play(pc)
    end
    if next(glowing) then flash(t) end
end

function M.tick(pc, t, inGame)
    if inGame and (ctx.option("ffmarker") or ctx.option("ffsound") or ctx.option("ffglow")) then tryHook(t) end
end

-- The teammates belong to the map that just went away.
function M.reset()
    glowing = {}
    soundAsked = false
end

function M.dump()
    local n = 0
    for _ in pairs(glowing) do n = n + 1 end
    log(string.format("  teammate hits: colour=%s glow=%s marker=%s sound=%s hooked=%s hits=%d flashes=%d (flashing now %d) markers coloured=%d sounds=%d last error=%s",
        M.color().name, tostring(ctx.option("ffglow")), tostring(ctx.option("ffmarker")), tostring(ctx.option("ffsound")), tostring(hooked),
        diag.hits, diag.flashes, n, diag.tints, diag.sounds, tostring(diag.err)))
end

return M
