@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Replace-Weasel.ps1" -Mode Verify
echo.
pause
