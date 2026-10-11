-- Kill streaks: MULTI KILL, MEGA KILL ... called out as big text with a sound.
-- A streak is kills in a row with no more than STREAK_GAP_S between them; each
-- tier is announced once per streak. Your kills come from the game's own run
-- leaderboard (the count its end screen uses).
-- The first tier stays on your own screen. From the second up, the call goes
-- out as a chat line through the game's own chat, so everybody gets it; each
-- player's copy of this mod spots those lines and adds the big text and the
-- sound. Sounds are the game's five difficulty-select stingers.

local UEHelpers = require("UEHelpers")

local M = {}

local STREAK_GAP_S = 4
-- team: also sent to the others. Without it a busy lobby would hear nothing else.
local TIERS = {
    { kills = 10, text = "MULTI KILL", sound = "A" },
    { kills = 25, text = "MEGA KILL", sound = "B", team = true },
    { kills = 50, text = "ULTRA KILL", sound = "C", team = true },
    { kills = 100, text = "MONSTER KILL", sound = "D", team = true },
    { kills = 200, text = "GODLIKE", sound = "E", team = true },
}
local SENDER_GAP_S = 10   -- one call-out per team mate in this long
local SOUND_PATH = "/Game/Interfaces/Preparation/S_SelectDifficulty_%s.S_SelectDifficulty_%s"
local VOLUME = 1.0
local SHOW_S, FADE_IN_S, FADE_OUT_S = 3.2, 0.12, 0.6
local W, H = 760, 104
local EDIT_Y = 300        -- in edit mode, below the banner that sits where call-outs normally go

-- FS_PlayerRuntimeLeaderboard / FS_ChatMessage fields keep their Blueprint GUID suffixes.
local LB_KILLS = "enemies_2_9973937A40A8847C477EFABB3A8ED2FB"
local CHAT = {
    name = "playerName_12_F312750C4535B7687009F18A1D6070C0",
    text = "text_5_B3D2581E44A0B1B9B8DDEA8054C14F28",
    color = "color_10_FA4504B645E6947C5B39F59CAD18D9FE",
    ps = "playerState_15_953D6504499D70822566D9A138F9A95A",
}

local ctx, FFWUi, C, log
local run = { addr = nil, kills = 0 }
local streak = { n = 0, lastT = 0, tier = 0 }
local chat = { count = nil, last = nil }
local heardAt = {}    -- team mate's name -> when their last call-out was shown
local showing = nil   -- { title, sub, t0, seconds, tier (nil for a plain notice) }
local panel, ui, panelY = nil, nil, nil
local preview = false -- set from the input thread, shown on the next tick
local soundsLoaded = false
local diag = { sent = 0, heard = 0, err = nil }

local function try(f, ...)
    local ok, v = pcall(f, ...)
    if ok then return v end
    return nil
end

local function str(v)
    if type(v) == "string" then return v end
    return try(function() return v:ToString() end) or tostring(v)
end

local function soundFor(tier)
    local s = TIERS[tier].sound
    return FFWUi.asset(string.format(SOUND_PATH, s, s))
end

local function play(pc, tier)
    local snd = soundFor(tier)
    if not snd then
        diag.err = "sound for tier " .. tier .. " not found"
        return
    end
    local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
    -- context, sound, volume, pitch, start time, concurrency, owner, UI sound
    local ok, err = pcall(function() gs:PlaySound2D(pc, snd, VOLUME, 1.0, 0.0, nil, nil, true) end)
    if not ok then
        ok, err = pcall(function()
            local none = CreateInvalidObject()
            gs:PlaySound2D(pc, snd, VOLUME, 1.0, 0.0, none, none, true)
        end)
    end
    if not ok then diag.err = "sound: " .. tostring(err) end
end

-- A call-out never pushes a bigger one off the screen. True when it was shown.
local function show(pc, tier, name, detail)
    local t = FFWUi.now()
    if showing and showing.tier and showing.tier > tier and t - showing.t0 < showing.seconds then return false end
    showing = { title = TIERS[tier].text, sub = name .. ((detail ~= "") and ("   " .. detail) or ""), t0 = t, seconds = SHOW_S, tier = tier }
    play(pc, tier)
    return true
end

---------------------------------------------------------------------------
-- Big text, upper middle of the screen
---------------------------------------------------------------------------
local function buildPanel()
    local p = FFWUi.newPanel("Announcer", { zOrder = 58 })
    if not p then return end
    p:setSize(W, H)
    panel, panelY = p, nil
    -- Soft dark patch behind the words, so they hold up against a bright sky.
    p:image((W - 580) / 2, -16, 580, 136, { R = 0, G = 0, B = 0, A = 0.6 }, { path = FFWUi.TEXTURES.glow, drawAs = 1, margin = 0.5, size = 128 })
    ui = {
        title = p:text(0, 0, 52, C.gold, { width = W, justify = 1, height = 66, skew = 0.2 }),
        sub = p:text(0, 68, 22, C.text, { font = "text", width = W, justify = 1, height = 30 }),
    }
    p:show()
end

local function draw(pc, t)
    if panel and not panel:valid() then panel, ui = nil, nil end
    if not showing then
        if panel then panel:setShown(false) end
        return
    end
    local age = t - showing.t0
    if age >= showing.seconds or not ctx.active(pc) then
        showing = nil
        if panel then panel:setShown(false) end
        return
    end
    if not panel then buildPanel() end
    if not panel then return end
    local y = ctx.editing() and EDIT_Y or ctx.CONFIG.ANNOUNCER_Y
    if panelY ~= y then
        panelY = y
        panel:setPosition(0.5, 0, 0, y)
    end
    FFWUi.setText(ui.title, showing.title)
    FFWUi.setText(ui.sub, showing.sub)
    local a = 1
    if age < FADE_IN_S then a = age / FADE_IN_S end
    if age > showing.seconds - FADE_OUT_S then a = (showing.seconds - age) / FADE_OUT_S end
    panel:setOpacity(math.floor(a * 20 + 0.5) / 20)
    panel:setShown(FFWUi.gameHudShown())
end

---------------------------------------------------------------------------
-- Your own streak
---------------------------------------------------------------------------
local function detail(n)
    return n .. " kills in a row"
end

local function broadcast(pc, tier, n)
    local ok, err = pcall(function()
        local ps = pc.PlayerState
        ps:F_AddMessageToChat_Server({
            [CHAT.name] = str(ps:GetPlayerName()),
            [CHAT.text] = FText(TIERS[tier].text .. "!  " .. detail(n)),
            [CHAT.color] = C.gold,
            [CHAT.ps] = ps,
        })
    end)
    if ok then diag.sent = diag.sent + 1 else diag.err = "chat send: " .. tostring(err) end
end

local function trackKills(pc, t)
    local ok, kills, addr = pcall(function()
        local ps = pc.PlayerState
        return ps.playerRuntimeLeaderboardLocal[LB_KILLS], ps:GetAddress()
    end)
    if not ok or type(kills) ~= "number" then return end
    if addr ~= run.addr or kills < run.kills then -- new player state, or the game reset its counters
        run.addr, run.kills = addr, kills
        streak.n, streak.tier = 0, 0
        return
    end
    local gained = kills - run.kills
    run.kills = kills
    if streak.n > 0 and t - streak.lastT > STREAK_GAP_S then streak.n, streak.tier = 0, 0 end
    if gained <= 0 then return end
    streak.n, streak.lastT = streak.n + gained, t
    local tier = 0
    for i, T in ipairs(TIERS) do
        if streak.n >= T.kills then tier = i end
    end
    if tier > streak.tier then
        streak.tier = tier
        local name = try(function() return str(pc.PlayerState:GetPlayerName()) end) or "You"
        show(pc, tier, name, detail(streak.n))
        if TIERS[tier].team then broadcast(pc, tier, streak.n) end
    end
end

---------------------------------------------------------------------------
-- Everybody else's, read from the chat
---------------------------------------------------------------------------
-- Only the exact line this mod sends counts, e.g. "ULTRA KILL!  50 kills in a row".
local function tierOf(text)
    local name, rest = text:match("^(.-)!%s+(%d+ kills in a row)$")
    if not name then return nil end
    for i, T in ipairs(TIERS) do
        if T.team and T.text == name then return i, rest end
    end
    return nil
end

local function readChat(pc, t)
    local ok, err = pcall(function()
        local arr = UEHelpers.GetGameInstance().chatMessages
        local n = #arr
        local lastText = (n > 0) and str(arr[n][CHAT.text]) or nil
        if chat.count == nil then -- first look: nothing here is news
            chat.count, chat.last = n, lastText
            return
        end
        local from = chat.count + 1
        if n < chat.count or (n == chat.count and lastText ~= chat.last) then from = n end -- list was trimmed
        chat.count, chat.last = n, lastText
        local mine = pc.PlayerState:GetAddress()
        for i = math.max(1, from), n do
            local m = arr[i]
            local sender = try(function() return m[CHAT.ps]:GetAddress() end)
            if sender ~= mine then
                local tier, rest = tierOf(str(m[CHAT.text]))
                local who = str(m[CHAT.name])
                if tier and t - (heardAt[who] or -1e9) >= SENDER_GAP_S and show(pc, tier, who, rest) then
                    heardAt[who] = t
                    diag.heard = diag.heard + 1
                end
            end
        end
    end)
    if not ok then diag.err = "chat read: " .. tostring(err) end
end

---------------------------------------------------------------------------
-- Module interface
---------------------------------------------------------------------------
function M.init(c)
    ctx, FFWUi, log = c, c.FFWUi, c.log
    C = FFWUi.COLORS
end

-- Called often: only the fade of a showing announcement needs it.
function M.fastTick(pc, t)
    if showing or preview then
        if preview then
            preview = false
            show(pc, 3, "Sample", "this is what a streak looks like")
        end
        draw(pc, t)
    end
end

function M.tick(pc, t, inGame)
    if not ctx.option("announcer") then
        -- Kills and chat lines that go by while switched off are never announced later.
        if showing and showing.tier then showing = nil end
        streak.n, streak.tier, run.addr, chat.count = 0, 0, nil, nil
        draw(pc, t)
        return
    end
    if inGame then
        if not soundsLoaded then -- loaded up front, so the first call-out does not hitch
            soundsLoaded = true
            for i = 1, #TIERS do soundFor(i) end
        end
        trackKills(pc, t)
        readChat(pc, t)
    end
    draw(pc, t)
end

-- A sample announcement, for when the option is switched on (input thread safe).
function M.preview()
    preview = true
end

-- A plain two-line message in the call-out spot, no sound (game thread).
function M.notice(title, sub, seconds)
    showing = { title = title, sub = sub, t0 = FFWUi.now(), seconds = seconds }
end

function M.reset()
    chat.count, heardAt = nil, {}
end

function M.destroy()
    if panel then panel:destroy() end
    panel, ui = nil, nil
    if showing and showing.tier then showing = nil end
end

function M.dump()
    log(string.format("  kill streaks: on=%s kills=%s streak=%d tier=%d sent=%d heard=%d chat seen=%s last error=%s",
        tostring(ctx.option("announcer")), tostring(run.kills), streak.n, streak.tier, diag.sent, diag.heard,
        tostring(chat.count), tostring(diag.err)))
    for i = 1, #TIERS do
        log(string.format("    %-13s at %3d kills, %s, sound %s", TIERS[i].text, TIERS[i].kills,
            TIERS[i].team and "whole team" or "own screen", soundFor(i) and "ok" or "MISSING"))
    end
end

return M
