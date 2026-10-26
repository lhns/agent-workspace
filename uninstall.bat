@echo off
rem Removes what install.bat wrote: the agent-workspace command, its PATH entry and the Explorer entry.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agents\install.ps1" -Uninstall
set "RC=%errorlevel%"
rem Started by double-click: keep the window open to read the result.
echo %cmdcmdline% | find /i "%~dpnx0" >nul && pause
exit /b %RC%
