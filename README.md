# Sveney Super Friends Together Time 5000

Far Far West mods built in-house, plus one installer bundle so every player runs identical files.
The pack was called FFWModpack up to 1.5.0; the installer upgrades that install in place.

## Download and install

Newest pack: https://github.com/xuuxij/Sveney-Super-Friends-Together-Time-5000/releases/latest (the `SveneySuperFriendsTogetherTime5000-v*.zip` file under Assets).

1. Close Far Far West.
2. Extract the zip anywhere (Desktop is fine).
3. Double-click `Install.bat`. It finds the game through Steam. If Windows shows "Windows protected your PC", click More info, then Run anyway.
4. Double-click `Verify.bat`. It must say OK and show the same fingerprint as everyone else in the lobby.

Later: `Update.bat` checks this page for a newer pack and installs it. `Uninstall.bat` removes the pack and puts back whatever the install moved aside.
The host ticks "Allow mods" when creating the room. Made for Far Far West 0.2.0.20 - CL 915; after a game update, wait for a new pack.

## What is in the repo

- `src/Mods/DamageMeter` – DPS / total / peak / 30 s graph (F7 toggle, F8 reset)
- `src/Mods/StatsPanel` – base vs current stats, weapon stats, active Jokers (F6, Ctrl+F6 dumps raw values to UE4SS.log)
- `src/Mods/Extras` – More Players panel (reads the MorePlayers mod's shared variables), speedometer, auto dash, muzzle flash switch, kill-streak call-outs, and the OPTIONS list in F9 edit mode (Ctrl+F5 dumps every part's state to UE4SS.log); one file per part
- `src/Mods/MorePlayers` – lobbies of up to 8: lobby cap on the host, player-count scaling continued past 4 (one hook on `F_GetCurveByNumberOfPlayers`), gold magnet table fix, name colours for players 5..8, status for the panel; `settings.txt` next to Scripts
- `tools/morepak/` – builds `ZZZ_SveneySuperFriendsTogetherTime5000_P` (13 vanilla Blueprints with 16 byte patches: player-count Selects fall back to the 4-player value, 8 lobby rows) from the installed game with retoc; `patches.json` is the spec, `kismet.py` the bytecode disassembler used to derive and re-derive it
- `src/Mods/shared/FFWUi` – shared UMG-in-code helpers
- `config/` – pack definition (name, title, version, game build lock, UE4SS asset + hash, pak name, update repository), UE4SS settings, AOB signatures
- `installer/` – Install/Verify/Update/Uninstall scripts shipped inside the zip
- `tools/Build-Pack.ps1` – builds `dist/SveneySuperFriendsTogetherTime5000-v<version>.zip`
- `tools/list_utoc.py` – lists asset paths from the game's IoStore index
- `dev/FFWProbe` – discovery mod, never shipped

`vendor/` is not tracked: `vendor/ue4ss/<asset from config/pack.json>` (official UE4SS-RE release,
hash-checked by the build) and `vendor/retoc/<retocAsset from config/pack.json>` (trumank/retoc release zip, hash-checked).
The pak is built from the game's own files on every pack build; nothing third-party ships in the pack any more.

After a game patch: check the exe hash in `config/pack.json`, re-test the signatures and hooks, re-derive
`tools/morepak/patches.json` (the build stops on any vanilla hash or byte mismatch; `kismet.py <json> <uexp> --at 0x..`
shows the bytecode around an offset), bump the version, rebuild.
