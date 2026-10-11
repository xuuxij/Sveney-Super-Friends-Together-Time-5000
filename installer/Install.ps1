param(
    [string]$GameRoot,
    [switch]$Verify,
    [switch]$Force
)
. (Join-Path $PSScriptRoot 'Common.ps1')

Write-PackHeader
$GameRoot = Resolve-GameRoot $GameRoot
Write-Host "Game folder: $GameRoot"

if ($Verify) {
    $problems = Test-PackInstall $GameRoot
    if ($problems.Count -eq 0) {
        Write-Host "OK - your mods match the pack exactly (fingerprint $($Manifest.fingerprint))." -ForegroundColor Green
        exit 0
    }
    Write-Host 'Your mods do NOT match the pack:' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  $_" }
    Write-Host 'Run Install.bat to fix.'
    exit 1
}

Assert-GameClosed

$exe = Join-Path $GameRoot $Manifest.game.exeRelativePath
if ((Get-Sha256 $exe) -ne $Manifest.game.exeSha256) {
    Write-Warning "Your game build is different from the one this pack was made for ($($Manifest.game.productVersion))."
    Write-Warning 'Let Steam finish updating. If it still differs, the pack needs updating for the new game version.'
    if (-not $Force) {
        $answer = Read-Host 'Install anyway? (y/N)'
        if ($answer -ne 'y') { exit 1 }
    }
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $GameRoot "FFWModpack-backup\$stamp"
$moved = 0

$previous = Get-InstallRecord $GameRoot
$previousFiles = @{}
if ($previous) {
    foreach ($p in $previous.files) { $previousFiles[($p -replace '/', '\').ToLowerInvariant()] = $true }
    Write-Host "Upgrading from $($previous.pack) v$($previous.version)"
}

# True when every file at/under this path came from an earlier pack install.
function Test-OwnedByPack([string]$Full) {
    $rel = (Get-RelativePath $GameRoot $Full).ToLowerInvariant()
    if ($previousFiles.ContainsKey($rel)) { return $true }
    if (Test-Path -LiteralPath $Full -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $Full -Recurse -File)
        if ($files.Count -eq 0) { return $false }
        foreach ($f in $files) {
            if (-not $previousFiles.ContainsKey((Get-RelativePath $GameRoot $f.FullName).ToLowerInvariant())) { return $false }
        }
        return $true
    }
    return $false
}

function Move-ToBackup([string]$Full) {
    $rel = Get-RelativePath $GameRoot $Full
    $dst = Join-Path $backup $rel
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Move-Item -LiteralPath $Full -Destination $dst -Force
    $script:moved++
    Write-Host "  moved aside: $rel"
}

# Other mods would make this setup differ from everyone else's, so they are
# moved into the backup folder (not deleted). Uninstall.bat puts them back.
$extras = @(Get-ExtraModFiles $GameRoot)
$foreign = @()
foreach ($x in $extras) {
    if (Test-OwnedByPack $x) {
        Remove-Item -LiteralPath $x -Recurse -Force
        Write-Host "  removed old pack file: $(Get-RelativePath $GameRoot $x)"
    } else {
        $foreign += $x
    }
}
if ($foreign.Count -gt 0) {
    Write-Host 'Other mods found; moving them to the backup folder so everyone has the same setup:'
    foreach ($x in $foreign) { Move-ToBackup $x }
}

$installed = @()
foreach ($f in $Manifest.files) {
    $rel = $f.path -replace '/', '\'
    $dst = Join-Path $GameRoot $rel
    if (Test-Path -LiteralPath $dst) {
        if ((Get-Sha256 $dst) -eq $f.sha256) { $installed += $f.path; continue }
        if (-not $previousFiles.ContainsKey($rel.ToLowerInvariant())) { Move-ToBackup $dst }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath (Join-Path $PackDir "files\$rel") -Destination $dst -Force
    if ((Get-Sha256 $dst) -ne $f.sha256) { throw "Copy check failed for $rel" }
    $installed += $f.path
}

$backups = @(Get-RecordBackups $previous)
if ($moved -gt 0) { $backups += "FFWModpack-backup\$stamp" }

$record = [ordered]@{
    pack = $Manifest.name
    version = $Manifest.version
    fingerprint = $Manifest.fingerprint
    installedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    backups = $backups
    files = $installed
}
$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $GameRoot $RecordName) -Encoding UTF8

$problems = Test-PackInstall $GameRoot
if ($problems.Count -ne 0) {
    Write-Host 'Installed, but the check found differences:' -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host ''
Write-Host "Installed $($installed.Count) files. Your setup matches the pack (fingerprint $($Manifest.fingerprint))." -ForegroundColor Green
if ($moved -gt 0) { Write-Host "Replaced files were saved in $backup" }
Write-Host 'In game: F6 = stats panel, F7 = damage meter on/off, F8 = reset damage meter, F9 = edit the panels (move, resize, pick stats) and switch the extras on or off.'
Write-Host 'When hosting, tick "Allow mods" when you create the room.'
