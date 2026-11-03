@echo off
rem SahelFlow PC check - double-click this file.
rem It runs sahelflow-pc-check.ps1 (same folder) with: -Launch -Twice
rem It reads and measures only. It sends nothing anywhere.
title SahelFlow PC check
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sahelflow-pc-check.ps1" -Launch -Twice -NoPause
echo.
echo The check is finished. You can close this window.
pause
