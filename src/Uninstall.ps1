# Uninstall.ps1 - stop the widget, remove shortcuts and installed files
param([switch]$Quiet)

$dest = Join-Path $env:LOCALAPPDATA 'Programs\BatteryRings'
. (Join-Path $PSScriptRoot 'i18n.ps1')

$startMenu  = Join-Path ([Environment]::GetFolderPath('Programs')) 'BatteryRings'
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'BatteryRings.lnk'
$cfgDir     = Join-Path $env:APPDATA 'BatteryRings'

Write-Host ''
Write-Host "  $(Tr 'uninst_title')" -ForegroundColor Cyan
Write-Host ''

Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'Widget\.ps1' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 500

foreach ($p in $startupLnk, $startMenu) { if (Test-Path $p) { Remove-Item $p -Recurse -Force } }

$delCfg = $false
if (-not $Quiet) { $delCfg = (Read-Host ('  ' + (Tr 'uninst_conf'))) -match '^\s*[yY]' }
if ($delCfg -and (Test-Path $cfgDir)) { Remove-Item $cfgDir -Recurse -Force }

# this script may be running from $dest; PowerShell has already read it, so the folder can be removed
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }

Write-Host ('  ' + (Tr 'uninst_done')) -ForegroundColor Green
Write-Host ''
if (-not $Quiet) { [void](Read-Host ('  ' + (Tr 'press_key'))) }
