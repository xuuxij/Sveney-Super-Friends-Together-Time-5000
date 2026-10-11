
---------------------------------------------------------------------------
-- DEV PROBE: appended to the game's copy of main.lua by devrun.ps1 -Probe.
-- Never part of the source tree or the pack. Hosts a private LAN session,
-- starts the first suggested mission, then runs whatever Lua is written to
-- cmd.lua in the scratch folder (a new first line makes it run again).
---------------------------------------------------------------------------
do
    local CMD = [[@CMD@]]
    local function P(label, f)
        local ok, v = pcall(f)
        log("probe " .. label .. ": " .. (ok and tostring(v) or ("ERR " .. tostring(v))))
    end
    local function at(ms, label, f)
        ExecuteInGameThreadWithDelay(ms, function() P(label, f) end)
    end

    at(28000, "create session", function()
        FindFirstOf("BP_Manager_Multiplayer_C"):F_CreateNewSession(true, false, true)
        return "called"
    end)
    if PROBE_MISSION ~= false then
        at(62000, "open mission map", function()
            FFWUi.localController().PlayerState:F_StartPreparation_Server()
            return "called"
        end)
        at(66000, "select contract", function()
            local m = FindFirstOf("BP_Manager_Contracts_C")
            m:F_SelectContract(m.suggestedContracts[1])
            return "called"
        end)
        at(67500, "go", function()
            local ui = FFWUi.localController().Pawn.UI_StartMission
            ui["BndEvt__UI_StartMission_Button_Go_K2Node_ComponentBoundEvent_7_OnButtonReleasedEvent__DelegateSignature"](ui)
            return "called"
        end)
        at(105000, "mission", function()
            local pc = FFWUi.localController()
            return pc:GetWorld():GetFName():ToString() .. " " .. pc.Pawn:GetClass():GetFName():ToString() .. " MISSION READY"
        end)
    end

    local env = setmetatable({
        FFWUi = FFWUi, log = log, CONFIG = CONFIG, C = C, options = options, dump = dump, P = P,
        autodash = autodash, muzzle = muzzle, announcer = announcer, moreplayers = moreplayers, speedometer = speedometer,
        pc = function() return FFWUi.localController() end,
        pawn = function() return FFWUi.localController().Pawn end,
        action = function(name)
            for _, a in ipairs(FindAllOf("InputAction") or {}) do
                if a:GetFName():ToString() == name then return a end
            end
        end,
        -- Presses an input action through Enhanced Input for `seconds`, then calls done.
        hold = function(act, vec, seconds, done)
            local sub = FindFirstOf("EnhancedInputLocalPlayerSubsystem")
            local t0 = os.clock()
            local function feed()
                if os.clock() - t0 > seconds then
                    if done then pcall(done) end
                    return
                end
                pcall(function() sub:InjectInputVectorForAction(act, vec, {}, {}) end)
                ExecuteInGameThreadWithDelay(8, function() pcall(feed) end)
            end
            feed()
        end,
        later = function(ms, f)
            ExecuteInGameThreadWithDelay(ms, function()
                local ok, e = pcall(f)
                if not ok then log("cmd later error: " .. tostring(e)) end
            end)
        end,
    }, { __index = _G })

    local last = nil
    local f0 = io.open(CMD, "r")
    if f0 then last = f0:read("a") f0:close() end -- whatever is there from the last run is not news
    LoopInGameThreadWithDelay(400, function()
        local f = io.open(CMD, "r")
        if not f then return end
        local src = f:read("a")
        f:close()
        if src == last or src == "" then return end
        last = src
        local fn, err = load(src, "=cmd", "t", env)
        if not fn then
            log("cmd compile error: " .. tostring(err))
            return
        end
        local ok, res = pcall(fn)
        log("cmd " .. (ok and "done: " or "ERR: ") .. tostring(res))
    end)
end
