param([string]$Src, [string]$Out, [int]$X, [int]$Y, [int]$W, [int]$H, [int]$Scale = 1)
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Image]::FromFile($Src)
$rect = New-Object System.Drawing.Rectangle -ArgumentList $X, $Y, $W, $H
$c = $img.Clone($rect, $img.PixelFormat)
if ($Scale -ne 1) {
  $big = New-Object System.Drawing.Bitmap -ArgumentList ([int]($W * $Scale)), ([int]($H * $Scale))
  $g = [System.Drawing.Graphics]::FromImage($big)
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
  $g.DrawImage($c, 0, 0, $big.Width, $big.Height)
  $big.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $big.Dispose()
} else {
  $c.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
}
Write-Output ("cropped {0} ({1}x{2})" -f $Out, $c.Width, $c.Height)
$c.Dispose(); $img.Dispose()
