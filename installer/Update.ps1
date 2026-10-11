# Checks GitHub for the newest pack and installs it. Windows PowerShell 5.1 compatible.
# Reads manifest.json next to this script for the current version and the repository.
param([switch]$CheckOnly)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'manifest.json') -Raw | ConvertFrom-Json
$repo = $manifest.updates.repository
$current = [version]$manifest.version
Write-Host ''
Write-Host "  $($manifest.name) v$current installed from this folder; checking https://github.com/$repo ..." -ForegroundColor Yellow

try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'FFWModpack-updater' } -TimeoutSec 30
} catch {
    throw "Could not reach GitHub: $($_.Exception.Message)"
}
$tag = "$($release.tag_name)".TrimStart('v', 'V')
$latest = [version]$tag
$asset = $release.assets | Where-Object { $_.name -like "$($manifest.name)-v*.zip" } | Select-Object -First 1
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

$work = Join-Path $env:TEMP "FFWModpack-update\$tag"
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Force -Path $work | Out-Null
$zip = Join-Path $work $asset.name
Write-Host "Downloading $($asset.name) ($([math]::Round($asset.size / 1MB, 1)) MB)..."
Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -Headers @{ 'User-Agent' = 'FFWModpack-updater' } -TimeoutSec 300
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $work)
$install = Get-ChildItem -LiteralPath $work -Recurse -Filter 'Install.ps1' | Select-Object -First 1
if (-not $install) { throw 'The downloaded zip has no Install.ps1 in it.' }

Write-Host ''
Write-Host "Installing v$latest ..." -ForegroundColor Yellow
& $install.FullName
if ($LASTEXITCODE -ne 0) { throw 'The install reported a problem (see above).' }
Write-Host ''
Write-Host "Updated to v$latest. The new pack folder is $($install.Directory.Parent.FullName); you can delete this old one." -ForegroundColor Green
Write-Host 'Everyone in the lobby needs the same version: tell the others to run Update.bat too.'
