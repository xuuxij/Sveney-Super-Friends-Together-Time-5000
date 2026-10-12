-- Clear zone: the game's markers fade out inside a circle around the
-- crosshair, so they stop covering what you are aiming at. Your own screen only.
-- Every marker is an actor that carries a small widget drawn at its place on
-- the screen: objective markers, pings, world icons, name tags, NPC labels,
-- joker cards and guide texts. Enemy health bars and damage numbers are left
-- alone: they belong to what you are shooting.
-- The engine keeps a list of the actors of each class, so asking for the
-- markers once a second costs next to nothing (a search through every object
-- takes a whole frame). Their places are read ten times a second. On every
-- frame only the camera is read and the rest is arithmetic: how far from the
-- middle of the screen each marker is drawn, and how see-through it should be.
-- In edit mode a dotted ring shows the size of the zone.

local M = {}

local CLASSES = {
    "/Game/Gamework/ObjectivePing/BP_ObjectivePing.BP_ObjectivePing_C", -- objective markers
    "/Game/Interfaces/Pings/BP_ObjectPing.BP_ObjectPing_C",             -- pings on things
    "/Game/Player/Pings/BP_Ping.BP_Ping_C",                             -- pings on places
    "/Game/Lobby/BP_WorldIcon.BP_WorldIcon_C",                          -- world icons
    "/Game/Player/BP_PlayerNameWidget.BP_PlayerNameWidget_C",           -- name tags
    "/Game/Characters/BP_NPC.BP_NPC_C",                                 -- NPC labels
    "/Game/GPE/BP_Pickable_Joker.BP_Pickable_Joker_C",                  -- joker cards lying about
    "/Game/GPE/Tools/BP_TextGuide.BP_TextGuide_C",                      -- guide texts
}
local PX_PER_STEP = 6     -- the slider's 0..100 is a radius of 0..600 screen pixels
local DEFAULT_STEP = 50   -- 300 px
local FADED = 0.1         -- how much of a marker is left inside the zone
local EDGE = 0.2          -- the fade runs over this share of the radius, outside it
local FADE_PER_S = 14     -- how quickly a marker follows
local SCAN_S, PLACE_S = 1.0, 0.1
local RING_DOTS = 60

local ctx, FFWUi, log
local classes = {}        -- same order as CLASSES
local marks = {}          -- actor address -> { actor, comp, widget, x, y, z, up, alpha, shown }
local count = 0
local nextScan, nextPlace, lastT = 0, 0, nil
local cam, pxPerTan = nil, nil
local ring = nil          -- { panel, dots, r }
local diag = { scans = 0, sets = 0, faded = 0, err = nil }

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function valid(o)
    return o ~= nil and type(o) == "userdata" and try(function() return o:IsValid() end) == true
end

-- The zone's radius in screen pixels.
function M.radius()
    local step = tonumber(ctx.value("clearzonepx", DEFAULT_STEP)) or DEFAULT_STEP
    return math.max(0, math.min(100, step)) * PX_PER_STEP
end

local function restore()
    for _, m in pairs(marks) do
        if m.shown ~= 1 and valid(m.widget) then pcall(function() m.widget:SetRenderOpacity(1.0) end) end
    end
    marks, count = {}, 0
end

-- Which markers exist right now.
local function scan(pc)
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local seen = {}
    for i, path in ipairs(CLASSES) do
        if not valid(classes[i]) then classes[i] = StaticFindObject(path) end
        if valid(classes[i]) then
            local out = {}
            if pcall(function() gs:GetAllActorsOfClass(pc, classes[i], out) end) then
                for _, entry in ipairs(out) do
                    local actor = try(function() return entry:get() end)
                    if valid(actor) then
                        local addr = actor:GetAddress()
                        seen[addr] = true
                        if not marks[addr] then
                            marks[addr] = { actor = actor, alpha = 1, shown = 1 }
                            count = count + 1
                        end
                    end
                end
            end
        end
    end
    for addr in pairs(marks) do
        if not seen[addr] then
            marks[addr] = nil
            count = count - 1
        end
    end
    diag.scans = diag.scans + 1
end

-- Where each marker is, and how many pixels the camera gives one unit of slope.
local function place(pc, loc, fx, fy, fz, rx, ry, rz)
    local scale = 1
    for addr, m in pairs(marks) do
        local ok = pcall(function()
            if not valid(m.comp) then
                m.comp, m.widget = m.actor.Widget, nil
                if not valid(m.comp) then error("no widget part") end
            end
            if not valid(m.widget) then
                m.widget, m.up = m.comp:GetUserWidgetObject(), nil
                if not valid(m.widget) then
                    m.widget = nil
                    return -- the game has not made it yet
                end
            end
            local l = m.comp:K2_GetComponentLocation()
            m.x, m.y, m.z = l.X, l.Y, l.Z
            if not m.up then
                -- A marker hung by its bottom edge is drawn above its place: aim for its middle.
                local size = m.widget:GetDesiredSize()
                if size.Y > 0 then
                    scale = try(function() return StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportScale(pc) end) or 1
                    m.up = (m.comp.Pivot.Y - 0.5) * size.Y * scale
                end
            end
            -- The game may have set the marker's own opacity again (it does when one appears).
            local now = m.widget.RenderOpacity
            if type(now) == "number" and math.abs(now - m.shown) > 0.02 then m.shown = now end
        end)
        if not ok then
            marks[addr] = nil
            count = count - 1
        end
    end
    local ahead = { X = loc.X + fx * 1000, Y = loc.Y + fy * 1000, Z = loc.Z + fz * 1000 }
    local aside = { X = ahead.X + rx * 100, Y = ahead.Y + ry * 100, Z = ahead.Z + rz * 100 }
    local a, b = {}, {}
    if pcall(function()
        pc:ProjectWorldLocationToScreen(ahead, a, false)
        pc:ProjectWorldLocationToScreen(aside, b, false)
    end) and type(a.X) == "number" and type(b.X) == "number" then
        local dx, dy = b.X - a.X, b.Y - a.Y
        local px = math.sqrt(dx * dx + dy * dy) * 10
        if px > 1 then pxPerTan = px end
    end
end

local function destroyRing()
    if ring then
        ring.panel:destroy()
        ring = nil
    end
end

-- Edit mode: a dotted ring the size of the zone.
local function drawRing(pc, want)
    if ring and not ring.panel:valid() then ring = nil end
    if not want then
        destroyRing()
        return
    end
    local scale = try(function() return StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportScale(pc) end)
    if type(scale) ~= "number" or scale <= 0 then return end
    if not ring then
        local p = FFWUi.newPanel("FFWClearZone", { zOrder = 45 })
        if not p then return end
        p:setSize(1, 1)
        p:setPosition(0.5, 0.5, 0, 0)
        ring = { panel = p, dots = {}, r = nil }
        for i = 1, RING_DOTS do ring.dots[i] = p:box(0, 0, 4, 4, FFWUi.COLORS.gold) end
        p:show()
        p:setShown(true)
    end
    local r = math.floor(M.radius() / scale + 0.5)
    if ring.r ~= r then
        ring.r = r
        for i, dot in ipairs(ring.dots) do
            local a = (i - 1) / RING_DOTS * 2 * math.pi
            ring.panel:move(dot.slot, math.floor(r * math.cos(a) - 2 + 0.5), math.floor(r * math.sin(a) - 2 + 0.5))
        end
    end
end

-- The switch or the slider moved (game thread).
function M.changed(pc)
    if not ctx.option("clearzone") then restore() end
    if pc then drawRing(pc, ctx.editing() and ctx.option("clearzone") and FFWUi.inGame(pc)) end
end

function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
end

function M.tick(pc, t, inGame)
    local on = inGame and ctx.option("clearzone")
    drawRing(pc, on and ctx.editing())
    if not on then
        if count > 0 then restore() end
        return
    end
    if t >= nextScan then
        nextScan = t + SCAN_S
        local ok, err = pcall(scan, pc)
        if not ok then diag.err = "scan: " .. tostring(err) end
    end
end

function M.fastTick(pc, t)
    local dt = lastT and (t - lastT) or 0
    lastT = t
    if count == 0 or not ctx.option("clearzone") then return end
    local ok, err = pcall(function()
        if not valid(cam) or t >= nextPlace then
            cam = pc.PlayerCameraManager
            if not valid(cam) then
                cam = nil
                return
            end
        end
        local loc, rot = cam:GetCameraLocation(), cam:GetCameraRotation()
        local pitch, yaw = math.rad(rot.Pitch), math.rad(rot.Yaw)
        local cp, sp, cy, sy = math.cos(pitch), math.sin(pitch), math.cos(yaw), math.sin(yaw)
        local fx, fy, fz = cp * cy, cp * sy, sp     -- where the camera looks
        local rx, ry, rz = -sy, cy, 0               -- its right
        local ux, uy, uz = -sp * cy, -sp * sy, cp   -- its up
        if t >= nextPlace then
            nextPlace = t + PLACE_S
            place(pc, loc, fx, fy, fz, rx, ry, rz)
        end
        if not pxPerTan then return end
        local radius = M.radius()
        local edge = radius * EDGE
        local step = math.min(1, dt * FADE_PER_S)
        local faded = 0
        for _, m in pairs(marks) do
            if m.widget and m.x then
                local dx, dy, dz = m.x - loc.X, m.y - loc.Y, m.z - loc.Z
                local depth = dx * fx + dy * fy + dz * fz
                local want = 1
                if depth > 1 and radius > 0 then
                    local sx = pxPerTan * (dx * rx + dy * ry + dz * rz) / depth
                    local sy2 = pxPerTan * (dx * ux + dy * uy + dz * uz) / depth + (m.up or 0)
                    local r = math.sqrt(sx * sx + sy2 * sy2)
                    if r <= radius then
                        want = FADED
                    elseif r < radius + edge then
                        want = FADED + (1 - FADED) * (r - radius) / edge
                    end
                end
                m.alpha = m.alpha + (want - m.alpha) * step
                if math.abs(m.alpha - want) < 0.01 then m.alpha = want end
                if m.alpha < 0.99 then faded = faded + 1 end
                if math.abs(m.alpha - m.shown) >= 0.03 or (m.alpha == want and m.shown ~= want) then
                    if valid(m.widget) then
                        m.widget:SetRenderOpacity(m.alpha)
                        m.shown = m.alpha
                        diag.sets = diag.sets + 1
                    else
                        m.widget = nil
                    end
                end
            end
        end
        diag.faded = faded
    end)
    if not ok then diag.err = "fade: " .. tostring(err) end
end

-- The markers and the ring belong to the map that just went away.
function M.reset()
    marks, count, cam, pxPerTan, nextScan, nextPlace = {}, 0, nil, nil, 0, 0
end

function M.destroy()
    destroyRing()
end

function M.dump()
    log(string.format("  clear zone: on=%s radius=%d px markers=%d faded now=%d scans=%d opacity changes=%d pixels per slope=%s ring=%s last error=%s",
        tostring(ctx.option("clearzone")), M.radius(), count, diag.faded, diag.scans, diag.sets,
        tostring(pxPerTan and math.floor(pxPerTan)), tostring(ring ~= nil), tostring(diag.err)))
end

return M
