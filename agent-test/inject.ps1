Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f = New-Object System.Windows.Forms.Form
$f.Text = "keycount self-test"
$f.Size = New-Object System.Drawing.Size(300,120)
$f.StartPosition = "CenterScreen"
$f.TopMost = $true
$tb = New-Object System.Windows.Forms.TextBox
$tb.Dock = "Fill"
$f.Controls.Add($tb)
$f.Add_Shown({
  $f.Activate(); $tb.Focus()
  Start-Sleep -Milliseconds 600
  [System.Windows.Forms.SendKeys]::SendWait("abc123")
  Start-Sleep -Milliseconds 300
  [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
  Start-Sleep -Milliseconds 300
  $f.Close()
})
[void]$f.ShowDialog()
Write-Output "injected into self-test window"
