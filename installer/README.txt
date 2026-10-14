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
  - Clear zone: objective markers, pings, world icons, name tags and other
    labels fade to a faint ghost inside a circle around your crosshair, so
    they stop covering what you are aiming at. The circle reaches 300
    pixels from the crosshair to start with; drag its slider in OPTIONS to
    change that (a dotted ring shows the size while you do). Enemy health
    bars and damage numbers stay as they are. Only changes your own screen.
  - Teammate arrows: a teammate who is off your screen and more than 50 m
    away gets an arrow at the edge of the screen, in their colour, pointing
    the way to turn, with the distance under it. A circle of dots fills in
    around the arrow, one dot for every 10 m past those 50 m (a full circle
    is 200 m past). From half full the arrow blinks and beats like a heart,
    faster and harder the further away they are, up to 1000 m. In OPTIONS:
    the distance on a slider, arrows for every teammate or only the closest
    one, and the distance text on or off. Only changes your own screen.
  - Teammate hits: the game lets you hurt your friends (half damage) and
    shows you the same hit marker as for an enemy. Now a teammate your shot
    lands on flashes brightly, your hit marker changes colour and a short
    error buzz plays (at most twice a second). You pick the colour, blue to
    start with; the glow, the marker and the sound each have their own
    switch. Only you see and hear it.
  - Minigun spin sound: a volume slider and a mute box for the barrel whine
    of every minigun you hear, yours and your team's. Only changes your own
    sound; the gunfire itself stays as it is.
  - F9 = edit mode: frees the mouse so you can
      * switch the speedometer, the More Players panel, auto dash, muzzle
        flash, kill streaks and the teammate hit glow, marker and sound on
        or off in the OPTIONS list
      * click a colour there for the teammate hit glow and marker
      * drag the Clear zone slider for the size of the circle, or untick
        its box to leave the markers alone
      * drag the Teammate arrows slider for the distance (a sample arrow on
        the left shows every distance while you do), untick it to switch
        the arrows off, and choose every teammate or only the closest one
      * drag the Minigun spin sound slider there to set its volume (you
        hear a short sample), or untick its box to mute it
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
