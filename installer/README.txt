{TITLE}  v{VERSION}   (fingerprint {FINGERPRINT})
A Far Far West modpack, made for Far Far West {GAME_VERSION}

WHAT'S IN IT
  - Damage meter: live DPS, total damage, kills, best second, all-time kills
    and damage, and a 30-second graph on the left of your HUD.
    F7 = show/hide, F8 = reset this map's numbers, Ctrl+F7 = write the
    numbers to the log. Kills and all-time totals use the game's own
    scoreboard counts; all-time totals are kept in totals.txt.
  - Stats panel: your stats as base -> now, your weapon's stats and what each
    Joker adds. F6 = show/hide.
  - More Players: lobbies of up to 8 instead of 4, made by this pack.
    The host's game lets a 5th..8th player in, the objectives that break
    past 4 players (TNT launcher, totem, pillars, shredder, laser cannon,
    drill, sigil, gold magnet...) use their 4-player settings, players 5..8
    get their own name colours, and past 4 players the enemies keep scaling
    the way the game scales them from 1 to 4: health keeps climbing on the
    same line, enemies come a little faster per extra player, loot drops stay
    at the 4-player rate. Settings are in ue4ss\Mods\MorePlayers\settings.txt
    (only the host's copy matters for the lobby and the enemies).
    The MORE PLAYERS panel on the right of your HUD shows the lobby size and
    what is being scaled right now. Gold numbers mean it is scaling; with up
    to 4 players everything stays x1.00.
  - Speedometer: your speed as a dial and a number, with your top speed.
  - Auto dash: keep the dash button held and you dash again every time you
    land. You have to be moving, and the dash keeps its normal cooldown.
  - Muzzle flash: can be switched off, so your own gun's flash stops
    blocking your aim. Only changes your own screen.
  - Kill streaks: MULTI KILL at 10 kills in a row (your screen only), then
    MEGA KILL at 25, ULTRA KILL at 50, MONSTER KILL at 100 and GODLIKE at
    200 are called out to the whole team: big text, a sound and a line in
    chat. More than 4 seconds without a kill ends a streak.
  - F9 = edit mode: frees the mouse so you can
      * switch the speedometer, the More Players panel, auto dash, muzzle
        flash and kill streaks on or off in the OPTIONS list
      * click a panel to move it, click again to put it down
      * click its bottom-right corner to resize it, click again when done
      * click the boxes next to stats to show or hide them (a few extra
        stats start switched off: recoil, stability, kill combo, spell
        cooldown, XP multiplier)
      * right-click a panel to hide/show it, middle-click to put it back
        where and how big it started
    F9 again when done. Your character can't act in edit mode, so do it in
    the saloon. Your layout and switches are remembered and are your own
    choice: they do not affect the pack check below.
  - UE4SS v3.0.1-1109 (the script loader the mods run on) and one small
    game-file patch pak ({PAK}) with the objective fixes.

INSTALL
  1. Close Far Far West.
  2. Extract this zip anywhere (Desktop is fine).
  3. Double-click Install.bat. It finds the game through Steam.
     If Windows shows "Windows protected your PC", click More info -> Run anyway.
  Anything it replaces, plus any other mods you had, gets moved to
  FarFarWest\{NAME}-backup\ so everyone runs exactly the same files.

CHECK YOU MATCH EVERYONE ELSE
  Double-click Verify.bat. It must say OK and show the same fingerprint
  as the host's: {FINGERPRINT}

UPDATE
  Double-click Update.bat. It looks at github.com/{REPO} for a newer pack,
  downloads it and installs it, then you run Verify.bat as above. Everyone in
  the lobby has to be on the same version, so say when you update.

UNINSTALL
  Double-click Uninstall.bat. It removes the pack and puts back whatever the
  install moved aside.

PLAYING
  The host ticks "Allow mods" when creating the room.
  After a game update, wait for a new pack before playing modded.
