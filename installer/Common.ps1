# Shared helpers for Install.ps1 / Uninstall.ps1. Windows PowerShell 5.1 compatible.

$ErrorActionPreference = 'Stop'
$PackDir = $PSScriptRoot
$Manifest = Get-Content -LiteralPath (Join-Path $PackDir 'manifest.json') -Raw | ConvertFrom-Json
$RecordName = "$($Manifest.name)-installed.json"
$LegacyRecordNames = @('FFWModpack-installed.json')   # the pack's name up to 1.5.0
$ShippingProcess = 'FarFarWest-Win64-Shipping'

function Find-GameRoot {
    $libs = @()
    foreach ($key in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $p = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($v in @($p.SteamPath, $p.InstallPath)) {
                if ($v) { $libs += ($v -replace '/', '\') }
            }
        } catch {}
    }
    foreach ($steam in @($libs)) {
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($line in Get-Content -LiteralPath $vdf) {
                if ($line -match '"path"\s+"(.+)"') { $libs += ($Matches[1] -replace '\\\\', '\') }
            }
        }
    }
    foreach ($lib in ($libs | Select-Object -Unique)) {
        $g = Join-Path $lib 'steamapps\common\FarFarWest'
        if (Test-Path -LiteralPath (Join-Path $g $Manifest.game.exeRelativePath)) { return $g }
    }
    return $null
}

function Resolve-GameRoot([string]$GameRoot) {
    if (-not $GameRoot) { $GameRoot = Find-GameRoot }
    if (-not $GameRoot) {
        $GameRoot = Read-Host 'Could not find Far Far West. Paste the game folder (the one that contains FarFarWest.exe)'
    }
    $GameRoot = $GameRoot.Trim().Trim('"').TrimEnd('\')
    if (-not (Test-Path -LiteralPath (Join-Path $GameRoot $Manifest.game.exeRelativePath))) {
        throw "Not a Far Far West folder: $GameRoot"
    }
    return $GameRoot
}

function Assert-GameClosed {
    if (Get-Process -Name $ShippingProcess -ErrorAction SilentlyContinue) {
        throw 'Far Far West is running. Close the game and run this again.'
    }
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-RelativePath([string]$Root, [string]$Full) {
    return $Full.Substring($Root.Length).TrimStart('\')
}

# Files that make a setup differ from the pack: anything modded that the pack
# does not ship. Logs and per-player data (history.csv) are ignored.
function Get-ExtraModFiles([string]$GameRoot) {
    $packPaths = @{}
    foreach ($f in $Manifest.files) { $packPaths[($f.path -replace '/', '\').ToLowerInvariant()] = $true }

    $vanilla = @{}
    $nonUfs = Join-Path $GameRoot 'Manifest_NonUFSFiles_Win64.txt'
    if (Test-Path -LiteralPath $nonUfs) {
        foreach ($line in Get-Content -LiteralPath $nonUfs) {
            $rel = ($line -split "`t")[0]
            if ($rel) { $vanilla[($rel -replace '/', '\').ToLowerInvariant()] = $true }
        }
    }

    $extras = @()
    $win64 = Join-Path $GameRoot 'FarFarWest\Binaries\Win64'
    foreach ($f in Get-ChildItem -LiteralPath $win64 -File -ErrorAction SilentlyContinue) {
        $rel = (Get-RelativePath $GameRoot $f.FullName).ToLowerInvariant()
        if ($f.Extension -in '.log', '.dmp') { continue }
        if ($vanilla.ContainsKey($rel) -or $packPaths.ContainsKey($rel)) { continue }
        $extras += $f.FullName
    }

    $packMods = @{}
    foreach ($f in $Manifest.files) {
        if ($f.path -match '^FarFarWest/Binaries/Win64/ue4ss/Mods/([^/]+)/') { $packMods[$Matches[1].ToLowerInvariant()] = $true }
    }
    $modsDir = Join-Path $win64 'ue4ss\Mods'
    foreach ($d in Get-ChildItem -LiteralPath $modsDir -Directory -ErrorAction SilentlyContinue) {
        if (-not $packMods.ContainsKey($d.Name.ToLowerInvariant())) { $extras += $d.FullName }
    }
    foreach ($sub in 'ue4ss\UE4SS_Signatures', 'ue4ss\Mods') {
        foreach ($f in Get-ChildItem -LiteralPath (Join-Path $win64 $sub) -File -ErrorAction SilentlyContinue) {
            $rel = (Get-RelativePath $GameRoot $f.FullName).ToLowerInvariant()
            if (-not $packPaths.ContainsKey($rel)) { $extras += $f.FullName }
        }
    }

    $paks = Join-Path $GameRoot 'FarFarWest\Content\Paks\~mods'
    foreach ($f in Get-ChildItem -LiteralPath $paks -File -Recurse -ErrorAction SilentlyContinue) {
        $rel = (Get-RelativePath $GameRoot $f.FullName).ToLowerInvariant()
        if (-not $packPaths.ContainsKey($rel)) { $extras += $f.FullName }
    }
    return $extras
}

# Returns a list of problems; empty means the game folder matches the pack exactly.
function Test-PackInstall([string]$GameRoot) {
    $problems = @()
    foreach ($f in $Manifest.files) {
        $dst = Join-Path $GameRoot ($f.path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $dst)) { $problems += "missing   $($f.path)"; continue }
        if ((Get-Sha256 $dst) -ne $f.sha256) { $problems += "different $($f.path)" }
    }
    foreach ($x in Get-ExtraModFiles $GameRoot) {
        $problems += "extra     $(Get-RelativePath $GameRoot $x)"
    }
    return $problems
}

# Previous install (any pack version): its files are ours to replace, and its
# backups must survive upgrades so Uninstall can still restore the original mods.
function Get-InstallRecordPath([string]$GameRoot) {
    foreach ($n in @($RecordName) + $LegacyRecordNames) {
        $path = Join-Path $GameRoot $n
        if (Test-Path -LiteralPath $path) { return $path }
    }
    return $null
}

function Get-InstallRecord([string]$GameRoot) {
    $path = Get-InstallRecordPath $GameRoot
    if (-not $path) { return $null }
    try { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-RecordBackups($Record) {
    $list = @()
    if ($Record) {
        if ($Record.PSObject.Properties['backups']) { $list += @($Record.backups | Where-Object { $_ }) }
        if ($Record.PSObject.Properties['backup'] -and $Record.backup) { $list += $Record.backup }
    }
    return $list
}

function Get-PackTitle {
    if ($Manifest.PSObject.Properties['title'] -and $Manifest.title) { return $Manifest.title }
    return $Manifest.name
}

function Write-PackHeader {
    Write-Host ''
    Write-Host "  $(Get-PackTitle) v$($Manifest.version)   fingerprint $($Manifest.fingerprint)" -ForegroundColor Yellow
    Write-Host "  made for Far Far West $($Manifest.game.productVersion)"
    Write-Host ''
}
