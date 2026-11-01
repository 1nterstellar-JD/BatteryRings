# Logitech: Unifying / Bolt / Lightspeed / Nano receivers, wired and Bluetooth devices (HID++ 2.0)
# Protocol reference: https://github.com/pwr-Solaar/Solaar (protocol facts only, no code copied)
#
#   long report : 11 <device> <feature index> <function<<4 | sw id> <params ...>        (20 bytes)
#   root (index 0x00) function 0 getFeature(id hi, id lo) -> [feature index, type, version]; index 0 = not supported
#   0x1004 UNIFIED_BATTERY  function 1 get_status -> [soc %, level flags, status, external power]
#   0x1000 BATTERY_STATUS   function 0            -> [level %, next level, status]
#   0x1001 BATTERY_VOLTAGE  function 0            -> [mV hi, mV lo, flags]   flags bit 7 = charging
#   0x0005 DEVICE_NAME      function 0 -> [length], function 1(offset) -> name chunk, function 2 -> [kind]
#   status: 0 discharging, 1 recharging, 2 almost full, 3 full, 4 slow recharge
#
# Receivers (PID 0xC5xx) address paired devices as 1..6; wired and Bluetooth devices use 0xFF.

$script:LogiSw = 0x0A
$script:LogiCache = @{}     # "<long path>|<index>" -> @{ Feat; Name; Kind; Known; EmptyUntil }
$script:LogiVoltTable = @(  # mV -> %, from Solaar's estimate_battery_level_percentage
    @(4186, 100), @(4067, 90), @(3989, 80), @(3922, 70), @(3859, 60), @(3811, 50),
    @(3778, 40), @(3751, 30), @(3717, 20), @(3671, 10), @(3646, 5), @(3579, 2), @(3500, 0))

function Invoke-Hidpp($ep, $idx, $featIdx, $func, [byte[]]$prm) {
    [HidIo]::Hidpp($ep.Short, $ep.Long, [byte]$idx, [byte]$featIdx, [byte](($func -shl 4) -bor $script:LogiSw), $prm, 1000)
}

# $null = timeout, -1 = HID++ error (e.g. device not connected), 0 = not supported, >0 = feature index
function Get-HidppFeatureIndex($ep, $idx, [int]$featureId) {
    $r = Invoke-Hidpp $ep $idx 0x00 0 ([byte[]](($featureId -shr 8) -band 0xFF, $featureId -band 0xFF))
    if ($null -eq $r) { return $null }
    if ($r.Length -eq 2) { return -1 }
    [int]$r[0]
}

function ConvertFrom-LogiVoltage([int]$mv) {
    $t = $script:LogiVoltTable
    if ($mv -ge $t[0][0]) { return 100 }
    if ($mv -le $t[-1][0]) { return 0 }
    for ($i = 0; $i -lt $t.Count - 1; $i++) {
        $hi = $t[$i]; $lo = $t[$i + 1]
        if ($mv -le $hi[0] -and $mv -ge $lo[0]) {
            return [int][math]::Round($lo[1] + ($hi[1] - $lo[1]) * ($mv - $lo[0]) / ($hi[0] - $lo[0]))
        }
    }
    0
}

function Get-LogiStatus([int]$s) {
    switch ($s) { 1 { 'charging' } 2 { 'charging' } 4 { 'charging' } 3 { 'full' } default { '' } }
}

# Group HID collections of one USB interface / Bluetooth device into a HID++ endpoint
function Get-LogiEndpoints($hid) {
    $eps = @{}
    foreach ($d in $hid | Where-Object { $_.InstanceId -match 'VID(_|&02)046D' }) {
        $path = Get-HidPath $d.InstanceId
        $caps = [HidIo]::Caps($path)
        if (-not $caps) { continue }
        $role = if ($caps[0] -eq 0xFF00 -and $caps[1] -eq 0x0002 -and $caps[3] -eq 20) { 'Long' }
                elseif ($caps[0] -eq 0xFF43 -and $caps[1] -eq 0x0202 -and $caps[3] -eq 20) { 'Long' }   # Bluetooth LE
                elseif ($caps[0] -eq 0xFF00 -and $caps[1] -eq 0x0001 -and $caps[3] -eq 7) { 'Short' }
                else { $null }
        if (-not $role) { continue }
        $seg = $d.InstanceId -split '\\'
        $key = ($seg[1] -replace '&COL[0-9A-F]+', '') + '|' + ($seg[2] -replace '&[^&]*$', '')
        if (-not $eps.ContainsKey($key)) {
            $devPid = if ($d.InstanceId -match 'PID(_|&)([0-9A-F]{4})') { [Convert]::ToInt32($Matches[2], 16) } else { 0 }
            $eps[$key] = @{ Long = $null; Short = $null; Pid = $devPid; Bt = $d.InstanceId -match '\{00001812-'; Id = $d.InstanceId }
        }
        $eps[$key][$role] = $path
    }
    @($eps.Values | Where-Object { $_.Long })
}

function Read-LogiDevice($ep, $idx) {
    $key = "$($ep.Long)|$idx"
    if (-not $script:LogiCache.ContainsKey($key)) {
        $script:LogiCache[$key] = @{ Feat = @{}; Name = $null; Kind = ''; Known = $false; EmptyUntil = [datetime]::MinValue }
    }
    $c = $script:LogiCache[$key]
    $receiver = ($ep.Pid -band 0xFF00) -eq 0xC500
    $conn = if ($receiver) { '24g' } elseif ($ep.Bt) { 'bluetooth' } else { 'wired' }

    if (-not $c.Known -and (Get-Date) -lt $c.EmptyUntil) { return }
    $asleep = { if ($c.Known) { New-BatteryRow -Name $c.Name -Connection $conn -Level $null -Status 'asleep' -Source 'Logitech' -Kind $c.Kind } }

    # discover battery features once per device
    if (-not $c.Feat.Count) {
        foreach ($fid in 0x1004, 0x1000, 0x1001) {
            $fi = Get-HidppFeatureIndex $ep $idx $fid
            if ($null -eq $fi -or $fi -lt 0) {
                if (-not $c.Known) { $c.EmptyUntil = (Get-Date).AddSeconds(30) }   # empty slot / device off
                $c.Feat = @{}
                return (& $asleep)
            }
            $c.Feat[$fid] = $fi
        }
        if (-not ($c.Feat.Values | Where-Object { $_ -gt 0 })) { $c.EmptyUntil = (Get-Date).AddMinutes(10); return }  # no battery
        $c.Known = $true
        # name and kind
        $fn = Get-HidppFeatureIndex $ep $idx 0x0005
        if ($fn -gt 0) {
            $len = Invoke-Hidpp $ep $idx $fn 0 $null
            if ($len -and $len.Length -eq 16) {
                $bytes = New-Object System.Collections.Generic.List[byte]
                while ($bytes.Count -lt $len[0]) {
                    $frag = Invoke-Hidpp $ep $idx $fn 1 ([byte[]]@($bytes.Count))
                    if (-not $frag -or $frag.Length -ne 16) { break }
                    $bytes.AddRange([byte[]]$frag[0..([math]::Min(15, $len[0] - $bytes.Count - 1))])
                }
                if ($bytes.Count) { $c.Name = [Text.Encoding]::UTF8.GetString($bytes.ToArray()).Trim([char]0, ' ') }
            }
            $k = Invoke-Hidpp $ep $idx $fn 2 $null
            if ($k -and $k.Length -eq 16) {
                $c.Kind = switch ([int]$k[0]) { 0 { 'keyboard' } 2 { 'keyboard' } 3 { 'mouse' } 4 { 'mouse' } 5 { 'mouse' } default { '' } }
            }
        }
        if (-not $c.Name) { $c.Name = if ($receiver) { "Logitech #$idx" } else { 'Logitech' } }
    }

    $level = $null; $st = ''
    if ($c.Feat[0x1004] -gt 0) {
        $r = Invoke-Hidpp $ep $idx $c.Feat[0x1004] 1 $null
        if ($r -and $r.Length -eq 16) {
            $level = [int]$r[0]
            if ($level -eq 0) { $level = switch ([int]$r[1]) { 8 { 90 } 4 { 50 } 2 { 20 } 1 { 5 } default { 0 } }; $st = 'approx' }
            $s2 = Get-LogiStatus $r[2]; if ($s2) { $st = $s2 }
        }
    } elseif ($c.Feat[0x1000] -gt 0) {
        $r = Invoke-Hidpp $ep $idx $c.Feat[0x1000] 0 $null
        if ($r -and $r.Length -eq 16 -and $r[0] -gt 0) { $level = [int]$r[0]; $st = Get-LogiStatus $r[2] }
    } elseif ($c.Feat[0x1001] -gt 0) {
        $r = Invoke-Hidpp $ep $idx $c.Feat[0x1001] 0 $null
        if ($r -and $r.Length -eq 16) {
            $level = ConvertFrom-LogiVoltage ((([int]$r[0]) -shl 8) -bor $r[1])
            $st = if ($r[2] -band 0x80) { if (($r[2] -band 0x03) -eq 2) { 'full' } else { 'charging' } } else { 'approx' }
        }
    }
    if ($r -and $r.Length -eq 2 -and $r[0] -eq 0xFF) { $c.Feat = @{} }   # feature error: rediscover next time
    if ($null -eq $level) { return (& $asleep) }
    New-BatteryRow -Name $c.Name -Connection $conn -Level ([math]::Min(100, $level)) -Status $st -Source 'Logitech' -Kind $c.Kind
}

Register-ResetHandler { foreach ($c in $script:LogiCache.Values) { $c.EmptyUntil = [datetime]::MinValue } }

Register-BatteryProvider 'Logitech' {
    param($ctx)
    foreach ($ep in Get-LogiEndpoints $ctx.Hid) {
        $indexes = if (($ep.Pid -band 0xFF00) -eq 0xC500) { 1..6 } else { @(0xFF) }
        foreach ($i in $indexes) { Read-LogiDevice $ep $i }
    }
}
