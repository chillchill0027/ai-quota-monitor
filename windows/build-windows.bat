@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-windows.ps1" %*
set "result=%ERRORLEVEL%"
pause
exit /b %result%
