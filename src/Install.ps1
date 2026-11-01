# Install.ps1 - copy to %LOCALAPPDATA%\Programs\BatteryRings, create shortcuts, start the widget
# Run via Install.cmd (double-click). No administrator rights needed.
# -Quiet  : no questions (autostart on)      -Update : used by the in-app updater (no questions, keep autostart as it was)
param([switch]$Quiet, [switch]$Update)
if ($Update) { $Quiet = $true }

$ErrorActionPreference = 'Stop'
$src  = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'Programs\BatteryRings'
. (Join-Path $src 'i18n.ps1')

$startMenu  = Join-Path ([Environment]::GetFolderPath('Programs')) 'BatteryRings'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'BatteryRings.lnk'

Write-Host ''
Write-Host "  $(Tr 'inst_title')" -ForegroundColor Cyan
Write-Host ''

# 1. stop a running widget (upgrade)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'Widget\.ps1' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

# 1b. migrate from the old name "WirelessBattery" (settings are kept)
$oldCfg = Join-Path $env:APPDATA 'WirelessBattery'
$newCfg = Join-Path $env:APPDATA 'BatteryRings'
if ((Test-Path $oldCfg) -and -not (Test-Path $newCfg)) { Copy-Item $oldCfg $newCfg -Recurse }
foreach ($old in (Join-Path $env:LOCALAPPDATA 'Programs\WirelessBattery'),
                 (Join-Path ([Environment]::GetFolderPath('Programs')) 'Wireless Battery'),
                 (Join-Path ([Environment]::GetFolderPath('Startup')) 'WirelessBattery.lnk'),
                 $oldCfg) {
    if (Test-Path $old) { Remove-Item $old -Recurse -Force -ErrorAction SilentlyContinue }
}

# 2. copy files
Write-Host ('  ' + (Tr 'inst_copy' $dest))
$same = (Resolve-Path $src).Path.TrimEnd('\') -eq $dest.TrimEnd('\')
if (-not $same) {
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory $dest -Force | Out-Null
    Copy-Item (Join-Path $src '*') $dest -Recurse -Force
}
# files from a downloaded ZIP carry the "downloaded from the internet" mark; remove it
Get-ChildItem $dest -Recurse -File | Unblock-File

# 3. Start Menu shortcuts
New-Item -ItemType Directory $startMenu -Force | Out-Null
$sh = New-Object -ComObject WScript.Shell
function New-Shortcut($path, $target, $arguments, $icon) {
    $l = $sh.CreateShortcut($path)
    $l.TargetPath = $target; $l.Arguments = $arguments; $l.WorkingDirectory = $dest
    if ($icon) { $l.IconLocation = $icon }
    $l.Save()
}
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$psExe   = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$icon    = Join-Path $dest 'assets\icon.ico'
New-Shortcut (Join-Path $startMenu 'BatteryRings.lnk') $wscript ('"' + (Join-Path $dest 'Widget.vbs') + '"') $icon
New-Shortcut (Join-Path $startMenu 'Uninstall BatteryRings.lnk') $psExe ('-NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $dest 'Uninstall.ps1') + '"') $null
Write-Host ('  ' + (Tr 'inst_shortcut'))

# 4. autostart (default: yes; an update keeps the current choice)
$auto = $true
if ($Update) { $auto = Test-Path $startupLnk }
elseif (-not $Quiet) {
    $ans = Read-Host ('  ' + (Tr 'inst_autostart'))
    $auto = $ans -notmatch '^\s*[nN]'
}
if ($auto) { New-Shortcut $startupLnk $wscript ('"' + (Join-Path $dest 'Widget.vbs') + '"') $icon }
elseif (Test-Path $startupLnk) { Remove-Item $startupLnk -Force }

# 5. start the widget
Start-Process $wscript -ArgumentList ('"' + (Join-Path $dest 'Widget.vbs') + '"')

Write-Host ''
Write-Host ('  ' + (Tr 'inst_done')) -ForegroundColor Green
Write-Host ''
if (-not $Quiet) { [void](Read-Host ('  ' + (Tr 'press_key'))) }
