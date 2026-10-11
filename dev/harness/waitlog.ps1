# Dev only: waits until a line matching -Until shows up in UE4SS.log after the newest line matching -After,
# then prints our mod's lines from -After on (per-frame trace noise left out).
param([string]$After, [string]$Until, [int]$TimeoutS = 60, [int]$Max = 60, [string]$Skip = 'TRACE (F_|Inp|On)')
$ueLog = 'C:\Program Files (x86)\Steam\steamapps\common\FarFarWest\FarFarWest\Binaries\Win64\ue4ss\UE4SS.log'
$deadline = (Get-Date).AddSeconds($TimeoutS)
do {
    $l = @(Select-String -Path $ueLog -Pattern '\[Lua\] \[(Extras|FFWUi|DamageMeter|StatsPanel)\]' | ForEach-Object { $_.Line -replace '^\[\d{4}-\d\d-\d\d (\d\d:\d\d:\d\d\.\d\d)[^\]]*\] \[Lua\] ', '$1 ' } | Where-Object { $_ -notmatch $Skip })
    $from = -1
    for ($i = $l.Count - 1; $i -ge 0; $i--) { if ($l[$i] -match $After) { $from = $i; break } }
    $done = $false
    if ($from -ge 0) { for ($i = $from + 1; $i -lt $l.Count; $i++) { if ($l[$i] -match $Until) { $done = $true; break } } }
    if (-not $done) { Start-Sleep -Milliseconds 1500 }
} while (-not $done -and (Get-Date) -lt $deadline)
if ($from -lt 0) { "marker '$After' not found"; $l | Select-Object -Last 10 } else { $l[$from..($l.Count - 1)] | Select-Object -First $Max }
if (-not $done) { "(timed out waiting for '$Until')" }
