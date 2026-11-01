<#
.SYNOPSIS
  BatteryRings - battery levels of wireless devices connected to this PC.
  无线设备电量 - 显示连接到本机的无线设备电量。

.EXAMPLE
  .\BatteryRings.ps1              # print once / 显示一次
  .\BatteryRings.ps1 -Watch       # refresh every 30 s / 每 30 秒刷新
  .\BatteryRings.ps1 -Json        # JSON output (used by the widget) / 输出 JSON
  .\BatteryRings.ps1 -Diag        # list HID devices for bug reports (read-only) / 诊断信息
  .\BatteryRings.ps1 -Lang en     # force language: auto | zh | en

  Options: -NoGatt (skip BLE GATT, faster)  -ProbeCMedia (try C-Media protocol on any device with report 0x55)
#>
param(
    [switch]$Watch,
    [int]$Interval = 30,
    [switch]$Json,
    [switch]$Diag,
    [switch]$NoGatt,
    [switch]$ProbeCMedia,
    [switch]$Lib,          # load functions only (dot-source); used by the widget's background runspace
    [ValidateSet('auto', 'zh', 'en')][string]$Lang = 'auto'
)

. (Join-Path $PSScriptRoot 'i18n.ps1')
$script:Lang = Resolve-Lang $Lang
. (Join-Path $PSScriptRoot 'Core.ps1')
foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot 'providers') -Filter '*.ps1' | Sort-Object Name) { . $f.FullName }

# The PnP device list is the most expensive part of a refresh (CIM query). It is cached and only
# re-read after a device change (-Fresh) or every 2 minutes, so frequent refreshes stay cheap.
$script:PnpCache = $null
$script:PnpTime  = [datetime]::MinValue
function Get-PnpSnapshot([switch]$Force) {
    if ($Force -or $null -eq $script:PnpCache -or ((Get-Date) - $script:PnpTime).TotalSeconds -gt 120) {
        $all = @(Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue)
        $script:PnpCache = @{ All = $all; Hid = @($all | Where-Object { $_.InstanceId -like 'HID\*' }) }
        $script:PnpTime = Get-Date
    }
    $script:PnpCache
}

# -Fresh: re-enumerate devices (after a device change). -Wake: retry devices that did not answer
# (after keyboard / mouse input). Both forget cached "no answer" states.
function Get-AllBattery([switch]$Fresh, [switch]$Wake) {
    if ($Fresh -or $Wake) { Reset-DeviceState }
    $snap = Get-PnpSnapshot -Force:$Fresh
    $ctx = @{
        All     = $snap.All
        Hid     = $snap.Hid
        Options = @{ NoGatt = [bool]$NoGatt; ProbeCMedia = [bool]$ProbeCMedia }
    }
    $rows = @()
    foreach ($p in $script:Providers) {
        try { $rows += @(& $p.Run $ctx) } catch { Write-Verbose "$($p.Name): $_" }
    }
    $rows = @($rows | Where-Object { $_ })
    # XInput rows without a level duplicate controllers already handled by a vendor provider
    if (@($rows | Where-Object { $_.Kind -eq 'gamepad' -and $_.Source -ne 'XInput' }).Count) {
        $rows = @($rows | Where-Object { -not ($_.Source -eq 'XInput' -and $null -eq $_.Level) })
    }
    # a Bluetooth device read by a vendor protocol as well: keep the vendor row (it has charging info)
    $vendor = @($rows | Where-Object { $_.Source -notin 'Windows', 'GATT' } | ForEach-Object { $_.Name.ToLowerInvariant() })
    $rows = @($rows | Where-Object { $_.Source -notin 'Windows', 'GATT' -or $vendor -notcontains $_.Name.ToLowerInvariant() })
    $rows
}

# ---------------- console output ----------------
function Show-Console {
    $rows = @(Get-AllBattery)
    Write-Host ("`n" + (Tr 'console_header' (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))) -ForegroundColor Cyan
    Write-Host ('-' * 72)
    if (-not $rows) { Write-Host (Tr 'console_none') -ForegroundColor Yellow }
    foreach ($r in $rows) {
        $n = if ($r.Name.Length -gt 33) { $r.Name.Substring(0, 32) + '…' } else { $r.Name }
        $v = $r.Level
        $color = if ($null -eq $v) { 'DarkGray' } elseif ($v -le 20) { 'Red' } elseif ($v -le 50) { 'Yellow' } else { 'Green' }
        $bar = if ($null -eq $v) { '-' * 10 } else { $k = [math]::Max(0, [math]::Min(10, [math]::Round($v / 10))); ('█' * $k) + ('░' * (10 - $k)) }
        $pct = if ($null -eq $v) { ' --' } else { '{0,3}%' -f $v }
        Write-Host ('{0,-34}' -f $n) -NoNewline
        Write-Host (' {0} {1,4}' -f $bar, $pct) -ForegroundColor $color -NoNewline
        Write-Host ('  {0} [{1}/{2}]' -f (Format-Status $r.Status), (Format-Connection $r.Connection), $r.Source) -ForegroundColor DarkGray
    }
    if ($rows | Where-Object { $_.Status -eq 'asleep' }) { Write-Host (Tr 'hint_asleep') -ForegroundColor DarkGray }
}

# ---------------- diagnostics (read-only) ----------------
function Show-Diag {
    $ver = try { (Get-Content (Join-Path $PSScriptRoot 'version.json') -Raw | ConvertFrom-Json).Version } catch { '?' }
    "BatteryRings $ver diagnostics  $(Get-Date -Format s)"
    "Windows $([Environment]::OSVersion.Version)  PowerShell $($PSVersionTable.PSVersion)  UI $((Get-UICulture).Name)"
    ''
    '## HID devices (UsagePage/Usage, report lengths in/out/feature, report ids)'
    foreach ($d in Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -like 'HID\VID_*' } | Sort-Object InstanceId) {
        $path = Get-HidPath $d.InstanceId
        $c = [HidIo]::Caps($path)
        if (-not $c) { '{0}  (no access)' -f $d.InstanceId; continue }
        $s = [HidIo]::Strings($path)
        $ids = 0..2 | ForEach-Object { ([HidIo]::ReportIds($path, $_) | ForEach-Object { '{0:X2}' -f $_ }) -join ',' }
        '{0}' -f $d.InstanceId
        '    UP={0:X4} U={1:X4}  len in/out/feat={2}/{3}/{4}  ids in=[{5}] out=[{6}] feat=[{7}]  "{8}" / "{9}"' -f `
            $c[0], $c[1], $c[2], $c[3], $c[4], $ids[0], $ids[1], $ids[2], $s[0], $s[1]
    }
    ''
    '## Bluetooth devices'
    Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId -match '^(BTHENUM|BTHLE)\\' -and $_.FriendlyName } |
        ForEach-Object { '{0}  [{1}]' -f $_.FriendlyName, $_.InstanceId }
    ''
    '## Result'
    ConvertTo-Json -InputObject @(Get-AllBattery)
}

if ($Lib) { return }
if ($Json) { ConvertTo-Json -InputObject @(Get-AllBattery) -Compress }
elseif ($Diag) { Show-Diag }
elseif ($Watch) { while ($true) { Clear-Host; Show-Console; Start-Sleep $Interval } }
else { Show-Console }
