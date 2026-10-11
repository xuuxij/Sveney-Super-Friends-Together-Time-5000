# Builds dist\FFWModpack-v<version>.zip from config\pack.json.
# Windows PowerShell 5.1 compatible. Does not touch the game folder.
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\FarFarWest'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$root = Split-Path -Parent $PSScriptRoot
$cfg = Get-Content -LiteralPath (Join-Path $root 'config\pack.json') -Raw | ConvertFrom-Json
$name = "$($cfg.name)-v$($cfg.version)"
$dist = Join-Path $root 'dist'
$stage = Join-Path $dist $name
$pack = Join-Path $stage 'pack'
$files = Join-Path $pack 'files'
$win64 = Join-Path $files 'FarFarWest\Binaries\Win64'
$ue = Join-Path $win64 'ue4ss'

function Copy-Tree([string]$From, [string]$To) {
    foreach ($f in Get-ChildItem -LiteralPath $From -Recurse -File) {
        $dst = Join-Path $To $f.FullName.Substring($From.Length).TrimStart('\')
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dst
    }
}

if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
New-Item -ItemType Directory -Force -Path $ue | Out-Null

# --- guard rails: never ship dev settings -------------------------------
foreach ($m in $cfg.luaMods) {
    foreach ($lua in Get-ChildItem -LiteralPath (Join-Path $root "src\Mods\$m\Scripts") -Filter *.lua -File) {
        if (Select-String -LiteralPath $lua.FullName -Pattern 'DEV_[A-Z_]+\s*=\s*true' -Quiet) { throw "$m\$($lua.Name) has a DEV_ switch turned on" }
    }
}
$ini = Join-Path $root 'config\ue4ss\UE4SS-settings.ini'
if (Select-String -LiteralPath $ini -Pattern '^\s*EnableAutoReloadingLuaMods\s*=\s*1' -Quiet) { throw 'Auto-reload is on in the shipped settings' }

# --- the game build the pack is locked to --------------------------------
$exe = Join-Path $GameRoot $cfg.game.exeRelativePath
if (Test-Path -LiteralPath $exe) {
    $h = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    if ($h -ne $cfg.game.exeSha256) { throw "Local game exe ($h) differs from config\pack.json; the game updated - re-verify before shipping." }
}

# --- UE4SS (official release, hash-checked) ------------------------------
$zip = Join-Path $root "vendor\ue4ss\$($cfg.ue4ss.asset)"
if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $cfg.ue4ss.sha256) { throw 'UE4SS zip hash mismatch' }
$tmp = Join-Path $dist '_ue4ss'
if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
[System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
Copy-Item -LiteralPath (Join-Path $tmp 'dwmapi.dll') -Destination $win64
Copy-Item -LiteralPath (Join-Path $tmp 'ue4ss\UE4SS.dll') -Destination $ue
Copy-Item -LiteralPath (Join-Path $tmp 'ue4ss\LICENSE') -Destination $ue
Copy-Tree (Join-Path $tmp 'ue4ss\Mods\shared') (Join-Path $ue 'Mods\shared')
Copy-Tree (Join-Path $tmp 'ue4ss\Mods\Keybinds') (Join-Path $ue 'Mods\Keybinds')
Remove-Item -LiteralPath $tmp -Recurse -Force

Copy-Item -LiteralPath $ini -Destination $ue
Copy-Tree (Join-Path $root 'config\ue4ss\UE4SS_Signatures') (Join-Path $ue 'UE4SS_Signatures')

# --- our mods ------------------------------------------------------------
Copy-Tree (Join-Path $root 'src\Mods\shared') (Join-Path $ue 'Mods\shared')
$lines = @()
foreach ($m in $cfg.luaMods) {
    Copy-Tree (Join-Path $root "src\Mods\$m\Scripts") (Join-Path $ue "Mods\$m\Scripts")
    $lines += "$m : 1"
}
$lines += '', '; Built-in keybinds, do not move up!', 'Keybinds : 1'
[IO.File]::WriteAllText((Join-Path $ue 'Mods\mods.txt'), (($lines -join "`r`n") + "`r`n"))

# --- our Blueprint-fix pak, built from the game's own files -------------
$pakOut = Join-Path $dist '_morepak'
& python -I (Join-Path $root 'tools\morepak\build_morepak.py') --game $GameRoot --out $pakOut
if ($LASTEXITCODE -ne 0) { throw 'pak build failed' }
Copy-Tree $pakOut $files

# --- third-party trees copied as-is from vendor (none at the moment) -----
foreach ($t in $cfg.vendorTrees) { Copy-Tree (Join-Path $root ($t -replace '/', '\')) $files }

# --- manifest + fingerprint ----------------------------------------------
$entries = @()
foreach ($f in Get-ChildItem -LiteralPath $files -Recurse -File | Sort-Object FullName) {
    $rel = $f.FullName.Substring($files.Length).TrimStart('\') -replace '\\', '/'
    $entries += [ordered]@{ path = $rel; sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash; size = $f.Length }
}
$fpSource = ($entries | ForEach-Object { "$($_.path) $($_.sha256)" }) -join "`n"
$sha = [System.Security.Cryptography.SHA256]::Create()
$fpBytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($fpSource))
$fingerprint = (($fpBytes | ForEach-Object { $_.ToString('X2') }) -join '').Substring(0, 12)

$manifest = [ordered]@{
    name = $cfg.name
    version = $cfg.version
    fingerprint = $fingerprint
    builtAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    game = $cfg.game
    ue4ss = $cfg.ue4ss
    updates = $cfg.updates
    files = $entries
}
[IO.File]::WriteAllText((Join-Path $pack 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5))

# --- installer + readme --------------------------------------------------
$inst = Join-Path $root 'installer'
foreach ($s in 'Common.ps1', 'Install.ps1', 'Uninstall.ps1', 'Update.ps1') { Copy-Item -LiteralPath (Join-Path $inst $s) -Destination $pack }
foreach ($b in 'Install.bat', 'Verify.bat', 'Uninstall.bat', 'Update.bat') { Copy-Item -LiteralPath (Join-Path $inst $b) -Destination $stage }
$readme = (Get-Content -LiteralPath (Join-Path $inst 'README.txt') -Raw).
    Replace('{VERSION}', $cfg.version).Replace('{FINGERPRINT}', $fingerprint).Replace('{GAME_VERSION}', $cfg.game.productVersion)
[IO.File]::WriteAllText((Join-Path $stage 'README.txt'), ($readme -replace "`r?`n", "`r`n"))

# --- zip with forward-slash entry names ----------------------------------
$zipOut = Join-Path $dist "$name.zip"
if (Test-Path -LiteralPath $zipOut) { Remove-Item -LiteralPath $zipOut -Force }
$archive = [System.IO.Compression.ZipFile]::Open($zipOut, 'Create')
try {
    foreach ($f in Get-ChildItem -LiteralPath $stage -Recurse -File) {
        $entry = "$name/" + ($f.FullName.Substring($stage.Length).TrimStart('\') -replace '\\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $f.FullName, $entry, 'Optimal') | Out-Null
    }
} finally { $archive.Dispose() }

Write-Host "Built $zipOut"
Write-Host "  $($entries.Count) game files, fingerprint $fingerprint"
