@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0net-switch.ps1" -Mode campus
pause
