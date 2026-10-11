# Dev only: (re)starts the game with the working-tree mods and captures the window at given times.
# With -Probe the game hosts a private LAN session by itself (and, unless -NoMission, starts the first
# suggested mission), then runs any Lua written to cmd.lua in this folder: a live console into the game
# that needs no keyboard, so it works while the PC is locked. wshot.ps1 captures the window, waitlog.ps1
# waits for a log line. A mission that is left to end (win or defeat) is saved to the player's profile:
# close the game before that. Run devdeploy.ps1 backup first and restore afterwards.
#   devrun.ps1 -Flags DEV_SHOW,DEV_LOG [-Probe] -Shots 72,103 [-Tag a]
# Shot times are seconds after the Extras mod loads; files are <Tag>_<seconds>.png in this folder.
param([string[]]$Flags = @(), [switch]$Probe, [switch]$NoMission, [int[]]$Shots = @(), [string]$Tag = 'run', [int]$Tail = 0)
$ErrorActionPreference = 'Stop'
$sp = $PSScriptRoot
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$win64 = 'C:\Program Files (x86)\Steam\steamapps\common\FarFarWest\FarFarWest\Binaries\Win64'
$mods = Join-Path $win64 'ue4ss\Mods'
$ueLog = Join-Path $win64 'ue4ss\UE4SS.log'

Get-Process -Name 'FarFarWest-Win64-Shipping' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 3

& "$sp\devdeploy.ps1" deploy | Out-Null
$main = Join-Path $mods 'Extras\Scripts\main.lua'
$s = [IO.File]::ReadAllText($main)
foreach ($f in $Flags) { $s = $s -replace "$f = false", "$f = true" }
if ($Probe) { $s += $(if ($NoMission) { "`nPROBE_MISSION = false`n" } else { '' }) + [IO.File]::ReadAllText((Join-Path $sp 'probe.lua')).Replace('@CMD@', (Join-Path $sp 'cmd.lua')) }
[IO.File]::WriteAllText($main, $s)

if (Test-Path $ueLog) { Remove-Item -LiteralPath $ueLog -Force -ErrorAction SilentlyContinue }
Start-Process 'steam://rungameid/3124540'
$deadline = (Get-Date).AddSeconds(120)
$loaded = $null
while ((Get-Date) -lt $deadline -and -not $loaded) {
    Start-Sleep -Seconds 2
    if (Test-Path $ueLog) {
        $m = Select-String -Path $ueLog -Pattern '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)[^\]]*\] \[Lua\] \[Extras\] v' | Select-Object -First 1
        if ($m) { $loaded = [datetime]::ParseExact($m.Matches[0].Groups[1].Value, 'yyyy-MM-dd HH:mm:ss', $null) }
    }
}
if (-not $loaded) { throw 'Extras did not load' }
"Extras loaded at $($loaded.ToString('HH:mm:ss'))"
foreach ($t in ($Shots | Sort-Object)) {
    $wait = ($loaded.AddSeconds($t) - (Get-Date)).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
    try { & "$sp\wshot.ps1" (Join-Path $sp "${Tag}_$t.png") -MaxWidth 1920 } catch { "shot $t failed: $_" }
}
if ($Tail -gt 0) {
    $wait = ($loaded.AddSeconds($Tail) - (Get-Date)).TotalSeconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]($wait * 1000)) }
}
'--- mod log ---'
Select-String -Path $ueLog -Pattern '\[Lua\] \[(Extras|FFWUi|DamageMeter|StatsPanel)\]|\[Lua\].*(error|Error)' | ForEach-Object { $_.Line -replace '^\[\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d)[^\]]*\] \[Lua\] ', '$1 ' }
