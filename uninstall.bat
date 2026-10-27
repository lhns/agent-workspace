@echo off
rem Removes what install.bat wrote: the agent-workspace command, its PATH entry and the Explorer entry.
call "%~dp0install.bat" -Uninstall
set "RC=%errorlevel%"
rem Started by double-click: keep the window open to read the result.
set "CL=%cmdcmdline:"=%"
call set "CL2=%%CL:%~f0=%%"
if not "%CL2%"=="%CL%" pause
exit /b %RC%
