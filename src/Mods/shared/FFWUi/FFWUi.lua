-- Shared HUD helpers for the FFWModpack Lua mods (DamageMeter, StatsPanel, Extras).
-- Builds UMG widgets in code, styled with the game's own fonts, colours and
-- panel textures (values read from its HUD and tooltip widgets).
-- Every overlay can be hidden, moved, resized and trimmed to the stats you
-- want (F9 edit mode); all of it is remembered in a settings.txt next to the mod.

local UEHelpers = require("UEHelpers")

local M = {}

M.VIS_HIDDEN = 2
M.VIS_HIT_TEST_INVISIBLE = 3
M.VIS_COLLAPSED = 1

M.LAYOUT_KEY = Key.F9
M.MIN_SCALE, M.MAX_SCALE = 0.5, 2.0
-- Every overlay in the pack, so overlapping panels can tell which one is on top.
M.OVERLAY_IDS = { "DamageMeter", "StatsPanel", "MorePlayers", "Speedometer", "Options" }

local FONTS = {
    title = "/Game/Materials/Fonts/Font_Title.Font_Title",
    text = "/Game/Materials/Fonts/Font_Text.Font_Text",
}
local TEX = {
    holder = "/Game/Interfaces/Textures/T_Holder_Large.T_Holder_Large", -- tooltip panel
    glow = "/Game/Interfaces/Textures/T_Ui_Glow.T_Ui_Glow",             -- soft shadow around it
}

M.TEXTURES = TEX

-- Linear colours copied from the game's widgets.
M.COLORS = {
    gold = { R = 1.0, G = 0.499, B = 0.0, A = 1.0 },     -- ammo, gold, tooltip titles
    text = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 },
    soft = { R = 0.875, G = 0.863, B = 0.855, A = 1.0 }, -- spell cooldown text
    dim = { R = 0.42, G = 0.41, B = 0.4, A = 1.0 },
    lime = { R = 0.37, G = 1.0, B = 0.0, A = 1.0 },      -- tickets
    soul = { R = 0.003, G = 1.0, B = 0.59, A = 1.0 },    -- souls, the Joker currency
    clear = { R = 0.0, G = 0.0, B = 0.0, A = 0.0 },
}

-- os.clock() is wall time since process start on Windows (MSVC clock()).
M.now = os.clock

function M.logger(tag)
    return function(msg) print("[" .. tag .. "] " .. msg .. "\n") end
end
local log = M.logger("FFWUi")

local function try(f)
    local ok, v = pcall(f)
    if ok then return v end
    return nil
end

local function isValid(o)
    return o ~= nil and try(function() return o:IsValid() end) == true
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

---------------------------------------------------------------------------
-- Game assets
---------------------------------------------------------------------------
local assets = {}

-- Finds (or loads) a game asset by object path; nil when it is missing.
function M.asset(path)
    local o = assets[path]
    if isValid(o) then return o end
    o = StaticFindObject(path)
    if not isValid(o) then
        pcall(function() LoadAsset(path) end)
        o = StaticFindObject(path)
    end
    if not isValid(o) then return nil end
    assets[path] = o
    return o
end

-- kind: "title" (the HUD's condensed font) or "text" (tooltip body font).
function M.font(kind)
    local obj = M.asset(FONTS[kind] or FONTS.title)
    if not obj then return nil end
    return { object = obj, typeface = FName("Default") }
end

-- FindAllOf walks every object, so the local controller is cached and only
-- searched for again (at most every 2 s) after it goes away.
local pcCache, pcNextSearch = nil, 0

function M.localController()
    if pcCache and pcCache:IsValid() then return pcCache end
    pcCache = nil
    local t = M.now()
    if t < pcNextSearch then return nil end
    pcNextSearch = t + 2
    local all = FindAllOf("PlayerController")
    if all then
        for _, c in ipairs(all) do
            if c:IsValid() and c:IsLocalPlayerController() then
                pcCache = c
                break
            end
        end
    end
    return pcCache
end

-- True when the local player has a real character (the menus use a placeholder pawn).
function M.inGame(pc)
    local ok, valid = pcall(function()
        local pawn = pc.Pawn
        if pawn == nil or not pawn:IsValid() then return false end
        local items = pawn.AC_PlayerItems
        return items ~= nil and items:IsValid()
    end)
    return ok and valid == true
end

-- Follows the game's own HUD (GameInstance.refUiPlayer): when the game hides
-- it, the overlays hide too. Anything unclear counts as shown.
local hudState = nil
function M.gameHudShown()
    local ok, shown = pcall(function()
        local hud = UEHelpers.GetGameInstance().refUiPlayer
        if hud == nil or not hud:IsValid() or not hud:IsInViewport() then return true end
        local vis = hud:GetVisibility()
        return vis ~= M.VIS_COLLAPSED and vis ~= M.VIS_HIDDEN
    end)
    local r = (not ok) or shown ~= false
    if r ~= hudState then
        if hudState ~= nil then log("game HUD " .. (r and "shown" or "hidden")) end
        hudState = r
    end
    return r
end

local layoutLib = nil
local function widgetLayout()
    if not isValid(layoutLib) then layoutLib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary") end
    return layoutLib
end

-- Viewport size in widget units (pixels / DPI scale), or nil.
function M.viewportSize()
    local pc = M.localController()
    if not pc then return nil end
    local ok, w, h = pcall(function()
        local lib = widgetLayout()
        local size = lib:GetViewportSize(pc)
        local scale = lib:GetViewportScale(pc)
        return size.X / scale, size.Y / scale
    end)
    if ok and type(w) == "number" and w > 0 and h > 0 then return w, h end
    return nil
end

---------------------------------------------------------------------------
-- Panels
---------------------------------------------------------------------------
local Panel = {}
Panel.__index = Panel

local serial = 0

local function construct(className, outer, name)
    return StaticConstructObject(StaticFindObject(className), outer, FName(name))
end

-- A full-screen UserWidget holding one "frame" canvas; everything a panel
-- draws sits inside the frame, so moving the panel is one slot update.
function M.newPanel(name, opts)
    opts = opts or {}
    local gi = UEHelpers.GetGameInstance()
    if not gi or not gi:IsValid() then return nil end
    serial = serial + 1
    local prefix = name .. serial .. "_"
    local root = construct("/Script/UMG.UserWidget", gi, prefix .. "Root")
    local tree = construct("/Script/UMG.WidgetTree", root, prefix .. "Tree")
    root.WidgetTree = tree
    local canvas = construct("/Script/UMG.CanvasPanel", tree, prefix .. "Canvas")
    tree.RootWidget = canvas
    local frame = construct("/Script/UMG.CanvasPanel", tree, prefix .. "Frame")
    local frameSlot = canvas:AddChildToCanvas(frame)
    frameSlot:SetAutoSize(false)
    frame:SetRenderTransformPivot({ X = 0, Y = 0 })
    return setmetatable({
        root = root, tree = tree, canvas = canvas, frame = frame, frameSlot = frameSlot,
        prefix = prefix, count = 0, zOrder = opts.zOrder or 50, shown = nil, opacity = 1, scale = 1,
    }, Panel)
end

function Panel:_name(kind)
    self.count = self.count + 1
    return self.prefix .. kind .. self.count
end

-- ax/ay: screen anchor (0..1). The same point of the panel sits on it, so a
-- panel near the bottom or right edge grows away from that edge.
function Panel:setPosition(ax, ay, x, y)
    self.frameSlot:SetAnchors({ Minimum = { X = ax, Y = ay }, Maximum = { X = ax, Y = ay } })
    self.frameSlot:SetAlignment({ X = ax, Y = ay })
    self.frameSlot:SetPosition({ X = x, Y = y })
end

function Panel:setSize(w, h)
    self.frameSlot:SetSize({ X = w, Y = h })
end

function Panel:setOpacity(a)
    if self.opacity ~= a then
        self.frame:SetRenderOpacity(a)
        self.opacity = a
    end
end

-- Uniform size: everything in the frame is drawn scaled from its top-left.
function Panel:setScale(s)
    if self.scale ~= s then
        self.frame:SetRenderScale({ X = s, Y = s })
        self.scale = s
    end
end

-- A sub-canvas inside the panel, so a block of widgets can move, hide or
-- fade as one. It takes the same text/box/image/group calls as a panel.
function Panel:group(x, y, w, h)
    local canvas = construct("/Script/UMG.CanvasPanel", self.tree, self:_name("Group"))
    local slot = self:place(canvas, x, y, w or 1, h or 1)
    return setmetatable({
        root = self.root, tree = self.tree, frame = canvas, widget = canvas, slot = slot,
        prefix = self:_name("G") .. "_", count = 0,
    }, Panel)
end

-- Edit-mode tick box: gold frame, dark inside, gold mark when ticked.
function Panel:checkbox(x, y)
    local g = self:group(x, y, 14, 14)
    g:box(0, 0, 14, 14, M.COLORS.gold)
    g:box(2, 2, 10, 10, { R = 0, G = 0, B = 0, A = 0.9 })
    return { widget = g.widget, slot = g.slot, mark = g:box(4, 4, 6, 6, M.COLORS.gold) }
end

-- Coordinates below are relative to the panel's top-left corner.
function Panel:place(widget, x, y, w, h)
    local slot = self.frame:AddChildToCanvas(widget)
    slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } })
    slot:SetAlignment({ X = 0, Y = 0 })
    slot:SetPosition({ X = x, Y = y })
    if w then
        slot:SetAutoSize(false)
        slot:SetSize({ X = w, Y = h })
    else
        slot:SetAutoSize(true)
    end
    return slot
end

function Panel:move(slot, x, y, w, h)
    slot:SetPosition({ X = x, Y = y })
    if w then slot:SetSize({ X = w, Y = h }) end
end

-- opts: font ("title" | "text"), skew, width + justify (0 left, 1 center,
-- 2 right) and height for fixed-width columns
function Panel:text(x, y, size, color, opts)
    opts = opts or {}
    local tb = construct("/Script/UMG.TextBlock", self.tree, self:_name("Text"))
    local font = M.font(opts.font or "title")
    if font then
        tb.Font.FontObject = font.object
        tb.Font.TypefaceFontName = font.typeface
    end
    tb.Font.Size = size
    pcall(function()
        if opts.skew then tb.Font.SkewAmount = opts.skew end
        -- The HUD's thin, soft outline.
        tb.Font.OutlineSettings.OutlineSize = 1
        tb.Font.OutlineSettings.OutlineColor.A = 0.4
    end)
    tb:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
    tb:SetText(FText(""))
    local slot
    if opts.width then
        tb:SetJustification(opts.justify or 0)
        slot = self:place(tb, x, y, opts.width, opts.height or (size * 1.6))
    else
        slot = self:place(tb, x, y)
    end
    return { widget = tb, slot = slot, text = "", color = color }
end

-- brush: { path, drawAs (1 box, 3 image), margin, size } for a game texture;
-- without one (or if it fails to load) this is a plain tinted rectangle.
function Panel:image(x, y, w, h, color, brush)
    local img = construct("/Script/UMG.Image", self.tree, self:_name("Img"))
    local res = brush and M.asset(brush.path)
    if res then
        pcall(function()
            img:SetBrushResourceObject(res)
            img.Brush.DrawAs = brush.drawAs or 3
            if brush.size then
                img.Brush.ImageSize.X = brush.size
                img.Brush.ImageSize.Y = brush.size
            end
            if brush.margin then
                local m = img.Brush.Margin
                m.Left, m.Top, m.Right, m.Bottom = brush.margin, brush.margin, brush.margin, brush.margin
            end
        end)
    end
    img:SetColorAndOpacity(color)
    local slot = self:place(img, x, y, w, h)
    return { widget = img, slot = slot, color = color }
end

function Panel:box(x, y, w, h, color)
    return self:image(x, y, w, h, color, nil)
end

-- The game's tooltip look: a dark brushed holder inside a soft dark glow.
local GLOW_PAD = 12
function Panel:backdrop(w, h, holderAlpha, glowAlpha)
    return {
        glow = self:image(-GLOW_PAD, -GLOW_PAD, w + GLOW_PAD * 2, h + GLOW_PAD * 2,
            { R = 0, G = 0, B = 0, A = glowAlpha }, { path = TEX.glow, drawAs = 1, margin = 0.5, size = 128 }),
        holder = self:image(0, 0, w, h, { R = 0, G = 0, B = 0, A = holderAlpha }, { path = TEX.holder }),
    }
end

function Panel:resizeBackdrop(bd, w, h)
    self:move(bd.glow.slot, -GLOW_PAD, -GLOW_PAD, w + GLOW_PAD * 2, h + GLOW_PAD * 2)
    self:move(bd.holder.slot, 0, 0, w, h)
end

-- Cheap setters: only touch the widget when something changed.
function M.setText(t, s)
    if t.text ~= s then
        t.widget:SetText(FText(s))
        t.text = s
    end
end

function M.setTextColor(t, color)
    if t.color ~= color then
        t.widget:SetColorAndOpacity({ SpecifiedColor = color, ColorUseRule = 0 })
        t.color = color
    end
end

function M.setBoxColor(b, color)
    if b.color ~= color then
        b.widget:SetColorAndOpacity(color)
        b.color = color
    end
end

-- For anything with a .widget: a text, box, group or checkbox.
function M.setShown(w, want)
    if w.shown ~= want then
        w.widget:SetVisibility(want and M.VIS_HIT_TEST_INVISIBLE or M.VIS_COLLAPSED)
        w.shown = want
    end
end
local setWidgetShown = M.setShown

-- Turns a widget (degrees, clockwise) around a point of its own box:
-- px/py 0..1, default its centre.
function M.setPivot(w, px, py)
    w.widget:SetRenderTransformPivot({ X = px, Y = py })
end

function M.setAngle(w, deg)
    if w.angle ~= deg then
        w.widget:SetRenderTransformAngle(deg)
        w.angle = deg
    end
end

-- Faded look for stats that are switched off (seen only in edit mode).
function M.setDim(w, dim)
    local a = dim and 0.35 or 1
    if w.opacity ~= a then
        w.widget:SetRenderOpacity(a)
        w.opacity = a
    end
end

function M.setCheck(cb, on)
    M.setShown(cb.mark, on)
end

function Panel:show()
    self.root:AddToViewport(self.zOrder)
end

-- A panel dies with its map: the viewport drops it and GC frees every widget.
-- Never call into a panel without this check first.
function Panel:valid()
    local ok, valid = pcall(function() return self.root:IsValid() and self.root:IsInViewport() end)
    return ok and valid == true
end

function Panel:destroy()
    if self:valid() then pcall(function() self.root:RemoveFromParent() end) end
end

function Panel:setShown(want)
    if self.shown ~= want then
        self.root:SetVisibility(want and M.VIS_HIT_TEST_INVISIBLE or M.VIS_HIDDEN)
        self.shown = want
    end
end

---------------------------------------------------------------------------
-- Overlays: a panel plus its saved position / shown state and move mode
---------------------------------------------------------------------------
local Overlay = {}
Overlay.__index = Overlay

local overlays = {}
local layout = { on = false, mx = 0, my = 0, loop = nil, inputBy = nil, pcAddr = nil, since = 0, banner = nil }

-- Other mods run in their own Lua state; UE4SS shared variables let the
-- overlays agree on which panel a click belongs to.
local function sharedSet(k, v) pcall(function() ModRef:SetSharedVariable(k, v) end) end
local function sharedGet(k)
    local ok, v = pcall(function() return ModRef:GetSharedVariable(k) end)
    if ok then return v end
    return nil
end

local function readSettings(path)
    local t = {}
    local f = path and io.open(path, "r")
    if not f then return t end
    for line in f:lines() do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k then t[k] = v end
    end
    f:close()
    return t
end

-- items: "key:1|key:0" (stats switched on/off in edit mode)
local function parseItems(v)
    local t = {}
    for part in tostring(v or ""):gmatch("[^|]+") do
        local k, on = part:match("^(.*):([01])$")
        if k and k ~= "" then t[k] = on == "1" end
    end
    return t
end

function Overlay:_save()
    local c = self.cfg
    local ok, err = pcall(function()
        local keys = {}
        for k in pairs(c.items) do keys[#keys + 1] = k end
        table.sort(keys)
        local items = {}
        for _, k in ipairs(keys) do items[#items + 1] = k .. ":" .. (c.items[k] and "1" or "0") end
        local f = io.open(self.def.settings, "w")
        if not f then return end
        local key = self.def.keyName and (", " .. self.def.keyName .. " shows/hides it") or ""
        f:write("# Saved by the game: F9 edits this overlay" .. key .. ".\n")
        f:write("# Delete this file to reset.\n")
        f:write(string.format("shown=%d\nax=%g\nay=%g\nx=%d\ny=%d\nscale=%g\nitems=%s\n",
            c.shown and 1 or 0, c.ax, c.ay, c.x, c.y, c.scale, table.concat(items, "|")))
        f:close()
    end)
    if not ok then log("could not save " .. tostring(self.def.settings) .. ": " .. tostring(err)) end
end

local function anchorOf(v, fallback)
    v = tonumber(v)
    if v == 0 or v == 0.5 or v == 1 then return v end
    return fallback
end

-- def: id, title, keyName, z, toggleKey, shown (default), pos {ax, ay, x, y},
--      width, height, settings (file path), build(panel, overlay) -> ui,
--      refresh() (redraw now, game thread), banner,
--      editOnly (a settings panel: on screen in edit mode and never outside it)
function M.overlay(def)
    local s = readSettings(def.settings)
    local d = def.pos
    local shown = def.shown == true
    if s.shown then shown = s.shown == "1" end
    local ov = setmetatable({
        def = def, id = def.id, z = def.z or 50, w = def.width or 100, h = def.height or 100,
        cfg = {
            shown = shown,
            ax = anchorOf(s.ax, d.ax), ay = anchorOf(s.ay, d.ay),
            x = math.floor(tonumber(s.x) or d.x), y = math.floor(tonumber(s.y) or d.y),
            scale = clamp(tonumber(s.scale) or 1, M.MIN_SCALE, M.MAX_SCALE),
            items = parseItems(s.items),
        },
        panel = nil, ui = nil, deco = nil, rect = nil, grabbed = false, active = false,
    }, Overlay)
    overlays[#overlays + 1] = ov
    if def.toggleKey then
        RegisterKeyBind(def.toggleKey, function() ov:toggle() end)
    end
    M._registerLayoutKeys()
    return ov
end

-- Edit mode is on: draw every stat, with tick boxes.
function Overlay:editing()
    return layout.on
end

function Overlay:itemShown(key, default)
    local v = self.cfg.items[key]
    if v == nil then return default ~= false end
    return v
end

-- Tick-box hit areas, { { key, default, x, y, w, h } } in unscaled panel coordinates.
-- A zone with a toggle function calls it instead of switching the item
-- (input thread: plain Lua only).
function Overlay:setToggles(zones)
    self.toggles = zones
end

function Overlay:_refresh()
    local fn = self.def.refresh
    if fn then ExecuteInGameThread(function() pcall(fn) end) end
end

function Overlay:_toggleItem(z)
    if z.toggle then
        pcall(z.toggle)
    else
        self.cfg.items[z.key] = not self:itemShown(z.key, z.default)
        self:_save()
    end
    self:_refresh()
end

-- On-screen size (layout size times the player's chosen scale).
function Overlay:_sw() return self.w * self.cfg.scale end
function Overlay:_sh() return self.h * self.cfg.scale end

function Overlay:toggle()
    if self.def.editOnly then return end
    self.cfg.shown = not self.cfg.shown
    self:_save()
    log(self.id .. (self.cfg.shown and " shown" or " hidden"))
    ExecuteInGameThread(function()
        pcall(function() self:update(M.localController(), self.active) end)
    end)
end

-- Panel rectangle in widget units for the saved position, kept on screen.
function Overlay:_rectFor(vw, vh)
    local c, w, h = self.cfg, self:_sw(), self:_sh()
    local left = c.ax * vw + c.x - c.ax * w
    local top = c.ay * vh + c.y - c.ay * h
    return { clamp(left, 0, math.max(0, vw - w)), clamp(top, 0, math.max(0, vh - h)), w, h }
end

function Overlay:_applyPosition()
    if not self.panel then return end
    local c = self.cfg
    local x, y = c.x, c.y
    local vw, vh = M.viewportSize()
    if vw then
        -- After a resolution change a saved spot may be off screen: pull it
        -- back for display without overwriting what was saved.
        local c0 = { c.ax * vw + c.x - c.ax * self:_sw(), c.ay * vh + c.y - c.ay * self:_sh() }
        local r = self:_rectFor(vw, vh)
        x, y = x + (r[1] - c0[1]), y + (r[2] - c0[2])
        self.rect = r
    end
    self.panel:setPosition(c.ax, c.ay, x, y)
end

-- Saves a new top-left, anchored to whichever screen third it landed in.
function Overlay:_setTopLeft(left, top, vw, vh)
    local function pick(center, size)
        if center < size / 3 then return 0 end
        if center > size * 2 / 3 then return 1 end
        return 0.5
    end
    local c, w, h = self.cfg, self:_sw(), self:_sh()
    c.ax = pick(left + w / 2, vw)
    c.ay = pick(top + h / 2, vh)
    c.x = math.floor(left - c.ax * vw + c.ax * w + 0.5)
    c.y = math.floor(top - c.ay * vh + c.ay * h + 0.5)
    self.panel:setPosition(c.ax, c.ay, c.x, c.y)
    self.rect = { left, top, w, h }
end

function Overlay:setSize(w, h)
    if w == self.w and h == self.h then return end
    self.w, self.h = w, h
    if self.panel then
        self.panel:setSize(self:_sw(), self:_sh())
        if not self.grabbed and not self.resizing then self:_applyPosition() end
        self:_layoutDeco()
    end
end

function Overlay:_build()
    local p = M.newPanel(self.id, { zOrder = self.z })
    if not p then return end
    local ok, ui = pcall(self.def.build, p, self)
    if not ok or not ui then
        log(self.id .. " build failed: " .. tostring(ui))
        return
    end
    self.panel, self.ui, self.deco = p, ui, nil
    p:setScale(self.cfg.scale)
    p:setSize(self:_sw(), self:_sh())
    self:_applyPosition()
    p:show()
    log(self.id .. " panel created")
end

function Overlay:_forget()
    self.panel, self.ui, self.deco, self.rect = nil, nil, nil, nil
    if self.grabbed or self.resizing then
        self.grabbed, self.resizing = false, false
        sharedSet("FFWUi.grab", "")
    end
end

-- Call from the mod's tick. active: the mod has something to show (in game).
-- Returns the mod's widgets when they should be refreshed, else nil.
function Overlay:update(pc, active)
    self.active = active
    if self.panel and not self.panel:valid() then self:_forget() end
    if active and (self.cfg.shown or layout.on) and not self.panel then self:_build() end
    if self.def.banner then M._updateBanner(active and layout.on) end
    if not self.panel then return nil end
    local visible = active and (layout.on or (self.cfg.shown and not self.def.editOnly and M.gameHudShown()))
    self.panel:setShown(visible)
    self:_decorate()
    if visible then return self.ui end
    return nil
end

function Overlay:destroy()
    if self.panel then self.panel:destroy() end
    self:_forget()
end

-- Edit-mode frame: gold outline, resize corner, name and key above the panel.
local DECO_LINES = { "top", "bottom", "left", "right", "handle" }
function Overlay:_makeDeco()
    local p, gold = self.panel, M.COLORS.gold
    self.deco = {
        top = p:box(0, 0, 1, 1, gold), bottom = p:box(0, 0, 1, 1, gold),
        left = p:box(0, 0, 1, 1, gold), right = p:box(0, 0, 1, 1, gold),
        handle = p:box(0, 0, 1, 1, gold),
        caption = p:text(0, -30, 18, gold),
    }
    self:_layoutDeco()
end

function Overlay:_layoutDeco()
    local d, p = self.deco, self.panel
    if not d or not p then return end
    local w, h, t = self.w, self.h, 2
    p:move(d.top.slot, -t, -t, w + t * 2, t)
    p:move(d.bottom.slot, -t, h, w + t * 2, t)
    p:move(d.left.slot, -t, 0, t, h)
    p:move(d.right.slot, w, 0, t, h)
    p:move(d.handle.slot, w - 12, h - 12, 14, 14)
end

function Overlay:_decorate()
    local on = layout.on
    if on and not self.deco then self:_makeDeco() end
    local d = self.deco
    if d then
        setWidgetShown(d.caption, on)
        for _, k in ipairs(DECO_LINES) do setWidgetShown(d[k], on) end
        if on then
            local color = (self.grabbed or self.resizing) and M.COLORS.lime or M.COLORS.gold
            for _, k in ipairs(DECO_LINES) do M.setBoxColor(d[k], color) end
            M.setTextColor(d.caption, color)
            local scale = (self.cfg.scale ~= 1) and string.format("   %d%%", math.floor(self.cfg.scale * 100 + 0.5)) or ""
            local key = self.def.keyName and ("  [" .. self.def.keyName .. "]") or ""
            local hidden = (self.cfg.shown or self.def.editOnly) and "" or "   HIDDEN"
            M.setText(d.caption, (self.def.title or self.id) .. key .. scale .. hidden)
        end
    end
    self.panel:setOpacity((on and not self.cfg.shown and not self.def.editOnly) and 0.45 or 1)
end

---------------------------------------------------------------------------
-- Move mode (F9): free mouse cursor, click to pick a panel up and drop it
---------------------------------------------------------------------------
local function buildBanner()
    local p = M.newPanel("FFWMoveMode", { zOrder = 60 })
    if not p then return nil end
    local W, H = 760, 128
    p:setSize(W, H)
    p:setPosition(0.5, 0, 0, 130)
    p:backdrop(W, H, 0.85, 0.5)
    local C = M.COLORS
    M.setText(p:text(0, 10, 28, C.gold, { width = W, justify = 1, height = 38 }), "EDIT OVERLAYS")
    M.setText(p:text(0, 48, 18, C.text, { font = "text", width = W, justify = 1, height = 24 }),
        "Click a panel to move it, or its corner to resize it, then click again to finish")
    M.setText(p:text(0, 72, 18, C.text, { font = "text", width = W, justify = 1, height = 24 }),
        "Click the boxes to choose what shows; switch the extras in OPTIONS")
    M.setText(p:text(0, 96, 18, C.soft, { font = "text", width = W, justify = 1, height = 24 }),
        "Right-click: hide panel      Middle-click: reset place and size      F9: done")
    p:show()
    return p
end

function M._updateBanner(want)
    local b = layout.banner
    if b and not b:valid() then b, layout.banner = nil, nil end
    if want and not b then
        layout.banner = buildBanner()
    elseif not want and b then
        b:destroy()
        layout.banner = nil
    end
end

local function publishRect(ov)
    local r = ov.rect
    if r and ov.panel then
        local f = math.floor
        sharedSet("FFWUi.rect." .. ov.id, string.format("%d %d %d %d %d", f(r[1]), f(r[2]), f(r[3]), f(r[4]), ov.z))
    else
        sharedSet("FFWUi.rect." .. ov.id, "")
    end
end

-- The top-most overlay (across all mods) under the cursor, if it is ours.
local function overlayAt(mx, my)
    local function inside(r) return mx >= r[1] and mx <= r[1] + r[3] and my >= r[2] and my <= r[2] + r[4] end
    for _, ov in ipairs(overlays) do
        if ov.panel and ov.rect and inside(ov.rect) then
            local covered = false
            for _, id in ipairs(M.OVERLAY_IDS) do
                if id ~= ov.id then
                    local s = sharedGet("FFWUi.rect." .. id)
                    local l, t, w, h, z = tostring(s or ""):match("^(%-?%d+) (%-?%d+) (%d+) (%d+) (%d+)$")
                    if l and tonumber(z) > ov.z and inside({ tonumber(l), tonumber(t), tonumber(w), tonumber(h) }) then
                        covered = true
                    end
                end
            end
            if not covered then return ov end
        end
    end
    return nil
end

-- Runs on UE4SS's input thread: plain Lua only, no widget calls.
local function onClick(button)
    if not layout.on then return end
    local t, mx, my = M.now(), layout.mx, layout.my
    if button == "left" then
        for _, ov in ipairs(overlays) do
            if ov.grabbed or ov.resizing then
                ov.grabbed, ov.resizing = false, false
                ov.savePending = true
                sharedSet("FFWUi.grab", "")
                sharedSet("FFWUi.dropAt", t)
                return
            end
        end
        -- This click put down a panel from the other mod, or one is still being carried.
        local g = sharedGet("FFWUi.grab")
        if type(g) == "string" and g ~= "" then return end
        local d = sharedGet("FFWUi.dropAt")
        if type(d) == "number" and t - d < 0.25 then return end
    end
    local ov = overlayAt(mx, my)
    if not ov then return end
    if button == "left" then
        local r, s = ov.rect, ov.cfg.scale
        local hs = math.max(14, 18 * s)
        if mx >= r[1] + r[3] - hs and my >= r[2] + r[4] - hs then
            ov.rx, ov.ry = r[1], r[2]
            ov.resizing = true
            sharedSet("FFWUi.grab", ov.id)
            return
        end
        local lx, ly = (mx - r[1]) / s, (my - r[2]) / s
        for _, z in ipairs(ov.toggles or {}) do
            if lx >= z.x and lx < z.x + z.w and ly >= z.y and ly < z.y + z.h then
                ov:_toggleItem(z)
                return
            end
        end
        ov.gx, ov.gy = mx - r[1], my - r[2]
        ov.grabbed = true
        sharedSet("FFWUi.grab", ov.id)
    elseif button == "right" then
        ov:toggle()
    elseif button == "middle" then
        ov.resetPending = true
    end
end

local function layoutTick()
    local pc = M.localController()
    if not pc or (layout.pcAddr and pc:GetAddress() ~= layout.pcAddr) then
        sharedSet("FFWUi.layoutOff", M.now())
        M.setLayout(false)
        return
    end
    -- The game took input back (e.g. Esc opened and closed its menu): leave move mode.
    if layout.inputBy == "game" and M.now() - layout.since > 1 then
        local mgr = M.menuManager()
        if mgr and try(function() return mgr.isUiMode end) == false then
            layout.inputBy = nil
            sharedSet("FFWUi.layoutOff", M.now())
            M.setLayout(false)
            return
        end
    end
    -- Another mod's copy of this file left move mode that way: follow it.
    local off = sharedGet("FFWUi.layoutOff")
    if type(off) == "number" and off > layout.since then
        M.setLayout(false)
        return
    end
    local ok, mx, my = pcall(function()
        local m = widgetLayout():GetMousePositionOnViewport(pc)
        return m.X, m.Y
    end)
    if ok and type(mx) == "number" then layout.mx, layout.my = mx, my end
    local vw, vh = M.viewportSize()
    for _, ov in ipairs(overlays) do
        if ov.panel and not ov.panel:valid() then ov:_forget() end
        if ov.panel and vw then
            if ov.resetPending then
                ov.resetPending = false
                local d = ov.def.pos
                ov.cfg.ax, ov.cfg.ay, ov.cfg.x, ov.cfg.y, ov.cfg.scale = d.ax, d.ay, d.x, d.y, 1
                ov.panel:setScale(1)
                ov.panel:setSize(ov.w, ov.h)
                ov:_applyPosition()
                ov.savePending = true
            end
            if ov.resizing then
                -- Top-left stays put; the corner follows the mouse.
                local s = math.max((layout.mx - ov.rx) / ov.w, (layout.my - ov.ry) / ov.h)
                s = clamp(math.floor(s * 20 + 0.5) / 20, M.MIN_SCALE, M.MAX_SCALE)
                if s ~= ov.cfg.scale then
                    ov.cfg.scale = s
                    ov.panel:setScale(s)
                    ov.panel:setSize(ov:_sw(), ov:_sh())
                end
                ov:_setTopLeft(clamp(ov.rx, 0, math.max(0, vw - ov:_sw())),
                    clamp(ov.ry, 0, math.max(0, vh - ov:_sh())), vw, vh)
            elseif ov.grabbed then
                ov:_setTopLeft(clamp(layout.mx - ov.gx, 0, math.max(0, vw - ov:_sw())),
                    clamp(layout.my - ov.gy, 0, math.max(0, vh - ov:_sh())), vw, vh)
            else
                ov.rect = ov:_rectFor(vw, vh)
            end
            ov:_decorate()
        end
        if ov.savePending then
            ov.savePending = false
            ov:_save()
        end
        publishRect(ov)
    end
end

-- The game's menu manager (BP_Manager_Menu) frees the mouse for its menus and
-- keeps it centred the rest of the time, so move mode goes through it too.
function M.menuManager()
    local mgr = try(function() return UEHelpers.GetGameInstance().refBpMenu end)
    if isValid(mgr) then return mgr end
    return nil
end

local function setGameInput(pc, uiMode)
    local wbl = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    pc.bShowMouseCursor = uiMode
    if uiMode then
        local ok, err = pcall(function() wbl:SetInputMode_UIOnlyEx(pc, nil, 0, true) end)
        if not ok then
            ok, err = pcall(function() wbl:SetInputMode_UIOnlyEx(pc, CreateInvalidObject(), 0, true) end)
        end
        if not ok then log("could not free the mouse: " .. tostring(err)) end
    else
        local ok, err = pcall(function() wbl:SetInputMode_GameOnly(pc, true) end)
        if not ok then log("could not give input back to the game: " .. tostring(err)) end
    end
end

-- Frees the mouse for move mode. Returns how ("game" / "ours"), or nil when
-- it was already free (a game menu is open).
local function takeInput(pc)
    local mgr = M.menuManager()
    if mgr then
        if try(function() return mgr.isUiMode end) == true then return nil end
        -- disableInputs, show cursor, special menu, go-back button, reset mouse, flush, close emote wheel, right stick
        local ok, err = pcall(function() mgr:F_SetInput_Ui(true, true, false, nil, false, true, true, false) end)
        if ok then return "game" end
        log("game menu input failed, using fallback: " .. tostring(err))
    end
    if try(function() return pc.bShowMouseCursor end) ~= false then return nil end
    setGameInput(pc, true)
    return "ours"
end

local function giveInputBack(pc, how)
    if how == "game" then
        local mgr = M.menuManager()
        local ok, err = pcall(function() mgr:F_SetInput_Game() end)
        if ok then return end
        log("game input restore failed, using fallback: " .. tostring(err))
    end
    setGameInput(pc, false)
end

-- Must run on the game thread. quiet: the map is unloading, leave widgets alone.
function M.setLayout(on, quiet)
    if on == layout.on then return end
    if on then
        layout.on = true
        sharedSet("FFWUi.grab", "")
        layout.inputBy, layout.pcAddr, layout.since = nil, nil, M.now()
        local pc = M.localController()
        -- Only take over input in gameplay; at the title screen the mouse is already free.
        if pc and M.inGame(pc) then
            layout.inputBy = takeInput(pc)
            if layout.inputBy then layout.pcAddr = pc:GetAddress() end
        end
        local lastErr = nil
        layout.loop = LoopInGameThreadWithDelay(16, function()
            local ok, err = pcall(layoutTick)
            if not ok and tostring(err) ~= lastErr then
                lastErr = tostring(err)
                log("move mode error: " .. lastErr)
            end
        end)
        for _, ov in ipairs(overlays) do
            pcall(function() ov:update(pc, ov.active) end)
            ov:_refresh()
        end
        log("move mode on (input: " .. tostring(layout.inputBy) .. ")")
    else
        layout.on = false
        if layout.loop then
            pcall(function() CancelDelayedAction(layout.loop) end)
            layout.loop = nil
        end
        for _, ov in ipairs(overlays) do
            if ov.grabbed or ov.resizing or ov.savePending then
                ov.grabbed, ov.resizing, ov.savePending = false, false, false
                ov:_save()
            end
            ov.rect = nil
            publishRect(ov)
        end
        sharedSet("FFWUi.grab", "")
        local pc = M.localController()
        if layout.inputBy and pc and pc:GetAddress() == layout.pcAddr then
            giveInputBack(pc, layout.inputBy)
        end
        layout.inputBy, layout.pcAddr = nil, nil
        if not quiet then
            M._updateBanner(false)
            for _, ov in ipairs(overlays) do
                pcall(function() ov:update(pc, ov.active) end)
                ov:_refresh()
            end
        end
        log("move mode off")
    end
end

local keysRegistered = false
function M._registerLayoutKeys()
    if keysRegistered then return end
    keysRegistered = true
    RegisterKeyBind(M.LAYOUT_KEY, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(M.setLayout, not layout.on)
            if not ok then log("move mode toggle failed: " .. tostring(err)) end
        end)
    end)
    RegisterKeyBind(Key.LEFT_MOUSE_BUTTON, function() onClick("left") end)
    RegisterKeyBind(Key.RIGHT_MOUSE_BUTTON, function() onClick("right") end)
    RegisterKeyBind(Key.MIDDLE_MOUSE_BUTTON, function() onClick("middle") end)
    pcall(function()
        RegisterLoadMapPreHook(function()
            -- The controller and widgets are about to go; the new map sets its own input.
            layout.inputBy = nil
            pcall(M.setLayout, false, true)
        end)
    end)
end

-- Runs fn on the game thread just before a map load, while the old map's
-- objects are still alive. Seamless travel skips LoadMap, so callers must also
-- cope with a panel going invalid on its own.
function M.beforeMapLoad(fn)
    pcall(function()
        RegisterLoadMapPreHook(function()
            pcCache = nil
            pcall(fn)
        end)
    end)
end

-- Dev only: logs the values move mode depends on.
function M.devReport()
    local pc = M.localController()
    local vw, vh = M.viewportSize()
    local m = pc and try(function() local v = widgetLayout():GetMousePositionOnViewport(pc) return v.X .. "," .. v.Y end)
    sharedSet("FFWUi.selftest", 42)
    log(string.format("dev: viewport=%s x %s mouse=%s shared=%s cursor=%s hud=%s fonts=%s/%s holder=%s glow=%s",
        tostring(vw), tostring(vh), tostring(m), tostring(sharedGet("FFWUi.selftest")),
        tostring(pc and try(function() return pc.bShowMouseCursor end)), tostring(M.gameHudShown()),
        tostring(M.font("title") ~= nil), tostring(M.font("text") ~= nil),
        tostring(M.asset(TEX.holder) ~= nil), tostring(M.asset(TEX.glow) ~= nil)))
end

return M
