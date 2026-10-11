@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pack\Uninstall.ps1" %*
pause
