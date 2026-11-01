# XInput controllers (Xbox and compatible). Windows only reports 4 levels: empty / low / medium / full.

Register-BatteryProvider 'XInput' {
    param($ctx)
    $rows = @()
    $approx = @{ 0 = 5; 1 = 25; 2 = 60; 3 = 100 }
    for ($i = 0; $i -lt 4; $i++) {
        $b = [XInput]::Battery($i)
        if (-not $b) { continue }
        $name = Tr 'name_xinput' ($i + 1)
        switch ($b[0]) {
            0 { }   # disconnected
            1 { $rows += New-BatteryRow -Name $name -Connection 'wired' -Level $null -Status 'nodata' -Source 'XInput' -Kind 'gamepad' }
            default { $rows += New-BatteryRow -Name $name -Connection 'wireless' -Level $approx[[int]$b[1]] -Status 'approx' -Source 'XInput' -Kind 'gamepad' }
        }
    }
    $rows
}
