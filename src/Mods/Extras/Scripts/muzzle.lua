-- Muzzle flash: switched off, the flash no longer covers what you aim at.
-- Two places make it, and both are handled on your own screen only:
--   guns with a Niagara part named Muzzle (Muzzle_L / Muzzle_R ...): hidden
--   bullets that carry their own muzzleEmitter (the Minigun's do): emptied
--     as each one is fired. UE4SS runs our hook after F_StartBullet, the
--     bullet draws its flash a moment later (F_MuzzleParticles), and the game
--     hands the bullet its effect back the next time it is fired, so
--     switching the flash back on needs nothing undone here.

local M = {}

local BULLET_FN = "/Game/Items/Assets/BP_PlayerBullet.BP_PlayerBullet_C:F_StartBullet"
local GUN_PARTS = { "Muzzle", "Muzzle_L", "Muzzle_R", "MuzzleL", "MuzzleR" }
local CHECK_EVERY_S = 0.5

local ctx, FFWUi, log
local off = false          -- the player wants no flash
local hooked, hookNextTry = false, 0
local saved = {}           -- bullet class address -> its muzzle effect, in case the game does not hand it back
local gunParts = {}        -- gun class address -> part names it has
local gunState = {}        -- gun address -> flash hidden
local nextCheck = 0
local diag = { bullets = 0, guns = 0, err = nil, clearBy = nil }

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function valid(o)
    return o ~= nil and type(o) == "userdata" and try(function() return o:IsValid() end) == true
end

-- Empties a bullet's muzzleEmitter; true when it reads back empty.
local function clearEmitter(bullet)
    local function empty() return not valid(try(function() return bullet.muzzleEmitter end)) end
    if pcall(function() bullet.muzzleEmitter = nil end) and empty() then
        diag.clearBy = "nil"
        return true
    end
    if pcall(function() bullet.muzzleEmitter = CreateInvalidObject() end) and empty() then
        diag.clearBy = "invalid object"
        return true
    end
    return false
end

-- Runs for every bullet fired (only once the flash has been switched off at
-- least once), so it stays small.
local function onBullet(self)
    local bullet = self:get()
    local cur = bullet.muzzleEmitter
    if valid(cur) then
        if not off then return end
        saved[bullet:GetClass():GetAddress()] = cur
        if clearEmitter(bullet) then diag.bullets = diag.bullets + 1 end
    elseif not off then
        local was = saved[bullet:GetClass():GetAddress()]
        if valid(was) then bullet.muzzleEmitter = was end
    end
end

local function tryHook(t)
    if hooked or t < hookNextTry then return end
    hookNextTry = t + 2
    if not valid(StaticFindObject(BULLET_FN)) then return end
    local ok, err = pcall(function()
        RegisterHook(BULLET_FN, function(self)
            local okb, e = pcall(onBullet, self)
            if not okb then diag.err = "bullet: " .. tostring(e) end
        end)
    end)
    hooked = ok
    if ok then log("muzzle: hooked " .. BULLET_FN) else diag.err = "hook: " .. tostring(err) end
end

-- Hides or shows the flash parts of the gun in hand.
local function applyToGun(pc)
    local item = try(function() return pc.Pawn.AC_PlayerItems.equipedItem end)
    if not valid(item) then return end
    local addr = item:GetAddress()
    if gunState[addr] == off then return end
    if gunState[addr] == nil and not off then return end -- never touched, nothing to undo
    local cls = try(function() return item:GetClass():GetAddress() end)
    local parts = cls and gunParts[cls]
    if not parts then
        parts = {}
        for _, name in ipairs(GUN_PARTS) do
            if valid(try(function() return item[name] end)) then parts[#parts + 1] = name end
        end
        if cls then gunParts[cls] = parts end
    end
    for _, name in ipairs(parts) do
        local ok, err = pcall(function() item[name]:SetVisibility(not off, false) end)
        if not ok then diag.err = "gun: " .. tostring(err) end
    end
    gunState[addr] = off
    if #parts > 0 then diag.guns = diag.guns + 1 end
end

function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
end

function M.tick(pc, t, inGame)
    if t < nextCheck then return end
    nextCheck = t + CHECK_EVERY_S
    off = not ctx.option("muzzle")
    if not inGame then return end
    if off then tryHook(t) end
    applyToGun(pc)
end

-- Guns belong to the map that just went away.
function M.reset()
    gunState = {}
end

function M.dump()
    log(string.format("  muzzle flash: off=%s hooked=%s bullets emptied=%d (by %s) guns changed=%d last error=%s",
        tostring(off), tostring(hooked), diag.bullets, tostring(diag.clearBy), diag.guns, tostring(diag.err)))
end

return M
