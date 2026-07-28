# Generates the app icon: a square labyrinth with one opening and the
# goal at its centre. Drawn in code so the 1024 px master is
# reproducible and the repo carries no binary source-of-truth.
#
#   powershell -File tools/icon/generate.ps1
Add-Type -AssemblyName System.Drawing

$W = 1024
$out = Join-Path $PSScriptRoot "..\..\apps\ios\Sources\Assets.xcassets\AppIcon.appiconset\icon-1024.png"
$out = [IO.Path]::GetFullPath($out)
New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null

$bmp = New-Object Drawing.Bitmap($W, $W)
$g = [Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'

# background: deep navy, lit slightly from the top-left
$rect = New-Object Drawing.Rectangle(0, 0, $W, $W)
$bg = New-Object Drawing.Drawing2D.LinearGradientBrush(
    $rect,
    [Drawing.Color]::FromArgb(255, 18, 30, 51),
    [Drawing.Color]::FromArgb(255, 8, 13, 24),
    45.0)
$g.FillRectangle($bg, $rect)

# the labyrinth: a square spiral wound inward, entrance at top-left
$inset = 168.0
$gap = 104.0
$x1 = $inset; $y1 = $inset
$x2 = $W - $inset; $y2 = $W - $inset
$pts = New-Object 'System.Collections.Generic.List[Drawing.PointF]'
$pts.Add((New-Object Drawing.PointF($x1, $y1)))
while (($x2 - $x1) -gt $gap -and ($y2 - $y1) -gt $gap) {
    $pts.Add((New-Object Drawing.PointF($x2, $y1)))
    $pts.Add((New-Object Drawing.PointF($x2, $y2)))
    $pts.Add((New-Object Drawing.PointF($x1, $y2)))
    $y1 += $gap
    $pts.Add((New-Object Drawing.PointF($x1, $y1)))
    $x1 += $gap
    $x2 -= $gap
    $y2 -= $gap
}

$pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(255, 34, 211, 238), 46.0)
$pen.LineJoin = 'Round'
$pen.StartCap = 'Round'
$pen.EndCap = 'Round'
$g.DrawLines($pen, $pts.ToArray())

# the goal at the centre - the thing you are being walked to
$dot = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 245, 158, 11))
$r = 62.0
$g.FillEllipse($dot, ($W / 2 - $r), ($W / 2 - $r), (2 * $r), (2 * $r))

$bmp.Save($out, [Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"wrote $out ({0:N0} bytes)" -f (Get-Item $out).Length
