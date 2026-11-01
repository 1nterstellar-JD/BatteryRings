# C-Media based USB headsets
# Protocol found in the C-Media XearONE driver UI (.NET), e.g. "DAILING Audio Center"
#
#   write output report [55 65 01 00 ...]   -> device sends input report [55 65 <battery %> <state>]
#   state: 3 = charging, 2/4 = not charging, 0x1A (26) = disconnected/unknown
#
# To avoid sending commands to unrelated devices we only probe HID collections that have
# input AND output report id 0x55, and that are either:
#   - VID 0D8C (C-Media), or manufacturer string contains "C-Media", or listed in $CMediaWhitelist
#   - or any such device when -ProbeCMedia is given

$script:CMediaWhitelist = @(
    # 'VID_xxxx&PID_xxxx'   # add headsets confirmed to support this protocol
)

Register-BatteryProvider 'C-Media' {
    param($ctx)
    $rows = @()
    foreach ($d in $ctx.Hid) {
        if ($d.InstanceId -notmatch 'VID_([0-9A-F]{4})&PID_([0-9A-F]{4})') { continue }
        $vid = $Matches[1]; $vp = "VID_$($Matches[1])&PID_$($Matches[2])"
        $path = Get-HidPath $d.InstanceId
        $caps = [HidIo]::Caps($path)
        if (-not $caps -or $caps[2] -lt 4 -or $caps[3] -lt 3) { continue }
        if (-not ([HidIo]::ReportIds($path, 1) -contains 0x55) -or -not ([HidIo]::ReportIds($path, 0) -contains 0x55)) { continue }
        $str = [HidIo]::Strings($path)
        $known = $vid -eq '0D8C' -or $str[0] -match 'C-?Media' -or $script:CMediaWhitelist -contains $vp
        if (-not $known -and -not $ctx.Options.ProbeCMedia) { continue }
        $name = if ($str[1]) { $str[1] } else { Get-UsbName $d.InstanceId }
        if (-not $name) { $name = Tr 'name_headset' $vp }
        $r = [HidIo]::Transact($path, [byte[]](0x55, 0x65, 0x01), $caps[3], $caps[2], 1500, 2)
        if ($r -and $r[2] -le 100 -and $r[2] -ne 26 -and $r[3] -ne 26) {
            $st = if ($r[3] -eq 3) { 'charging' } else { '' }
            $rows += New-BatteryRow -Name $name -Connection 'wireless' -Level $r[2] -Status $st -Source 'C-Media' -Kind 'headset'
        } else {
            $rows += New-BatteryRow -Name $name -Connection 'wireless' -Level $null -Status 'asleep' -Source 'C-Media' -Kind 'headset'
        }
    }
    $rows
}
