@echo off
rem Starts uninstall.ps1 with the same options (see uninstall.ps1 or "uninstall.cmd --help").
rem Bypass only applies to this run: Windows blocks downloaded scripts by default.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
set "code=%ERRORLEVEL%"
rem Opened by double-click: keep the window open so the result can be read.
echo %cmdcmdline% | find /i "%~0" >nul && pause
exit /b %code%
