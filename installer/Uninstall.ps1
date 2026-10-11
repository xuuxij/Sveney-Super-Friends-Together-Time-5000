param(
    [string]$GameRoot
)
. (Join-Path $PSScriptRoot 'Common.ps1')

Write-PackHeader
$GameRoot = Resolve-GameRoot $GameRoot
Write-Host "Game folder: $GameRoot"
Assert-GameClosed

$recordPath = Get-InstallRecordPath $GameRoot
if (-not $recordPath) {
    Write-Host 'The modpack is not installed in this folder (no install record found).'
    exit 0
}
$record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json

foreach ($p in $record.files) {
    $full = Join-Path $GameRoot ($p -replace '/', '\')
    if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Force }
}

# Drop folders the pack created if they are now empty (logs keep ue4ss around).
$dirs = $record.files | ForEach-Object { Split-Path -Parent (Join-Path $GameRoot ($_ -replace '/', '\')) } |
    Select-Object -Unique | Sort-Object -Property Length -Descending
foreach ($d in $dirs) {
    while ($d -and $d.Length -gt $GameRoot.Length -and (Test-Path -LiteralPath $d) -and
           -not (Get-ChildItem -LiteralPath $d -Force | Select-Object -First 1)) {
        Remove-Item -LiteralPath $d -Force
        $d = Split-Path -Parent $d
    }
}

foreach ($b in @(Get-RecordBackups $record)) {
    $backup = Join-Path $GameRoot $b
    if (Test-Path -LiteralPath $backup) {
        Write-Host 'Restoring what the install moved aside:'
        foreach ($f in Get-ChildItem -LiteralPath $backup -Recurse -File) {
            $rel = Get-RelativePath $backup $f.FullName
            $dst = Join-Path $GameRoot $rel
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
            Move-Item -LiteralPath $f.FullName -Destination $dst -Force
            Write-Host "  restored: $rel"
        }
        Remove-Item -LiteralPath $backup -Recurse -Force
        $parent = Split-Path -Parent $backup
        if (-not (Get-ChildItem -LiteralPath $parent -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $parent -Force }
    }
}

Remove-Item -LiteralPath $recordPath -Force
Write-Host 'Modpack removed. The game is back to how it was before the install.' -ForegroundColor Green
