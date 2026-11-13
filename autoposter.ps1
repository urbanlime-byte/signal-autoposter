# Signal Auto Poster
$Version = '2.0.2'
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Dir = Split-Path -Parent $PSCommandPath
$CfgPath = Join-Path $Dir 'config.json'
$LogPath = Join-Path $Dir 'autoposter.log'
$TmpDir = Join-Path $Dir 'tmp'
if (-not (Test-Path $TmpDir)) { New-Item -ItemType Directory $TmpDir | Out-Null }

trap {
  $m = "Signal Auto Poster hit an error:`r`n$($_.Exception.Message)`r`n(line $($_.InvocationInfo.ScriptLineNumber))"
  try { Add-Content $LogPath $m -Encoding UTF8 } catch {}
  [System.Windows.Forms.MessageBox]::Show($m, 'Signal Auto Poster') | Out-Null
  break
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\SignalAutoPosterApp')
if (-not $mutex.WaitOne(0)) { [System.Windows.Forms.MessageBox]::Show('its already open, check ur taskbar / tray icons', 'Signal Auto Poster') | Out-Null; exit }

# ---------- config ----------
function New-Acct($num) { @{ number = $num; on = $true; groups = @(); message = ''; attachment = '' } }
function Load-Config {
  $c = @{ accounts = New-Object System.Collections.ArrayList; intervalMinutes = 60; secondsBetweenAccounts = 3; running = $false; updateUrl = 'https://raw.githubusercontent.com/urbanlime-byte/signal-autoposter/main/' }
  if (Test-Path $CfgPath) {
    try { $j = Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $j = $null }
    if ($j) {
      if ($j.intervalMinutes) { $c.intervalMinutes = [int]$j.intervalMinutes }
      if ($j.secondsBetweenAccounts -ne $null) { $c.secondsBetweenAccounts = [int]$j.secondsBetweenAccounts }
      if ($j.running) { $c.running = $true }
      if ($j.signalCli) { $script:CliOverride = [string]$j.signalCli }
      if ($j.accounts) {
        foreach ($a in @($j.accounts)) {
          $x = New-Acct ([string]$a.number); $x.on = [bool]$a.on; $x.groups = @($a.groups | Where-Object { $_ }); $x.message = [string]$a.message; $x.attachment = [string]$a.attachment
          [void]$c.accounts.Add($x)
        }
      } elseif ($j.account) {
        $x = New-Acct ([string]$j.account); $x.groups = @($j.groups | Where-Object { $_ }); $x.message = [string]$j.message; $x.attachment = [string]$j.attachment
        [void]$c.accounts.Add($x)
      }
    }
  }
  if ($c.intervalMinutes -lt 10) { $c.intervalMinutes = 10 }
  return $c
}
function Save-Config {
  $o = [ordered]@{ intervalMinutes = $C.intervalMinutes; secondsBetweenAccounts = $C.secondsBetweenAccounts; running = $C.running; accounts = @($C.accounts | ForEach-Object { [ordered]@{ number = $_.number; on = $_.on; groups = @($_.groups); message = $_.message; attachment = $_.attachment } }) }
  $tmp = "$CfgPath.tmp"
  [IO.File]::WriteAllText($tmp, ($o | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
  Move-Item $tmp $CfgPath -Force
}
$C = Load-Config

# ---------- log ----------
function Log($t) {
  $line = (Get-Date -Format 'MM-dd HH:mm:ss') + '  ' + $t
  try { if ((Test-Path $LogPath) -and (Get-Item $LogPath).Length -gt 2MB) { Move-Item $LogPath "$LogPath.old" -Force } ; Add-Content $LogPath $line -Encoding UTF8 } catch {}
  if ($script:LogBox) { $LogBox.AppendText($line + "`r`n"); if ($LogBox.Lines.Count -gt 800) { $LogBox.Lines = $LogBox.Lines[-400..-1] } }
}

# ---------- disk ----------
function Clean-Tmp {
  Get-ChildItem $TmpDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}
function Clean-OldTemp {
  # old versions left a copy of signals dll in windows temp on every send, thats what filled the disk
  $n = 0; $b = 0
  foreach ($f in @(Get-ChildItem $env:TEMP -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'libsignal*' -or $_.Name -like 'sqlite-*' -or $_.Name -like 'zkgroup*' })) {
    try { $s = 0; if ($f.PSIsContainer) { $s = (Get-ChildItem $f.FullName -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum } else { $s = $f.Length }; Remove-Item $f.FullName -Recurse -Force; $n++; $b += $s } catch {}
  }
  if ($n -gt 0) { Log ("cleaned " + $n + " leftover signal temp files (" + [math]::Round($b / 1MB) + " MB freed)") }
}
function Free-MB { try { $d = New-Object IO.DriveInfo ([IO.Path]::GetPathRoot($Dir)); [math]::Floor($d.AvailableFreeSpace / 1MB) } catch { 99999 } }

# ---------- signal-cli ----------
function Find-Cli {
  if ($script:CliOverride -and (Test-Path -LiteralPath $script:CliOverride)) { return $script:CliOverride }
  $d = Get-ChildItem $Dir -Directory -Filter 'signal-cli-*' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($d) { $b = Join-Path $d.FullName 'bin\signal-cli.bat'; if (Test-Path $b) { return $b } }
  return $null
}
function Java-Version {
  try {
    $o = (cmd.exe /d /c 'java -version 2>&1') -join ' '
    if ($o -match 'version "(\d+)') { return [int]$Matches[1] }
  } catch {}
  return 0
}
function Q($s) { '"' + ($s -replace '"', '') + '"' }
function Invoke-Cli([string[]]$argv, [string]$stdin = '', [int]$timeout = 120, [scriptblock]$tick = $null) {
  $bat = Find-Cli
  if (-not $bat) { return @{ code = -1; out = ''; err = 'signal isnt set up yet, hit Setup' } }
  Clean-Tmp
  $run = Join-Path $env:LOCALAPPDATA 'SignalAutoPoster'
  if (-not (Test-Path $run)) { New-Item -ItemType Directory $run | Out-Null }
  $id = [guid]::NewGuid().ToString('N')
  $fin = Join-Path $run "$id.in"; $fout = Join-Path $run "$id.out"; $ferr = Join-Path $run "$id.err"
  [IO.File]::WriteAllBytes($fin, (New-Object Text.UTF8Encoding($false)).GetBytes($stdin))
  $env:JAVA_OPTS = '-Dfile.encoding=UTF-8 -Dstdin.encoding=UTF-8 -Dstdout.encoding=UTF-8 -Dsun.stdout.encoding=UTF-8 "-Djava.io.tmpdir=' + $TmpDir + '"'
  $env:JAVA_TOOL_OPTIONS = $null
  $line = '"' + (Q $bat) + ' ' + (($argv | ForEach-Object { Q $_ }) -join ' ') + ' < ' + (Q $fin) + ' > ' + (Q $fout) + ' 2> ' + (Q $ferr) + '"'
  $psi = New-Object Diagnostics.ProcessStartInfo 'cmd.exe', ('/d /s /c ' + $line)
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.WorkingDirectory = $Dir
  $p = [Diagnostics.Process]::Start($psi)
  $sw = [Diagnostics.Stopwatch]::StartNew()
  while (-not $p.HasExited) {
    [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100
    if ($tick) { & $tick $fout }
    if ($sw.Elapsed.TotalSeconds -gt $timeout) { cmd.exe /d /c "taskkill /T /F /PID $($p.Id) >nul 2>&1"; break }
  }
  $timedOut = -not $p.HasExited
  $code = if ($timedOut) { -2 } else { $p.ExitCode }
  $out = ''; $err = ''
  try { $out = [IO.File]::ReadAllText($fout, [Text.Encoding]::UTF8) } catch {}
  try { $err = [IO.File]::ReadAllText($ferr, [Text.Encoding]::UTF8) } catch {}
  Remove-Item $fin, $fout, $ferr -Force -ErrorAction SilentlyContinue
  Clean-Tmp
  if ($timedOut) { $err = "took too long, stopped it. $err" }
  return @{ code = $code; out = $out; err = $err }
}
function First-Line($t) { $l = @(($t -split "`r?`n") | Where-Object { $_.Trim() -and $_ -notmatch '^\s+at ' -and $_ -notmatch 'Picked up' }); if ($l.Count) { $l[0].Trim() } else { '' } }
function Why($r) {
  $t = $r.err + ' ' + $r.out
  if ($t -match 'not enough space') { return 'ur disk is full, free some space on ur C drive' }
  if ($t -match 'not registered|Unauthorized|AuthorizationFailed|DeviceNotLinked|User .* is not registered') { return 'this phone got unlinked from signal, select it and hit Add phone again' }
  if ($t -match 'RateLimit|rate limit|429') { return 'signal is rate limiting this phone, it ll try again next round' }
  if ($t -match 'UnknownHost|Unable to resolve|timed out|Connection') { return 'no internet / cant reach signal, trying again next round' }
  $f = First-Line $r.err; if (-not $f) { $f = First-Line $r.out }; if (-not $f) { $f = "exit code $($r.code)" }
  return $f
}
$Groups = @{}
function Get-Groups($num) {
  $r = Invoke-Cli @('-a', $num, '-o', 'json', 'listGroups') '' 120
  if ($r.code -ne 0) { Log ("cant get groups for " + $num + ": " + (Why $r)); return $null }
  try { $j = $r.out | ConvertFrom-Json } catch { Log 'groups came back weird, try Refresh groups again'; return $null }
  $g = @(@($j) | Where-Object { $_.isMember -ne $false -and $_.name } | ForEach-Object { @{ id = [string]$_.id; name = [string]$_.name } })
  $Groups[$num] = $g
  return $g
}
function Get-LinkedNumbers {
  $r = Invoke-Cli @('listAccounts') '' 60
  return @([regex]::Matches($r.out, '\+\d{6,}') | ForEach-Object { $_.Value } | Select-Object -Unique)
}

# ---------- posting ----------
$script:Busy = $false
function Post-Account($a) {
  if (-not $a.message.Trim() -and -not $a.attachment) { Log ($a.number + ': no ad written, skipping'); return }
  if (-not $a.groups.Count) { Log ($a.number + ': no groups ticked, skipping'); return }
  [void](Invoke-Cli @('-a', $a.number, 'receive', '-t', '2', '--ignore-attachments') '' 90)
  $g = $Groups[$a.number]; if (-not $g) { $g = Get-Groups $a.number }; if (-not $g) { return }
  $ids = @(); $missing = @()
  foreach ($name in $a.groups) {
    $hit = @($g | Where-Object { $_.name -ieq $name }) | Select-Object -First 1
    if ($hit) { $ids += $hit.id } else { $missing += $name }
  }
  foreach ($m in $missing) { Log ($a.number + ": cant find group '" + $m + "' anymore, hit Refresh groups") }
  if (-not $ids.Count) { return }
  $argv = @('-a', $a.number, 'send', '--message-from-stdin')
  foreach ($i in $ids) { $argv += '-g'; $argv += $i }
  if ($a.attachment) {
    if (Test-Path -LiteralPath $a.attachment) { $argv += '-a'; $argv += $a.attachment } else { Log ($a.number + ': picture not found, sending text only') }
  }
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Invoke-Cli $argv $a.message 300
  if ($r.code -eq 0) { Log ($a.number + ': posted to ' + $ids.Count + ' groups in ' + [int]$sw.Elapsed.TotalSeconds + 's') }
  else { Log ($a.number + ': send failed, ' + (Why $r)) }
}
function Post-Round {
  if ($script:Busy) { return }
  $script:Busy = $true
  try {
    Grab-Ui
    $free = Free-MB
    if ($free -lt 300) { Log ("heads up only " + $free + " MB free on ur drive, signal needs room to work") }
    $list = @($C.accounts | Where-Object { $_.on })
    if (-not $list.Count) { Log 'no phones turned on'; return }
    $first = $true
    foreach ($a in $list) {
      if (-not $first -and $C.secondsBetweenAccounts -gt 0) { $t = [DateTime]::Now.AddSeconds($C.secondsBetweenAccounts); while ([DateTime]::Now -lt $t) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 } }
      $first = $false
      try { Post-Account $a } catch { Log ($a.number + ': error ' + $_.Exception.Message) }
    }
  } finally { $script:Busy = $false; Refresh-Status }
}

# ---------- update ----------
function Check-Update([bool]$quiet) {
  try {
    $base = $C.updateUrl; if (-not $base.EndsWith('/')) { $base += '/' }
    $wc = New-Object Net.WebClient; $wc.Encoding = [Text.Encoding]::UTF8; $wc.Headers['Cache-Control'] = 'no-cache'
    $v = $wc.DownloadString($base + 'version.txt?t=' + [DateTime]::Now.Ticks).Trim()
    if ([version]$v -le [version]$Version) { if (-not $quiet) { Log ("ur on the newest version (" + $Version + ")") }; return }
    if ($quiet) { Log ("update " + $v + " is out, hit Update"); $BtnUpd.Text = "Update to $v"; return }
    $new = Join-Path $Dir 'autoposter.ps1.new'
    $wc.DownloadFile($base + 'autoposter.ps1?t=' + [DateTime]::Now.Ticks, $new)
    $errs = $null; [void][Management.Automation.Language.Parser]::ParseFile($new, [ref]$null, [ref]$errs)
    if ($errs.Count) { Remove-Item $new -Force; Log 'update download was broken, didnt install it'; return }
    Copy-Item $PSCommandPath (Join-Path $Dir 'autoposter.ps1.bak') -Force
    Move-Item $new $PSCommandPath -Force
    Log ("updated to " + $v + ", restarting")
    Save-Config
    $mutex.ReleaseMutex(); $mutex.Dispose()
    Start-Process 'wscript.exe' ('"' + (Join-Path $Dir 'Signal Auto Poster.vbs') + '"')
    $script:Quit = $true; $Form.Close()
  } catch { if (-not $quiet) { Log ("update check failed: " + $_.Exception.Message) } }
}

# ---------- setup + link ----------
function Do-Setup {
  $jv = Java-Version
  if ($jv -lt 21) {
    $a = [System.Windows.Forms.MessageBox]::Show("signal needs Java 21 or newer (u have " + $(if ($jv) { $jv } else { 'none' }) + ").`r`ninstall it now? takes a minute", 'Setup', 'YesNo')
    if ($a -ne 'Yes') { return }
    Log 'installing java...'
    $p = Start-Process 'winget' 'install -e --id EclipseAdoptium.Temurin.21.JRE --accept-package-agreements --accept-source-agreements' -PassThru -WindowStyle Hidden
    while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
    if ((Java-Version) -lt 21) { Log 'java didnt install, close the app, install Java 21 from adoptium.net and open it again'; return }
  }
  Log 'getting newest signal-cli...'
  $rel = Invoke-RestMethod 'https://api.github.com/repos/AsamK/signal-cli/releases/latest' -Headers @{ 'User-Agent' = 'signal-auto-poster' }
  $asset = @($rel.assets | Where-Object { $_.name -match '^signal-cli-[\d.]+\.tar\.gz$' })[0]
  if (-not $asset) { Log 'couldnt find the signal-cli download'; return }
  $cur = Find-Cli
  if ($cur -and $cur -like ('*' + $asset.name.Replace('.tar.gz', '') + '*')) { Log 'signal-cli already up to date'; Refresh-Status; return }
  if ((Free-MB) -lt 400) { Log 'not enough disk space for setup, free some space on ur C drive first'; return }
  $tgz = Join-Path $Dir $asset.name
  $wc = New-Object Net.WebClient; $t = $wc.DownloadFileTaskAsync($asset.browser_download_url, $tgz)
  while (-not $t.IsCompleted) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
  if ($t.IsFaulted) { Log ('download failed: ' + $t.Exception.InnerException.Message); return }
  $p = Start-Process 'tar.exe' ('-xzf "' + $tgz + '" -C "' + $Dir + '"') -PassThru -WindowStyle Hidden
  while (-not $p.HasExited) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
  Remove-Item $tgz -Force -ErrorAction SilentlyContinue
  $newDir = Join-Path $Dir $asset.name.Replace('.tar.gz', '')
  if (-not (Test-Path (Join-Path $newDir 'bin\signal-cli.bat'))) { Log 'unpacking signal-cli failed, hit Setup again'; return }
  Get-ChildItem $Dir -Directory -Filter 'signal-cli-*' | Where-Object { $_.FullName -ne $newDir } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  (Get-Item $newDir).LastWriteTime = Get-Date
  Log 'setup done, now hit Add phone'
  Refresh-Status
}
function Show-Qr($uri) {
  $js = [IO.File]::ReadAllText((Join-Path $Dir 'qrcode.min.js'))
  $html = '<!DOCTYPE html><html><head><meta http-equiv="X-UA-Compatible" content="IE=edge"><meta charset="utf-8"><script>' + $js + '</script></head><body style="margin:0;text-align:center;font-family:Segoe UI"><div id="q"></div><p>signal on ur phone &gt; settings &gt; linked devices &gt; + &gt; scan this</p><script>var q=qrcode(0,"M");q.addData("' + $uri + '");q.make();document.getElementById("q").innerHTML=q.createImgTag(6,12);</script></body></html>'
  $f = New-Object Windows.Forms.Form; $f.Text = 'Scan with Signal'; $f.Size = New-Object Drawing.Size(460, 540); $f.StartPosition = 'CenterParent'; $f.TopMost = $true
  $wb = New-Object Windows.Forms.WebBrowser; $wb.Dock = 'Fill'; $wb.ScrollBarsEnabled = $false; $wb.DocumentText = $html
  $f.Controls.Add($wb); $f.Show($Form)
  return $f
}
function Add-Phone {
  if (-not (Find-Cli)) { Log 'hit Setup first'; return }
  $before = Get-LinkedNumbers
  Log 'making link code...'
  $script:qr = $null
  $tick = { param($fout) if (-not $script:qr -and (Test-Path $fout)) { try { $fs = New-Object IO.FileStream($fout, 'Open', 'Read', 'ReadWrite'); $sr = New-Object IO.StreamReader($fs); $t = $sr.ReadToEnd(); $sr.Close() } catch { $t = '' }; if ($t -match '(sgnl://\S+)') { $script:qr = Show-Qr $Matches[1] } } }
  $r = Invoke-Cli @('link', '-n', ('autoposter-' + $env:COMPUTERNAME)) '' 300 $tick
  if ($script:qr) { $script:qr.Close() }
  if ($r.code -ne 0) { if (-not $script:qr) { Log ('link failed, no code came back: ' + (Why $r)) } else { Log 'link code ran out before it got scanned, hit Add phone and scan it quicker' }; return }
  $after = Get-LinkedNumbers
  $new = @($after | Where-Object { $before -notcontains $_ })
  if (-not $new.Count) { $new = @($after | Where-Object { $n = $_; -not ($C.accounts | Where-Object { $_.number -eq $n }) }) }
  foreach ($n in $new) { if (-not ($C.accounts | Where-Object { $_.number -eq $n })) { [void]$C.accounts.Add((New-Acct $n)) } ; Log ("linked " + $n) }
  Save-Config; Fill-Accounts; if ($new.Count) { $Cmb.SelectedItem = $new[0] }
}

# ---------- UI ----------
$Form = New-Object Windows.Forms.Form
$Form.Text = "Signal Auto Poster $Version"; $Form.Size = New-Object Drawing.Size(820, 680); $Form.StartPosition = 'CenterScreen'; $Form.MinimumSize = $Form.Size
$Form.Font = New-Object Drawing.Font('Segoe UI', 9)
function Btn($t, $x, $y, $w) { $b = New-Object Windows.Forms.Button; $b.Text = $t; $b.Location = New-Object Drawing.Point($x, $y); $b.Size = New-Object Drawing.Size($w, 28); $Form.Controls.Add($b); $b }
function Lbl($t, $x, $y, $w) { $l = New-Object Windows.Forms.Label; $l.Text = $t; $l.Location = New-Object Drawing.Point($x, $y); $l.Size = New-Object Drawing.Size($w, 20); $Form.Controls.Add($l); $l }

$Status = Lbl '' 12 10 780; $Status.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$BtnSetup = Btn 'Setup' 12 36 90
$BtnAdd = Btn 'Add phone' 108 36 100
$BtnDel = Btn 'Remove phone' 214 36 110
$BtnUpd = Btn 'Check for update' 650 36 145

[void](Lbl 'Phone:' 12 78 50)
$Cmb = New-Object Windows.Forms.ComboBox; $Cmb.DropDownStyle = 'DropDownList'; $Cmb.Location = New-Object Drawing.Point(62, 75); $Cmb.Size = New-Object Drawing.Size(200, 24); $Form.Controls.Add($Cmb)
$ChkOn = New-Object Windows.Forms.CheckBox; $ChkOn.Text = 'post from this phone'; $ChkOn.Location = New-Object Drawing.Point(272, 76); $ChkOn.Size = New-Object Drawing.Size(160, 22); $Form.Controls.Add($ChkOn)
$BtnRef = Btn 'Refresh groups' 440 73 120

[void](Lbl 'Groups to post in (this phone):' 12 108 300)
$Lst = New-Object Windows.Forms.CheckedListBox; $Lst.CheckOnClick = $true; $Lst.Location = New-Object Drawing.Point(12, 130); $Lst.Size = New-Object Drawing.Size(300, 300); $Form.Controls.Add($Lst)
[void](Lbl 'Ad for this phone (emojis fine):' 324 108 300)
$Msg = New-Object Windows.Forms.TextBox; $Msg.Multiline = $true; $Msg.ScrollBars = 'Vertical'; $Msg.AcceptsReturn = $true; $Msg.Location = New-Object Drawing.Point(324, 130); $Msg.Size = New-Object Drawing.Size(470, 260); $Msg.Font = New-Object Drawing.Font('Segoe UI Emoji', 10); $Form.Controls.Add($Msg)
$PicLbl = Lbl 'Picture: none' 324 402 300
$BtnPic = Btn 'Pick picture' 630 397 90
$BtnPicX = Btn 'Clear' 724 397 70

[void](Lbl 'Post every' 12 446 70)
$Num = New-Object Windows.Forms.NumericUpDown; $Num.Minimum = 10; $Num.Maximum = 1440; $Num.Location = New-Object Drawing.Point(84, 443); $Num.Size = New-Object Drawing.Size(60, 24); $Form.Controls.Add($Num)
[void](Lbl 'minutes' 150 446 60)
$BtnNow = Btn 'Post once now' 324 440 120
$BtnGo = Btn 'START' 452 440 120; $BtnGo.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
$Next = Lbl '' 584 446 210

$LogBox = New-Object Windows.Forms.TextBox; $LogBox.Multiline = $true; $LogBox.ReadOnly = $true; $LogBox.ScrollBars = 'Vertical'; $LogBox.Location = New-Object Drawing.Point(12, 480); $LogBox.Size = New-Object Drawing.Size(782, 150); $LogBox.Anchor = 'Top,Bottom,Left,Right'; $Form.Controls.Add($LogBox)

$Tray = New-Object Windows.Forms.NotifyIcon; $Tray.Icon = [Drawing.SystemIcons]::Application; $Tray.Text = 'Signal Auto Poster'; $Tray.Visible = $true
$Tray.add_DoubleClick({ $Form.Show(); $Form.WindowState = 'Normal'; $Form.Activate() })

$script:Loading = $false
function Cur { if ($Cmb.SelectedIndex -ge 0 -and $Cmb.SelectedIndex -lt $C.accounts.Count) { return $C.accounts[$Cmb.SelectedIndex] }; return $null }
function Grab-Ui {
  if ($script:Loading) { return }
  $a = Cur
  if ($a) { $a.message = $Msg.Text; $a.on = $ChkOn.Checked; $a.groups = @($Lst.CheckedItems | ForEach-Object { [string]$_ }) }
  $C.intervalMinutes = [int]$Num.Value
  Save-Config
}
function Show-Acct {
  $script:Loading = $true
  $a = Cur
  $Lst.Items.Clear()
  if ($a) {
    $names = @(); if ($Groups[$a.number]) { $names = @($Groups[$a.number] | ForEach-Object { $_.name }) }
    foreach ($n in $a.groups) { if ($names -notcontains $n) { $names += $n } }
    foreach ($n in ($names | Sort-Object -Unique)) { [void]$Lst.Items.Add($n, ($a.groups -contains $n)) }
    $Msg.Text = $a.message; $ChkOn.Checked = $a.on
    $PicLbl.Text = 'Picture: ' + $(if ($a.attachment) { Split-Path -Leaf $a.attachment } else { 'none' })
  } else { $Msg.Text = ''; $ChkOn.Checked = $false; $PicLbl.Text = 'Picture: none' }
  $Msg.Enabled = [bool]$a; $Lst.Enabled = [bool]$a; $ChkOn.Enabled = [bool]$a
  $script:Loading = $false
}
function Fill-Accounts {
  $script:Loading = $true
  $i = $Cmb.SelectedIndex; $Cmb.Items.Clear()
  foreach ($a in $C.accounts) { [void]$Cmb.Items.Add($a.number) }
  if ($Cmb.Items.Count) { $Cmb.SelectedIndex = [math]::Max(0, [math]::Min($i, $Cmb.Items.Count - 1)) }
  $script:Loading = $false
  Show-Acct; Refresh-Status
}
$script:NextAt = $null
function Refresh-Status {
  $on = @($C.accounts | Where-Object { $_.on }).Count
  if (-not (Find-Cli)) { $Status.Text = 'Step 1: hit Setup' }
  elseif (-not $C.accounts.Count) { $Status.Text = 'Step 2: hit Add phone and scan the code with Signal' }
  elseif ($script:Timer.Enabled) { $Status.Text = "RUNNING - $on phone(s), every $($C.intervalMinutes) min. minimize it, it keeps going in the tray" }
  else { $Status.Text = "Ready - $($C.accounts.Count) phone(s) linked. tick groups, write ad, hit START" }
  if ($script:Timer.Enabled -and $script:NextAt) { $Next.Text = 'next post: ' + $script:NextAt.ToString('HH:mm') } else { $Next.Text = '' }
  $BtnGo.Text = $(if ($script:Timer.Enabled) { 'STOP' } else { 'START' })
  $Tray.Text = $(if ($script:Timer.Enabled) { 'Signal Auto Poster - running' } else { 'Signal Auto Poster - stopped' })
}

$script:Timer = New-Object Windows.Forms.Timer; $Timer.Interval = 5000
$Timer.add_Tick({
  if ($script:Busy -or -not $script:NextAt) { return }
  if ([DateTime]::Now -ge $script:NextAt) {
    $script:NextAt = [DateTime]::Now.AddMinutes($C.intervalMinutes)
    try { Post-Round } catch { Log ('round error: ' + $_.Exception.Message) }
    Refresh-Status
  }
})
function Start-Posting { Grab-Ui; $C.running = $true; Save-Config; $script:NextAt = [DateTime]::Now; $Timer.Start(); Log 'started'; Refresh-Status }
function Stop-Posting { $Timer.Stop(); $C.running = $false; Save-Config; $script:NextAt = $null; Log 'stopped'; Refresh-Status }

$Cmb.add_SelectedIndexChanged({ if (-not $script:Loading) { Show-Acct } })
$Msg.add_Leave({ Grab-Ui })
$Msg.add_TextChanged({ if (-not $script:Loading) { $a = Cur; if ($a) { $a.message = $Msg.Text } } })
$ChkOn.add_CheckedChanged({ Grab-Ui; Refresh-Status })
$Lst.add_ItemCheck({ if (-not $script:Loading -and $Form.IsHandleCreated) { $Form.BeginInvoke([Action]{ Grab-Ui }) | Out-Null } })
$Num.add_ValueChanged({ Grab-Ui; if ($script:Timer.Enabled -and $script:NextAt) { Refresh-Status } })
$BtnSetup.add_Click({ $BtnSetup.Enabled = $false; try { Do-Setup } finally { $BtnSetup.Enabled = $true } })
$BtnAdd.add_Click({ $BtnAdd.Enabled = $false; try { Add-Phone } finally { $BtnAdd.Enabled = $true } })
$BtnDel.add_Click({
  $a = Cur; if (-not $a) { return }
  if ([System.Windows.Forms.MessageBox]::Show("remove " + $a.number + " from the app? (it stays in signal, u can unlink it on ur phone)", 'Remove phone', 'YesNo') -ne 'Yes') { return }
  $C.accounts.Remove($a); Save-Config; Fill-Accounts; Log ('removed ' + $a.number)
})
$BtnRef.add_Click({
  $a = Cur; if (-not $a) { Log 'add a phone first'; return }
  $BtnRef.Enabled = $false
  try { Log 'getting groups...'; $g = Get-Groups $a.number; if ($g) { Log ('found ' + $g.Count + ' groups'); Show-Acct } } finally { $BtnRef.Enabled = $true }
})
$BtnPic.add_Click({
  $a = Cur; if (-not $a) { return }
  $d = New-Object Windows.Forms.OpenFileDialog; $d.Filter = 'Pictures/videos|*.jpg;*.jpeg;*.png;*.gif;*.webp;*.mp4|All files|*.*'
  if ($d.ShowDialog() -eq 'OK') { $a.attachment = $d.FileName; Save-Config; Show-Acct }
})
$BtnPicX.add_Click({ $a = Cur; if ($a) { $a.attachment = ''; Save-Config; Show-Acct } })
$BtnNow.add_Click({ $BtnNow.Enabled = $false; try { Log 'posting now...'; Post-Round } finally { $BtnNow.Enabled = $true } })
$BtnGo.add_Click({ if ($Timer.Enabled) { Stop-Posting } else { Start-Posting } })
$BtnUpd.add_Click({ $BtnUpd.Enabled = $false; try { Check-Update $false } finally { $BtnUpd.Enabled = $true } })

$script:Quit = $false
$script:TrayTip = $false
$Form.add_Resize({ if ($Form.WindowState -eq 'Minimized') { $Form.Hide(); if (-not $script:TrayTip) { $Tray.ShowBalloonTip(3000, 'Signal Auto Poster', 'still running down here, double click to open', 'Info'); $script:TrayTip = $true } } })
$Form.add_FormClosing({
  param($s, $e)
  if (-not $script:Quit -and $Timer.Enabled) {
    $r = [System.Windows.Forms.MessageBox]::Show('its still posting. close it anyway?  (No = hide it in the tray and keep going)', 'Signal Auto Poster', 'YesNoCancel')
    if ($r -eq 'No') { $e.Cancel = $true; $Form.WindowState = 'Minimized'; return }
    if ($r -eq 'Cancel') { $e.Cancel = $true; return }
  }
  try { Grab-Ui } catch {}
})
$Form.add_FormClosed({ $Tray.Visible = $false; $Tray.Dispose() })
$Form.add_Shown({
  Log "opened v$Version"
  Clean-OldTemp
  $Num.Value = [math]::Min(1440, [math]::Max(10, $C.intervalMinutes))
  Fill-Accounts
  foreach ($a in $C.accounts) { if (Find-Cli) { [void](Get-Groups $a.number) } }
  Show-Acct
  Check-Update $true
  if ($C.running -and (Find-Cli) -and $C.accounts.Count) { Log 'was running before, starting again'; Start-Posting }
})

if ($env:SAP_SELFTEST) { Fill-Accounts; Post-Round; exit }
[System.Windows.Forms.Application]::Run($Form)
