@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pack\Install.ps1" %*
pause
