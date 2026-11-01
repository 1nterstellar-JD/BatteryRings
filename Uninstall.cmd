@echo off
rem BatteryRings uninstaller
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Uninstall.ps1" %*
