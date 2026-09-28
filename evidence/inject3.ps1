Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$f = New-Object System.Windows.Forms.Form
$f.Text = "keycount key-test (另一个窗口)"
$f.Size = New-Object System.Drawing.Size(460,150)
$f.StartPosition = "CenterScreen"
$f.TopMost = $true
$tb = New-Object System.Windows.Forms.TextBox
$tb.Dock = "Fill"
$f.Controls.Add($tb)
$f.Add_Shown({
  $f.Activate(); $tb.Focus()
  Start-Sleep -Milliseconds 900
  # Shift+A 测归一化；空格/退格/回车/Tab 测命名键
  [System.Windows.Forms.SendKeys]::SendWait("+abc 1{BS}{ENTER}{TAB}")
  Start-Sleep -Milliseconds 700
  [System.IO.File]::WriteAllText("C:\Users\<user>\.pi\profiles\assistant\scratch\<session-id>\keycount\native\inject-received.txt", $tb.Text)
  Start-Sleep -Milliseconds 2000
  $f.Close()
})
[void]$f.ShowDialog()
