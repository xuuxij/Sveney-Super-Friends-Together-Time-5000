-- Minigun spin sound: the barrel whine can be turned down or muted, on your
-- own screen only.
-- Every minigun (yours and your team's) plays the same looping sound,
-- S_Minigun_Spin. The gun sets its own volume for it on every frame (5% at
-- rest, 100% while spinning), so a volume written on the gun does not last.
-- The sound itself has a base volume (1 as shipped) that the engine applies
-- on top of the gun's and that the game never touches: that is what is set
-- here, so one write covers every minigun you hear.
-- Moving the slider plays a short sample at the new volume, as edit mode
-- cannot fire the gun.

local M = {}

local WAVE = "/Game/Items/Assets/Minigun/S_Minigun_Spin.S_Minigun_Spin"
local BASE_VOLUME = 1.0
local SAMPLE_PITCH = 2.0   -- the gun's pitch at full spin
local SAMPLE_S = 1.0
local SAMPLE_FADE_S = 0.25

local ctx, log
local wave, waveNextLoad = nil, 0
local sample, sampleStop = nil, nil
local diag = { writes = 0, samples = 0, err = nil }

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function valid(o)
    return o ~= nil and type(o) == "userdata" and try(function() return o:IsValid() end) == true
end

-- The sound is in memory while anyone holds a minigun. load: bring it in for
-- a sample (at most every 3 s).
local function findWave(load)
    if valid(wave) then return wave end
    wave = StaticFindObject(WAVE)
    if not valid(wave) and load then
        local t = ctx.FFWUi.now()
        if t >= waveNextLoad then
            waveNextLoad = t + 3
            pcall(function() LoadAsset(WAVE) end)
            wave = StaticFindObject(WAVE)
        end
    end
    if not valid(wave) then wave = nil end
    return wave
end

-- The player's choice, 0..1: the slider, or nothing when muted.
function M.volume()
    if not ctx.option("spinsound") then return 0 end
    local pct = tonumber(ctx.value("spinvol", 100)) or 100
    return math.max(0, math.min(100, pct)) / 100
end

-- Writes the choice to the sound when it differs. The game loads the sound
-- afresh (at full volume) after it has been out of memory, hence the check
-- on every slow tick.
local function apply(load)
    local w = findWave(load)
    if not w then return nil end
    local want = BASE_VOLUME * M.volume()
    local cur = try(function() return w.Volume end)
    if type(cur) ~= "number" then
        diag.err = "volume not readable"
        return nil
    end
    if math.abs(cur - want) > 0.001 then
        local ok, err = pcall(function() w.Volume = want end)
        if ok then diag.writes = diag.writes + 1 else diag.err = "write: " .. tostring(err) end
    end
    return w
end

local function stopSample(fade)
    local s = sample
    sample, sampleStop = nil, nil
    if not valid(s) then return end
    if not (fade and pcall(function() s:FadeOut(SAMPLE_FADE_S, 0.0, 0) end)) then pcall(function() s:Stop() end) end
end

-- The slider or the mute box changed (game thread): apply now and let the
-- player hear it.
function M.changed(pc)
    local w = apply(true)
    if not w or not pc then return end
    if valid(sample) then -- still playing: it follows the new volume by itself
        sampleStop = ctx.FFWUi.now() + SAMPLE_S
        return
    end
    if M.volume() <= 0 then return end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    -- context, sound, volume, pitch, start time, concurrency, persist across levels, auto destroy
    local ok, comp = pcall(function() return gs:SpawnSound2D(pc, w, 1.0, SAMPLE_PITCH, 0.0, nil, false, true) end)
    if not ok then
        ok, comp = pcall(function() return gs:SpawnSound2D(pc, w, 1.0, SAMPLE_PITCH, 0.0, CreateInvalidObject(), false, true) end)
    end
    if ok and valid(comp) then
        sample, sampleStop = comp, ctx.FFWUi.now() + SAMPLE_S
        diag.samples = diag.samples + 1
    elseif not ok then
        diag.err = "sample: " .. tostring(comp)
    end
end

function M.init(c)
    ctx, log = c, c.log
end

function M.tick(pc, t)
    if sampleStop and t >= sampleStop then stopSample(true) end
    apply(false)
end

-- The sample is a looping sound: it must never outlive edit mode or the map.
function M.reset()
    stopSample(false)
end

function M.dump()
    local w = findWave(false)
    log(string.format("  minigun spin sound: wanted=%.2f sound volume=%s (%s) writes=%d samples=%d sample playing=%s last error=%s",
        M.volume(), tostring(w and try(function() return w.Volume end)), w and "in memory" or "not in memory",
        diag.writes, diag.samples, tostring(valid(sample)), tostring(diag.err)))
end

return M
