# Generates assets/icon.ico matching the dashboard's monochrome gauge, so
# the taskbar/shortcut icon actually matches the app instead of inheriting
# PowerShell's default icon. Re-run any time the palette changes. No
# external tools, pure GDI+ (System.Drawing), PNG-in-ICO format.

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$outPath = Join-Path $here 'icon.ico'

$BG  = [System.Drawing.ColorTranslator]::FromHtml('#0A0A0B')
$Arc = [System.Drawing.ColorTranslator]::FromHtml('#F5F5F5')

function New-IconMaster([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # rounded-square background
    $pad = [math]::Round($size * 0.04)
    $rect = New-Object System.Drawing.Rectangle $pad, $pad, ($size - 2*$pad), ($size - 2*$pad)
    $radius = [math]::Round($size * 0.22)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $radius * 2
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $bgBrush = New-Object System.Drawing.SolidBrush $BG
    $g.FillPath($bgBrush, $path)

    # the gauge arc: same 150deg->390deg (240deg) sweep as the dashboard.
    # Solid, not gradient, monochrome doesn't have a second hue to fade
    # into, and a flat fill reads more reliably once shrunk to 16px anyway.
    $cx = $size / 2.0; $cy = $size / 2.0
    $r = $size * 0.30
    $strokeW = $size * 0.135
    $arcRect = New-Object System.Drawing.RectangleF ($cx - $r), ($cy - $r), ($r * 2), ($r * 2)
    $pen = New-Object System.Drawing.Pen $Arc, $strokeW
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $g.DrawArc($pen, $arcRect, 150, 240)

    $g.Dispose()
    return $bmp
}

function ConvertTo-PngBytes([System.Drawing.Bitmap]$bmp) {
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    return $ms.ToArray()
}

$master = New-IconMaster 256
$sizes = @(256, 48, 32, 16)
$pngs = @{}
foreach ($s in $sizes) {
    if ($s -eq 256) {
        $pngs[$s] = ConvertTo-PngBytes $master
    } else {
        $small = New-Object System.Drawing.Bitmap $s, $s
        $g2 = [System.Drawing.Graphics]::FromImage($small)
        $g2.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g2.DrawImage($master, 0, 0, $s, $s)
        $g2.Dispose()
        $pngs[$s] = ConvertTo-PngBytes $small
        $small.Dispose()
    }
}
$master.Dispose()

# hand-assemble the ICO container (PNG-in-ICO, supported since Vista)
$fs = New-Object System.IO.FileStream $outPath, 'Create'
$bw = New-Object System.IO.BinaryWriter $fs
$bw.Write([uint16]0)      # reserved
$bw.Write([uint16]1)      # type = icon
$bw.Write([uint16]$sizes.Count)

$headerSize = 6 + (16 * $sizes.Count)
$offset = $headerSize
foreach ($s in $sizes) {
    $byteLen = $pngs[$s].Length
    $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))  # width (0 = 256)
    $bw.Write([byte]($(if ($s -ge 256) { 0 } else { $s })))  # height
    $bw.Write([byte]0)    # color count
    $bw.Write([byte]0)    # reserved
    $bw.Write([uint16]1)  # planes
    $bw.Write([uint16]32) # bit count
    $bw.Write([uint32]$byteLen)
    $bw.Write([uint32]$offset)
    $offset += $byteLen
}
$bw.Flush()
# BinaryWriter.Write(byte[]) is ambiguous against the newer
# Write(ReadOnlySpan<Byte>) overload on this .NET runtime and silently
# writes a single byte instead of the array. Write the raw PNG blobs
# straight to the FileStream instead, where Write(byte[], int, int) is
# unambiguous.
foreach ($s in $sizes) { $fs.Write($pngs[$s], 0, $pngs[$s].Length) }
$fs.Flush(); $bw.Close(); $fs.Close()

Write-Output "Wrote $outPath ($([math]::Round((Get-Item $outPath).Length / 1KB, 1)) KB, sizes: $($sizes -join ', '))"
