@echo off
rem Runs the backup from this drive. Double-click it.
rem Add -NoAnim (no animation), -Plain (no colors, ASCII only) or -DryRun (write nothing) after the command if you want.
chcp 65001 >nul
color 0E
title ALA EH! :: BACKUP
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0backup-usb.ps1" -Ask %*
echo.
echo Finished. Check backup-log.txt on this drive for details.
pause
