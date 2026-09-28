param([string]$Out = "shot.png", [int]$MaxW = 1100)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
Write-Output ("virtual screen {0}x{1} at {2},{3}" -f $vs.Width, $vs.Height, $vs.Left, $vs.Top)
$scale = [Math]::Min(1.0, $MaxW / [double]$vs.Width)
$w = [int]($vs.Width * $scale); $h = [int]($vs.Height * $scale)
$bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size)
$small = New-Object System.Drawing.Bitmap $w, $h
$g2 = [System.Drawing.Graphics]::FromImage($small)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g2.DrawImage($bmp, 0, 0, $w, $h)
$small.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Output ("saved {0} ({1}x{2})" -f $Out, $w, $h)
$g.Dispose(); $g2.Dispose(); $bmp.Dispose(); $small.Dispose()
