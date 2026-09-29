Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f = New-Object System.Windows.Forms.Form
$f.Text = "keycount key-test window"
$f.Size = New-Object System.Drawing.Size(420,140)
$f.StartPosition = "CenterScreen"
$f.TopMost = $true
$tb = New-Object System.Windows.Forms.TextBox
$tb.Dock = "Fill"
$f.Controls.Add($tb)
$f.Add_Shown({
  $f.Activate(); $tb.Focus()
  Start-Sleep -Milliseconds 800
  [System.Windows.Forms.SendKeys]::SendWait("abc123")
  Start-Sleep -Milliseconds 400
  Write-Output ("THIS WINDOW RECEIVED: [" + $tb.Text + "]  focused=" + $f.Focused)
  Start-Sleep -Milliseconds 2200
  $f.Close()
})
[void]$f.ShowDialog()
