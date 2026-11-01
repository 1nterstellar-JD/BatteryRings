# Razer HyperSpeed / wireless mice, keyboards and docks
# Protocol reference: https://github.com/openrazer/openrazer (driver/razercommon.*, razermouse_driver.c; facts only)
#
# 90-byte feature report (report id 0 prepended on Windows = 91 bytes):
#   [1] status  [2] transaction id  [3..4] remaining  [5] protocol  [6] data size  [7] class  [8] command
#   [9..88] arguments   [89] crc = XOR of bytes [3..88]
#   get battery  : class 0x07 command 0x80 -> arguments[1] = 0..255
#   get charging : class 0x07 command 0x84 -> arguments[1] = 1 while charging
#   reply status : 0x02 ok, 0x01 busy, 0x03 failed, 0x04 timeout (device asleep), 0x05 not supported
# The transaction id differs between models (0x1F, 0x3F, 0xFF, 0x9F); the working one is remembered.

$script:RazerTid = @{}   # path -> transaction id that answered

function Invoke-RazerCommand($path, [byte]$tid, [byte]$class, [byte]$cmd) {
    $rep = New-Object byte[] 91
    $rep[2] = $tid; $rep[6] = 0x02; $rep[7] = $class; $rep[8] = $cmd
    $crc = 0; for ($i = 3; $i -le 88; $i++) { $crc = $crc -bxor $rep[$i] }
    $rep[89] = [byte]$crc
    for ($try = 0; $try -lt 3; $try++) {
        $r = [HidIo]::FeatureTransact($path, $rep, 91, 60)
        if (-not $r) { return $null }
        if ($r[1] -ne 0x01) { return $r }          # not busy
        Start-Sleep -Milliseconds 60
    }
    $null
}

Register-BatteryProvider 'Razer' {
    param($ctx)
    $done = @{}
    foreach ($d in $ctx.Hid | Where-Object { $_.InstanceId -match 'VID(_|&02)1532' }) {
        $seg = $d.InstanceId -split '\\'
        $dev = ($seg[1] -replace '&(MI|COL)_?[0-9A-F]+', '')   # one row per USB device
        if ($done[$dev]) { continue }
        $path = Get-HidPath $d.InstanceId
        $caps = [HidIo]::Caps($path)
        if (-not $caps -or $caps[4] -ne 91) { continue }       # control interface: 90-byte feature report

        $tids = if ($script:RazerTid.ContainsKey($path)) { @($script:RazerTid[$path]) } else { 0x1F, 0x3F, 0xFF, 0x9F }
        $r = $null
        foreach ($t in $tids) {
            $r = Invoke-RazerCommand $path $t 0x07 0x80
            if ($r -and $r[1] -in 0x02, 0x04) { $script:RazerTid[$path] = $t; break }
            $r = $null
        }
        if (-not $r) { continue }                              # no battery (wired-only device) or other interface
        $done[$dev] = $true
        $name = Get-UsbName $d.InstanceId
        if (-not $name) { $name = 'Razer' }
        $name = $name -replace '\s*(Dongle|Receiver)$', ''
        $kind = if ($name -match 'Keyboard|BlackWidow|Huntsman|DeathStalker|Ornata|Pro Type') { 'keyboard' }
                elseif ($name -match 'Barracuda|Kraken|BlackShark|Nari|Hammerhead') { 'headset' } else { 'mouse' }
        if ($r[1] -eq 0x04) {
            New-BatteryRow -Name $name -Connection '24g' -Level $null -Status 'asleep' -Source 'Razer' -Kind $kind
            continue
        }
        $level = [int][math]::Round($r[10] * 100 / 255)
        $c = Invoke-RazerCommand $path $script:RazerTid[$path] 0x07 0x84
        $st = if ($c -and $c[1] -eq 0x02 -and $c[10] -eq 1) { if ($level -ge 100) { 'full' } else { 'charging' } } else { '' }
        New-BatteryRow -Name $name -Connection $(if ($st) { 'wired' } else { '24g' }) -Level $level -Status $st -Source 'Razer' -Kind $kind
    }
}
