@echo off
rem Shared launcher, called by the root run-agent.bat: [harness] [args...]. Without a harness (first
rem argument not listed in agents\harness-dirs) a menu picks one and all arguments go to it.
rem Writes only gitignored paths.
setlocal disableDelayedExpansion
cd /d "%~dp0.."

rem Arguments are collected before delayed expansion is on, so quotes and ! survive; the last
rem command runs with it off again.
set "HARNESS="
if not "%~1"=="" for /f "usebackq eol=# tokens=1" %%H in ("agents\harness-dirs") do if "%%H"=="%~1" set "HARNESS=%%H"
if defined HARNESS shift
set "ARGS="
:collect
if "%~1"=="" goto collected
set ARGS=%ARGS% %1
shift
goto collect
:collected
setlocal enabledelayedexpansion

rem Without a terminal (stdin redirected: CI, pipes) compose can't allocate a tty and fails; -T skips it.
set "TTYFLAG="
for /f "usebackq" %%T in (`powershell -NoProfile -Command "if ([Console]::IsInputRedirected) { '-T' }"`) do set "TTYFLAG=%%T"

rem .env: created from the example, and refused until the user has edited it.
if not exist .env copy .env.example .env >nul
fc .env.example .env >nul && (echo Edit .env first & pause & exit /b 1)
for /f "delims==" %%K in ('findstr /r /b "[A-Z_]*=" .env.example') do (
    findstr /b /c:"%%K=" .env >nul || echo Warning: %%K is missing in .env ^(see .env.example^)
)

rem Settings: a non-empty shell variable wins over .env, like compose's own interpolation.
rem Prebuilt images come from ghcr.io unless AGENTS_LOCAL_BUILD is non-empty; they are <prefix>-<harness>:<hash>,
rem the base image <prefix>-base:<hash>.
for %%V in (WORKSPACE_DIR AGENTS_LOCAL_BUILD AGENTS_IMAGE_PREFIX) do if not defined %%V for /f "usebackq tokens=1,* delims==" %%A in (".env") do if "%%A"=="%%V" if not "%%B"=="" set "%%V=%%~B"
if not defined AGENTS_IMAGE_PREFIX set "AGENTS_IMAGE_PREFIX=ghcr.io/lhns/agent-workspace"
if defined WORKSPACE_DIR (
    if not exist "!WORKSPACE_DIR!\" (echo WORKSPACE_DIR '!WORKSPACE_DIR!' does not exist & exit /b 1)
) else (
    if not exist workspace mkdir workspace
)

rem The workspace is mounted at its host path (C:\code\foo becomes /c/code/foo), so harnesses that key
rem sessions by directory keep them per host folder. A path with no drive letter falls back to /workspace.
set "WS=workspace"
if defined WORKSPACE_DIR set "WS=!WORKSPACE_DIR!"
for %%I in ("!WS!") do set "WS_ABS=%%~fI"
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "$p = $env:WS_ABS.Replace('\', '/'); if ($p.Length -ge 2 -and $p[1] -eq ':') { '/' + $p.Substring(0, 1).ToLower() + $p.Substring(2).TrimEnd('/') } else { '/workspace' }"`) do set "AGENTS_WORKSPACE_TARGET=%%T"

rem State dirs, so docker doesn't create them as root.
if not exist shared\git mkdir shared\git
if not exist shared\AGENTS.md type nul > shared\AGENTS.md

rem Seed git config from the host once; delete shared\git\config to re-seed.
if not exist shared\git\config (
    set "SRC="
    if defined HOME if exist "%HOME%\.gitconfig" set "SRC=%HOME%\.gitconfig"
    if not defined SRC if exist "%USERPROFILE%\.gitconfig" set "SRC=%USERPROFILE%\.gitconfig"
    if not defined SRC if defined XDG_CONFIG_HOME if exist "%XDG_CONFIG_HOME%\git\config" set "SRC=%XDG_CONFIG_HOME%\git\config"
    if not defined SRC if exist "%USERPROFILE%\.config\git\config" set "SRC=%USERPROFILE%\.config\git\config"
    if defined SRC (
        copy "!SRC!" shared\git\config >nul
        rem Drop values with Windows paths (drive letter, not "https:/"); they're meaningless in the container.
        for /f %%K in ('git config -f shared/git/config --name-only --get-regexp . "(^|[^A-Za-z])[A-Za-z]:[\/]"') do git config -f shared/git/config --unset-all %%K "(^|[^A-Za-z])[A-Za-z]:[\/]"
    ) else (
        type nul > shared\git\config
    )
)

rem shared\.last-harness: "<workspace><TAB><harness>" for this workspace and "*<TAB>..." for anywhere,
rem so the menu offers the last used one first; the picker (agents\pick-harness.sh) writes the same format.
if defined HARNESS goto remember

rem No harness given: the menu runs in the base image, which is ensured first. It records its choice
rem in the state file (compose's exit code can't carry it).
call :ensure base "agents\base\Dockerfile" || exit /b 1
docker compose run --rm %TTYFLAG% base
if errorlevel 1 exit /b %errorlevel%
for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "$k = $env:AGENTS_WORKSPACE_TARGET; $t = [char]9; Get-Content shared\.last-harness -ErrorAction SilentlyContinue | Where-Object { $_.StartsWith($k + $t) } | Select-Object -First 1 | ForEach-Object { $_.Substring($k.Length + 1) }"`) do set "HARNESS=%%H"
if not defined HARNESS (echo No harness chosen & exit /b 1)
findstr /b /c:"!HARNESS! " agents\harness-dirs >nul 2>&1 || (echo No harness chosen & exit /b 1)
goto ready

:remember
powershell -NoProfile -Command "$f = 'shared\.last-harness'; $k = $env:AGENTS_WORKSPACE_TARGET; $t = [char]9; $l = @(); if (Test-Path $f) { $l = @(Get-Content $f | Where-Object { -not $_.StartsWith($k + $t) -and -not $_.StartsWith('*' + $t) }) }; $l += $k + $t + $env:HARNESS; $l += '*' + $t + $env:HARNESS; [IO.File]::WriteAllText($f, ($l -join [char]10) + [char]10)"

:ready
for /f "usebackq eol=# tokens=1,*" %%H in ("agents\harness-dirs") do if "%%H"=="%HARNESS%" for %%D in (%%I) do if not exist "agents\%HARNESS%\%%D" mkdir "agents\%HARNESS%\%%D"
call :ensure %HARNESS% "agents\base\Dockerfile" "agents\%HARNESS%\Dockerfile" || exit /b 1

setlocal disableDelayedExpansion
docker compose run --rm %TTYFLAG% %HARNESS% %ARGS%
exit /b %errorlevel%

rem :ensure NAME DOCKERFILE [DOCKERFILE]  (NAME is base or a harness)
rem Update an image only when its Dockerfiles changed since the last time (much faster than
rem asking docker). The hash is also the ghcr tag, so a pull gets exactly this checkout's
rem image; an edited Dockerfile misses the registry and builds locally. Docker's layer cache
rem keeps a local rebuild short.
:ensure
setlocal
set "E_NAME=%~1"
set "F1=%~2"
set "F2=%~3"
set "HASHFILE=agents\%E_NAME%\.build.sha256"
for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "$b = [IO.File]::ReadAllBytes($env:F1); if ($env:F2) { $b += [IO.File]::ReadAllBytes($env:F2) }; [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b)).Replace('-', '').ToLower()"`) do set "NEW_HASH=%%H"
set "OLD_HASH="
if exist "%HASHFILE%" set /p OLD_HASH=<"%HASHFILE%"
set "CHANGED="
if not "%NEW_HASH%"=="%OLD_HASH%" set "CHANGED=1"
rem A matching hash with the image gone (pruned) counts as changed.
if not defined CHANGED docker image inspect agent-workspace-%E_NAME% >nul 2>&1 || set "CHANGED=1"
if not defined CHANGED exit /b 0
set "REF=%AGENTS_IMAGE_PREFIX%-%E_NAME%:%NEW_HASH%"
set "PULLED="
if not defined AGENTS_LOCAL_BUILD (
    echo Pulling %E_NAME% image...
    docker pull "!REF!"
    if errorlevel 1 (
        echo No prebuilt %E_NAME% image available, building locally.
    ) else (
        docker tag "!REF!" agent-workspace-%E_NAME% || exit /b 1
        docker rmi "!REF!" >nul
        set "PULLED=1"
    )
)
if not defined PULLED (
    echo Building %E_NAME% image...
    if "%E_NAME%"=="base" (
        docker compose build base || exit /b 1
    ) else (
        rem Build on the published or already local base so the layers are shared.
        call :ensure base "agents\base\Dockerfile" || exit /b 1
        docker compose build %E_NAME% || exit /b 1
    )
)
>"%HASHFILE%" echo %NEW_HASH%
exit /b 0
