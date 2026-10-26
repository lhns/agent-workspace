@echo off
rem Installs the agent-workspace command and the Explorer entry for this user (see agents\install.ps1).
rem Options: -Update, -Uninstall. Remove it again with uninstall.bat.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0agents\install.ps1" %*
set "RC=%errorlevel%"
rem Started by double-click: keep the window open to read the result.
echo %cmdcmdline% | find /i "%~dpnx0" >nul && pause
exit /b %RC%
