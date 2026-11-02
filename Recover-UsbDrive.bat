@echo off
rem Double-click launcher: asks for Administrator rights, then runs the recovery script.
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process -Verb RunAs -FilePath \"%~f0\"" & exit /b)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Recover-UsbDrive.ps1" %*
pause
