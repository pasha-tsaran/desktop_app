param([Parameter(Mandatory)][string]$Sphere, [Parameter(Mandatory)][string]$IconSheet)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repo = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $repo 'apps/desktop/assets/branding'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
Copy-Item -LiteralPath $Sphere -Destination "$assets/sphere-logo.png"
# Mechanical sprite extraction; preserve the alpha produced by imagegen.
$atlas = [Drawing.Bitmap]::new($IconSheet)
if ($atlas.Width -ne 1536 -or $atlas.Height -ne 1024) { throw 'Expected 3x2 atlas' }
$names = @('servers','account','logs','vpnSettings','settings','support')
for ($index=0; $index -lt 6; $index++) {
    $rect = [Drawing.Rectangle]::new(($index%3)*512, [int][Math]::Floor($index/3)*512, 512, 512)
    $cell = $atlas.Clone($rect, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $cell.Save("$assets/$($names[$index]).png", [Drawing.Imaging.ImageFormat]::Png)
    $cell.Dispose()
}
$atlas.Dispose()
# Package the same logo into the Windows multi-resolution ICO container.
$source = [Drawing.Bitmap]::new($Sphere)
$entries = [Collections.Generic.List[byte[]]]::new()
$sizes = @(16,24,32,48,64,128,256)
foreach ($size in $sizes) {
    $resized = [Drawing.Bitmap]::new($size,$size,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($resized)
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.DrawImage($source,0,0,$size,$size)
    $stream = [IO.MemoryStream]::new()
    $resized.Save($stream,[Drawing.Imaging.ImageFormat]::Png)
    $entries.Add($stream.ToArray())
    $stream.Dispose(); $graphics.Dispose(); $resized.Dispose()
}
$source.Dispose()
$writer = [IO.BinaryWriter]::new([IO.File]::Create((Join-Path $repo 'apps/desktop/windows/runner/resources/app_icon.ico')))
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset = 6+16*$sizes.Count
    for ($index=0; $index -lt $sizes.Count; $index++) {
        $dimension = if ($sizes[$index] -eq 256) { 0 } else { $sizes[$index] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$entries[$index].Length); $writer.Write([uint32]$offset)
        $offset += $entries[$index].Length
    }
    foreach ($bytes in $entries) { $writer.Write($bytes) }
} finally { $writer.Dispose() }
Write-Output 'branding_assets=7; ico_sizes=16,24,32,48,64,128,256'
