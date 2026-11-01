<#
  Widget.ps1 - desktop battery widget (inspired by the macOS "Batteries" widget)
  桌面电量小组件 (仿 macOS "电池" 小组件)

  - dark / light / follow-system appearance, size, opacity
  - data is read in a background runspace (UI never freezes)
  - tray icon: hover = all levels, left click = bring widget to front, right click = menu
  - low battery notifications, charging detection (reported by the device or inferred from rising levels)
  - settings: %APPDATA%\BatteryRings\widget.json, last known levels: last.json

  Start: double-click Widget.vbs (no console window)
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
# the widget redraws once per refresh; software rendering saves ~35 MB of Direct3D memory
[System.Windows.Media.RenderOptions]::ProcessRenderMode = 'SoftwareOnly'

$ScriptDir  = $PSScriptRoot
$MainScript = Join-Path $ScriptDir 'BatteryRings.ps1'
$IconFile   = Join-Path $ScriptDir 'assets\icon.ico'
$CfgDir     = Join-Path $env:APPDATA 'BatteryRings'
$CfgFile    = Join-Path $CfgDir 'widget.json'
$LastFile   = Join-Path $CfgDir 'last.json'
$StartupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'BatteryRings.lnk'

. (Join-Path $ScriptDir 'i18n.ps1')

# ---------- single instance ----------
$mutex = New-Object System.Threading.Mutex($false, 'Global\BatteryRingsWidget')
$owned = $false
try { $owned = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
if (-not $owned) { return }

# ---------- settings ----------
$cfg = [pscustomobject][ordered]@{
    Left = $null; Top = $null; Topmost = $false; Locked = $false
    Lang = 'auto'; Theme = 'auto'; Scale = 1.0; Opacity = 0.85
    Interval = 60; LowBattery = 20; ShowAsleep = $true; Hidden = @()
    CheckUpdates = $true; NotifiedVersion = ''; LastRunVersion = ''
}
if (Test-Path $CfgFile) {
    try {
        $saved = Get-Content $CfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    } catch { }
}
$cfg.Hidden = @($cfg.Hidden | Where-Object { $_ })
$script:Lang = Resolve-Lang $cfg.Lang

function Save-Config {
    if (-not (Test-Path $CfgDir)) { New-Item -ItemType Directory $CfgDir | Out-Null }
    $cfg.Left = $win.Left; $cfg.Top = $win.Top
    $cfg | ConvertTo-Json | Set-Content $CfgFile -Encoding UTF8
}

# ---------- themes ----------
$Themes = @{
    dark  = @{ Card = '#1C1C1E'; Text = '#F2F2F7'; Sub = '#8E8E93'; Track = '#3A3A3C'; Dim = '#636366'
               Green = '#30D158'; Yellow = '#FFD60A'; Red = '#FF453A'; Shadow = 0.45 }
    light = @{ Card = '#FFFFFF'; Text = '#1C1C1E'; Sub = '#6E6E73'; Track = '#E5E5EA'; Dim = '#AEAEB2'
               Green = '#34C759'; Yellow = '#FF9F0A'; Red = '#FF3B30'; Shadow = 0.22 }
}
function Get-SystemTheme {
    try {
        $v = Get-ItemPropertyValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' -ErrorAction Stop
        if ($v -eq 1) { 'light' } else { 'dark' }
    } catch { 'dark' }
}
function Resolve-Theme { if ($cfg.Theme -in 'dark', 'light') { $cfg.Theme } else { Get-SystemTheme } }
$script:themeName = Resolve-Theme
$script:T = $Themes[$script:themeName]

# ---------- Win32: hide from Alt+Tab, keep at the bottom of the z-order, device change notifications ----------
Add-Type -ReferencedAssemblies ([System.Windows.Interop.HwndSource].Assembly.Location), ([System.Windows.Threading.Dispatcher].Assembly.Location), 'System.Xaml' @'
using System; using System.Runtime.InteropServices;
public static class WidgetWin {
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    public static void ToolWindow(IntPtr h) { SetWindowLong(h, -20, GetWindowLong(h, -20) | 0x80); }   // WS_EX_TOOLWINDOW
    public static void SendToBottom(IntPtr h) { SetWindowPos(h, new IntPtr(1), 0, 0, 0, 0, 0x0013); }  // HWND_BOTTOM
    [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr p);
    // free garbage and hand unused pages back to Windows (the widget is idle between refreshes)
    public static void TrimMemory() {
        GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect();
        EmptyWorkingSet(System.Diagnostics.Process.GetCurrentProcess().Handle);
    }
    // WM_DEVICECHANGE is broadcast to every top-level window when devices are added or removed.
    public static int DeviceChanges;
    public static DateTime LastDeviceChange;
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO p);
    // tick count of the last keyboard / mouse input in the session (cheap, no hooks)
    public static uint LastInputTick() { var l = new LASTINPUTINFO(); l.cbSize = 8; GetLastInputInfo(ref l); return l.dwTime; }
    public static void HookDeviceChange(IntPtr hwnd) {
        System.Windows.Interop.HwndSource.FromHwnd(hwnd).AddHook(Hook);
    }
    static IntPtr Hook(IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) {
        if (msg == 0x0219) { DeviceChanges++; LastDeviceChange = DateTime.Now; }
        return IntPtr.Zero;
    }
}
'@

# ---------- window ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        SizeToContent="WidthAndHeight"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ResizeMode="NoResize" FontFamily="Microsoft YaHei UI, Segoe UI">
  <Border Name="Card" Width="276" CornerRadius="20" Margin="12" Padding="16,12,16,12">
    <StackPanel Name="List"/>
  </Border>
</Window>
'@
$win  = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$card = $win.FindName('Card')
$list = $win.FindName('List')
$cardBrush = New-Object System.Windows.Media.SolidColorBrush
$card.Background = $cardBrush
$shadow = New-Object System.Windows.Media.Effects.DropShadowEffect
$shadow.BlurRadius = 18; $shadow.ShadowDepth = 2
$card.Effect = $shadow
$scale = New-Object System.Windows.Media.ScaleTransform
$card.LayoutTransform = $scale

$win.Title = Tr 'app_title'
$win.Topmost = [bool]$cfg.Topmost

$wa = [System.Windows.SystemParameters]::WorkArea
if ($null -ne $cfg.Left -and $cfg.Left -ge $wa.Left - 200 -and $cfg.Left -lt $wa.Right - 50 -and $cfg.Top -ge $wa.Top - 50 -and $cfg.Top -lt $wa.Bottom - 50) {
    $win.Left = $cfg.Left; $win.Top = $cfg.Top
} else {
    $win.Left = $wa.Right - 300 - 8; $win.Top = $wa.Top + 8
}

# ---------- drawing helpers ----------
$bc = New-Object System.Windows.Media.BrushConverter
function Brush($hex) { $bc.ConvertFromString($hex) }
$IconFont = New-Object System.Windows.Media.FontFamily('Segoe Fluent Icons, Segoe MDL2 Assets')

function Test-Charging($r) { $r.Status -in 'charging', 'charging_guess', 'ac' }

function Get-LevelBrush($v, $charging) {
    if ($null -eq $v) { return (Brush $T.Dim) }
    if ($charging)    { return (Brush $T.Green) }
    if ($v -le 20)    { return (Brush $T.Red) }
    if ($v -le 50)    { return (Brush $T.Yellow) }
    Brush $T.Green
}

function Get-DeviceGlyph($r) {
    $kind = $r.Kind
    if (-not $kind) {
        $n = "$($r.Name)"
        $kind = if ($n -match 'Controller|Gamepad|手柄|Xbox|DualSense') { 'gamepad' }
                elseif ($n -match 'Keyboard|键盘') { 'keyboard' }
                elseif ($n -match 'Mouse|鼠标') { 'mouse' }
                elseif ($n -match 'Head|耳机|Buds|AirPods|Earphone') { 'headset' }
                else { '' }
    }
    switch ($kind) {
        'laptop'   { [char]0xE7F8 }
        'gamepad'  { [char]0xE7FC }
        'keyboard' { [char]0xE92E }
        'mouse'    { [char]0xE962 }
        'headset'  { [char]0xE7F6 }
        default    { [char]0xE702 }
    }
}

function New-TextBlock($text, $color, $size) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.Foreground = Brush $color; $t.FontSize = $size
    $t
}

function New-Ring($value, $brush, $glyph, $dimIcon) {
    $size = 40.0; $th = 4.0; $rad = ($size - $th) / 2; $c = $size / 2
    $g = New-Object System.Windows.Controls.Grid
    $g.Width = $size; $g.Height = $size

    $bg = New-Object System.Windows.Shapes.Ellipse
    $bg.Stroke = Brush $T.Track; $bg.StrokeThickness = $th
    [void]$g.Children.Add($bg)

    if ($null -ne $value -and $value -gt 0) {
        if ($value -ge 100) {
            $arc = New-Object System.Windows.Shapes.Ellipse
        } else {
            $ang = [math]::PI * 2 * $value / 100 - [math]::PI / 2
            $fig = New-Object System.Windows.Media.PathFigure
            $fig.StartPoint = New-Object System.Windows.Point($c, ($c - $rad))
            $seg = New-Object System.Windows.Media.ArcSegment
            $seg.Point = New-Object System.Windows.Point(($c + $rad * [math]::Cos($ang)), ($c + $rad * [math]::Sin($ang)))
            $seg.Size = New-Object System.Windows.Size($rad, $rad)
            $seg.IsLargeArc = $value -gt 50
            $seg.SweepDirection = 'Clockwise'
            [void]$fig.Segments.Add($seg)
            $geo = New-Object System.Windows.Media.PathGeometry
            [void]$geo.Figures.Add($fig)
            $arc = New-Object System.Windows.Shapes.Path
            $arc.Data = $geo
            $arc.StrokeStartLineCap = 'Round'; $arc.StrokeEndLineCap = 'Round'
        }
        $arc.Stroke = $brush; $arc.StrokeThickness = $th
        [void]$g.Children.Add($arc)
    }

    $ic = New-TextBlock $glyph $(if ($dimIcon) { $T.Sub } else { $T.Text }) 16
    $ic.FontFamily = $IconFont
    $ic.HorizontalAlignment = 'Center'; $ic.VerticalAlignment = 'Center'
    [void]$g.Children.Add($ic)
    $g
}

# 'yyyy-MM-dd HH:mm' -> 'HH:mm' (today) or 'M/d HH:mm'
function Format-LastTime($s) {
    try {
        $t = [datetime]::ParseExact($s, 'yyyy-MM-dd HH:mm', $null)
        if ($t.Date -eq (Get-Date).Date) { $t.ToString('HH:mm') } else { $t.ToString('M/d HH:mm') }
    } catch { $s }
}

function New-DeviceRow($r) {
    $charging = Test-Charging $r
    $stale = $null -eq $r.Level -and $null -ne $r.Last
    $level = if ($stale) { $r.Last } else { $r.Level }
    $brush = if ($stale) { Brush $T.Sub } else { Get-LevelBrush $r.Level $charging }

    $row = New-Object System.Windows.Controls.Grid
    $row.Margin = '0,4,0,4'
    foreach ($w in 'Auto', '*', 'Auto') {
        $cd = New-Object System.Windows.Controls.ColumnDefinition
        $cd.Width = (New-Object System.Windows.GridLengthConverter).ConvertFromString($w)
        [void]$row.ColumnDefinitions.Add($cd)
    }

    $ring = New-Ring $level $brush (Get-DeviceGlyph $r) ($null -eq $r.Level)
    [System.Windows.Controls.Grid]::SetColumn($ring, 0)
    [void]$row.Children.Add($ring)

    $txt = New-Object System.Windows.Controls.StackPanel
    $txt.Margin = '12,0,8,0'; $txt.VerticalAlignment = 'Center'
    $name = New-TextBlock $r.Name $T.Text 13
    $name.TextTrimming = 'CharacterEllipsis'
    [void]$txt.Children.Add($name)
    $sub = Format-Connection $r.Connection
    if ($stale) { $sub = "$sub · " + (Tr 'asleep_last' (Format-LastTime $r.LastTime)) }
    elseif ($r.Status) { $sub = "$sub · " + (Format-Status $r.Status) }
    $subText = New-TextBlock $sub $T.Sub 10.5
    $subText.TextTrimming = 'CharacterEllipsis'
    [void]$txt.Children.Add($subText)
    [System.Windows.Controls.Grid]::SetColumn($txt, 1)
    [void]$row.Children.Add($txt)

    $pctText = if ($null -eq $level) { '--' } elseif ($charging -and -not $stale) { "⚡$level%" } else { "$level%" }
    $pct = New-TextBlock $pctText $(if ($null -eq $r.Level) { $T.Sub } else { $T.Text }) 17
    $pct.FontWeight = 'SemiBold'; $pct.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($pct, 2)
    [void]$row.Children.Add($pct)

    $row.ToolTip = "$($r.Name)`n$(Tr 'source'): $($r.Source)"
    $row
}

function Show-Message($text) {
    $list.Children.Clear()
    [void]$list.Children.Add((New-TextBlock $text $T.Sub 12))
}

function Render {
    if ($null -eq $script:rows) { Show-Message (Tr 'loading'); return }
    $rows = @($script:rows | Where-Object { $cfg.Hidden -notcontains $_.Name })
    if (-not $cfg.ShowAsleep) { $rows = @($rows | Where-Object { $null -ne $_.Level }) }
    if (-not $rows.Count) { Show-Message (Tr 'none'); return }
    $list.Children.Clear()
    $sorted = $rows | Sort-Object @{ e = { $null -eq $_.Level -and $null -eq $_.Last } }, @{ e = { if ($null -ne $_.Level) { $_.Level } else { $_.Last } } }
    foreach ($r in $sorted) { [void]$list.Children.Add((New-DeviceRow $r)) }
}

function Apply-Appearance {
    $script:themeName = Resolve-Theme
    $script:T = $Themes[$script:themeName]
    $cardBrush.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($T.Card)
    $cardBrush.Opacity = [double]$cfg.Opacity
    $shadow.Opacity = $T.Shadow
    $scale.ScaleX = [double]$cfg.Scale; $scale.ScaleY = [double]$cfg.Scale
    Render
}

# ---------- state: last known levels, charging inference, notifications ----------
$script:lastKnown = @{}
if (Test-Path $LastFile) {
    try {
        (Get-Content $LastFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
            ForEach-Object { $script:lastKnown[$_.Name] = @{ Level = $_.Value.Level; Time = $_.Value.Time } }
    } catch { }
}
$script:history  = @{}   # name -> list of @{ T; L } within the last 30 minutes
$script:chargeOn = @{}   # name -> $true while a rising level was observed
$script:notified = @{}   # name -> $true after a low battery alert

# Devices that do not report charging: a level that rose by >= 2 points within 30 minutes = charging.
# A falling level resets the history. Reaching 100 % while "charging" shows "full".
function Update-ChargeGuess($r) {
    if ($null -eq $r.Level) { return }
    $now = Get-Date
    if (-not $script:history.ContainsKey($r.Name)) { $script:history[$r.Name] = New-Object System.Collections.ArrayList }
    $h = $script:history[$r.Name]
    if ($h.Count -and $r.Level -lt $h[$h.Count - 1].L) { $h.Clear(); $script:chargeOn.Remove($r.Name) }
    [void]$h.Add(@{ T = $now; L = $r.Level })
    while ($h.Count -gt 1 -and ($now - $h[0].T).TotalMinutes -gt 30) { $h.RemoveAt(0) }
    if ($r.Status) { return }                     # the protocol already reports a state
    if ($h.Count -ge 2 -and ($r.Level - $h[0].L) -ge 2) { $script:chargeOn[$r.Name] = $true }
    if ($script:chargeOn[$r.Name]) { $r.Status = if ($r.Level -ge 100) { 'full' } else { 'charging_guess' } }
}

function Test-LowBattery($rows) {
    if (-not $cfg.LowBattery) { return }
    foreach ($r in $rows) {
        if ($null -eq $r.Level -or $cfg.Hidden -contains $r.Name -or $r.Kind -eq 'laptop') { continue }
        $charging = (Test-Charging $r) -or $r.Status -eq 'full'
        if ($r.Level -le $cfg.LowBattery -and -not $charging) {
            if (-not $script:notified[$r.Name]) {
                $tray.ShowBalloonTip(8000, (Tr 'low_title'), (Tr 'low_text' $r.Name $r.Level), [System.Windows.Forms.ToolTipIcon]::Warning)
                $script:notified[$r.Name] = $true
            }
        } elseif ($charging -or $r.Level -gt $cfg.LowBattery + 5) { $script:notified.Remove($r.Name) }
    }
}

function Update-TrayText {
    $parts = foreach ($r in $script:rows | Where-Object { $null -ne $_.Level -and $cfg.Hidden -notcontains $_.Name }) {
        $n = if ($r.Name.Length -gt 14) { $r.Name.Substring(0, 13) + '…' } else { $r.Name }
        "$n $($r.Level)%"
    }
    $text = if ($parts) { $parts -join "`n" } else { Tr 'app_title' }
    if ($text.Length -gt 63) { $text = $text.Substring(0, 62) + '…' }   # NotifyIcon limit
    $tray.Text = $text
}

$script:lastSig = $null     # JSON of the last rows shown; identical data is not redrawn
$script:lastSaved = $null   # JSON of last.json as written
function Receive-Rows($rows) {
    foreach ($r in $rows) {
        Update-ChargeGuess $r
        if ($null -ne $r.Level) {
            $script:lastKnown[$r.Name] = @{ Level = $r.Level; Time = (Get-Date -Format 'yyyy-MM-dd HH:mm') }
        } elseif ($script:lastKnown.ContainsKey($r.Name)) {
            $k = $script:lastKnown[$r.Name]
            $r | Add-Member -NotePropertyName Last -NotePropertyValue $k.Level -Force
            $r | Add-Member -NotePropertyName LastTime -NotePropertyValue $k.Time -Force
        }
    }
    $known = $script:lastKnown | ConvertTo-Json -Compress
    if ($known -ne $script:lastSaved) {           # at most once a minute (timestamps have minute precision)
        try {
            if (-not (Test-Path $CfgDir)) { New-Item -ItemType Directory $CfgDir | Out-Null }
            $script:lastKnown | ConvertTo-Json | Set-Content $LastFile -Encoding UTF8
            $script:lastSaved = $known
        } catch { }
    }
    $script:rows = $rows
    $script:updated = Get-Date
    $asleep = @($rows | Where-Object { $null -eq $_.Level -and $_.Status -eq 'asleep' }).Count
    if ($script:refreshWasWake) {
        $script:wakeGap = if ($asleep -lt $script:asleepCount) { 3 } else { [math]::Min(60, $script:wakeGap * 2) }
    } elseif ($asleep -ne $script:asleepCount) { $script:wakeGap = 3 }
    $script:asleepCount = $asleep
    $sig = ConvertTo-Json -InputObject @($rows) -Compress
    if ($sig -eq $script:lastSig) { return }      # nothing changed since the last refresh
    $script:lastSig = $sig
    Update-TrayText
    Test-LowBattery $rows
    Render
}

# ---------- background refresh ----------
# One persistent runspace: BatteryRings.ps1 is loaded once (-Lib), then each refresh only calls Get-AllBattery.
# Creating a fresh runspace per refresh re-imports the PnP/CIM modules every time and costs ~100 MB.
$script:rows = $null
$script:job = $null
$script:ps  = $null
$script:rs  = $null
$script:updated = $null
$script:lastTrim = [datetime]::MinValue
function Start-Refresh([switch]$Fresh, [switch]$Wake) {
    if ($script:job) { if ($Fresh) { $script:freshPending = $true }; return }
    if (-not $script:rs -or $script:rs.RunspaceStateInfo.State -ne 'Opened') {
        $script:rs = [runspacefactory]::CreateRunspace()
        $script:rs.Open()
        $init = [powershell]::Create(); $init.Runspace = $script:rs
        [void]$init.AddScript(". '$($MainScript.Replace("'", "''"))' -Lib").Invoke()
        $init.Dispose()
    }
    $script:ps = [powershell]::Create()
    $script:ps.Runspace = $script:rs
    [void]$script:ps.AddScript('param($l, $f, $w) $script:Lang = $l; ConvertTo-Json -InputObject @(Get-AllBattery -Fresh:$f -Wake:$w) -Compress').AddArgument($script:Lang).AddArgument([bool]$Fresh).AddArgument([bool]$Wake)
    $script:refreshWasWake = [bool]$Wake
    $script:job = $script:ps.BeginInvoke()
    $poll.Start()
}

$poll = New-Object System.Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromMilliseconds(250)
$poll.Add_Tick({
    if (-not $script:job -or -not $script:job.IsCompleted) { return }
    $poll.Stop()
    try {
        $out = $script:ps.EndInvoke($script:job) | Out-String
        $rows = @()
        if ($out.Trim()) { $rows = @(($out | ConvertFrom-Json) | ForEach-Object { $_ }) }
        Receive-Rows $rows
    } catch {
        if ($null -eq $script:rows) { Show-Message (Tr 'failed' $_.Exception.Message) }
        try { $script:rs.Dispose() } catch { }; $script:rs = $null    # rebuild the runspace next time
    } finally {
        $script:ps.Dispose(); $script:ps = $null; $script:job = $null
        # trimming pages them out; doing it every few seconds would just page them back in
        if (((Get-Date) - $script:lastTrim).TotalSeconds -ge 120) { [WidgetWin]::TrimMemory(); $script:lastTrim = Get-Date }
    }
})

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds([math]::Max(5, [int]$cfg.Interval))
$timer.Add_Tick({ Start-Refresh })
$timer.Start()

# refresh right after a device is plugged in / removed / (dis)connected via Bluetooth,
# once Windows has been quiet for 1.5 s (a single plug-in sends several notifications)
$script:seenChanges = 0
$script:freshPending = $false
$script:lastInput = [WidgetWin]::LastInputTick()
$script:lastWake = [datetime]::MinValue
$script:wakeGap = 3          # seconds; doubles (max 60) while woken-up probes find nothing new
$script:asleepCount = 0
$script:refreshWasWake = $false
$devWatch = New-Object System.Windows.Threading.DispatcherTimer
$devWatch.Interval = [TimeSpan]::FromMilliseconds(500)
$devWatch.Add_Tick({
    if ([WidgetWin]::DeviceChanges -ne $script:seenChanges) { $script:seenChanges = [WidgetWin]::DeviceChanges; $script:freshPending = $true }
    if ($script:freshPending -and -not $script:job -and ((Get-Date) - [WidgetWin]::LastDeviceChange).TotalMilliseconds -gt 1500) {
        $script:freshPending = $false
        Start-Refresh -Fresh
        return
    }
    # wake-up: keyboard / mouse input while a device is asleep -> ask it again right away
    $li = [WidgetWin]::LastInputTick()
    if ($li -ne $script:lastInput) {
        $script:lastInput = $li
        if (-not $script:job -and $script:asleepCount -gt 0 -and ((Get-Date) - $script:lastWake).TotalSeconds -ge $script:wakeGap) {
            $script:lastWake = Get-Date
            Start-Refresh -Wake
        }
    }
})
$devWatch.Start()

# follow the system light/dark setting
$themeWatch = New-Object System.Windows.Threading.DispatcherTimer
$themeWatch.Interval = [TimeSpan]::FromSeconds(5)
$themeWatch.Add_Tick({ if ($cfg.Theme -eq 'auto' -and (Get-SystemTheme) -ne $script:themeName) { Apply-Appearance } })
$themeWatch.Start()

# ---------- tray icon ----------
$tray = New-Object System.Windows.Forms.NotifyIcon
try { $tray.Icon = New-Object System.Drawing.Icon($IconFile, 16, 16) } catch { $tray.Icon = [System.Drawing.SystemIcons]::Information }
$tray.Text = Tr 'app_title'
$tray.Visible = $true

function Show-Front {
    $win.Topmost = $true
    [void]$win.Activate()
    if (-not $cfg.Topmost) { $win.Topmost = $false }   # stays in front until another window is activated
}
$tray.Add_MouseUp({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Front }
    elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        [void]$win.Activate()
        $win.ContextMenu.PlacementTarget = $null
        $win.ContextMenu.Placement = 'MousePoint'
        $win.ContextMenu.IsOpen = $true
    }
})

# ---------- updates (GitHub Releases) ----------
$script:Version = '0.0.0'; $script:Repo = $null
try {
    $vj = Get-Content (Join-Path $ScriptDir 'version.json') -Raw | ConvertFrom-Json
    $script:Version = $vj.Version; $script:Repo = $vj.Repo
} catch { }
$script:UpdateEnabled = [bool]($script:Repo -and $script:Repo -notmatch '^YOUR_')
$script:update   = $null    # @{ Tag; Url; Page } when a newer release exists
$script:updState = ''       # '' | checking | latest | failed | downloading
$script:updPs = $null; $script:updJob = $null; $script:updManual = $false; $script:updKind = ''

function Start-UpdateJob([string]$kind, [scriptblock]$code, $arg) {
    if ($script:updJob) { return }
    $script:updKind = $kind
    $script:updPs = [powershell]::Create()
    [void]$script:updPs.AddScript($code).AddArgument($arg)
    $script:updJob = $script:updPs.BeginInvoke()
    $updPoll.Start()
}

function Start-UpdateCheck([switch]$Manual) {
    if (-not $script:UpdateEnabled -or $script:updJob) { return }
    $script:updManual = [bool]$Manual
    $script:updState = 'checking'
    Start-UpdateJob 'check' {
        param($repo)
        # github.com/<repo>/releases/latest redirects to .../releases/tag/<tag>. Reading the redirect needs no
        # API call, so the 60 requests/hour API limit for anonymous users does not apply.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [Net.HttpWebRequest]::Create("https://github.com/$repo/releases/latest")
        $req.AllowAutoRedirect = $false; $req.Method = 'HEAD'; $req.UserAgent = 'BatteryRings'; $req.Timeout = 20000
        $resp = $req.GetResponse()
        try { $loc = $resp.Headers['Location'] } finally { $resp.Close() }
        if ($loc -notmatch '/releases/tag/([^/?#]+)') { throw 'no release' }
        $tag = [Uri]::UnescapeDataString($Matches[1])
        [pscustomobject]@{
            Tag  = $tag
            Url  = "https://github.com/$repo/releases/download/$tag/BatteryRings.zip"
            Page = "https://github.com/$repo/releases/tag/$tag"
        }
    } $script:Repo
}

# download the release zip, extract it and run its installer in update mode (it restarts the widget)
function Install-Update {
    if (-not $script:update -or $script:updJob) { return }
    $script:updState = 'downloading'
    Build-Menu
    Start-UpdateJob 'install' {
        param($url)
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $dir = Join-Path $env:TEMP 'BatteryRings-update'
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        New-Item -ItemType Directory $dir | Out-Null
        $zip = Join-Path $dir 'BatteryRings.zip'
        (New-Object Net.WebClient).DownloadFile($url, $zip)
        Expand-Archive $zip (Join-Path $dir 'x') -Force
        $inst = Get-ChildItem (Join-Path $dir 'x') -Recurse -Filter 'Install.ps1' | Select-Object -First 1
        if (-not $inst) { throw 'Install.ps1 not found in the release' }
        Get-ChildItem (Join-Path $dir 'x') -Recurse -File | Unblock-File
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($inst.FullName)`"", '-Update')
        'ok'
    } $script:update.Url
}

$updPoll = New-Object System.Windows.Threading.DispatcherTimer
$updPoll.Interval = [TimeSpan]::FromMilliseconds(500)
$updPoll.Add_Tick({
    if (-not $script:updJob -or -not $script:updJob.IsCompleted) { return }
    $updPoll.Stop()
    try {
        $res = @($script:updPs.EndInvoke($script:updJob))[0]
        if ($script:updPs.HadErrors -or -not $res) { throw 'failed' }
        if ($script:updKind -eq 'check') {
            $v = [version]($res.Tag.TrimStart('v', 'V'))
            if ($v -gt [version]$script:Version -and $res.Url) {
                $script:update = $res; $script:updState = ''
                if ($script:updManual -or $cfg.NotifiedVersion -ne $res.Tag) {
                    $tray.ShowBalloonTip(10000, (Tr 'update_title' $res.Tag), (Tr 'update_text'), [System.Windows.Forms.ToolTipIcon]::Info)
                    $cfg.NotifiedVersion = $res.Tag; Save-Config
                }
            } else {
                $script:update = $null; $script:updState = 'latest'
                if ($script:updManual) { $tray.ShowBalloonTip(5000, 'BatteryRings', (Tr 'update_latest' "v$($script:Version)"), [System.Windows.Forms.ToolTipIcon]::Info) }
            }
        }
    } catch {
        $script:updState = 'failed'
        if ($script:updManual -or $script:updKind -eq 'install') {
            $tray.ShowBalloonTip(5000, 'BatteryRings', (Tr 'update_failed'), [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    } finally {
        $script:updPs.Dispose(); $script:updPs = $null; $script:updJob = $null
        Build-Menu
    }
})

# first check 20 s after start, then once a day
$updTimer = New-Object System.Windows.Threading.DispatcherTimer
$updTimer.Interval = [TimeSpan]::FromSeconds(20)
$updTimer.Add_Tick({
    $updTimer.Interval = [TimeSpan]::FromHours(24)
    if ($cfg.CheckUpdates) { Start-UpdateCheck }
})
if ($script:UpdateEnabled) { $updTimer.Start() }

# ---------- settings menu actions ----------
function Format-Interval([int]$s) { if ($s % 60 -eq 0) { Tr 'interval_min' ($s / 60) } else { Tr 'interval_sec' $s } }

# Small themed dialog asking for the refresh interval in seconds. Returns the value, or $null when cancelled.
function Read-Interval {
    [xml]$x = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" SizeToContent="WidthAndHeight"
        ShowInTaskbar="False" ResizeMode="NoResize" Topmost="True" FontFamily="Microsoft YaHei UI, Segoe UI">
  <Border Name="Box" CornerRadius="14" Padding="20,16,20,16" Margin="12" Width="280">
    <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.4"/></Border.Effect>
    <StackPanel>
      <TextBlock Name="Title" FontSize="15" FontWeight="SemiBold"/>
      <TextBlock Name="Hint" FontSize="11.5" TextWrapping="Wrap" Margin="0,4,0,0"/>
      <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
        <TextBox Name="Input" Width="90" FontSize="14" Padding="6,3" BorderThickness="1"/>
        <TextBlock Name="Unit" FontSize="13" VerticalAlignment="Center" Margin="8,0,0,0"/>
      </StackPanel>
      <TextBlock Name="Err" FontSize="11" Margin="0,6,0,0" Visibility="Collapsed"/>
      <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button Name="Cancel" MinWidth="72" Margin="0,0,8,0" Padding="10,4" IsCancel="True"/>
        <Button Name="Ok" MinWidth="72" Padding="10,4" IsDefault="True"/>
      </StackPanel>
    </StackPanel>
  </Border>
</Window>
'@
    $script:dlg = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $x))
    $d = $script:dlg
    $d.FindName('Box').Background = Brush $T.Card
    $d.FindName('Title').Text = Tr 'interval_prompt'; $d.FindName('Title').Foreground = Brush $T.Text
    $d.FindName('Hint').Text = Tr 'interval_hint';    $d.FindName('Hint').Foreground = Brush $T.Sub
    $d.FindName('Unit').Text = Tr 'unit_sec';         $d.FindName('Unit').Foreground = Brush $T.Text
    $err = $d.FindName('Err'); $err.Text = Tr 'interval_invalid'; $err.Foreground = Brush $T.Red
    $script:dlgInput = $d.FindName('Input')
    $script:dlgInput.Text = "$($cfg.Interval)"
    $script:dlgInput.Background = Brush $T.Track; $script:dlgInput.Foreground = Brush $T.Text; $script:dlgInput.BorderBrush = Brush $T.Dim
    $d.FindName('Cancel').Content = Tr 'btn_cancel'
    $d.FindName('Ok').Content = Tr 'btn_ok'
    foreach ($bn in 'Cancel', 'Ok') {
        $btn = $d.FindName($bn)
        $btn.Background = if ($bn -eq 'Ok') { Brush $T.Green } else { Brush $T.Track }
        $btn.Foreground = if ($bn -eq 'Ok') { Brush '#FFFFFF' } else { Brush $T.Text }
        $btn.BorderThickness = 0
    }
    $d.FindName('Ok').Add_Click({
        $v = 0
        if ([int]::TryParse($script:dlgInput.Text.Trim(), [ref]$v) -and $v -ge 5 -and $v -le 3600) {
            $script:dlg.Tag = $v; $script:dlg.DialogResult = $true
        } else {
            $script:dlg.FindName('Err').Visibility = 'Visible'
            $script:dlgInput.SelectAll(); [void]$script:dlgInput.Focus()
        }
    })
    $d.Add_MouseLeftButtonDown({ try { $script:dlg.DragMove() } catch { } })
    $d.Add_ContentRendered({ $script:dlgInput.SelectAll(); [void]$script:dlgInput.Focus() })
    $d.Left = $win.Left + ($win.ActualWidth - 304) / 2   # centred on the widget
    $d.Top = $win.Top + 20
    if ($d.ShowDialog()) { return [int]$d.Tag }
    $null
}

function Set-Autostart([bool]$on) {
    if ($on) {
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut($StartupLnk)
        $lnk.TargetPath = Join-Path $env:WINDIR 'System32\wscript.exe'
        $lnk.Arguments = '"' + (Join-Path $ScriptDir 'Widget.vbs') + '"'
        $lnk.WorkingDirectory = $ScriptDir
        $lnk.IconLocation = $IconFile
        $lnk.Save()
    } elseif (Test-Path $StartupLnk) { Remove-Item $StartupLnk -Force }
}

function Set-Setting([string]$key, $value) {
    switch ($key) {
        'Lang'       { $cfg.Lang = $value; $script:Lang = Resolve-Lang $value; $win.Title = Tr 'app_title'; Start-Refresh }
        'Theme'      { $cfg.Theme = $value }
        'Scale'      { $cfg.Scale = [double]$value }
        'Opacity'    { $cfg.Opacity = [double]$value }
        'Interval'   { $cfg.Interval = [int]$value; $timer.Interval = [TimeSpan]::FromSeconds([int]$value) }
        'IntervalCustom' { $v = Read-Interval; if ($v) { Set-Setting 'Interval' $v }; return }
        'LowBattery' { $cfg.LowBattery = [int]$value; $script:notified = @{} }
        'Hide'       { $cfg.Hidden = if ($cfg.Hidden -contains $value) { @($cfg.Hidden | Where-Object { $_ -ne $value }) } else { @($cfg.Hidden) + $value } }
        'ShowAll'    { $cfg.Hidden = @() }
        'ShowAsleep' { $cfg.ShowAsleep = -not $cfg.ShowAsleep }
        'Locked'     { $cfg.Locked = -not $cfg.Locked }
        'Topmost'    { $cfg.Topmost = -not $cfg.Topmost; $win.Topmost = $cfg.Topmost; if (-not $cfg.Topmost) { [WidgetWin]::SendToBottom($script:hwnd) } }
        'Autostart'  { Set-Autostart (-not (Test-Path $StartupLnk)) }
        'Refresh'    { Start-Refresh; return }
        'Update'     { Install-Update; return }
        'UpdateCheck' { Start-UpdateCheck -Manual; return }
        'UpdateAuto' { $cfg.CheckUpdates = -not $cfg.CheckUpdates }
        'Exit'       { $win.Close(); return }
    }
    Save-Config
    Build-Menu
    Apply-Appearance
    Update-TrayText
}

# Menu items carry @{ Key; Value } in Tag; one shared click handler calls Set-Setting.
$OnMenuClick = { Set-Setting $this.Tag.Key $this.Tag.Value }
function New-MenuItem($header, $key, $value, $checked) {
    $mi = New-Object System.Windows.Controls.MenuItem
    $mi.Header = $header
    if ($key) { $mi.Tag = @{ Key = $key; Value = $value }; $mi.Add_Click($OnMenuClick) }
    if ($null -ne $checked) { $mi.IsChecked = [bool]$checked }
    $mi
}
function New-ChoiceMenu($header, $key, $current, $choices) {
    $parent = New-MenuItem $header $null $null $null
    foreach ($c in $choices) { [void]$parent.Items.Add((New-MenuItem $c[1] $key $c[0] ("$current" -eq "$($c[0])"))) }
    $parent
}

function Build-Menu {
    $m = New-Object System.Windows.Controls.ContextMenu

    $script:miUpdated = New-MenuItem '' $null $null $null
    $script:miUpdated.IsEnabled = $false
    [void]$m.Items.Add($script:miUpdated)
    if ($script:update) {
        $label = if ($script:updState -eq 'downloading') { Tr 'update_downloading' } else { Tr 'update_install' $script:update.Tag }
        $mi = New-MenuItem $label 'Update' $null $null
        $mi.FontWeight = 'SemiBold'
        $mi.IsEnabled = $script:updState -ne 'downloading'
        [void]$m.Items.Add($mi)
    }
    [void]$m.Items.Add((New-MenuItem (Tr 'menu_refresh') 'Refresh' $null $null))
    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))

    [void]$m.Items.Add((New-ChoiceMenu (Tr 'menu_theme') 'Theme' $cfg.Theme @(
        @('auto', (Tr 'theme_auto')), @('dark', (Tr 'theme_dark')), @('light', (Tr 'theme_light')))))
    [void]$m.Items.Add((New-ChoiceMenu (Tr 'menu_size') 'Scale' $cfg.Scale @(
        @(0.85, (Tr 'size_s')), @(1.0, (Tr 'size_m')), @(1.2, (Tr 'size_l')))))
    [void]$m.Items.Add((New-ChoiceMenu (Tr 'menu_opacity') 'Opacity' $cfg.Opacity @(
        @(0.6, '60%'), @(0.75, '75%'), @(0.85, '85%'), @(1.0, '100%'))))
    $iv = New-ChoiceMenu (Tr 'menu_interval') 'Interval' $cfg.Interval @(
        @(5, (Tr 'interval_sec' 5)), @(10, (Tr 'interval_sec' 10)), @(30, (Tr 'interval_sec' 30)),
        @(60, (Tr 'interval_min' 1)), @(300, (Tr 'interval_min' 5)))
    $isCustom = [int]$cfg.Interval -notin 5, 10, 30, 60, 300
    $customLabel = if ($isCustom) { Tr 'interval_custom_cur' (Format-Interval $cfg.Interval) } else { Tr 'interval_custom' }
    [void]$iv.Items.Add((New-Object System.Windows.Controls.Separator))
    [void]$iv.Items.Add((New-MenuItem $customLabel 'IntervalCustom' $null $isCustom))
    [void]$m.Items.Add($iv)
    [void]$m.Items.Add((New-ChoiceMenu (Tr 'menu_lowbatt') 'LowBattery' $cfg.LowBattery @(
        @(0, (Tr 'lowbatt_off')), @(10, '10%'), @(20, '20%'), @(30, '30%'))))

    $hide = New-MenuItem (Tr 'menu_hidden') $null $null $null
    $names = @(@($script:rows | ForEach-Object { $_.Name }) + $cfg.Hidden | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($n in $names) { [void]$hide.Items.Add((New-MenuItem $n 'Hide' $n ($cfg.Hidden -contains $n))) }
    if ($names.Count) { [void]$hide.Items.Add((New-Object System.Windows.Controls.Separator)) }
    [void]$hide.Items.Add((New-MenuItem (Tr 'show_all') 'ShowAll' $null $null))
    [void]$m.Items.Add($hide)

    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
    [void]$m.Items.Add((New-MenuItem (Tr 'menu_asleep') 'ShowAsleep' $null $cfg.ShowAsleep))
    [void]$m.Items.Add((New-MenuItem (Tr 'menu_lock') 'Locked' $null $cfg.Locked))
    [void]$m.Items.Add((New-MenuItem (Tr 'menu_topmost') 'Topmost' $null $cfg.Topmost))
    [void]$m.Items.Add((New-MenuItem (Tr 'menu_autostart') 'Autostart' $null (Test-Path $StartupLnk)))
    [void]$m.Items.Add((New-ChoiceMenu (Tr 'menu_language') 'Lang' $cfg.Lang @(
        @('auto', (Tr 'menu_lang_auto')), @('zh', '中文'), @('en', 'English'))))
    if ($script:UpdateEnabled) {
        [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
        $chk = switch ($script:updState) {
            'checking' { Tr 'update_checking' } 'latest' { Tr 'update_latest' "v$($script:Version)" }
            'failed' { Tr 'update_failed' } default { Tr 'menu_update_check' } }
        [void]$m.Items.Add((New-MenuItem $chk 'UpdateCheck' $null $null))
        [void]$m.Items.Add((New-MenuItem (Tr 'menu_update_auto') 'UpdateAuto' $null $cfg.CheckUpdates))
    }
    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
    $ab = New-MenuItem (Tr 'about' "v$($script:Version)") $null $null $null
    $ab.IsEnabled = $false
    [void]$m.Items.Add($ab)
    [void]$m.Items.Add((New-Object System.Windows.Controls.Separator))
    [void]$m.Items.Add((New-MenuItem (Tr 'menu_exit') 'Exit' $null $null))

    $m.Add_Opened({
        $script:miUpdated.Header = if ($script:updated) { Tr 'updated' ($script:updated.ToString('HH:mm:ss')) } else { Tr 'loading' }
    })
    $win.ContextMenu = $m
}

# ---------- window events ----------
$win.Add_MouseLeftButtonDown({ if (-not $cfg.Locked) { try { $win.DragMove() } catch { }; Save-Config } })
# behave like a desktop widget: sink below other windows when it loses focus
$win.Add_Deactivated({ if (-not $cfg.Topmost -and $script:hwnd) { [WidgetWin]::SendToBottom($script:hwnd) } })
$win.Add_SourceInitialized({
    $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
    [WidgetWin]::ToolWindow($script:hwnd)
    [WidgetWin]::HookDeviceChange($script:hwnd)
    if (-not $win.Topmost) { [WidgetWin]::SendToBottom($script:hwnd) }
})
$win.Add_Loaded({
    Start-Refresh
    # first start after an update: say so
    if ($cfg.LastRunVersion -and $cfg.LastRunVersion -ne $script:Version) {
        $tray.ShowBalloonTip(5000, 'BatteryRings', (Tr 'update_done' "v$($script:Version)"), [System.Windows.Forms.ToolTipIcon]::Info)
    }
    if ($cfg.LastRunVersion -ne $script:Version) { $cfg.LastRunVersion = $script:Version; Save-Config }
})
$win.Add_Closed({
    Save-Config
    $timer.Stop(); $poll.Stop(); $themeWatch.Stop(); $devWatch.Stop(); $updTimer.Stop(); $updPoll.Stop()
    if ($script:rs) { try { $script:rs.Dispose() } catch { } }
    $tray.Visible = $false; $tray.Dispose()
    try { $mutex.ReleaseMutex() } catch { }
})

Build-Menu
Apply-Appearance
[void]$win.ShowDialog()
