@echo off
rem BatteryRings installer - double-click to install (no admin rights needed)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\Install.ps1" %*
