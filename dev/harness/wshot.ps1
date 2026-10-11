# Captures the game window's own contents (works when it is covered or the PC is locked).
#   wshot.ps1 <out.png> [-MaxWidth 1400] [-Crop x,y,w,h]   (crop in window client pixels)
param([Parameter(Position = 0)][string]$Out, [int]$MaxWidth = 1400, [int[]]$Crop)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class WShot {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
}
'@
[WShot]::SetProcessDPIAware() | Out-Null
$p = Get-Process -Name 'FarFarWest-Win64-Shipping' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { throw 'game not running' }
$r = New-Object WShot+RECT
[WShot]::GetClientRect($p.MainWindowHandle, [ref]$r) | Out-Null
$w, $h = ($r.R - $r.L), ($r.B - $r.T)
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$ok = [WShot]::PrintWindow($p.MainWindowHandle, $hdc, 3)   # client only + full content
$g.ReleaseHdc($hdc); $g.Dispose()
if ($Crop) {
    $c = New-Object System.Drawing.Rectangle $Crop[0], $Crop[1], $Crop[2], $Crop[3]
    $part = $bmp.Clone($c, $bmp.PixelFormat); $bmp.Dispose(); $bmp = $part
}
if ($bmp.Width -gt $MaxWidth) {
    $nh = [int]($bmp.Height * $MaxWidth / $bmp.Width)
    $small = New-Object System.Drawing.Bitmap $MaxWidth, $nh
    $g2 = [System.Drawing.Graphics]::FromImage($small)
    $g2.InterpolationMode = 'HighQualityBicubic'
    $g2.DrawImage($bmp, 0, 0, $MaxWidth, $nh)
    $g2.Dispose(); $bmp.Dispose(); $bmp = $small
}
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
"saved $Out $($bmp.Width)x$($bmp.Height) (client ${w}x${h}, PrintWindow=$ok)"
$bmp.Dispose()
