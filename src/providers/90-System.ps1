# Built-in laptop / tablet battery

Register-BatteryProvider 'System' {
    param($ctx)
    foreach ($b in Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) {
        # BatteryStatus: 2 = on AC power, 3 = full, 6-9 = charging
        $st = if ($b.BatteryStatus -in 6, 7, 8, 9) { 'charging' } elseif ($b.BatteryStatus -eq 3) { 'full' } elseif ($b.BatteryStatus -eq 2) { 'ac' } else { '' }
        New-BatteryRow -Name (Tr 'name_laptop') -Connection 'internal' -Level $b.EstimatedChargeRemaining -Status $st -Source 'WMI' -Kind 'laptop'
    }
}
