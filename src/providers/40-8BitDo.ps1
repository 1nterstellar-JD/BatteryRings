# 8BitDo controllers (Ultimate 2 Wireless and others using the same config channel)
# Protocol reference: https://github.com/MiguelSanzBr/8bitdo-ultimate2-linux (docs/PROTOCOL.md)
#
#   vendor collection UsagePage FF7A (controller) / FFA0 (2.4G receiver), out report 0x81 / in report 0x02, 64 bytes
#   read-only query [81 04 21 01 00 00 06] -> [02 04 04 00 21 01 ...], byte 18 = battery %

Register-BatteryProvider '8BitDo' {
    param($ctx)
    $rows = @()
    foreach ($d in $ctx.Hid | Where-Object { $_.InstanceId -like 'HID\VID_2DC8*' }) {
        $path = Get-HidPath $d.InstanceId
        $caps = [HidIo]::Caps($path)
        if (-not $caps -or ($caps[0] -ne 0xFF7A -and $caps[0] -ne 0xFFA0) -or $caps[3] -ne 64) { continue }
        $name = Get-UsbName $d.InstanceId
        if (-not $name) { $name = Tr 'name_gamepad' }
        $r = [HidIo]::Transact($path, [byte[]](0x81, 0x04, 0x21, 0x01, 0x00, 0x00, 0x06), 64, 64, 1500, 0)
        if ($r -and $r[0] -eq 2 -and $r[1] -eq 4 -and $r[4] -eq 0x21 -and $r[5] -eq 1 -and $r[18] -le 100) {
            $rows += New-BatteryRow -Name $name -Connection '24g' -Level $r[18] -Source '8BitDo' -Kind 'gamepad'
        } else {
            $rows += New-BatteryRow -Name $name -Connection 'wired' -Level $null -Status 'nodata' -Source '8BitDo' -Kind 'gamepad'
        }
    }
    $rows
}
