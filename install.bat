@echo off
rem Installs the `agent-workspace` command for this user (no admin) and a right-click entry for folders.
rem Plain batch on purpose: no PowerShell script file, so execution policies (AllSigned) don't get in
rem the way. Remove it again with uninstall.bat.
rem   install.bat [-Update | -Uninstall]
rem Registry mode (reg.exe works):
rem   %LOCALAPPDATA%\agent-workspace\bin\agent-workspace.cmd   the shim: current folder = workspace
rem   that bin folder on the user PATH (HKCU\Environment, kept as REG_EXPAND_SZ)
rem   HKCU\Software\Classes\Directory\shell\agent-workspace and ...\Directory\Background\shell\...
rem Fallback, when a policy disables the registry tools (reg.exe is not worked around, nor setx):
rem   the shim in %LOCALAPPDATA%\Microsoft\WindowsApps if that is on the PATH, else in the bin folder above
rem   %APPDATA%\Microsoft\Windows\SendTo\agent-workspace.cmd   Send to > agent-workspace opens a folder
rem Already installed (either mode): asks to update (default, e.g. after moving this repo), remove or
rem cancel; without a terminal (stdin redirected) the answer is empty, so it updates. -Update /
rem -Uninstall skip the question. Uninstall removes both modes' pieces, whatever exists.
rem
rem Test overrides (environment), so tests never touch the real machine:
rem   AW_INSTALL_BIN_DIR    shim folder            AW_INSTALL_REG_ROOT  registry key path, default HKCU\Software\Classes
rem   AW_INSTALL_PATH_FILE  file standing in for the user PATH   AW_INSTALL_WT  "none" or the wt.exe to use
rem   AW_INSTALL_WINAPPS    fallback shim folder   AW_INSTALL_SENDTO    SendTo folder
rem   AW_INSTALL_NOREG      1 = registry tools disabled; add = reg query works but writes fail
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
set "BINSHIM=%BIN%\agent-workspace.cmd"
set "WA=%AW_INSTALL_WINAPPS%"
if not defined WA set "WA=%LOCALAPPDATA%\Microsoft\WindowsApps"
set "WASHIM=%WA%\agent-workspace.cmd"
set "STDIR=%AW_INSTALL_SENDTO%"
if not defined STDIR set "STDIR=%APPDATA%\Microsoft\Windows\SendTo"
set "STFILE=%STDIR%\agent-workspace.cmd"
set "REGROOT=%AW_INSTALL_REG_ROOT%"
if not defined REGROOT set "REGROOT=HKCU\Software\Classes"
set "BINT=%BIN%"
if "%BINT:~-1%"=="\" set "BINT=%BINT:~0,-1%"

rem Can reg.exe be used? Assumption: with DisableRegistryTools even a read-only query fails, so a
rem succeeding query means writes work too. If a policy only blocks writes, the first failing write
rem is caught below: what was written is undone and the fallback runs.
set "REGOK="
if defined AW_INSTALL_NOREG if not "%AW_INSTALL_NOREG%"=="add" goto :probed
reg query "HKCU\Environment" >nul 2>&1
if not errorlevel 1 set "REGOK=1"
:probed

if "%MODE%"=="uninstall" goto :uninstall
set "EXISTS="
if exist "%BINSHIM%" set "EXISTS=1"
if exist "%WASHIM%" set "EXISTS=1"
if exist "%STFILE%" set "EXISTS=1"
if "%MODE%"=="install" if defined EXISTS call :ask
if "%MODE%"=="uninstall" goto :uninstall
if "%MODE%"=="cancel" echo Nothing changed
if "%MODE%"=="cancel" exit /b 0

rem wt.exe if there is one, else a plain cmd window.
set "WT=%AW_INSTALL_WT%"
if not defined WT set "WT=none"
if not defined AW_INSTALL_WT where wt.exe >nul 2>&1
if not defined AW_INSTALL_WT if not errorlevel 1 set "WT=wt.exe"

if not defined REGOK goto :fallback
call :reginstall
if not errorlevel 1 goto :regdone
rem A registry write failed (a policy that only blocks writes): undo it, then the fallback.
set "MSG=Writing the registry failed; undoing it and using the fallback"
call :say
call :rmregparts
call :rmfile "%BINSHIM%"
rd "%BIN%" 2>nul
goto :fallback
:regdone
rem Leftovers of a fallback install are redundant now.
call :rmfile "%WASHIM%"
call :rmfile "%STFILE%"
exit /b 0

:fallback
set "MSG=Registry tools are disabled: installing without the registry"
call :say
rem The shim goes next to the Windows Store app aliases when that folder is on the PATH.
set "SHIM=%BINSHIM%"
set "SCANT=%WA%"
if "%SCANT:~-1%"=="\" set "SCANT=%SCANT:~0,-1%"
set "PVAL=%PATH:"=%"
call :scan
set "WAOK="
if exist "%WA%\" if defined ONPATH set "WAOK=1"
if defined WAOK set "SHIM=%WASHIM%"
if defined WAOK call :rmfile "%BINSHIM%"
if not defined WAOK if not exist "%BIN%\" mkdir "%BIN%"
if defined WAOK rd "%BIN%" 2>nul
call :writeshim
if errorlevel 1 exit /b 1
set "MSG=Installed %SHIM% -> %REPO%"
call :say
if not defined WAOK set "MSG=%WA% is not on your PATH, so add %BIN% to it (Windows settings, or: rundll32 sysdm.cpl,EditEnvironmentVariables), or call the shim by its full path"
if not defined WAOK call :say
if not exist "%STDIR%\" mkdir "%STDIR%"
call :writesendto
if errorlevel 1 exit /b 1
set "MSG=Added the SendTo entry: right-click a folder, Send to, agent-workspace (Windows 11: under Show more options)"
call :say
exit /b 0

rem Registry mode. Exit 1 on the first failure (the caller undoes what was written).
:reginstall
rem The shim is CRLF in the OEM code page cmd reads batch files in (echo writes both).
set "SHIM=%BINSHIM%"
if not exist "%BIN%\" mkdir "%BIN%"
call :writeshim
if errorlevel 1 exit /b 1
set "MSG=Installed %SHIM% -> %REPO%"
call :say

call :getpath
set "SCANT=%BINT%"
call :scan
if defined ONPATH goto :regkeys
if defined NEWPATH (set "NEWPATH=%NEWPATH%;%BIN%") else set "NEWPATH=%BIN%"
call :setpath
if errorlevel 1 exit /b 1
set "MSG=Added %BIN% to the user PATH (open a new terminal to use agent-workspace)"
call :say

:regkeys
call :regwrite "%REGROOT%\Directory\shell\agent-workspace"
if errorlevel 1 exit /b 1
call :regwrite "%REGROOT%\Directory\Background\shell\agent-workspace"
if errorlevel 1 exit /b 1
echo Added the Explorer entry 'Open with agent-workspace' (Windows 11: under Show more options)
exit /b 0

rem Removes everything either mode wrote, whatever exists. Without reg.exe the registry parts are skipped.
:uninstall
set "ANY="
set "URC=0"
call :rmfile "%BINSHIM%"
if defined ANY set "BINGONE=1"
rd "%BIN%" 2>nul
call :rmfile "%WASHIM%"
call :rmfile "%STFILE%"
if defined REGOK call :rmregparts
if defined REGOK if errorlevel 1 set "URC=1"
if not defined REGOK if defined BINGONE echo reg.exe is disabled here: a user PATH entry and Explorer entries from a registry-mode install could not be checked or removed
if not defined ANY echo agent-workspace is not installed
exit /b %URC%

rem The user PATH entry and the Explorer keys.
:rmregparts
call :getpath
set "SCANT=%BINT%"
call :scan
if defined ONPATH call :setpath
if defined ONPATH if errorlevel 1 exit /b 1
if defined ONPATH set "MSG=Removed %BIN% from the user PATH"
if defined ONPATH call :say
if defined ONPATH set "ANY=1"
call :delkey "%REGROOT%\Directory\shell\agent-workspace"
call :delkey "%REGROOT%\Directory\Background\shell\agent-workspace"
exit /b 0

:rmfile
if not exist "%~1" exit /b 0
del "%~1"
set "MSG=Removed %~1"
call :say
set "ANY=1"
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
set "CURF=%BINSHIM%"
if not exist "%CURF%" set "CURF=%WASHIM%"
if exist "%CURF%" for /f usebackq^ tokens^=2^ delims^=^" %%R in (`findstr /b /c:"call " "%CURF%"`) do set "CUR=%%~dpR"
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

rem PVAL split at ; -> ONPATH (1 if SCANT is an entry) and NEWPATH (the entries without SCANT).
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
if /i "%E2%"=="%SCANT%" (set "ONPATH=1") else if defined NEWPATH (set "NEWPATH=%NEWPATH%;%ENTRY%") else set "NEWPATH=%ENTRY%"
goto :scanloop

rem NEWPATH -> user PATH, then an environment-change broadcast (setx of a dummy variable, then delete it).
:setpath
if "%AW_INSTALL_NOREG%"=="add" exit /b 1
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
if "%AW_INSTALL_NOREG%"=="add" exit /b 1
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

rem The Send to entry: opens a terminal in the selected folder, or in a selected file's folder. Send to
rem passes every selected item as an argument; only the first is used (one terminal, no window flood).
rem Without an argument it uses the current folder. Quotes keep & ( ) in paths literal; ^&^& reaches
rem the new cmd as && (written with carets so the batch file itself doesn't split at it). With wt.exe
rem there is no start: wt hands over to Windows Terminal and returns at once.
:writesendto
setlocal enableDelayedExpansion
set "AMP=^&^&"
>"!STFILE!" echo @echo off
>>"!STFILE!" echo setlocal
>>"!STFILE!" echo set "D=%%~1"
>>"!STFILE!" echo if not defined D set "D=%%CD%%"
>>"!STFILE!" echo if not exist "%%D%%\" for %%%%F in ("%%D%%") do set "D=%%%%~dpF"
>>"!STFILE!" echo if not "%%D:~-1%%"=="\" set "D=%%D%%\"
if /i "!WT!"=="none" >>"!STFILE!" echo start "" cmd /k pushd "%%D%%" !AMP! "!SHIM!"
if /i not "!WT!"=="none" >>"!STFILE!" echo "!WT!" -d "%%D%%." cmd /k "!SHIM!"
exit /b 0
