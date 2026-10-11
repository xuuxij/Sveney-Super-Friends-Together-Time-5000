-- Gold magnet objective. BP_GoldMagnet_C stores NumberOfPlayer = players in
-- the game and reads GoldDetectorSize[NumberOfPlayer] (the box that finds
-- gold) and ShadowDecalSize[NumberOfPlayer] (the crane shadow); both tables
-- have 5 entries, so with 5+ players the lookups are out of range and gold
-- pickup stops working. The game sets the value and calls
-- OnRep_NumberOfPlayer right after (on the host too); this runs after that
-- call, caps the value at 4 and runs the notify again so the shadow uses the
-- 4-player size. The detector lookup happens later each tick and sees the
-- capped value.

local M = {}

local CLASS = "/Game/Objectives/Assets/GoldMagnet/BP_GoldMagnet.BP_GoldMagnet_C"
local HOOK = CLASS .. ":OnRep_NumberOfPlayer"

local ctx, log
local hooked = false
local capped = 0
local busy = false

local function onRep(self)
    if busy then return end
    local ok, err = pcall(function()
        local magnet = self:get()
        if not magnet:IsValid() then return end
        local n = magnet.NumberOfPlayer
        if type(n) == "number" and n > 4 then
            magnet.NumberOfPlayer = 4
            capped = capped + 1
            log(string.format("gold magnet: %d players, using the 4-player table entry", n))
            busy = true
            pcall(function() magnet:OnRep_NumberOfPlayer() end)
            busy = false
        end
    end)
    busy = false
    if not ok then log("gold magnet hook: " .. tostring(err)) end
end

local function hook()
    if hooked then return true end
    local ok = pcall(RegisterHook, HOOK, onRep)
    if ok then
        hooked = true
        ctx.hooks.magnet = true
        log("hooked " .. HOOK)
    end
    return ok
end

function M.init(c)
    ctx, log = c, c.log
    -- The class only exists once a mission with the magnet loads it.
    pcall(NotifyOnNewObject, CLASS, function(obj)
        hook()
        return hooked
    end)
    -- Keeps trying (cheap) in case the construction notice is missed.
    local function tryHook()
        if not hook() then ExecuteInGameThreadWithDelay(5000, tryHook) end
    end
    ExecuteInGameThreadWithDelay(5000, tryHook)
end

function M.state() return { hooked = hooked, capped = capped } end

return M
