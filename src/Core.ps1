# Core.ps1 - shared helpers for battery providers
#
# Every provider returns rows created by New-BatteryRow:
#   Name        display name
#   Kind        mouse | keyboard | headset | gamepad | laptop | ''   (used for the widget icon)
#   Connection  bluetooth | ble | 24g | wired | internal | wireless
#   Level       0-100, or $null when unknown (device asleep / not reporting)
#   Status      '' | charging | full | asleep | nodata | ac | approx
#   Source      short protocol name, e.g. 'ROG', 'Compx'

if (-not ('HidIo' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'HidIo.cs') }

$script:HidGuid = '{4d1e55b2-f16f-11cf-88cb-001111000030}'

# PnP instance id (HID\VID_xxxx&PID_xxxx\...) -> device interface path usable with CreateFile
function Get-HidPath([string]$instanceId) {
    '\\?\' + $instanceId.Replace('\', '#') + '#' + $script:HidGuid
}

function New-BatteryRow {
    param(
        [string]$Name,
        [string]$Connection,
        $Level,
        [string]$Status = '',
        [string]$Source,
        [string]$Kind = ''
    )
    [pscustomobject]@{
        Name       = $Name
        Kind       = $Kind
        Connection = $Connection
        Level      = if ($null -eq $Level) { $null } else { [int]$Level }
        Status     = $Status
        Source     = $Source
    }
}

# Product name of the USB device that owns a HID collection (e.g. "ATK Mouse 8K Dongle").
# Two CIM queries (~250 ms each), so the result is cached; names never change.
$script:UsbNameCache = @{}
function Get-UsbName([string]$hidInstanceId) {
    if ($script:UsbNameCache.ContainsKey($hidInstanceId)) { return $script:UsbNameCache[$hidInstanceId] }
    $name = $null
    try {
        $parent = (Get-PnpDeviceProperty -InstanceId $hidInstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction Stop).Data
        $name = (Get-PnpDeviceProperty -InstanceId $parent -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction Stop).Data
    } catch { }
    $script:UsbNameCache[$hidInstanceId] = $name
    $name
}

# Registry of providers. Each providers/*.ps1 file calls Register-BatteryProvider.
#   Run receives a context: @{ All = all PnP devices; Hid = HID devices; Options = @{ NoGatt; ProbeCMedia } }
$script:Providers = @()
function Register-BatteryProvider([string]$Name, [scriptblock]$Run) {
    $script:Providers += [pscustomobject]@{ Name = $Name; Run = $Run }
}

# Called when cached "no answer" states should be forgotten (a device was plugged in, or the user
# just touched the mouse / keyboard). Providers with their own caches register a handler.
$script:ResetHandlers = @()
function Register-ResetHandler([scriptblock]$Handler) { $script:ResetHandlers += $Handler }
function Reset-DeviceState {
    [HidIo]::ResetBackoff()
    foreach ($h in $script:ResetHandlers) { try { & $h } catch { } }
}
