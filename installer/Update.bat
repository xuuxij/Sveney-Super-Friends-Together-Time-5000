@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0pack\Update.ps1" %*
pause
