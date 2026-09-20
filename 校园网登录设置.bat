@echo off
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0campus-login.ps1" -Mode gui
