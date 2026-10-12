# Dev only: copies the working-tree Lua mods into the installed game so they
# can be tried without building a pack.
#   devdeploy.ps1 backup        save the player's own files (settings, history, totals) in backup\<time>
#   devdeploy.ps1 deploy [-Dev] copy mods in; -Dev switches the Extras DEV_ flags on in the game copy
#   devdeploy.ps1 restore       put the player's own files back from that backup, drop dev-run leftovers
# One backup folder per dev cycle: restore closes it, so the next cycle saves the files afresh. The player
# plays between cycles, so a backup older than MAX_AGE_H hours is never put back.
param([Parameter(Position = 0)][string]$Cmd, [switch]$Dev)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$mods = 'C:\Program Files (x86)\Steam\steamapps\common\FarFarWest\FarFarWest\Binaries\Win64\ue4ss\Mods'
$bak = Join-Path $PSScriptRoot 'backup'
$userFiles = 'DamageMeter\settings.txt', 'DamageMeter\history.csv', 'DamageMeter\totals.txt', 'StatsPanel\settings.txt',
    'Extras\settings-options.txt', 'Extras\settings-moreplayers.txt', 'Extras\settings-speedometer.txt', 'MorePlayers\settings.txt'
$MAX_AGE_H = 12

# Backups of this cycle: backup\<yyyyMMdd-HHmmss> without a restored.txt, oldest first.
function Get-OpenBackups {
    @(Get-ChildItem -LiteralPath $bak -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d{8}-\d{6}$' -and -not (Test-Path -LiteralPath (Join-Path $_.FullName 'restored.txt')) } | Sort-Object Name)
}
function Get-BackupAgeHours($Dir) { ((Get-Date) - [datetime]::ParseExact($Dir.Name, 'yyyyMMdd-HHmmss', $null)).TotalHours }

switch ($Cmd) {
    'backup' {
        $fresh = $false
        foreach ($o in Get-OpenBackups) {
            if ((Get-BackupAgeHours $o) -le $MAX_AGE_H) { $fresh = $true; "backup $($o.Name) is open (this cycle's), left alone" }
            else { [IO.File]::WriteAllText((Join-Path $o.FullName 'restored.txt'), 'abandoned: too old to put back'); "backup $($o.Name) is too old to put back, closed" }
        }
        if ($fresh) { break }
        $dir = Join-Path $bak (Get-Date -Format 'yyyyMMdd-HHmmss')
        New-Item -ItemType Directory -Force $dir | Out-Null
        foreach ($f in $userFiles) {
            $src = Join-Path $mods $f
            if (Test-Path -LiteralPath $src) {
                $dst = Join-Path $dir $f
                New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
                Copy-Item -LiteralPath $src -Destination $dst
                "saved $f"
            } else { "absent $f" }
        }
        Copy-Item -LiteralPath (Join-Path $mods 'mods.txt') -Destination (Join-Path $dir 'mods.txt')
    }
    'deploy' {
        foreach ($m in 'shared\FFWUi', 'DamageMeter\Scripts', 'StatsPanel\Scripts', 'Extras\Scripts', 'MorePlayers\Scripts') {
            $to = Join-Path $mods $m
            New-Item -ItemType Directory -Force $to | Out-Null
            Copy-Item -Path (Join-Path $repo "src\Mods\$m\*.lua") -Destination $to -Force
        }
        $txt = Join-Path $mods 'mods.txt'
        $lines = Get-Content -LiteralPath $txt
        foreach ($pair in @(@('StatsPanel', 'Extras'), @('Extras', 'MorePlayers'))) {
            $after, $name = $pair
            if (-not ($lines -match "^$name\s*:")) {
                $out = @(); $done = $false
                foreach ($l in $lines) {
                    if (-not $done -and $l -match "^$after\s*:") { $out += $l; $out += "$name : 1"; $done = $true } else { $out += $l }
                }
                $lines = $out
                [IO.File]::WriteAllText($txt, (($out -join "`r`n") + "`r`n"))
            }
        }
        if ($Dev) {
            $main = Join-Path $mods 'Extras\Scripts\main.lua'
            $s = [IO.File]::ReadAllText($main)
            $s = $s -replace 'DEV_SHOW = false', 'DEV_SHOW = true' -replace 'DEV_LOG = false', 'DEV_LOG = true' -replace 'DEV_EDIT = false', 'DEV_EDIT = true'
            [IO.File]::WriteAllText($main, $s)
        }
        "deployed (dev flags: $([bool]$Dev))"
    }
    'restore' {
        $open = Get-OpenBackups
        if ($open.Count -eq 0) { throw 'no open backup: "devdeploy.ps1 backup" comes before a dev run' }
        $dir = $open[0]
        if ((Get-BackupAgeHours $dir) -gt $MAX_AGE_H) { throw "backup $($dir.Name) is too old to put back: the player's files have moved on" }
        foreach ($f in $userFiles) {
            $src = Join-Path $dir.FullName $f; $dst = Join-Path $mods $f
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dst -Force; "restored $f" }
            elseif (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force; "removed dev-run $f" }
        }
        foreach ($o in $open) { [IO.File]::WriteAllText((Join-Path $o.FullName 'restored.txt'), (Get-Date -Format o)) }
    }
    default { throw "unknown command '$Cmd'" }
}
