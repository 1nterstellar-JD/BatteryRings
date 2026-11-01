# Bluetooth devices
#  1. Windows battery property DEVPKEY_Bluetooth_Battery (works for most headsets, mice, keyboards)
#  2. BLE GATT Battery Service 0x180F / Battery Level 0x2A19 (for BLE devices Windows does not report)

function Get-BluetoothKind([string]$name) {
    if ($name -match 'Mouse|鼠标|MX (Master|Anywhere)') { return 'mouse' }
    if ($name -match 'Keyboard|键盘|Keys') { return 'keyboard' }
    if ($name -match 'Controller|Gamepad|手柄|Xbox|DualSense|DualShock|Pro Controller') { return 'gamepad' }
    if ($name -match 'Head|耳机|Buds|AirPods|Earphone|WH-|WF-|Bose|Beats|Jabra') { return 'headset' }
    ''
}

function Get-BtPropertyBattery($all) {
    $result = @{}
    $key = '{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2'   # DEVPKEY_Bluetooth_Battery
    $bt = @($all | Where-Object { $_.InstanceId -match '^(BTHENUM|BTHLE|BTHLEDEVICE|BTHHFENUM)\\' })
    if (-not $bt.Count) { return $result }
    $names = @{}; foreach ($d in $bt) { $names[$d.InstanceId] = $d.FriendlyName }
    # one CIM call for all devices instead of one per device
    $props = Get-PnpDeviceProperty -InstanceId $bt.InstanceId -KeyName $key -ErrorAction SilentlyContinue
    foreach ($p in $props) {
        if ($null -eq $p.Data) { continue }
        $id = $p.InstanceId
        $mac = if ($id -match '([0-9A-F]{12})') { $Matches[1] } else { $id }
        if (-not $result.ContainsKey($mac)) {
            $n = $names[$id]
            $result[$mac] = New-BatteryRow -Name $n -Connection 'bluetooth' -Level $p.Data -Source 'Windows' -Kind (Get-BluetoothKind $n)
        }
    }
    $result
}

# ---- BLE GATT via WinRT ----
$script:WinRtReady = $null
function Initialize-WinRT {
    if ($null -ne $script:WinRtReady) { return $script:WinRtReady }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
        $null = [Windows.Devices.Bluetooth.GenericAttributeProfile.GattDeviceService, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
        $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
        $null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
        $script:AsTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
        $script:WinRtReady = $true
    } catch { $script:WinRtReady = $false }
    $script:WinRtReady
}
function Wait-WinRT($op, [Type]$type, [int]$timeoutMs = 4000) {
    $task = $script:AsTask.MakeGenericMethod($type).Invoke($null, @($op))
    if (-not $task.Wait($timeoutMs)) { throw 'timeout' }
    $task.Result
}

function Get-GattBattery {
    $result = @{}
    if (-not (Initialize-WinRT)) { return $result }
    $ns = 'Windows.Devices.Bluetooth.GenericAttributeProfile'
    try {
        $sel = [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromConnectionStatus(
            [Windows.Devices.Bluetooth.BluetoothConnectionStatus]::Connected)
        $infos = Wait-WinRT ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($sel)) ([Windows.Devices.Enumeration.DeviceInformationCollection])
    } catch { return $result }
    $battUuid  = [Guid]'0000180f-0000-1000-8000-00805f9b34fb'
    $levelUuid = [Guid]'00002a19-0000-1000-8000-00805f9b34fb'
    foreach ($info in $infos) {
        try {
            $dev = Wait-WinRT ([Windows.Devices.Bluetooth.BluetoothLEDevice]::FromIdAsync($info.Id)) ([Windows.Devices.Bluetooth.BluetoothLEDevice])
            if (-not $dev) { continue }
            $mac = '{0:X12}' -f $dev.BluetoothAddress
            $svcs = Wait-WinRT ($dev.GetGattServicesForUuidAsync($battUuid)) ("$ns.GattDeviceServicesResult" -as [Type])
            foreach ($svc in $svcs.Services) {
                $chars = Wait-WinRT ($svc.GetCharacteristicsForUuidAsync($levelUuid)) ("$ns.GattCharacteristicsResult" -as [Type])
                foreach ($c in $chars.Characteristics) {
                    $r = Wait-WinRT ($c.ReadValueAsync()) ("$ns.GattReadResult" -as [Type])
                    if ($r.Status -eq 'Success') {
                        $level = [Windows.Storage.Streams.DataReader]::FromBuffer($r.Value).ReadByte()
                        $result[$mac] = New-BatteryRow -Name $dev.Name -Connection 'ble' -Level $level -Source 'GATT' -Kind (Get-BluetoothKind $dev.Name)
                    }
                }
                $svc.Dispose()
            }
            $dev.Dispose()
        } catch { }   # HID-over-GATT devices usually deny access; the Windows property covers those
    }
    $result
}

Register-BatteryProvider 'Bluetooth' {
    param($ctx)
    $bt = Get-BtPropertyBattery $ctx.All
    if (-not $ctx.Options.NoGatt) {
        (Get-GattBattery).GetEnumerator() | ForEach-Object { if (-not $bt.ContainsKey($_.Key)) { $bt[$_.Key] = $_.Value } }
    }
    @($bt.Values)
}
