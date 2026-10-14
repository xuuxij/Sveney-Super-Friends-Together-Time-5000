-- Teammate arrows: a teammate who is off your screen and further away than
-- the distance you set (50 m to start with) gets an arrow at the edge of the
-- screen, pointing the way to turn, in that player's own colour. Your own
-- screen only.
-- Around the arrow a circle of dots fills in, one dot for every 10 m past
-- that distance. Once the circle is half full the arrow beats like a heart:
-- it blinks and swells, faster and harder the further away the teammate is,
-- up to 1000 m. The distance can be written under the arrow.
-- OPTIONS: the arrows on or off with the distance on a slider, arrows for
-- every teammate or only the closest one past that distance, and the
-- distance text on or off. In edit mode a sample arrow on the left walks
-- through every distance, so the slider can be tried alone.
-- The teammates are looked up twice a second (the engine keeps a list of the
-- actors of each class); on every frame only they and the camera are read.

local M = {}

local PLAYER_CLASS = "/Game/Player/BP_Player.BP_Player_C"
local GAMEPLAY_LIB = "/Game/Gamework/BPFL_Gameplay.Default__BPFL_Gameplay_C"
local ARROW_TEX = { path = "/Game/Interfaces/Textures/T_Arrow.T_Arrow" }        -- the game's thin chevron, pointing left
local DOT_TEX = { path = "/Game/Interfaces/Textures/T_Ui_Circle.T_Ui_Circle" } -- a round disc
local UNITS_PER_M = 100   -- the game's unit is a centimetre
local M_PER_STEP = 5      -- the slider's 0..100 is 0..500 m
local DEFAULT_STEP = 10   -- 50 m
local M_PER_DOT = 10
local DOTS = 20           -- a full circle: 200 m past the distance
local FARTHEST_M = 1000   -- the heartbeat is at its strongest from here on
local MAX_ARROWS = 8
local SCAN_S, PLACE_S = 0.5, 0.1

-- Sizes in widget units. The arrow's middle stays EDGE from the screen's edge.
local BOX = 96            -- each arrow's own canvas; the arrow sits in its middle
local RING_R, DOT = 28, 6
local ARROW_W, ARROW_H = 18, 36
local EDGE = 72
local TEXT_SIZE = 16

-- The heartbeat: a strong beat and a softer second one, then a rest.
local BEAT_SLOW_S, BEAT_FAST_S = 1.1, 0.42      -- time between heartbeats, half full .. farthest
local SWELL_LOW, SWELL_HIGH = 0.12, 0.5          -- how much bigger the arrow gets on a beat
local DIP_LOW, DIP_HIGH = 0.3, 0.85              -- how far it fades between beats
local SECOND_AT, SECOND = 0.26, 0.6              -- the second beat: where in the cycle, how strong
local BEAT_WIDTH = 0.07                          -- share of the cycle each beat lasts

local SHADOW = { R = 0, G = 0, B = 0, A = 0.55 }
local WHITE = { R = 1, G = 1, B = 1, A = 1 }
local SAMPLE_SWEEP_S = 12 -- the edit-mode sample goes from the distance to past 1000 m in this time

local ctx, FFWUi, log, C
local ui = nil            -- { panel, slots = { ... }, hw, hh }
local mates = {}          -- actor address -> { actor, color, colorAt }
local mateCount = 0
local nextScan, nextPlace, nextColor = 0, 0, 0
local cam, pxPerTan, scale = nil, nil, nil
local wanted = false      -- in a game, switched on and the game's HUD is up (checked by tick)
local diag = { scans = 0, shown = 0, err = nil, nearest = nil }

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function valid(o)
    return o ~= nil and type(o) == "userdata" and try(function() return o:IsValid() end) == true
end

-- The distance from the OPTIONS slider, in metres.
function M.threshold()
    local step = tonumber(ctx.value("tmarrowm", DEFAULT_STEP)) or DEFAULT_STEP
    return math.max(0, math.min(100, step)) * M_PER_STEP
end

---------------------------------------------------------------------------
-- Teammates
---------------------------------------------------------------------------
local function colorOf(pc, actor)
    local c = try(function()
        local ps = actor.PlayerState
        if not valid(ps) then return nil end
        local lib = StaticFindObject(GAMEPLAY_LIB)
        if not valid(lib) then return nil end
        local out = {}
        lib:F_GetPlayerColor(ps, pc, out)
        if type(out.R) ~= "number" then return nil end
        return { R = out.R, G = out.G, B = out.B, A = 1 }
    end)
    return c or WHITE
end

local function scan(pc)
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    local cls = StaticFindObject(PLAYER_CLASS)
    if not valid(cls) then return end
    local mine = try(function() return pc.Pawn end)
    local mineAddr = valid(mine) and mine:GetAddress() or nil
    local out = {}
    gs:GetAllActorsOfClass(pc, cls, out)
    local seen = {}
    for _, entry in ipairs(out) do
        local actor = try(function() return entry:get() end)
        if valid(actor) then
            local addr = actor:GetAddress()
            if addr ~= mineAddr then
                seen[addr] = true
                if not mates[addr] then
                    mates[addr] = { actor = actor }
                    mateCount = mateCount + 1
                end
            end
        end
    end
    for addr in pairs(mates) do
        if not seen[addr] then
            mates[addr] = nil
            mateCount = mateCount - 1
        end
    end
    diag.scans = diag.scans + 1
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------
local function destroyUi()
    if ui then
        ui.panel:destroy()
        ui = nil
    end
end

-- One arrow: the circle of dots, the arrow (with a dark copy behind it) and the distance.
local function newSlot(p)
    local g = p:group(0, 0, BOX, BOX)
    local s = { group = g, dots = {}, lit = -1 }
    local mid = BOX / 2
    for i = 1, DOTS do
        local a = math.rad(-90 + (i - 1) * 360 / DOTS) -- from the top, clockwise
        local x, y = mid + RING_R * math.cos(a) - DOT / 2, mid + RING_R * math.sin(a) - DOT / 2
        g:image(x - 1, y - 1, DOT + 2, DOT + 2, SHADOW, DOT_TEX) -- stays: the faint track shows how full the circle is
        s.dots[i] = g:image(x, y, DOT, DOT, WHITE, DOT_TEX)
    end
    s.arrow = g:group(mid - ARROW_W, mid - ARROW_H / 2, ARROW_W * 2, ARROW_H)
    s.arrow:image(ARROW_W / 2 - 3, -3, ARROW_W + 6, ARROW_H + 6, SHADOW, ARROW_TEX)
    s.head = s.arrow:image(ARROW_W / 2, 0, ARROW_W, ARROW_H, WHITE, ARROW_TEX)
    s.text = g:text(0, mid + RING_R + DOT / 2 + 1, TEXT_SIZE, C.text, { width = BOX, justify = 1, height = TEXT_SIZE + 6 })
    FFWUi.setShown(g, false)
    s.shown = false
    return s
end

local function ensureUi(pc)
    if ui and not ui.panel:valid() then ui = nil end
    if ui then return ui end
    local p = FFWUi.newPanel("FFWTeamArrows", { zOrder = 44 })
    if not p then return nil end
    p:setSize(1, 1)
    p:setPosition(0.5, 0.5, 0, 0)
    ui = { panel = p, slots = {} }
    for i = 1, MAX_ARROWS + 1 do ui.slots[i] = newSlot(p) end -- the last one is the edit-mode sample
    p:show()
    p:setShown(true)
    return ui
end

local function setOpacity(w, a)
    if w.opacity ~= a then
        w.widget:SetRenderOpacity(a)
        w.opacity = a
    end
end

local function setScale(w, sc)
    if w.scale ~= sc then
        w.widget:SetRenderScale({ X = sc, Y = sc })
        w.scale = sc
    end
end

local function beatShape(x)
    return math.exp(-(x / BEAT_WIDTH) ^ 2)
end

-- 0 at rest .. 1 on a beat, for a heartbeat `strength` 0..1 at time t.
local function heartbeat(t, strength)
    local period = BEAT_SLOW_S + (BEAT_FAST_S - BEAT_SLOW_S) * strength
    local x = (t % period) / period
    return math.max(beatShape(x), beatShape(x - 1), SECOND * beatShape(x - SECOND_AT))
end

-- Draws slot s at (x, y) from the screen's middle, pointing `angle` degrees
-- (0 = right, clockwise), for a teammate `m` metres away in colour `color`.
local function drawSlot(s, x, y, angle, m, color, t)
    local thr = M.threshold()
    local lit = math.max(0, math.min(DOTS, math.floor((m - thr) / M_PER_DOT)))
    if lit ~= s.lit then
        for i, d in ipairs(s.dots) do FFWUi.setShown(d, i <= lit) end
        s.lit = lit
    end
    for _, d in ipairs(s.dots) do FFWUi.setBoxColor(d, color) end
    FFWUi.setBoxColor(s.head, color)
    -- Half full: the heartbeat, from gentle there to strongest at FARTHEST_M.
    local sc, alpha = 1, 1
    if lit * 2 >= DOTS then
        local half = thr + DOTS / 2 * M_PER_DOT
        local strength = math.max(0, math.min(1, (m - half) / math.max(1, FARTHEST_M - half)))
        local b = heartbeat(t, strength)
        sc = 1 + (SWELL_LOW + (SWELL_HIGH - SWELL_LOW) * strength) * b
        local dip = DIP_LOW + (DIP_HIGH - DIP_LOW) * strength
        alpha = 1 - dip * (1 - b)
    end
    setScale(s.arrow, math.floor(sc * 100 + 0.5) / 100)
    setOpacity(s.arrow, math.floor(alpha * 50 + 0.5) / 50)
    FFWUi.setAngle(s.arrow, math.floor((angle - 180) * 2 + 0.5) / 2) -- the texture points left
    local wantText = ctx.option("tmdist")
    FFWUi.setShown(s.text, wantText)
    if wantText then FFWUi.setText(s.text, string.format("%d m", math.floor(m + 0.5))) end
    ui.panel:move(s.group.slot, math.floor(x - BOX / 2 + 0.5), math.floor(y - BOX / 2 + 0.5))
    if not s.shown then
        FFWUi.setShown(s.group, true)
        s.shown = true
        ui.anyShown = true
    end
end

local function hideSlot(s)
    if s.shown then
        FFWUi.setShown(s.group, false)
        s.shown = false
    end
end

local function hideAll()
    if ui and ui.anyShown and ui.panel:valid() then
        for _, s in ipairs(ui.slots) do hideSlot(s) end
        ui.anyShown = false
    end
    diag.shown = 0
end

-- Where on the edge an arrow pointing (vx, vy) goes, from the screen's middle.
local function onEdge(vx, vy, hw, hh)
    local ax, ay = hw - EDGE, hh - EDGE
    if math.abs(vx) < 1e-6 and math.abs(vy) < 1e-6 then vy = 1 end -- straight behind: point down
    local k = math.min(math.abs(vx) > 1e-6 and ax / math.abs(vx) or math.huge, math.abs(vy) > 1e-6 and ay / math.abs(vy) or math.huge)
    return vx * k, vy * k
end

---------------------------------------------------------------------------
-- Module interface
---------------------------------------------------------------------------
function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
    C = FFWUi.COLORS
end

-- The switches or the slider moved (game thread): the next frame redraws.
function M.changed(pc)
    if not ctx.option("tmarrows") then hideAll() end
end

function M.tick(pc, t, inGame)
    wanted = inGame and ctx.option("tmarrows") and FFWUi.gameHudShown()
    if not wanted then
        hideAll()
        return
    end
    if t >= nextScan then
        nextScan = t + SCAN_S
        local ok, err = pcall(scan, pc)
        if not ok then diag.err = "scan: " .. tostring(err) end
    end
    if t >= nextColor then -- colours follow the game's (a new player joins, the order changes)
        nextColor = t + 2
        for _, mt in pairs(mates) do mt.color = colorOf(pc, mt.actor) end
    end
end

function M.fastTick(pc, t)
    local editing = ctx.editing()
    if not (wanted and ctx.option("tmarrows") and (mateCount > 0 or editing)) then
        if ui then hideAll() end
        return
    end
    local ok, err = pcall(function()
        local u = ensureUi(pc)
        if not u then return end
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
        if t >= nextPlace or not pxPerTan or not u.hw then
            nextPlace = t + PLACE_S
            -- Widget units on the screen per unit of slope, from two points the engine projects.
            local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
            local sc = try(function() return lib:GetViewportScale(pc) end)
            if type(sc) == "number" and sc > 0 then scale = sc end
            local vw, vh = FFWUi.viewportSize()
            if vw then u.hw, u.hh = vw / 2, vh / 2 end
            local ahead = { X = loc.X + fx * 1000, Y = loc.Y + fy * 1000, Z = loc.Z + fz * 1000 }
            local aside = { X = ahead.X + rx * 100, Y = ahead.Y + ry * 100, Z = ahead.Z + rz * 100 }
            local a, b = {}, {}
            if scale and pcall(function()
                pc:ProjectWorldLocationToScreen(ahead, a, false)
                pc:ProjectWorldLocationToScreen(aside, b, false)
            end) and type(a.X) == "number" and type(b.X) == "number" then
                local dx, dy = b.X - a.X, b.Y - a.Y
                local px = math.sqrt(dx * dx + dy * dy) * 10 / scale
                if px > 1 then pxPerTan = px end
            end
        end
        if not pxPerTan or not u.hw then return end
        local hw, hh = u.hw, u.hh
        local thr = M.threshold()
        -- Measured from you; the camera when you have no body.
        local from = try(function() return pc.Pawn:K2_GetActorLocation() end) or loc
        local list = {}
        for addr, mt in pairs(mates) do
            local l = try(function() return mt.actor:K2_GetActorLocation() end)
            if l then
                local dx, dy, dz = l.X - loc.X, l.Y - loc.Y, l.Z - loc.Z
                local ex, ey, ez = l.X - from.X, l.Y - from.Y, l.Z - from.Z
                local m = math.sqrt(ex * ex + ey * ey + ez * ez) / UNITS_PER_M
                local depth = dx * fx + dy * fy + dz * fz
                local vx = dx * rx + dy * ry + dz * rz
                local vy = -(dx * ux + dy * uy + dz * uz)
                local onScreen = depth > 1 and math.abs(pxPerTan * vx / depth) < hw and math.abs(pxPerTan * vy / depth) < hh
                if m > thr and not onScreen then
                    list[#list + 1] = { m = m, vx = vx, vy = vy, color = mt.color or WHITE }
                end
            else
                mates[addr] = nil
                mateCount = mateCount - 1
            end
        end
        table.sort(list, function(a, b) return a.m < b.m end)
        diag.nearest = list[1] and list[1].m or nil
        local n = ctx.option("tmall") and math.min(#list, MAX_ARROWS) or math.min(#list, 1)
        for i = 1, MAX_ARROWS do
            local s = u.slots[i]
            local it = list[i]
            if i <= n then
                local x, y = onEdge(it.vx, it.vy, hw, hh)
                drawSlot(s, x, y, math.deg(math.atan(it.vy, it.vx)), it.m, it.color, t)
            else
                hideSlot(s)
            end
        end
        diag.shown = n
        -- Edit mode: a sample on the left edge, walking through every distance.
        local sample = u.slots[MAX_ARROWS + 1]
        if editing then
            local span = FARTHEST_M + 100 - thr
            local m = thr + 1 + (t % SAMPLE_SWEEP_S) / SAMPLE_SWEEP_S * span
            drawSlot(sample, -(hw - EDGE), -120, 180, m, C.gold, t)
        else
            hideSlot(sample)
        end
    end)
    if not ok then diag.err = "draw: " .. tostring(err) end
end

-- The teammates and the panel belong to the map that just went away.
function M.reset()
    mates, mateCount, cam, pxPerTan, nextScan, nextPlace, nextColor, wanted = {}, 0, nil, nil, 0, 0, 0, false
end

function M.destroy()
    destroyUi()
end

function M.dump()
    log(string.format("  teammate arrows: on=%s distance=%d m every teammate=%s distance text=%s teammates=%d arrows now=%d nearest past it=%s scans=%d slope px=%s last error=%s",
        tostring(ctx.option("tmarrows")), M.threshold(), tostring(ctx.option("tmall")), tostring(ctx.option("tmdist")),
        mateCount, diag.shown, diag.nearest and string.format("%.0f m", diag.nearest) or "none", diag.scans,
        tostring(pxPerTan and math.floor(pxPerTan)), tostring(diag.err)))
end

return M
