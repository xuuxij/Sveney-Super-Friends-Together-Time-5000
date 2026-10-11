-- Dev-only: dumps the game's own HUD/menu widget trees (fonts, colours,
-- brushes, layout) to UE4SS.log so our overlays can copy the game's style.
-- Never shipped in the pack.

local TAG = "[StyleProbe] "
local function log(m) print(TAG .. m .. "\n") end
local function try(f) local ok, v = pcall(f) if ok then return v end return nil end

local WIDGETS = {
    "/Game/Interfaces/UI_Player",
    "/Game/Interfaces/UI_Counter",
    "/Game/Interfaces/UI_ShortMessage",
    "/Game/Interfaces/UI_Tooltip",
    "/Game/Interfaces/UI_Notif",
    "/Game/Interfaces/UI_Timer",
    "/Game/Interfaces/UI_Interact",
    "/Game/Interfaces/UI_SpellCooldown",
    "/Game/Interfaces/UI_Joker_Informations",
    "/Game/Interfaces/Equipment/UI_Equipment_PlayerStats",
    "/Game/Interfaces/Equipment/UI_EpicTweakTooltip",
    "/Game/Interfaces/Tweaks/UI_Joker_InGameOnScreen",
    "/Game/Interfaces/MainMenu/UI_Menu_Container_PauseGame",
    "/Game/Interfaces/MainMenu/UI_Menu_Popup",
}

local function name(o) return try(function() return o:GetFName():ToString() end) or "?" end
local function full(o)
    if o == nil then return "nil" end
    return try(function() if not o:IsValid() then return "invalid" end return o:GetFullName() end) or "?"
end
local function f3(v) return type(v) == "number" and string.format("%.3f", v) or tostring(v) end
local function color(c)
    return try(function() return "(" .. f3(c.R) .. "," .. f3(c.G) .. "," .. f3(c.B) .. "," .. f3(c.A) .. ")" end) or "?"
end
local function slateColor(sc)
    return color(try(function() return sc.SpecifiedColor end)) .. "/rule" .. tostring(try(function() return sc.ColorUseRule end))
end
local function margin(m)
    return try(function() return "(" .. f3(m.Left) .. "," .. f3(m.Top) .. "," .. f3(m.Right) .. "," .. f3(m.Bottom) .. ")" end) or "?"
end
local function vec2(v) return try(function() return "(" .. f3(v.X) .. "," .. f3(v.Y) .. ")" end) or "?" end
local function brush(b)
    if b == nil then return "nil" end
    local o = try(function() return b.OutlineSettings end)
    return string.format("res=%s drawAs=%s size=%s margin=%s tint=%s tiling=%s outline[radii=%s width=%s color=%s round=%s]",
        full(try(function() return b.ResourceObject end)), tostring(try(function() return b.DrawAs end)),
        vec2(try(function() return b.ImageSize end)), margin(try(function() return b.Margin end)),
        slateColor(try(function() return b.TintColor end)), tostring(try(function() return b.Tiling end)),
        try(function() local r = o.CornerRadii return f3(r.X) .. "," .. f3(r.Y) .. "," .. f3(r.Z) .. "," .. f3(r.W) end) or "?",
        tostring(try(function() return o.Width end)), slateColor(try(function() return o.Color end)),
        tostring(try(function() return o.RoundingType end)))
end

local function slotInfo(w)
    local s = try(function() return w.Slot end)
    if s == nil or not try(function() return s:IsValid() end) then return "" end
    local cls = name(s:GetClass())
    if cls == "CanvasPanelSlot" then
        return try(function()
            local L = s.LayoutData
            return string.format(" [canvas off=%s anch=%s-%s align=%s auto=%s z=%s]", margin(L.Offsets),
                vec2(L.Anchors.Minimum), vec2(L.Anchors.Maximum), vec2(L.Alignment), tostring(s.bAutoSize), tostring(s.ZOrder))
        end) or " [canvas ?]"
    end
    return string.format(" [%s pad=%s h=%s v=%s]", cls, margin(try(function() return s.Padding end)),
        tostring(try(function() return s.HorizontalAlignment end)), tostring(try(function() return s.VerticalAlignment end)))
end

local function walk(w, depth)
    if w == nil or not try(function() return w:IsValid() end) then return end
    local cls = name(w:GetClass())
    local ind = string.rep("  ", depth)
    log(ind .. cls .. " " .. name(w) .. slotInfo(w) .. " vis=" .. tostring(try(function() return w.Visibility end))
        .. " op=" .. f3(try(function() return w.RenderOpacity end)))
    local font = try(function() return w.Font end)
    if font ~= nil and try(function() return w.Font.Size end) then
        log(ind .. "  font=" .. full(try(function() return font.FontObject end)) .. " face=" .. tostring(try(function() return font.TypefaceFontName:ToString() end))
            .. " size=" .. tostring(try(function() return font.Size end)) .. " spacing=" .. tostring(try(function() return font.LetterSpacing end))
            .. " skew=" .. tostring(try(function() return font.SkewAmount end))
            .. " outline=" .. tostring(try(function() return font.OutlineSettings.OutlineSize end)) .. color(try(function() return font.OutlineSettings.OutlineColor end))
            .. " mat=" .. full(try(function() return font.FontMaterial end)))
        log(ind .. "  color=" .. slateColor(try(function() return w.ColorAndOpacity end))
            .. " shadow=" .. vec2(try(function() return w.ShadowOffset end)) .. color(try(function() return w.ShadowColorAndOpacity end))
            .. " justify=" .. tostring(try(function() return w.Justification end))
            .. " text=\"" .. tostring(try(function() return w.Text:ToString() end)):sub(1, 40) .. "\"")
    end
    if cls == "Image" then
        log(ind .. "  brush " .. brush(try(function() return w.Brush end)) .. " color=" .. color(try(function() return w.ColorAndOpacity end)))
    elseif cls == "Border" then
        log(ind .. "  bg " .. brush(try(function() return w.Background end)) .. " brushColor=" .. color(try(function() return w.BrushColor end))
            .. " pad=" .. margin(try(function() return w.Padding end)) .. " content=" .. color(try(function() return w.ContentColorAndOpacity end)))
    elseif cls == "ProgressBar" then
        log(ind .. "  bgImg " .. brush(try(function() return w.WidgetStyle.BackgroundImage end)))
        log(ind .. "  fillImg " .. brush(try(function() return w.WidgetStyle.FillImage end)) .. " fillColor=" .. color(try(function() return w.FillColorAndOpacity end)))
    elseif cls == "SizeBox" then
        log(ind .. "  sizebox w=" .. tostring(try(function() return w.WidthOverride end)) .. " h=" .. tostring(try(function() return w.HeightOverride end)))
    end
    local slots = try(function() return w.Slots end)
    if slots then
        pcall(function()
            slots:ForEach(function(_, s)
                local sl = s:get()
                walk(try(function() return sl.Content end), depth + 1)
            end)
        end)
    end
end

local function dumpWidget(path)
    local short = path:match("([^/]+)$")
    pcall(function() LoadAsset(path .. "." .. short) end)
    local tree = StaticFindObject(path .. "." .. short .. "_C:WidgetTree")
    if not tree or not tree:IsValid() then log("== " .. short .. ": no WidgetTree") return end
    log("== " .. short)
    walk(try(function() return tree.RootWidget end), 1)
end

ExecuteInGameThreadWithDelay(8000, function()
    log("dump start")
    for _, p in ipairs(WIDGETS) do
        local ok, err = pcall(dumpWidget, p)
        if not ok then log("error in " .. p .. ": " .. tostring(err)) end
    end
    log("dump end")
end)
