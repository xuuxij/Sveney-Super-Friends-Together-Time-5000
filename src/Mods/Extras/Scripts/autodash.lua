-- Auto dash: hold the dash button and you dash once each time you land, so
-- chaining dashes does not need the button mashed.
-- A landing is the character going from falling to not falling. The dash is
-- made by running the game's own "dash pressed" handler on the player, so its
-- rules still apply: you must be moving in a direction, and the dash must be
-- off cooldown (BP_Player_C.dashCount is the dashes ready to use). After a
-- dash the next one comes back about half a second after you land, so the
-- landing is remembered until then, as long as you stay on the ground and
-- keep the button held.

local M = {}

local DASH_ACTION = "IA_Dash"
local DASH_HANDLER = "InpActEvt_IA_Dash_K2Node_EnhancedInputActionEvent_8"
local WAIT_EXTRA_S = 0.3  -- remember a landing for the dash cooldown plus this
local RETRY_S = 0.05
local KEYS_EVERY_S = 5    -- re-read the key binding this often, for rebinds

local ctx, FFWUi, log
local action, actionNextSearch = nil, 0
local keys, keysAt = {}, -1e9
local wasFalling, pendingUntil, nextTry = false, nil, 0
local diag = { landings = 0, tries = 0, dashes = 0, err = nil, held = false, falling = false }

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function valid(o)
    return o ~= nil and type(o) == "userdata" and try(function() return o:IsValid() end) == true
end

-- The dash input action is an asset the player blueprint loads; searched for
-- (at most every 3 s) until it shows up.
local function findAction(t)
    if valid(action) then return action end
    action = nil
    if t < actionNextSearch then return nil end
    actionNextSearch = t + 3
    for _, a in ipairs(FindAllOf("InputAction") or {}) do
        if a:IsValid() and a:GetFName():ToString() == DASH_ACTION then
            action = a
            break
        end
    end
    return action
end

-- Names of the keys / buttons currently bound to dash.
local function readKeys(act, t)
    if t - keysAt < KEYS_EVERY_S then return end
    keysAt = t
    local found = {}
    local ok, err = pcall(function()
        local sub = FindFirstOf("EnhancedInputLocalPlayerSubsystem")
        -- Comes back as a Lua table of wrapped FKey structs (LeftShift, Gamepad_FaceButton_Right ...).
        for _, e in ipairs(sub:QueryKeysMappedToAction(act)) do
            local name = e:get().KeyName:ToString()
            if name and name ~= "" and name ~= "None" then found[#found + 1] = name end
        end
    end)
    if not ok then diag.err = "key lookup: " .. tostring(err) end
    if #found > 0 then keys = found end
end

local function dashHeld(pc)
    if ctx.CONFIG.DEV_HOLD then return true end
    for _, name in ipairs(keys) do
        if try(function() return pc:IsInputKeyDown({ KeyName = FName(name) }) end) == true then return true end
    end
    return false
end

-- A pawn without the property (menus) hands back a placeholder object, not nil.
local function dashesReady(pawn)
    local n = try(function() return pawn.dashCount end)
    return (type(n) == "number") and n or 0
end

-- Runs the game's handler for a dash press; true when a dash was used up.
local function pressDash(pawn, act)
    local before = dashesReady(pawn)
    -- action value, elapsed time, triggered time, source action
    local ok, err = pcall(function() pawn[DASH_HANDLER](pawn, {}, 0.0, 0.0, act) end)
    diag.tries = diag.tries + 1
    if not ok then
        diag.err = "dash call: " .. tostring(err)
        return true -- no point repeating a call that errors
    end
    local after = dashesReady(pawn)
    if ctx.CONFIG.DEV_LOG then log(string.format("auto dash try: dashes ready %d -> %d", before, after)) end
    return after < before
end

function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
end

function M.tick(pc, t, inGame)
    if not inGame or not ctx.option("autodash") then
        wasFalling, pendingUntil = false, nil
        return
    end
    local act = findAction(t)
    if not act then return end
    readKeys(act, t)
    local pawn = pc.Pawn
    local falling = try(function() return pawn.CharacterMovement:IsFalling() end) == true
    local landed = wasFalling and not falling
    wasFalling = falling
    local held = (landed or pendingUntil ~= nil) and dashHeld(pc)
    diag.falling, diag.held = falling, held
    if landed then
        diag.landings = diag.landings + 1
        local cooldown = try(function() return pawn.dashCooldown end)
        pendingUntil = held and (t + ((type(cooldown) == "number") and cooldown or 1) + WAIT_EXTRA_S) or nil
        nextTry = t
    end
    if pendingUntil then
        if not held or falling or t > pendingUntil then
            pendingUntil = nil
        elseif t >= nextTry and dashesReady(pawn) > 0 then
            -- No dash happens while you stand still; keep trying until you move or let go.
            nextTry = t + RETRY_S
            if pressDash(pawn, act) then
                diag.dashes = diag.dashes + 1
                pendingUntil = nil
            end
        end
    end
end

function M.dump()
    local pc = FFWUi.localController()
    log(string.format("  auto dash: on=%s action=%s keys=%s held now=%s", tostring(ctx.option("autodash")),
        tostring(valid(action)), table.concat(keys, ","), tostring(pc and dashHeld(pc))))
    log(string.format("    landings=%d tries=%d dashes=%d falling=%s waiting=%s last error=%s", diag.landings, diag.tries,
        diag.dashes, tostring(diag.falling), tostring(pendingUntil ~= nil), tostring(diag.err)))
    local pawn = pc and try(function() return pc.Pawn end)
    if valid(pawn) then
        log(string.format("    dashes ready=%d cooldown=%s s", dashesReady(pawn), tostring(try(function() return pawn.dashCooldown end))))
    end
end

return M
