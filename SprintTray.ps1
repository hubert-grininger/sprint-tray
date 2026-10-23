param(
    [string]$Project = 'APPOBS',
    [int]$RefreshMinutes = 1440
)

# Keep in sync with the -version passed to ps2exe (see CLAUDE.md, Build and test)
$version = '1.1.0'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

# Single instance: quit if another SprintTray (script or exe) is already running
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\SprintTray', [ref]$createdNew)
if (-not $createdNew) { exit }

$setupHelp = @"
SprintTray needs the Atlassian CLI with PII redaction (acli-pii):

1. Install acli-pii and make sure it is on your PATH
   (default location: %USERPROFILE%\.local\bin\acli-pii.exe).
2. Log in once in a terminal:
     acli-pii jira auth login
3. Check it works:
     acli-pii jira sprint list --project $Project --state active

Then right-click the tray icon and choose Refresh.
"@

function Get-ActiveSprint {
    if (-not (Get-Command acli-pii -ErrorAction SilentlyContinue)) {
        throw 'acli-pii not found - see Help'
    }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'acli-pii'
    $psi.Arguments = "jira sprint list --project $Project --state active --json"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    # Read asynchronously so a hung acli-pii cannot block the UI thread on ReadToEnd
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit(60000)) {
        $p.Kill()
        throw 'acli-pii timed out (no answer from Jira within 60 s)'
    }
    $p.WaitForExit()  # second call flushes the async readers
    $out = $outTask.Result
    $err = $errTask.Result
    if ($p.ExitCode -ne 0) {
        $msg = ($err -replace '[^ -~]', '').Trim()
        if ($msg -match 'auth|login|401|unauthori|credential|token') { $msg = "Not logged in to Jira ($msg)" }
        throw "acli-pii failed: $msg"
    }

    # ForEach-Object unrolls the array (Windows PowerShell 5.1 emits it as one object)
    $sprints = @($out | ConvertFrom-Json | ForEach-Object { $_ })
    # Prefer real sprints ("... Sprint 351") over long-running planning buckets
    $candidates = @($sprints | Where-Object { $_.name -match 'Sprint\s*\d+' })
    if (-not $candidates) { $candidates = $sprints }
    if (-not $candidates) { throw "No active sprint in $Project" }
    $candidates | Sort-Object { [datetime]$_.startDate } -Descending | Select-Object -First 1
}

# Last sprint that loaded successfully, kept on disk so the icon still works after a restart
$cacheFile = Join-Path (Join-Path $env:LOCALAPPDATA 'SprintTray') 'last-sprint.json'

function Get-LastSprint {
    try {
        $c = Get-Content -Path $cacheFile -Raw | ConvertFrom-Json
        if ($c.project -eq $Project) { return $c }
    } catch {}  # missing or corrupt cache is not an error; start without a fallback
    $null
}

function Save-LastSprint($s) {
    $script:lastGood = [pscustomobject]@{ project = $Project; name = $s.name; startDate = $s.startDate; endDate = $s.endDate }
    try {
        New-Item -ItemType Directory -Force -Path (Split-Path $cacheFile) | Out-Null
        $script:lastGood | ConvertTo-Json | Set-Content -Path $cacheFile -Encoding UTF8
    } catch {}  # best effort: the in-memory copy still covers this session
}

function New-TextIcon([string]$text, [System.Drawing.Color]$color, [double]$progress = -1) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    # Reserve room for the progress bar (6px + 3px gap) below the text
    $barH = 6; $gap = 3
    $availH = if ($progress -ge 0) { 32 - $barH - $gap } else { 32 }
    # Scale the actual glyph outline so it fills the icon (aspect ratio kept)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $family = New-Object System.Drawing.FontFamily 'Segoe UI'
    $path.AddString($text, $family, [int][System.Drawing.FontStyle]::Bold, 100, (New-Object System.Drawing.PointF 0, 0), [System.Drawing.StringFormat]::GenericTypographic)
    $b = $path.GetBounds()
    $scale = [math]::Min(32 / $b.Width, $availH / $b.Height)
    $textH = $b.Height * $scale
    $blockH = if ($progress -ge 0) { $textH + $gap + $barH } else { $textH }
    $top = (32 - $blockH) / 2
    $mx = New-Object System.Drawing.Drawing2D.Matrix
    $mx.Translate((32 - $b.Width * $scale) / 2, $top)
    $mx.Scale($scale, $scale)
    $mx.Translate(-$b.X, -$b.Y)
    $path.Transform($mx)
    $brush = New-Object System.Drawing.SolidBrush $color
    $g.FillPath($brush, $path)
    if ($progress -ge 0) {
        # Green = remaining (highlighted), red = elapsed part of the sprint
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::None
        $barY = [int][math]::Round($top + $textH + $gap)
        $track = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(30, 160, 60))
        $g.FillRectangle($track, 0, $barY, 32, $barH)
        $elapsed = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(200, 30, 30))
        $g.FillRectangle($elapsed, 0, $barY, [int][math]::Round(32 * [math]::Min(1.0, $progress)), $barH)
        $track.Dispose(); $elapsed.Dispose()
    }
    $g.Dispose(); $path.Dispose(); $family.Dispose(); $mx.Dispose(); $brush.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $icon
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Visible = $true
$script:sprintName = ''
$script:lastError = ''
$script:lastGood = $null

function Show-Help {
    $status = if ($script:lastError) {
        $cached = if ($script:lastGood) { "Showing the last known sprint: $($script:lastGood.name)`n`n" } else { '' }
        "Current problem:`n$($script:lastError)`n`n$cached"
    } else { "Status: OK ($($script:sprintName))`n`n" }
    [System.Windows.Forms.MessageBox]::Show($status + $setupHelp, "SprintTray $version", 'OK',
        $(if ($script:lastError) { 'Warning' } else { 'Information' })) | Out-Null
}

function Get-TextColor {
    # Taskbar follows SystemUsesLightTheme: 0 = dark taskbar, so the text must be light
    $light = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name SystemUsesLightTheme -ErrorAction SilentlyContinue).SystemUsesLightTheme
    if ($light -eq 0) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(0, 40, 120) }
}

function Update-Tray {
    $s = $null
    try {
        $s = Get-ActiveSprint
        Save-LastSprint $s
        $script:lastError = ''
    } catch {
        $errText = $_.Exception.Message
        # Notify once per distinct problem; clicking the balloon opens the help
        if ($errText -ne $script:lastError) {
            $hint = if ($script:lastGood) { 'Showing the last known sprint.' } else { 'Click for setup help.' }
            $tray.ShowBalloonTip(10000, 'SprintTray: cannot read sprint', "$errText`n$hint", 'Warning')
        }
        $script:lastError = $errText
        # Fall back to the last sprint that loaded (null on a first run with no cache)
        $s = $script:lastGood
    }
    try {
        if (-not $s) { throw $script:lastError }
        $stale = [bool]$script:lastError
        $script:sprintName = $s.name
        $num = if ($s.name -match '(\d+)\D*$') { $Matches[1] } else { 'S' }
        $start = ([datetime]$s.startDate).ToLocalTime()
        $end = ([datetime]$s.endDate).ToLocalTime()
        # Progress is computed from the clock, so the bar keeps moving while Jira is unreachable
        $progress = [math]::Max(0.0, [math]::Min(1.0, ((Get-Date) - $start).TotalSeconds / ($end - $start).TotalSeconds))
        $days = [math]::Ceiling(($end - (Get-Date)).TotalDays)
        $label = if ($stale) { "$($s.name) (cached)" } else { $s.name }
        $tip = "$label - ends $($end.ToString('ddd dd.MM.')) ($days d left, $([int]($progress * 100))%)"
        # Grey glyph marks data that is not from the latest successful call
        $color = if ($stale) { [System.Drawing.Color]::FromArgb(128, 128, 128) } else { Get-TextColor }
        $newIcon = New-TextIcon $num $color $progress
    } catch {
        $tip = "Sprint: $($_.Exception.Message)"
        $newIcon = New-TextIcon '?' ([System.Drawing.Color]::FromArgb(190, 40, 40))
    }
    $old = $tray.Icon
    $tray.Icon = $newIcon
    $tray.Text = if ($tip.Length -gt 63) { $tip.Substring(0, 63) } else { $tip }
    if ($old) { $old.Dispose() }
}

$autoStartLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'SprintTray.lnk'

function Set-AutoStart([bool]$on) {
    if (-not $on) { if (Test-Path $autoStartLnk) { Remove-Item $autoStartLnk }; return }
    # Running as the exe: point at ourselves. Running as a script: launch it through the .vbs
    $self = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($autoStartLnk)
    if ($PSCommandPath) {
        $lnk.TargetPath = 'wscript.exe'
        $lnk.Arguments = "`"$(Join-Path $PSScriptRoot 'SprintTray.vbs')`""
        $lnk.WorkingDirectory = $PSScriptRoot
    } else {
        $lnk.TargetPath = $self
        $lnk.WorkingDirectory = Split-Path $self
    }
    $lnk.Save()
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
# Greyed-out header so the running version is visible without opening Help
$menu.Items.Add("SprintTray $version").Enabled = $false
$menu.Items.Add('Refresh', $null, { Update-Tray }) | Out-Null
$menu.Items.Add('Copy sprint name', $null, {
    if ($script:sprintName) { [System.Windows.Forms.Clipboard]::SetText($script:sprintName) }
}) | Out-Null
$menu.Items.Add('Help / status', $null, { Show-Help }) | Out-Null
$autoItem = New-Object System.Windows.Forms.ToolStripMenuItem 'Start with Windows'
$autoItem.CheckOnClick = $true
$autoItem.Checked = Test-Path $autoStartLnk
$autoItem.add_Click({
    try { Set-AutoStart $this.Checked } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'SprintTray') | Out-Null
        $this.Checked = Test-Path $autoStartLnk
    }
})
$menu.Items.Add($autoItem) | Out-Null
$menu.Items.Add('Exit', $null, {
    $tray.Visible = $false; $tray.Dispose(); [System.Windows.Forms.Application]::Exit()
}) | Out-Null
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ Update-Tray })
$tray.add_BalloonTipClicked({ Show-Help })

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $RefreshMinutes * 60 * 1000
$timer.add_Tick({ Update-Tray })
$timer.Start()

$script:lastGood = Get-LastSprint
Update-Tray
[System.Windows.Forms.Application]::Run()
