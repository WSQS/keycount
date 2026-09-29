param([string]$Src, [string]$Out, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Scale = 2)
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile($Src)
$crop = New-Object System.Drawing.Bitmap $W, $H
$g = [System.Drawing.Graphics]::FromImage($crop)
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $W, $H), (New-Object System.Drawing.Rectangle $X, $Y, $W, $H), [System.Drawing.GraphicsUnit]::Pixel)
$big = New-Object System.Drawing.Bitmap ([int]($W * $Scale)), ([int]($H * $Scale))
$g2 = [System.Drawing.Graphics]::FromImage($big)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g2.DrawImage($crop, 0, 0, $big.Width, $big.Height)
$big.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ("cropped {0} -> {1} ({2}x{3})" -f $Src, $Out, $big.Width, $big.Height)
$g.Dispose(); $g2.Dispose(); $crop.Dispose(); $big.Dispose(); $src.Dispose()
