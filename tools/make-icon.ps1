# Generates assets/icon.ico (PNG-compressed ICO, 16-256 px). Run once; the .ico is committed.
Add-Type -AssemblyName System.Drawing
$out = Join-Path $PSScriptRoot '..\src\assets\icon.ico'
New-Item -ItemType Directory (Split-Path $out) -Force | Out-Null

function New-IconPng([int]$s) {
    $bmp = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([Drawing.Color]::Transparent)
    # rounded dark background
    $r = $s * 0.22; $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90); $p.AddArc($s - 2 * $r - 1, 0, 2 * $r, 2 * $r, 270, 90)
    $p.AddArc($s - 2 * $r - 1, $s - 2 * $r - 1, 2 * $r, 2 * $r, 0, 90); $p.AddArc(0, $s - 2 * $r - 1, 2 * $r, 2 * $r, 90, 90)
    $p.CloseFigure()
    $g.FillPath((New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 28, 28, 30))), $p)
    # ring
    $th = [math]::Max(2, $s * 0.11); $m = $s * 0.16 + $th / 2; $d = $s - 2 * $m
    $track = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 58, 58, 60)), $th
    $g.DrawEllipse($track, $m, $m, $d, $d)
    $arc = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 48, 209, 88)), $th
    $arc.StartCap = 'Round'; $arc.EndCap = 'Round'
    $g.DrawArc($arc, $m, $m, $d, $d, -90, 270)
    # battery in the middle
    $bw = $s * 0.30; $bh = $s * 0.17; $bx = ($s - $bw) / 2 - $s * 0.015; $by = ($s - $bh) / 2
    $w = [math]::Max(1, $s * 0.035)
    $white = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(255, 242, 242, 247)), $w
    $g.DrawRectangle($white, $bx, $by, $bw, $bh)
    $fill = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(255, 242, 242, 247))
    $g.FillRectangle($fill, $bx + $bw, $by + $bh * 0.3, $s * 0.03, $bh * 0.4)
    $g.FillRectangle($fill, $bx + $w * 1.5, $by + $w * 1.5, ($bw - $w * 3) * 0.75, $bh - $w * 3)
    $g.Dispose()
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    , $ms.ToArray()
}

$sizes = 256, 64, 48, 32, 24, 16
$pngs = foreach ($s in $sizes) { , (New-IconPng $s) }
$fs = [IO.File]::Create($out); $bw = New-Object IO.BinaryWriter $fs
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $s = $sizes[$i]; $len = $pngs[$i].Length
    $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Close()
[IO.File]::WriteAllBytes((Join-Path $PSScriptRoot '..\docs\images\icon-256.png'), $pngs[0])
"saved $out"
