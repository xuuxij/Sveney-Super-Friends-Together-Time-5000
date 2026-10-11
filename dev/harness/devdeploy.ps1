# Dev only: copies the working-tree Lua mods into the installed game so they
# can be tried without building a pack.
#   devdeploy.ps1 backup        save the player's own files (settings, history, totals) once
#   devdeploy.ps1 deploy [-Dev] copy mods in; -Dev switches the Extras DEV_ flags on in the game copy
#   devdeploy.ps1 restore       put the player's own files back, drop dev-run leftovers
param([Parameter(Position = 0)][string]$Cmd, [switch]$Dev)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$mods = 'C:\Program Files (x86)\Steam\steamapps\common\FarFarWest\FarFarWest\Binaries\Win64\ue4ss\Mods'
$bak = Join-Path $PSScriptRoot 'backup'
$userFiles = 'DamageMeter\settings.txt', 'DamageMeter\history.csv', 'DamageMeter\totals.txt', 'StatsPanel\settings.txt'

switch ($Cmd) {
    'backup' {
        if (Test-Path $bak) { 'backup already exists, left alone'; break }
        New-Item -ItemType Directory -Force $bak | Out-Null
        foreach ($f in $userFiles) {
            $src = Join-Path $mods $f
            if (Test-Path -LiteralPath $src) {
                $dst = Join-Path $bak $f
                New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
                Copy-Item -LiteralPath $src -Destination $dst
                "saved $f"
            } else { "absent $f" }
        }
        Copy-Item -LiteralPath (Join-Path $mods 'mods.txt') -Destination (Join-Path $bak 'mods.txt')
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
        foreach ($f in $userFiles) {
            $src = Join-Path $bak $f; $dst = Join-Path $mods $f
            if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination $dst -Force; "restored $f" }
            elseif (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Force; "removed dev-run $f" }
        }
        Get-ChildItem (Join-Path $mods 'Extras') -Filter 'settings-*.txt' -ErrorAction SilentlyContinue | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force; "removed dev-run Extras\$($_.Name)" }
    }
    default { throw "unknown command '$Cmd'" }
}
