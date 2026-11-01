# Sony DualSense (PS5) / DualSense Edge / DualShock 4 (PS4), USB and Bluetooth
# Protocol reference: Linux drivers/hid/hid-playstation.c (protocol facts only)
#
# The controllers stream input reports continuously; the battery is part of them, so this provider
# only LISTENS (sends nothing).
#   DualSense  USB report 0x01 (64 B): status byte [53]   BT report 0x31 (78 B): status byte [54]
#              low nibble = level 0-10 (x10 +5 %), high nibble = 0 discharging, 1 charging, 2 full
#   DualShock4 USB report 0x01 (64 B): status byte [30]   BT report 0x11 (78 B): status byte [32]
#              low nibble = level, bit 4 = cable; with cable: <10 charging, 10 charging 100 %, 11 full
# Over Bluetooth both pads send a minimal report until a calibration feature report is read
# (DualSense 0x05, DualShock4 0x05); that read only returns data and is what games do as well.

$script:PsPads = @{
    0x0CE6 = @{ Name = 'DualSense Wireless Controller'; Type = 'ds' }
    0x0DF2 = @{ Name = 'DualSense Edge Wireless Controller'; Type = 'ds' }
    0x05C4 = @{ Name = 'DUALSHOCK 4 Wireless Controller'; Type = 'ds4' }
    0x09CC = @{ Name = 'DUALSHOCK 4 Wireless Controller'; Type = 'ds4' }
    0x0BA0 = @{ Name = 'DUALSHOCK 4 USB Wireless Adaptor'; Type = 'ds4' }
}

function Read-PsReport($path, [int]$inLen) {
    $l = [HidListen]::Listen($path, $inLen, 300, 4)
    if ($l -and $l.Count) { return $l[$l.Count - 1] }
    $null
}

Register-BatteryProvider 'PlayStation' {
    param($ctx)
    foreach ($d in $ctx.Hid | Where-Object { $_.InstanceId -match 'VID(_|&0002)054C' }) {
        if ($d.InstanceId -notmatch 'PID(_|&)([0-9A-F]{4})') { continue }
        $pad = $script:PsPads[[Convert]::ToInt32($Matches[2], 16)]
        if (-not $pad) { continue }
        $path = Get-HidPath $d.InstanceId
        $caps = [HidIo]::Caps($path)
        if (-not $caps -or $caps[0] -ne 0x0001 -or $caps[1] -ne 0x0005) { continue }   # gamepad collection
        $bt = $d.InstanceId -match '\{00001124-|\{00001812-|BTH'
        $conn = if ($bt) { 'bluetooth' } elseif ($pad.Name -like '*Adaptor*') { '24g' } else { 'wired' }

        $rep = Read-PsReport $path $caps[2]
        if ($rep -and $bt -and $rep[0] -eq 0x01) {
            # minimal Bluetooth report: ask for the full report mode, then listen again
            [void][HidIo]::GetFeature($path, 0x05, [math]::Max(41, $caps[4]))
            $rep = Read-PsReport $path $caps[2]
        }
        if (-not $rep) {
            New-BatteryRow -Name $pad.Name -Connection $conn -Level $null -Status 'asleep' -Source 'PlayStation' -Kind 'gamepad'
            continue
        }

        $level = $null; $st = ''
        if ($pad.Type -eq 'ds') {
            $i = if ($rep[0] -eq 0x31) { 54 } elseif ($rep[0] -eq 0x01 -and $rep.Length -ge 64) { 53 } else { -1 }
            if ($i -ge 0) {
                $data = $rep[$i] -band 0x0F; $chg = ($rep[$i] -shr 4) -band 0x0F
                switch ($chg) {
                    0 { $level = [math]::Min($data * 10 + 5, 100) }
                    1 { $level = [math]::Min($data * 10 + 5, 100); $st = 'charging' }
                    2 { $level = 100; $st = 'full' }
                }
            }
        } else {
            $i = if ($rep[0] -eq 0x11) { 32 } elseif ($rep[0] -eq 0x01 -and $rep.Length -ge 64) { 30 } else { -1 }
            if ($i -ge 0) {
                $data = $rep[$i] -band 0x0F
                if ($rep[$i] -band 0x10) {
                    if ($data -lt 10) { $level = $data * 10 + 5; $st = 'charging' }
                    elseif ($data -eq 10) { $level = 100; $st = 'charging' }
                    elseif ($data -eq 11) { $level = 100; $st = 'full' }
                } else {
                    $level = [math]::Min([math]::Min($data, 10) * 10 + 5, 100)
                }
                if ($pad.Name -like '*Adaptor*' -and $level -eq 5 -and -not $st) { $level = $null }   # adaptor without a paired pad
            }
        }
        New-BatteryRow -Name $pad.Name -Connection $conn -Level $level -Status $(if ($null -eq $level) { 'nodata' } else { $st }) -Source 'PlayStation' -Kind 'gamepad'
    }
}
