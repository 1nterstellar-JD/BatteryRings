# Compx / Nordic 2.4G mice: ATK, VXE, VGN, Scyrox, Dareu, G-Wolves, Zaopin ...
# Protocol reference: https://github.com/Fan4Metal/mouse_tray (protocol facts only, no code copied)
#
#   Nordic 52840: vendor collection UsagePage FF02 / Usage 0002, 17-byte reports
#                 write [08 04 00 .. 00 49] -> [6] = battery %, [7] = wired flag
#   Nordic 54L15: vendor collection UsagePage FF05 / Usage 0001, 64-byte reports
#                 write [08 7D 72 02 00 01 07 01] -> [1]=72, [5]=07, [7] = battery %

$script:CompxVids = 'VID_373B', 'VID_3554', 'VID_260D', 'VID_33E4'

Register-BatteryProvider 'Compx' {
    param($ctx)
    $rows = @()
    $cands = $ctx.Hid | Where-Object { $id = $_.InstanceId; $script:CompxVids | Where-Object { $id -like "HID\$_*" } }
    foreach ($d in $cands) {
        $path = Get-HidPath $d.InstanceId
        $caps = [HidIo]::Caps($path)
        if (-not $caps) { continue }
        $res = $null; $proto = $null
        if ($caps[0] -eq 0xFF02 -and $caps[1] -eq 0x0002 -and $caps[3] -eq 17) {
            $proto = 1
            $pkt = New-Object byte[] 17; $pkt[0] = 8; $pkt[1] = 4; $pkt[16] = 0x49
            $r = [HidIo]::Transact($path, $pkt, 17, 17, 1500, 2)
            if ($r) { $res = @{ Level = [int]$r[6]; Wired = $r[7] -ne 0 } }
        } elseif ($caps[0] -eq 0xFF05 -and $caps[1] -eq 0x0001 -and $caps[3] -eq 64) {
            $proto = 2
            $r = [HidIo]::Transact($path, [byte[]](8, 0x7D, 0x72, 2, 0, 1, 7, 1), 64, 64, 1500, 1)
            if ($r -and $r[1] -eq 0x72 -and $r[5] -eq 7) { $res = @{ Level = [int]$r[7]; Wired = $false } }
        }
        if (-not $proto) { continue }
        $name = Get-UsbName $d.InstanceId
        if (-not $name) { $name = Tr 'name_mouse' }
        if ($res) {
            $st = if ($res.Wired) { if ($res.Level -ge 100) { 'full' } else { 'charging' } } else { '' }
            $conn = if ($res.Wired) { 'wired' } else { '24g' }
            $rows += New-BatteryRow -Name $name -Connection $conn -Level $res.Level -Status $st -Source 'Compx' -Kind 'mouse'
        } else {
            $rows += New-BatteryRow -Name $name -Connection '24g' -Level $null -Status 'asleep' -Source 'Compx' -Kind 'mouse'
        }
    }
    $rows
}
