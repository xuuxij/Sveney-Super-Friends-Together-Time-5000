-- StatsPanel: your stats as base -> current, plus what each Joker adds.
--   F6       show / hide (remembered)
--   F9       edit mode (shared with the damage meter): move, resize, and
--            tick which stats to show; extra stats start switched off
--   Ctrl+F6  write every raw value to UE4SS.log (for tuning the panel)
-- Base values come from class defaults; current values come from the live
-- objects or the game's own stat getters (F_GetAttackSpeed, F_GetJumpHeight, ...).

local MOD_VERSION = "1.2.0"

local CONFIG = {
    TOGGLE_KEY = Key.F6,
    REFRESH_MS = 500,
    JOKER_REFRESH_S = 2,     -- joker effects are recomputed less often
    MAX_ROWS = 44,
    -- Default spot: vertically centred, right of the damage meter. F9 in game
    -- moves it; the new spot is saved in settings.txt next to this mod.
    POSITION = { ax = 0, ay = 0.5, x = 290, y = 0 },
    DEV_SHOW = false,        -- dev only: open at start and render outside gameplay
}

-- settings.txt sits next to this mod's Scripts folder, whatever the working directory is.
local MOD_DIR = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]Scripts[/\\][^/\\]+$")) or "."

local LIB_PATH = "/Game/Gamework/BPFL_FunctionLibrary.Default__BPFL_FunctionLibrary_C"

-- Joker data-table fields keep their Blueprint GUID suffixes.
local JK = {
    name = "name_3_900CE89C4C42F8E3996E31AE7D18EF03",
    flat = "displayValueAsFlat_75_35F59DDB47A6C7A160A0198B5BDDAA13",
    heal = "updatePlayerHealValueInGame_57_50A62A9641DD3BC920A3289C6604C66D",
    shield = "updatePlayerShieldPointsValueInGame_73_440251DC4BD01AC2CD5348A0B4808896",
}
-- Per-weapon loadout: GameInstance.playerProgress.itemJokers[ItemName]
local PROGRESS_ITEM_JOKERS = "itemJokers_221_B68401A4476969C408297F9FD92F3128"
local SLOT_FIELDS = {
    "jokerA_3_23C049D0462EEF85DCEED5A552CB20C6",
    "jokerB_5_6F57743649A6BCBB31FA92AB586E5927",
    "jokerC_7_CAA1435144DD919464E77BBC212050C1",
    "jokerD_9_FBF331A148DB2793079596AA71EF8375",
}
local SLOT_LIST = "jokers_13_7822C195413EA2810E969F8C260AA8B6"

local ITEM = {
    mag = "maxMagazineAmmos_8_E1B199D345F51D5DF152DBBB0371E153",
    total = "maxTotalAmmos_18_2EACEDBD42C653C7490D2F999719144E",
}

local FFWUi = require("FFWUi")
local log = FFWUi.logger("StatsPanel")
local C = FFWUi.COLORS

---------------------------------------------------------------------------
-- Reading values (every read is guarded: a missing field shows as "-")
---------------------------------------------------------------------------
local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function num(v)
    if type(v) == "number" then return v end
    return nil
end

local function valid(o)
    return o ~= nil and type(o) == "userdata" and try(function() return o:IsValid() end) == true
end

local function cdo(obj)
    return try(function() return obj:GetClass():GetCDO() end)
end

local function str(v)
    return try(function() return v:ToString() end) or tostring(v)
end

-- Calls a Blueprint function whose result comes back through an out param.
local function callOut(obj, fn, outName, ...)
    local args = { ... }
    local out = {}
    args[#args + 1] = out
    local ok = pcall(function() obj[fn](obj, table.unpack(args)) end)
    if ok then return out[outName] end
    return nil
end

local function countNames(arr, counts)
    pcall(function()
        arr:ForEach(function(_, e)
            local n = str(e:get())
            counts[n] = (counts[n] or 0) + 1
        end)
    end)
end

---------------------------------------------------------------------------
-- Joker effects
---------------------------------------------------------------------------
local jokerCache = { t = -1e9, list = {}, healBonus = 0, shieldBonus = 0, diag = {} }

-- Jokers equipped on this weapon in the loadout. The list field is used when
-- present; the four fixed slots are the fallback, so nothing is counted twice.
local function weaponJokers(gi, itemName, counts, diag)
    local entry = try(function() return gi.playerProgress[PROGRESS_ITEM_JOKERS]:Find(itemName) end)
    if not entry then diag[#diag + 1] = "no loadout entry for weapon" return end
    local row = try(function() return entry:get() end) or entry
    local listCounts, n = {}, 0
    pcall(function()
        row[SLOT_LIST]:ForEach(function(_, e)
            local id = str(e:get())
            if id ~= "None" and id ~= "" then
                listCounts[id] = (listCounts[id] or 0) + 1
                n = n + 1
            end
        end)
    end)
    local slots = {}
    for _, f in ipairs(SLOT_FIELDS) do
        local id = str(try(function() return row[f] end))
        if id and id ~= "None" and id ~= "" and id ~= "nil" then slots[#slots + 1] = id end
    end
    diag[#diag + 1] = "loadout list=" .. n .. " slots=" .. table.concat(slots, ",")
    if n > 0 then
        for id, c in pairs(listCounts) do counts[id] = (counts[id] or 0) + c end
    else
        for _, id in ipairs(slots) do counts[id] = (counts[id] or 0) + 1 end
    end
end

local function readJokers(pc, pawn, ps, item)
    local gi = try(function() return ps.GameInstance end)
    if not valid(gi) then return jokerCache end
    local lib = StaticFindObject(LIB_PATH)
    local itemName = item and try(function() return item.ItemName end)

    local owned, diag = {}, {}
    countNames(try(function() return gi.runtimerJokers end), owned)
    countNames(try(function() return ps.itemHeroJokers end), owned)
    if itemName then weaponJokers(gi, itemName, owned, diag) end
    diag[#diag + 1] = "library " .. (valid(lib) and "found" or "MISSING")

    local list, heal, shield = {}, 0, 0
    local callErr = nil
    pcall(function()
        gi.jokersDataTable:ForEach(function(k, v)
            local key = k:get()
            local id = str(key)
            local row = v:get()
            local count = owned[id] or 0
            local equipped, value = false, nil
            if valid(lib) and itemName then
                local o1, o2 = {}, {}
                local ok, err = pcall(function()
                    lib:F_GetJokerEffects(gi, key, itemName, pc, o1, o2)
                end)
                if not ok and not callErr then callErr = tostring(err) end
                if ok then
                    equipped = o1.isJokerEquiped == true
                    value = num(o2.jokerCumulativeValue)
                end
            end
            if equipped or count > 0 then
                local display = try(function() return row[JK.name]:ToString() end)
                list[#list + 1] = {
                    id = id,
                    name = (display and display ~= "") and display or id,
                    count = count,
                    value = value,
                    flat = try(function() return row[JK.flat] end) == true,
                }
                heal = heal + (num(try(function() return row[JK.heal] end)) or 0) * count
                shield = shield + (num(try(function() return row[JK.shield] end)) or 0) * count
            end
        end)
    end)
    table.sort(list, function(a, b) return a.name < b.name end)
    if callErr then diag[#diag + 1] = "F_GetJokerEffects error: " .. callErr end
    jokerCache = { t = FFWUi.now(), list = list, healBonus = heal, shieldBonus = shield, diag = diag }
    return jokerCache
end

---------------------------------------------------------------------------
-- Stat rows
---------------------------------------------------------------------------
-- kind: "pct" shows % change, "diff" shows +/- difference
local function collect(pc, forceJokers)
    local rows = {}
    -- key: what edit mode switches on/off; extra: off until switched on.
    local function header(text, key) rows[#rows + 1] = { header = text, key = "section:" .. key } end
    local function row(label, base, now, kind, extra)
        rows[#rows + 1] = { label = label, key = label, base = num(base), now = num(now), kind = kind or "pct", extra = extra }
    end

    local pawn = try(function() return pc.Pawn end)
    local ps = try(function() return pc.PlayerState end)
    if not valid(pawn) or not valid(ps) then return rows end
    local pawnCdo, psCdo = cdo(pawn), cdo(ps)
    local items = try(function() return pawn.AC_PlayerItems end)
    local item = valid(items) and try(function() return items.equipedItem end) or nil
    if not valid(item) then item = nil end

    if forceJokers or FFWUi.now() - jokerCache.t >= CONFIG.JOKER_REFRESH_S then
        readJokers(pc, pawn, ps, item)
    end

    header("PLAYER", "PLAYER")
    local maxHp = try(function() return ps.playerMaxHeal end)
    row("Max HP", num(maxHp) and (maxHp - jokerCache.healBonus), maxHp, "diff")

    local shieldComp = try(function() return ps.AC_PlayerState_Shield end)
    if valid(shieldComp) then
        local sMax = try(function() return shieldComp.shieldPointsMax end)
        local sBase = try(function() return cdo(shieldComp).shieldPointsMax end)
        if num(sMax) and jokerCache.shieldBonus ~= 0 then sBase = sMax - jokerCache.shieldBonus end
        row("Max shield", sBase, sMax, "diff")
    end

    row("Damage taken x", 1.0, try(function() return ps.jokerDamageReduction end))
    row("Cooldown reduction", try(function() return psCdo.tweakCooldownReduction end),
        try(function() return ps.tweakCooldownReduction end), "diff")

    local move = try(function() return pawn.CharacterMovement end)
    local moveCdo = try(function() return pawnCdo.CharacterMovement end)
    row("Move speed", try(function() return moveCdo.MaxWalkSpeed end), try(function() return move.MaxWalkSpeed end))
    local baseJump = try(function() return moveCdo.JumpZVelocity end)
    local jump = num(baseJump) and try(function() return pawn:F_GetJumpHeight(baseJump) end)
    row("Jump height", baseJump, num(jump) or try(function() return move.JumpZVelocity end))
    row("Jumps", try(function() return pawnCdo.JumpMaxCount end), try(function() return pawn.JumpMaxCount end), "diff")
    row("Dashes", try(function() return pawnCdo.maxDash end), try(function() return pawn.maxDash end), "diff")
    row("Dash cooldown (s)", try(function() return pawnCdo.dashCooldown end), try(function() return pawn.dashCooldown end))
    row("Size", try(function() return psCdo.playerSize end), try(function() return ps.playerSize end))
    row("Recoil", try(function() return pawnCdo.weaponRecoil end), try(function() return pawn.weaponRecoil end), "pct", true)
    row("Stability", try(function() return pawnCdo.stability end), try(function() return pawn.stability end), "pct", true)
    row("Kill combo", nil, try(function() return ps.enemyKillCombo end), "diff", true)

    if item then
        local itemCdo = cdo(item)
        local raw = str(try(function() return item.ItemName end)) or "?"
        local pretty = raw:gsub("^item", ""):gsub("(%l)(%u)", "%1 %2")
        header("WEAPON  " .. pretty, "WEAPON")
        -- The Minigun spins up on its own fire rate instead of the shared attack-speed getter.
        local minigunBase = num(try(function() return itemCdo.minigunFirerate end))
        if minigunBase then
            row("Fire rate", minigunBase, try(function() return item:F_GetMinigunFireRate() end))
        else
            local baseRate = try(function() return itemCdo.fireRate end)
            row("Attack speed", baseRate, num(baseRate) and callOut(item, "F_GetAttackSpeed", "AttackSpeed", baseRate))
        end
        row("Reload speed", nil, callOut(item, "F_GetReloadSpeed", "ReloadSpeed"))
        local swap = {}
        pcall(function() item:F_GetWeaponSwapSpeed(1.0, 1.0, swap, swap) end)
        row("Swap speed x", 1.0, swap.Speed)
        row("Ricochets", 0, callOut(item, "F_GetRicochetsAmount", "Amount"), "diff")
        local datas = {}
        pcall(function() item:F_GetItemDatas(datas) end)
        row("Magazine", try(function() return itemCdo.defaultItemDatas[ITEM.mag] end), datas[ITEM.mag], "diff")
        row("Max ammo", try(function() return itemCdo.defaultItemDatas[ITEM.total] end), datas[ITEM.total], "diff")
        row("Spell cooldown (s)", try(function() return itemCdo.spellCooldown end),
            try(function() return item.spellCooldown end), "pct", true)
        row("XP multiplier", try(function() return itemCdo.xpMultiplier end), try(function() return item.xpMultiplier end), "pct", true)
    end

    header("JOKERS  (" .. #jokerCache.list .. ")", "JOKERS")
    for _, j in ipairs(jokerCache.list) do
        rows[#rows + 1] = { joker = j }
    end
    return rows
end

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------
local function fmtNum(v)
    if not v then return "-" end
    if math.abs(v - math.floor(v)) < 1e-6 then return string.format("%d", math.floor(v)) end
    local s = string.format("%.2f", v):gsub("0+$", ""):gsub("%.$", "")
    return s
end

local function change(r)
    if not r.base or not r.now then return "", C.dim end
    local d = r.now - r.base
    if math.abs(d) < 1e-6 then return "", C.dim end
    local color = C.gold
    if r.kind == "diff" then
        return (d > 0 and "+" or "") .. fmtNum(d), color
    end
    if math.abs(r.base) < 1e-9 then return (d > 0 and "+" or "") .. fmtNum(d), color end
    local pct = d / math.abs(r.base) * 100
    return string.format("%+.0f%%", pct), color
end

local function jokerValue(j)
    if not j.value then return "" end
    return "+" .. fmtNum(j.value) .. (j.flat and "" or "%")
end

---------------------------------------------------------------------------
-- HUD (the game's tooltip look: dark holder, gold titles)
---------------------------------------------------------------------------
local PAD = 16
local TOP = 48           -- first row
local PITCH = 22
local EDIT_DX = 24       -- room for the tick boxes in edit mode
-- Column x and width, relative to the row.
local COLS = { label = { 0, 168 }, base = { 168, 72 }, now = { 246, 72 }, change = { 324, 64 } }
local WIDTH = 420

local function panelHeight(n)
    return TOP + math.max(n, 1) * PITCH + 10
end

local function rowY(i)
    return TOP + (i - 1) * PITCH
end

local function col(g, name, size, color)
    local c = COLS[name]
    -- Labels may run into the base column, which is empty on header and Joker rows.
    local width = c[2] + ((name == "label") and COLS.base[2] or 0)
    return g:text(c[1], 0, size or 17, color or C.text, { width = width, justify = (name == "label") and 0 or 2, height = PITCH })
end

local function buildUi(p)
    local u = { panel = p, rows = {}, checks = {}, dx = 0 }
    u.bd = p:backdrop(WIDTH, panelHeight(1), 0.85, 0.5)
    FFWUi.setText(p:text(PAD, 6, 28, C.gold), "STATS")
    u.head = p:group(PAD, 16)
    FFWUi.setText(col(u.head, "base", 16, C.dim), "BASE")
    FFWUi.setText(col(u.head, "now", 16, C.dim), "NOW")
    for i = 1, CONFIG.MAX_ROWS do
        local g = p:group(PAD, rowY(i))
        u.rows[i] = { group = g, label = col(g, "label"), base = col(g, "base"), now = col(g, "now"), change = col(g, "change") }
    end
    return u
end

local tick -- forward: edit-mode clicks redraw straight away

local overlay = FFWUi.overlay({
    id = "StatsPanel", title = "STATS", keyName = "F6", z = 51,
    toggleKey = CONFIG.TOGGLE_KEY, shown = CONFIG.DEV_SHOW, pos = CONFIG.POSITION,
    width = WIDTH, height = panelHeight(1),
    settings = MOD_DIR .. "/settings.txt",
    build = buildUi,
    refresh = function() if tick then tick() end end,
})

-- Rows to draw: switched-off stats and sections are skipped, except in edit
-- mode, where everything shows (faded when off) next to a tick box.
local function visibleRows(rows, editing)
    local out, sectionOn = {}, true
    for _, r in ipairs(rows) do
        local on
        if r.header then
            sectionOn = overlay:itemShown(r.key, true)
            on = sectionOn
        else
            on = sectionOn and (r.key == nil or overlay:itemShown(r.key, not r.extra))
        end
        if on or editing then out[#out + 1] = { row = r, on = on } end
    end
    return out
end

-- Tick boxes are only built the first time edit mode needs them.
local function checkFor(ui, i)
    local cb = ui.checks[i]
    if not cb then
        cb = ui.panel:checkbox(PAD, rowY(i) + 4)
        ui.checks[i] = cb
    end
    return cb
end

local function render(ui, rows)
    local editing = overlay:editing()
    local dx = editing and EDIT_DX or 0
    if ui.dx ~= dx then
        ui.dx = dx
        ui.panel:move(ui.head.slot, PAD + dx, 16)
        for i, w in ipairs(ui.rows) do ui.panel:move(w.group.slot, PAD + dx, rowY(i)) end
    end
    local list = visibleRows(rows, editing)
    local n = math.min(#list, CONFIG.MAX_ROWS)
    local zones = {}
    for i = 1, CONFIG.MAX_ROWS do
        local w, e = ui.rows[i], list[i]
        if i > n or not e then
            FFWUi.setShown(w.group, false)
            if ui.checks[i] then FFWUi.setShown(ui.checks[i], false) end
        else
            local r = e.row
            FFWUi.setShown(w.group, true)
            FFWUi.setDim(w.group, not e.on)
            if r.header then
                FFWUi.setTextColor(w.label, C.gold)
                FFWUi.setText(w.label, r.header)
                FFWUi.setText(w.base, ""); FFWUi.setText(w.now, ""); FFWUi.setText(w.change, "")
            elseif r.joker then
                local j = r.joker
                FFWUi.setTextColor(w.label, C.text)
                FFWUi.setText(w.label, j.name .. ((j.count > 1) and ("  x" .. j.count) or ""))
                FFWUi.setText(w.base, "")
                FFWUi.setText(w.now, "")
                FFWUi.setTextColor(w.change, C.soul)
                FFWUi.setText(w.change, jokerValue(j))
            else
                FFWUi.setTextColor(w.label, C.text)
                FFWUi.setText(w.label, r.label)
                FFWUi.setTextColor(w.base, C.dim)
                FFWUi.setText(w.base, fmtNum(r.base))
                FFWUi.setText(w.now, fmtNum(r.now))
                local s, color = change(r)
                FFWUi.setTextColor(w.change, color)
                FFWUi.setText(w.change, s)
            end
            local boxed = editing and r.key ~= nil
            if boxed then
                local cb = checkFor(ui, i)
                local default = not r.extra
                FFWUi.setShown(cb, true)
                FFWUi.setCheck(cb, overlay:itemShown(r.key, default))
                zones[#zones + 1] = { key = r.key, default = default, x = 0, y = rowY(i), w = PAD + dx, h = PITCH }
            elseif ui.checks[i] then
                FFWUi.setShown(ui.checks[i], false)
            end
        end
    end
    if #list > CONFIG.MAX_ROWS then FFWUi.setText(ui.rows[CONFIG.MAX_ROWS].label, "...") end
    overlay:setToggles(zones)
    local w, h = WIDTH + dx, panelHeight(n)
    if ui.w ~= w or ui.h ~= h then
        ui.w, ui.h = w, h
        ui.panel:resizeBackdrop(ui.bd, w, h)
        overlay:setSize(w, h)
    end
end

local function destroyUi()
    overlay:destroy()
end

FFWUi.beforeMapLoad(destroyUi)

-- Dev only: sample rows so the panel can be checked at the main menu.
local function sampleRows()
    local function stat(label, base, now, kind, extra)
        return { label = label, key = label, base = base, now = now, kind = kind, extra = extra }
    end
    return {
        { header = "PLAYER", key = "section:PLAYER" },
        stat("Max HP", 91, 120, "diff"),
        stat("Move speed", 550, 682, "pct"),
        stat("Dash cooldown (s)", 1, 0.85, "pct"),
        stat("Recoil", 1, 0.8, "pct", true),
        { header = "WEAPON  Minigun", key = "section:WEAPON" },
        stat("Fire rate", 12, 15.5, "pct"),
        stat("Max ammo", 300, 585, "diff"),
        { header = "JOKERS  (2)", key = "section:JOKERS" },
        { joker = { name = "Quick Hands", count = 2, value = 20, flat = false } },
        { joker = { name = "Extra Lead", count = 1, value = 285, flat = true } },
    }
end

local currentWorld = nil

function tick()
    local pc = FFWUi.localController()
    if not pc then return end
    local world = try(function() return pc:GetWorld() end)
    if valid(world) then
        local key = world:GetAddress()
        if key ~= currentWorld then
            currentWorld = key
            jokerCache.t = -1e9
            destroyUi()
        end
    end
    local inGame = FFWUi.inGame(pc)
    local ui = overlay:update(pc, CONFIG.DEV_SHOW or inGame)
    if ui then
        local rows = (CONFIG.DEV_SHOW and not inGame) and sampleRows() or collect(pc, false)
        render(ui, rows)
    end
end

---------------------------------------------------------------------------
-- Ctrl+F6: raw dump for tuning
---------------------------------------------------------------------------
local function dump()
    local pc = FFWUi.localController()
    if not pc then log("dump: no local controller") return end
    local rows = collect(pc, true)
    log("---- stats dump v" .. MOD_VERSION .. " ----")
    for _, r in ipairs(rows) do
        if r.header then
            log("[" .. r.header .. "]")
        elseif r.joker then
            local j = r.joker
            log(string.format("  joker %s (%s) count=%d value=%s flat=%s", j.name, j.id, j.count, tostring(j.value), tostring(j.flat)))
        else
            log(string.format("  %-20s base=%s now=%s", r.label, tostring(r.base), tostring(r.now)))
        end
    end
    log(string.format("  heal bonus from jokers=%s shield bonus=%s", tostring(jokerCache.healBonus), tostring(jokerCache.shieldBonus)))
    for _, d in ipairs(jokerCache.diag or {}) do log("  joker source: " .. d) end
    local ps = try(function() return pc.PlayerState end)
    if valid(ps) then
        log("  F_GetDamageReduction()=" .. tostring(try(function() return ps:F_GetDamageReduction() end)))
        log("  playerHeal=" .. tostring(try(function() return ps.playerHeal end)))
        local item = try(function() return pc.Pawn.AC_PlayerItems.equipedItem end)
        local mg = valid(item) and num(try(function() return item.minigunFirerate end))
        if mg then
            log(string.format("  minigun: minigunFirerate=%s default=%s F_GetMinigunFireRate()=%s speedAlpha=%s",
                tostring(mg), tostring(try(function() return cdo(item).minigunFirerate end)),
                tostring(try(function() return item:F_GetMinigunFireRate() end)),
                tostring(try(function() return item.speedAlpha end))))
        end
    end
    log("---- end dump ----")
end

RegisterKeyBind(CONFIG.TOGGLE_KEY, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(dump)
        if not ok then log("dump failed: " .. tostring(err)) end
    end)
end)

log("v" .. MOD_VERSION .. " loaded")

ExecuteInGameThreadWithDelay(3000, function()
    local lastErr = nil
    LoopInGameThreadWithDelay(CONFIG.REFRESH_MS, function()
        local ok, err = pcall(tick)
        if not ok and tostring(err) ~= lastErr then
            lastErr = tostring(err)
            log("tick error: " .. lastErr)
        end
    end)
end)
