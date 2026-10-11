-- Dev-only discovery mod. Never shipped in the pack.
-- 1. Generates the C++ header dump of every reflected class (once per launch).
-- 2. When a local pawn exists, logs its class chain, components and numeric
--    properties next to the class-default (base) values.
-- 3. Logs the first damage-number calls with their color/amount.

local TAG = "[FFWProbe] "
local function log(msg) print(TAG .. msg .. "\n") end

local SIMPLE = {
    FloatProperty = true, DoubleProperty = true, IntProperty = true, Int64Property = true,
    ByteProperty = true, BoolProperty = true, NameProperty = true, StrProperty = true,
}

local function fieldType(p)
    local ok, name = pcall(function() return p:GetClass():GetFName():ToString() end)
    return ok and name or "?"
end

local function fieldName(p)
    local ok, name = pcall(function() return p:GetFName():ToString() end)
    return ok and name or "?"
end

local function valueOf(obj, name)
    local ok, v = pcall(function() return obj[name] end)
    if not ok then return "<err>" end
    if type(v) == "userdata" then
        local ok2, s = pcall(function() return v:ToString() end)
        if ok2 then return s end
        local ok3, n = pcall(function() return v:GetFullName() end)
        if ok3 then return n end
        return "<ud>"
    end
    return tostring(v)
end

local function dumpObject(obj, label)
    local cls = obj:GetClass()
    local cdo = cls:GetCDO()
    log("=== " .. label .. " " .. obj:GetFullName())
    local s = cls
    while s and s:IsValid() do
        local owner = s:GetFullName()
        local n = 0
        s:ForEachProperty(function(p)
            n = n + 1
            local t = fieldType(p)
            local name = fieldName(p)
            if SIMPLE[t] then
                local cur, base = valueOf(obj, name), valueOf(cdo, name)
                log(string.format("  %s | %s : %s = %s (base %s)%s", owner, name, t, cur, base,
                    cur ~= base and "  <-- CHANGED" or ""))
            else
                log(string.format("  %s | %s : %s", owner, name, t))
            end
        end)
        s = s:GetSuperStruct()
        if s and s:IsValid() and s:GetFullName():find("/Script/Engine%.") then
            -- engine base classes are huge and not interesting
            log("  (stops at " .. s:GetFullName() .. ")")
            break
        end
    end
end

local dumpedPawn = false

local function tryDumpPawn()
    if dumpedPawn then return end
    local pcs = FindAllOf("PlayerController")
    if not pcs then return end
    for _, pc in ipairs(pcs) do
        if pc:IsValid() and pc:IsLocalPlayerController() then
            local pawn = pc.Pawn
            if pawn and pawn:IsValid() then
                dumpedPawn = true
                dumpObject(pc, "CONTROLLER")
                dumpObject(pawn, "PAWN")
                local ps = pc.PlayerState
                if ps and ps:IsValid() then dumpObject(ps, "PLAYERSTATE") end
                local comps = pawn:K2_GetComponentsByClass(StaticFindObject("/Script/Engine.ActorComponent"))
                local function logComp(c)
                    if c and c.IsValid and c:IsValid() then log("  COMPONENT " .. c:GetFullName()) end
                end
                if type(comps) == "table" then
                    for _, c in ipairs(comps) do logComp(c) end
                elseif comps then
                    comps:ForEach(function(_, e) logComp(e:get()) end)
                end
                local jm = FindFirstOf("BP_Manager_Jokers_C")
                if jm and jm:IsValid() then dumpObject(jm, "JOKERS") end
                log("pawn dump done")
            end
        end
    end
end

local calls = 0
ExecuteInGameThreadWithDelay(3000, function()
    local ok, err = pcall(function()
        LoadAsset("/Game/Interfaces/BP_Pool_Damages.BP_Pool_Damages")
        RegisterHook("/Game/Interfaces/BP_Pool_Damages.BP_Pool_Damages_C:F_ShowDamages", function(self, loc, color, dmg)
            calls = calls + 1
            if calls > 60 then return end
            local c = color:get()
            log(string.format("DMG %s color=(%.2f,%.2f,%.2f,%.2f)", tostring(dmg:get()), c.R, c.G, c.B, c.A))
        end)
    end)
    log(ok and "damage hook ok" or ("damage hook failed " .. tostring(err)))
end)

log("loaded")
ExecuteInGameThreadWithDelay(10000, function()
    log("generating SDK headers")
    local ok, err = pcall(GenerateSDK)
    log("SDK " .. (ok and "done" or ("failed " .. tostring(err))))
end)
LoopInGameThreadWithDelay(5000, function()
    local ok, err = pcall(tryDumpPawn)
    if not ok then log("pawn dump error " .. tostring(err)) dumpedPawn = true end
end)
