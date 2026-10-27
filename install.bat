@echo off
rem Installs the `agent-workspace` command for this user (no admin) and an Explorer entry
rem "Open with agent-workspace" for folders. Plain batch on purpose: no PowerShell script file, so
rem execution policies (AllSigned) don't get in the way. Remove it again with uninstall.bat.
rem   install.bat [-Update | -Uninstall]
rem It writes:
rem   %LOCALAPPDATA%\agent-workspace\bin\agent-workspace.cmd   the shim: current folder = workspace
rem   that bin folder on the user PATH (HKCU\Environment, kept as REG_EXPAND_SZ)
rem   HKCU\Software\Classes\Directory\shell\agent-workspace and ...\Directory\Background\shell\...
rem Already installed: asks to update (default, e.g. after moving this repo), remove or cancel;
rem without a terminal (stdin redirected) the answer is empty, so it updates. -Update / -Uninstall skip the question.
rem
rem Test overrides (environment), so tests never touch the real machine:
rem   AW_INSTALL_BIN_DIR    shim folder            AW_INSTALL_REG_ROOT  registry key path, default HKCU\Software\Classes
rem   AW_INSTALL_PATH_FILE  file standing in for the user PATH   AW_INSTALL_WT  "none" or the wt.exe to use
rem
rem Delayed expansion is off, so ! in PATH entries survives; the subroutines that write paths into
rem files and registry values turn it on and use !VAR!, so ) & ! in paths can't break parsing.
rem Messages go through a quoted set "MSG=..." and :say (echo of !MSG!), never echo %VAR% directly.
setlocal disableDelayedExpansion
set "MODE=install"
if /i "%~1"=="-Update" set "MODE=update"
if /i "%~1"=="-Uninstall" set "MODE=uninstall"
set "REPO=%~dp0"
if "%REPO:~-1%"=="\" set "REPO=%REPO:~0,-1%"
call :main
set "RC=%errorlevel%"
rem Started by double-click: keep the window open to read the result.
set "CL=%cmdcmdline:"=%"
call set "CL2=%%CL:%~f0=%%"
if not "%CL2%"=="%CL%" pause
exit /b %RC%

:main
set "BIN=%AW_INSTALL_BIN_DIR%"
if not defined BIN set "BIN=%LOCALAPPDATA%\agent-workspace\bin"
set "SHIM=%BIN%\agent-workspace.cmd"
set "REGROOT=%AW_INSTALL_REG_ROOT%"
if not defined REGROOT set "REGROOT=HKCU\Software\Classes"
set "BINT=%BIN%"
if "%BINT:~-1%"=="\" set "BINT=%BINT:~0,-1%"

if "%MODE%"=="uninstall" goto :uninstall
if "%MODE%"=="install" if exist "%SHIM%" call :ask
if "%MODE%"=="uninstall" goto :uninstall
if "%MODE%"=="cancel" echo Nothing changed
if "%MODE%"=="cancel" exit /b 0

rem Install. The shim is CRLF in the OEM code page cmd reads batch files in (echo writes both).
if not exist "%BIN%\" mkdir "%BIN%"
call :writeshim
if errorlevel 1 exit /b 1
set "MSG=Installed %SHIM% -> %REPO%"
call :say

call :getpath
call :scan
if defined ONPATH goto :wt
if defined NEWPATH (set "NEWPATH=%NEWPATH%;%BIN%") else set "NEWPATH=%BIN%"
call :setpath
if errorlevel 1 exit /b 1
set "MSG=Added %BIN% to the user PATH (open a new terminal to use agent-workspace)"
call :say

:wt
rem wt.exe if there is one, else a plain cmd window.
set "WT=%AW_INSTALL_WT%"
if not defined WT set "WT=none"
if not defined AW_INSTALL_WT where wt.exe >nul 2>&1
if not defined AW_INSTALL_WT if not errorlevel 1 set "WT=wt.exe"
call :regwrite "%REGROOT%\Directory\shell\agent-workspace"
if errorlevel 1 exit /b 1
call :regwrite "%REGROOT%\Directory\Background\shell\agent-workspace"
if errorlevel 1 exit /b 1
echo Added the Explorer entry 'Open with agent-workspace' (Windows 11: under Show more options)
exit /b 0

:uninstall
set "ANY="
if not exist "%SHIM%" goto :u_path
del "%SHIM%"
rem Only removes the folder if it is empty.
rd "%BIN%" 2>nul
set "MSG=Removed %SHIM%"
call :say
set "ANY=1"
:u_path
call :getpath
call :scan
if not defined ONPATH goto :u_reg
call :setpath
if errorlevel 1 exit /b 1
set "MSG=Removed %BIN% from the user PATH"
call :say
set "ANY=1"
:u_reg
call :delkey "%REGROOT%\Directory\shell\agent-workspace"
call :delkey "%REGROOT%\Directory\Background\shell\agent-workspace"
if not defined ANY echo agent-workspace is not installed
exit /b 0

:delkey
reg query "%~1" >nul 2>&1
if errorlevel 1 exit /b 0
reg delete "%~1" /f >nul
set "MSG=Removed %~1"
call :say
set "ANY=1"
exit /b 0

rem Existing install: update (default), remove or cancel. With stdin redirected set /p reads
rem nothing, so the answer stays empty and it updates.
:ask
set "CUR=?"
for /f usebackq^ tokens^=2^ delims^=^" %%R in (`findstr /b /c:"call " "%SHIM%"`) do set "CUR=%%~dpR"
if "%CUR:~-1%"=="\" set "CUR=%CUR:~0,-1%"
set "ANS="
set /p "ANS=agent-workspace is already installed (-> %CUR%). [U]pdate / [r]emove / [c]ancel? "
if not defined ANS exit /b 0
set "ANS=%ANS:"=%"
if /i "%ANS:~0,1%"=="r" set "MODE=uninstall"
if /i "%ANS:~0,1%"=="u" exit /b 0
if "%MODE%"=="install" set "MODE=cancel"
exit /b 0

rem Prints MSG; delayed expansion, so & ) ^ in paths are text, not syntax.
:say
setlocal enableDelayedExpansion
echo(!MSG!
exit /b 0

rem User PATH -> PVAL (as stored, %VARS% unexpanded) and PTYPE.
:getpath
set "PVAL="
set "PTYPE=REG_EXPAND_SZ"
if defined AW_INSTALL_PATH_FILE goto :getfile
for /f "tokens=1,2,*" %%A in ('reg query "HKCU\Environment" /v Path 2^>nul ^| findstr /c:"REG_"') do set "PTYPE=%%B" & set "PVAL=%%C"
exit /b 0
:getfile
if exist "%AW_INSTALL_PATH_FILE%" for /f "usebackq eol=| delims=" %%L in ("%AW_INSTALL_PATH_FILE%") do set "PVAL=%%L"
exit /b 0

rem PVAL split at ; -> ONPATH (1 if BIN is an entry) and NEWPATH (the entries without BIN).
rem Goto loop, no parenthesized blocks: entries like C:\Program Files (x86)\x contain ).
:scan
set "ONPATH="
set "NEWPATH="
set "REST=%PVAL%"
:scanloop
if not defined REST exit /b 0
set "ENTRY="
for /f "tokens=1* delims=;" %%A in ("%REST%") do set "ENTRY=%%A" & set "REST=%%B"
if not defined ENTRY exit /b 0
set "E2=%ENTRY%"
if "%E2:~-1%"=="\" set "E2=%E2:~0,-1%"
if /i "%E2%"=="%BINT%" (set "ONPATH=1") else if defined NEWPATH (set "NEWPATH=%NEWPATH%;%ENTRY%") else set "NEWPATH=%ENTRY%"
goto :scanloop

rem NEWPATH -> user PATH, then an environment-change broadcast (setx of a dummy variable, then delete it).
:setpath
if defined AW_INSTALL_PATH_FILE goto :setfile
rem A trailing \ would escape reg's closing quote.
if defined NEWPATH if "%NEWPATH:~-1%"=="\" set "NEWPATH=%NEWPATH%;"
reg add "HKCU\Environment" /v Path /t %PTYPE% /d "%NEWPATH%" /f >nul
if errorlevel 1 exit /b 1
setx AGENT_WORKSPACE_NOTIFY 1 >nul
reg delete "HKCU\Environment" /v AGENT_WORKSPACE_NOTIFY /f >nul 2>&1
exit /b 0
:setfile
setlocal enableDelayedExpansion
>"!AW_INSTALL_PATH_FILE!" echo(!NEWPATH!
exit /b 0

rem The current folder becomes the workspace; an explicit --workdir still wins (run.bat applies it last).
:writeshim
setlocal enableDelayedExpansion
>"!SHIM!" echo @echo off
>>"!SHIM!" echo setlocal
>>"!SHIM!" echo set "WORKSPACE_DIR=%%CD%%"
>>"!SHIM!" echo call "!REPO!\run-agent.bat" %%*
exit /b 0

rem One Explorer entry: name, icon, command. /k keeps the shell open after the agent exits, so errors
rem stay readable. pushd also handles network folders. "%V." because wt mangles a trailing
rem backslash (a drive root) before the closing quote. \" is reg's escape for a quote in /d.
:regwrite
set "K=%~1"
setlocal enableDelayedExpansion
set "AMP=&&"
set "CMDV=cmd.exe /k pushd \"%%V\" !AMP! \"!SHIM!\""
if /i not "!WT!"=="none" set "CMDV=!WT! -d \"%%V.\" cmd /k \"!SHIM!\""
reg add "!K!" /ve /d "Open with agent-workspace" /f >nul
if errorlevel 1 exit /b 1
reg add "!K!" /v Icon /d cmd.exe /f >nul
if errorlevel 1 exit /b 1
reg add "!K!\command" /ve /d "!CMDV!" /f >nul
if errorlevel 1 exit /b 1
exit /b 0
