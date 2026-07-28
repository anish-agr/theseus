# Generates the app icon: the Theseus thread — one continuous line that
# ends in a glowing warm destination dot, on deep indigo. Matches the
# brand spec (docs/BRAND.md) and Sources/Brand/Brand.swift exactly:
# thread #33A8FF, dot #FFF6E8, background #0E1B4D.
#
#   powershell -File tools/icon/generate.ps1
Add-Type -AssemblyName System.Drawing

$W = 1024.0
$out = Join-Path $PSScriptRoot "..\..\apps\ios\Sources\Assets.xcassets\AppIcon.appiconset\icon-1024.png"
$out = [IO.Path]::GetFullPath($out)
New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null

$bmp = New-Object Drawing.Bitmap([int]$W, [int]$W)
$g = [Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'

# background: deep indigo, slightly darker toward the bottom
$rect = New-Object Drawing.Rectangle(0, 0, [int]$W, [int]$W)
$bg = New-Object Drawing.Drawing2D.LinearGradientBrush(
    $rect,
    [Drawing.Color]::FromArgb(255, 16, 30, 84),
    [Drawing.Color]::FromArgb(255, 8, 16, 48),
    90.0)
$g.FillRectangle($bg, $rect)

# the thread: three horizontal runs joined by two U-turns, same
# parametric path as ThreadShape in Brand.swift (unit coords * W)
function P([double]$x, [double]$y) {
    New-Object Drawing.PointF([single]($x * $W), [single]($y * $W))
}
$k = 0.173   # Bezier control offset that reads as a semicircle r=0.13
$path = New-Object Drawing.Drawing2D.GraphicsPath
$path.AddLine((P 0.24 0.20), (P 0.58 0.20))
$path.AddBezier((P 0.58 0.20), (P ($k + 0.58) 0.20),
                (P ($k + 0.58) 0.46), (P 0.58 0.46))
$path.AddLine((P 0.58 0.46), (P 0.38 0.46))
$path.AddBezier((P 0.38 0.46), (P (0.38 - $k) 0.46),
                (P (0.38 - $k) 0.72), (P 0.38 0.72))
$path.AddLine((P 0.38 0.72), (P 0.72 0.72))

$pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255, 51, 168, 255), [single](0.085 * $W))
$pen.LineJoin = 'Round'
$pen.StartCap = 'Round'
$pen.EndCap = 'Round'
$g.DrawPath($pen, $path)

# the destination dot, with a soft warm halo (the only thing that glows)
$cx = 0.82 * $W; $cy = 0.72 * $W
$haloR = 0.16 * $W
$haloPath = New-Object Drawing.Drawing2D.GraphicsPath
$haloPath.AddEllipse([single]($cx - $haloR), [single]($cy - $haloR),
                     [single](2 * $haloR), [single](2 * $haloR))
$halo = New-Object Drawing.Drawing2D.PathGradientBrush($haloPath)
$halo.CenterColor = [Drawing.Color]::FromArgb(140, 255, 246, 232)
$halo.SurroundColors = @([Drawing.Color]::FromArgb(0, 255, 246, 232))
$g.FillPath($halo, $haloPath)

$dot = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 255, 246, 232))
$r = 0.065 * $W
$g.FillEllipse($dot, [single]($cx - $r), [single]($cy - $r),
               [single](2 * $r), [single](2 * $r))

$bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"wrote $out ({0:N0} bytes)" -f (Get-Item $out).Length
