# ASUS ROG Omni receiver (2.4G, VID 0B05 PID 1ACE)
# Protocol reference: https://github.com/seerge/g-helper (app/Peripherals)
#
#   pairing list : COL01, write [01 A0 00 00] -> paired device PIDs from byte 5, 4 bytes each (little endian)
#   mouse        : COL03, write [03 12 07]    -> [5] = battery %, [10] = charging
#   keyboard     : COL02, write [02 12 01]    -> [6] = battery % ([11] on Falchion), [9] = charging

$script:OmniMice = @{
    0x1B65 = 'ROG Harpe Ace Mini'; 0x1C0E = 'ROG Keris II Origin'; 0x1D4E = 'ROG Keris II Origin KJP'
    0x1A94 = 'ROG Harpe Ace Aim Lab Edition'; 0x1AD7 = 'ROG Strix Impact III Wireless'
    0x1A72 = 'ROG Gladius III Aimpoint'; 0x1A68 = 'ROG Keris Wireless Aimpoint'; 0x1A6A = 'ROG Keris Wireless Aimpoint'
    0x1B1A = 'ROG Keris II Ace'; 0x1B18 = 'ROG Keris II Ace'; 0x1B68 = 'ROG Harpe Ace Extreme'; 0x1B69 = 'ROG Harpe Ace Extreme'
}
$script:OmniKeyboards = @{
    0x1A85 = 'ROG Azoth'; 0x1B42 = 'ROG Azoth Extreme'; 0x1CF1 = 'ROG Azoth Extreme SE'
    0x1AB0 = 'ROG Strix Scope II 96 Wireless'; 0x1B7A = 'ROG Strix Scope II 96 RX Wireless'
    0x1B06 = 'ROG Falchion RX Low Profile'; 0x1C24 = 'ROG Azoth X'; 0x1C25 = 'ROG Azoth X'
}

function Read-AsusMouse($path) {
    $r = [HidIo]::Transact($path, [byte[]](3, 0x12, 0x07), 64, 64, 1500, 1)
    if ($r -and $r[1] -eq 0x12 -and $r[2] -eq 0x07 -and $r[5] -gt 0) {
        return @{ Level = [int]$r[5]; Charging = $r[10] -gt 0 }
    }
    $null
}
function Read-AsusKeyboard($path, $devPid) {
    $r = [HidIo]::Transact($path, [byte[]](2, 0x12, 0x01), 64, 64, 1500, 1)
    if ($r -and $r[1] -eq 0x12 -and $r[2] -eq 0x01) {
        $lv = if ($devPid -eq 0x1B06) { $r[11] } else { $r[6] }
        return @{ Level = [int]$lv; Charging = $r[9] -eq 1 }
    }
    $null
}

Register-BatteryProvider 'ROG Omni' {
    param($ctx)
    $rows = @()
    $omni = $ctx.Hid | Where-Object { $_.InstanceId -like 'HID\VID_0B05&PID_1ACE&MI_02&COL0*' }
    $groups = $omni | Group-Object { ($_.InstanceId -split '\\')[2] -replace '&[^&]*$', '' }
    foreach ($g in $groups) {
        $c1 = $g.Group | Where-Object InstanceId -like '*COL01*' | Select-Object -First 1
        $c2 = $g.Group | Where-Object InstanceId -like '*COL02*' | Select-Object -First 1
        $c3 = $g.Group | Where-Object InstanceId -like '*COL03*' | Select-Object -First 1
        if (-not $c1) { continue }
        $list = [HidIo]::Transact((Get-HidPath $c1.InstanceId), [byte[]](1, 0xA0, 0, 0), 64, 64, 1500, 2)
        if (-not $list) { continue }
        for ($o = 5; $o + 3 -lt $list.Length; $o += 4) {
            $devPid = [int]$list[$o] -bor ([int]$list[$o + 1] -shl 8)
            if ($devPid -eq 0) { break }
            $res = $null
            if ($script:OmniMice.ContainsKey($devPid)) {
                $name = $script:OmniMice[$devPid]; $kind = 'mouse'
                if ($c3) { $res = Read-AsusMouse (Get-HidPath $c3.InstanceId) }
            } else {
                $kind = if ($script:OmniKeyboards.ContainsKey($devPid)) { 'keyboard' } else { '' }
                $name = if ($kind) { $script:OmniKeyboards[$devPid] } else { Tr 'name_rog' ('{0:X4}' -f $devPid) }
                if ($c2) { $res = Read-AsusKeyboard (Get-HidPath $c2.InstanceId) $devPid }
                if (-not $res -and $c3 -and -not $kind) { $res = Read-AsusMouse (Get-HidPath $c3.InstanceId) }
            }
            if ($res) {
                $rows += New-BatteryRow -Name $name -Connection '24g' -Level $res.Level -Status $(if ($res.Charging) { 'charging' } else { '' }) -Source 'ROG' -Kind $kind
            } else {
                $rows += New-BatteryRow -Name $name -Connection '24g' -Level $null -Status 'asleep' -Source 'ROG' -Kind $kind
            }
        }
    }
    $rows
}
