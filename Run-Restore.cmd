@echo off
rem Restores files from the backup on this drive. Double-click it.
rem Add -NoAnim (no animation) or -Plain (no colors, ASCII only) after the command if you want.
chcp 65001 >nul
color 0E
title ALA EH! :: RESTORE
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0restore-usb.ps1" %*
echo.
pause
