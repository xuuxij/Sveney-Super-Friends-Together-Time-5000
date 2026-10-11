-- Speedometer: how fast you are moving over the ground, as a number and a
-- car-style dial. Units are the game's own (1 unit = 1 cm), per second.
-- The dial starts at DIAL_START, stretches when you go faster than it shows,
-- and comes back down once you have been well under it for a while.

local M = {}

local W, CX, CY, R = 200, 100, 98, 80
local SWEEP = 110       -- degrees either side of straight up
local SEGMENTS = 20     -- ticks; every 5th is long and numbered
local RED_FROM = 17     -- ticks from here up are the red end of the dial
local RIM_STEP, RIM_PIECE = 5, 8 -- degrees between rim pieces, and their length
local NEEDLE_LEN = 46   -- stops short of the numbers
local SHRINK_AFTER_S = 8 -- under half the dial for this long: the range comes back down
local READ_H = 58       -- number + caption
local ROW_H, EDIT_DX = 22, 24
local SAMPLE_S = 0.03

local NEEDLE = { R = 1.0, G = 0.22, B = 0.08, A = 1.0 }
local RED = { R = 1.0, G = 0.16, B = 0.1, A = 1.0 }

-- Parts that can be switched off in edit mode (F9).
local ITEMS = {
    { key = "dial", label = "Dial" },
    { key = "top", label = "Top speed" },
}

local ctx, FFWUi, C, log
local overlay
local st = { speed = 0, shown = 0, top = 0, max = 2000, lastT = nil, loc = nil, nextSample = 0 }

---------------------------------------------------------------------------
-- Speed
---------------------------------------------------------------------------
-- Over-the-ground speed of the pawn. Its own velocity is exact on foot; on a
-- mount or zipline that reads 0, so movement between two looks is used instead.
local function measure(pc, t)
    local ok, vel, x, y = pcall(function()
        local pawn = pc.Pawn
        local v = pawn:GetVelocity()
        local l = pawn:K2_GetActorLocation()
        return math.sqrt(v.X * v.X + v.Y * v.Y), l.X, l.Y
    end)
    if not ok or type(vel) ~= "number" then
        st.loc, st.lastT = nil, nil
        return nil
    end
    local moved = nil
    if st.loc and st.lastT and t - st.lastT > 0.005 and t - st.lastT < 0.5 then
        local dx, dy = x - st.loc[1], y - st.loc[2]
        moved = math.sqrt(dx * dx + dy * dy) / (t - st.lastT)
        if moved > 30000 then moved = nil end -- a teleport, not a speed
    end
    st.loc, st.lastT = { x, y }, t
    if vel < 1 and moved and moved > 50 then return moved end
    return vel
end

local function fmtDial(v)
    if v >= 1000 then return (string.format("%.1f", v / 1000):gsub("%.0$", "")) .. "K" end
    return string.format("%d", v)
end

---------------------------------------------------------------------------
-- HUD
---------------------------------------------------------------------------
local function buildUi(p)
    local u = { panel = p, labels = {}, checks = {}, rows = {} }
    u.bd = p:backdrop(W, CY + READ_H + 10, 0.65, 0.35)
    u.dial = p:group(0, 0, W, CY + 30)
    -- A bar on the dial: centred `radius` out from the hub at `angle`, turned to face it.
    local function onDial(angle, radius, w, h, color)
        local rad = math.rad(angle)
        local b = u.dial:box(CX + radius * math.sin(rad) - w / 2, CY - radius * math.cos(rad) - h / 2, w, h, color)
        FFWUi.setAngle(b, angle)
        return b
    end
    local step = 2 * SWEEP / SEGMENTS
    -- Rim: short straight pieces, close enough to an arc at this size.
    for a = -SWEEP, SWEEP, RIM_STEP do
        onDial(a, R + 3, RIM_PIECE, 2, (a >= -SWEEP + RED_FROM * step) and RED or C.soft)
    end
    for i = 0, SEGMENTS do
        local major = i % 5 == 0
        local h = major and 12 or 6
        onDial(-SWEEP + i * step, R - h / 2, major and 3 or 2, h, (i >= RED_FROM) and RED or (major and C.text or C.soft))
    end
    u.needle = u.dial:box(CX - 2, CY - NEEDLE_LEN, 4, NEEDLE_LEN, NEEDLE)
    FFWUi.setPivot(u.needle, 0.5, 1)
    -- The numbers go on after the needle, so it passes behind them.
    for i = 0, SEGMENTS, 5 do
        local rad = math.rad(-SWEEP + i * step)
        local lr = R - 25
        u.labels[#u.labels + 1] = u.dial:text(CX + lr * math.sin(rad) - 24, CY - lr * math.cos(rad) - 8, 11,
            (i >= RED_FROM) and RED or C.soft, { font = "text", width = 48, justify = 1, height = 16 })
    end
    -- Hub: two squares, one turned 45 degrees, read as a round cap at this size.
    u.dial:box(CX - 6, CY - 6, 12, 12, C.gold)
    FFWUi.setAngle(u.dial:box(CX - 6, CY - 6, 12, 12, C.gold), 45)

    u.read = p:group(0, 0, W, READ_H)
    u.number = u.read:text(0, 0, 30, C.text, { width = W, justify = 1, height = 38 })
    u.caption = u.read:text(0, 36, 13, C.soft, { font = "text", width = W, justify = 1, height = 18 })

    for i, it in ipairs(ITEMS) do
        local g = p:group(0, 0, W, ROW_H)
        FFWUi.setText(g:text(14 + EDIT_DX, 0, 16, C.soft, { height = ROW_H, width = W - 14 - EDIT_DX, justify = 0 }), it.label)
        u.rows[i] = g
        u.checks[i] = p:checkbox(14, 0)
    end
    return u
end

-- Places the dial, the read-out and (in edit mode) the tick boxes.
local function layoutUi(ui)
    local editing = overlay:editing()
    local dial = overlay:itemShown("dial")
    local sig = tostring(editing) .. tostring(dial)
    for _, it in ipairs(ITEMS) do sig = sig .. (overlay:itemShown(it.key) and "1" or "0") end
    if sig == ui.sig then return end
    ui.sig = sig
    FFWUi.setShown(ui.dial, dial)
    local y = dial and (CY + 2) or 8
    ui.panel:move(ui.read.slot, 0, y)
    y = y + READ_H + 4
    local zones = {}
    for i, it in ipairs(ITEMS) do
        local g, cb = ui.rows[i], ui.checks[i]
        FFWUi.setShown(g, editing)
        FFWUi.setShown(cb, editing)
        if editing then
            ui.panel:move(g.slot, 0, y)
            ui.panel:move(cb.slot, 14, y + 4)
            FFWUi.setCheck(cb, overlay:itemShown(it.key))
            zones[#zones + 1] = { key = it.key, x = 0, y = y, w = W, h = ROW_H }
            y = y + ROW_H
        end
    end
    overlay:setToggles(zones)
    ui.panel:resizeBackdrop(ui.bd, W, y + 4)
    overlay:setSize(W, y + 4)
end

local function refreshUi(ui)
    layoutUi(ui)
    if ui.max ~= st.max then
        ui.max = st.max
        for i, label in ipairs(ui.labels) do
            FFWUi.setText(label, fmtDial(st.max * (i - 1) / (#ui.labels - 1)))
        end
    end
    local frac = math.min(1, st.shown / st.max)
    FFWUi.setAngle(ui.needle, math.floor((-SWEEP + frac * 2 * SWEEP) * 2 + 0.5) / 2)
    FFWUi.setText(ui.number, string.format("%d", math.floor(st.shown + 0.5)))
    local caption = "speed"
    if overlay:itemShown("top") then caption = caption .. "      top " .. string.format("%d", math.floor(st.top + 0.5)) end
    FFWUi.setText(ui.caption, caption)
end

---------------------------------------------------------------------------
-- Module interface
---------------------------------------------------------------------------
function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
    C = FFWUi.COLORS
    st.max = ctx.CONFIG.DIAL_START
    overlay = FFWUi.overlay({
        id = "Speedometer", title = "SPEEDOMETER", z = 53,
        shown = true, pos = ctx.CONFIG.SPEEDOMETER_POSITION,
        width = W, height = CY + READ_H + 10,
        settings = ctx.MOD_DIR .. "/settings-speedometer.txt",
        build = buildUi,
        refresh = function() M.tick(FFWUi.localController(), FFWUi.now(), true) end,
    })
    M.overlay = overlay
end

function M.tick(pc, t, force)
    if not pc or (t < st.nextSample and not force) then return end
    st.nextSample = t + SAMPLE_S
    local inGame = FFWUi.inGame(pc)
    local speed = inGame and measure(pc, t) or nil
    if not speed and ctx.CONFIG.DEV_SHOW then speed = 1300 + 1250 * math.sin(t * 0.7) end -- dev: sweep the dial at the menu
    speed = speed or 0
    st.speed = speed
    st.shown = st.shown + (speed - st.shown) * 0.35
    if st.shown < 0.5 then st.shown = 0 end
    if st.shown > st.top then st.top = st.shown end
    -- Steps of 2000 keep the four numbers on the dial round.
    local start = ctx.CONFIG.DIAL_START
    if st.shown > st.max then st.max = math.min(20000, math.ceil(st.shown / 2000) * 2000) end
    -- One launch or zipline should not leave the dial stretched for the rest of the map.
    if st.max > start and st.shown < st.max / 2 then
        st.lowSince = st.lowSince or t
        st.lowPeak = math.max(st.lowPeak or 0, st.shown)
        if t - st.lowSince > SHRINK_AFTER_S then
            st.max = math.max(start, math.ceil(st.lowPeak / 2000) * 2000)
            st.lowSince, st.lowPeak = nil, nil
        end
    else
        st.lowSince, st.lowPeak = nil, nil
    end
    local ui = overlay:update(pc, ctx.active(pc))
    if ui then refreshUi(ui) end
end

-- New map: the top speed and the dial's range start over.
function M.reset()
    st.top, st.max, st.shown, st.loc, st.lastT = 0, ctx.CONFIG.DIAL_START, 0, nil, nil
    st.lowSince, st.lowPeak = nil, nil
end

function M.destroy()
    overlay:destroy()
end

function M.dump()
    log(string.format("  speedometer: speed=%.0f shown=%.0f top=%.0f dial max=%d", st.speed, st.shown, st.top, st.max))
end

return M
