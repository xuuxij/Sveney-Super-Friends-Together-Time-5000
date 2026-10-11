# Checks GitHub for the newest pack and installs it. Windows PowerShell 5.1 compatible.
# Reads manifest.json next to this script for the current version and the repository.
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
$repo = $manifest.updates.repository
if (-not $repo) { $repo = 'xuuxij/Sveney-Super-Friends-Together-Time-5000' }   # packs before 1.5.0 have no updates entry
$current = [version]$manifest.version
Write-Host ''
$title = $manifest.name
if ($manifest.PSObject.Properties['title'] -and $manifest.title) { $title = $manifest.title }
Write-Host "  $title v$current installed from this folder; checking https://github.com/$repo ..." -ForegroundColor Yellow

try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'SveneySuperFriendsTogetherTime5000-updater' } -TimeoutSec 30
} catch {
    throw "Could not reach GitHub: $($_.Exception.Message)"
}
$tag = "$($release.tag_name)".TrimStart('v', 'V')
$latest = [version]$tag
# The pack zip: by our name first, else the zip that is there (the pack has been renamed once).
$asset = $release.assets | Where-Object { $_.name -like "$($manifest.name)-v*.zip" } | Select-Object -First 1
if (-not $asset) { $asset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1 }
if (-not $asset) { throw "The newest release ($($release.tag_name)) has no pack zip attached." }

if ($latest -le $current) {
    Write-Host "You already have the newest pack (v$current)." -ForegroundColor Green
    exit 0
}
Write-Host "Newer pack available: v$latest (you have v$current)."
if ($CheckOnly) { exit 2 }
if (Get-Process -Name 'FarFarWest-Win64-Shipping' -ErrorAction SilentlyContinue) {
    throw 'Far Far West is running. Close the game and run this again.'
}

$zipDir = Join-Path $env:TEMP "$($manifest.name)-update"
New-Item -ItemType Directory -Force -Path $zipDir | Out-Null
$zip = Join-Path $zipDir $asset.name
Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..."
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers @{ 'User-Agent' = 'SveneySuperFriendsTogetherTime5000-updater' } -TimeoutSec 300
# The new pack folder goes next to this one (the zip holds a single top-level folder).
$parent = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
try { $top = ($archive.Entries[0].FullName -split '/')[0] } finally { $archive.Dispose() }
$dest = Join-Path $parent $top
if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $parent)
Remove-Item -LiteralPath $zip -Force
$install = Get-ChildItem -LiteralPath $dest -Recurse -Filter 'Install.ps1' | Select-Object -First 1
if (-not $install) { throw 'The downloaded zip has no Install.ps1 in it.' }

Write-Host ''
Write-Host "Installing v$latest ..." -ForegroundColor Yellow
# A child PowerShell so the exit code is the installer's own.
& powershell -NoProfile -ExecutionPolicy Bypass -File $install.FullName
if ($LASTEXITCODE -ne 0) { throw 'The install reported a problem (see above).' }
Write-Host ''
Write-Host "Updated to v$latest. The new pack folder is $dest (next to this one); you can delete this old one." -ForegroundColor Green
Write-Host 'Everyone in the lobby needs the same version: tell the others to run Update.bat too.'
