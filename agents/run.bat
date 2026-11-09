@echo off
rem Host side of the launcher, called by the root run-agent.bat: [--workdir DIR] [options] [harness] [harness args...].
rem It does what must run on the host (.env, workspace path, image pull/build, docker compose);
rem the options, the harness menu and shared\.last-harness are agents\launch.sh, run in the base
rem image with %* untouched. Its result comes back in shared\.launch\<id>. Writes only gitignored paths.
rem Delayed expansion stays off in the main part, so ! in arguments survives; it is on in the
rem subroutines. Known limit: % in arguments is expanded by cmd (twice via the root launcher).
setlocal disableDelayedExpansion
rem A leading --workdir DIR is the workspace (beats the shell and .env). %~f2 resolves it against the
rem caller's folder, so it must come before the cd below. %* stays untouched: the core skips it.
if /i "%~1"=="--workdir" if "%~2"=="" >&2 echo --workdir needs a folder& exit /b 1
if /i "%~1"=="--workdir" set "WORKSPACE_DIR=%~f2"
cd /d "%~dp0.."

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
for %%V in (WORKSPACE_DIR AGENTS_LOCAL_BUILD AGENTS_IMAGE_PREFIX AGENTS_PLATFORM) do if not defined %%V for /f "usebackq tokens=1,* delims==" %%A in (".env") do if "%%A"=="%%V" if not "%%B"=="" set "%%V=%%~B"
if not defined AGENTS_IMAGE_PREFIX set "AGENTS_IMAGE_PREFIX=ghcr.io/lhns/agent-workspace"

rem Linux or Windows containers: whatever the daemon runs, unless AGENTS_PLATFORM says otherwise.
rem Windows containers use their own images, names and paths (ADR 26); the Linux ones stay as they were.
if not defined AGENTS_PLATFORM for /f "usebackq delims=" %%P in (`docker info -f "{{.OSType}}" 2^>nul`) do set "AGENTS_PLATFORM=%%P"
if /i "%AGENTS_PLATFORM%"=="windows" (set "AGENTS_PLATFORM=windows") else (set "AGENTS_PLATFORM=linux")
rem The files that make up the images: the Dockerfiles, and on Windows the base's install script.
set "IMG_SUFFIX="
set "DF_EXT="
set "BASE_DF=agents\base\Dockerfile"
set "BASE_DF2="
if "%AGENTS_PLATFORM%"=="windows" (
    set "IMG_SUFFIX=-windows"
    set "DF_EXT=.windows"
    set "BASE_DF=agents\base\Dockerfile.windows"
    set "BASE_DF2=agents\base\install.ps1"
    set "AGENTS_IMAGE_SUFFIX=-windows"
    set "AGENTS_DOCKERFILE=Dockerfile.windows"
    set "AGENTS_DIR=C:/agent-workspace"
    set "AGENTS_HOME=C:/Users/ContainerAdministrator"
    set "AGENTS_HERMES_STATE=C:/Users/ContainerAdministrator/AppData/Local/hermes/profiles/agent"
)
if not defined WORKSPACE_DIR if not exist workspace mkdir workspace
if defined WORKSPACE_DIR if not exist "%WORKSPACE_DIR%\" >&2 echo WORKSPACE_DIR '%WORKSPACE_DIR%' does not exist& exit /b 1

rem The workspace is mounted at its host path (C:\code\foo becomes /c/code/foo; C:\code\foo itself for
rem Windows containers, where only C: works and any other drive goes to C:\workspace), so harnesses that key
rem sessions by directory keep them per host folder. A path with no drive letter falls back to /workspace
rem (C:\workspace). The container side guards it further (launch.sh), and the result is read back below.
set "WS=workspace"
if defined WORKSPACE_DIR set "WS=%WORKSPACE_DIR%"
for %%I in ("%WS%") do set "WS_ABS=%%~fI"
for /f "usebackq delims=" %%T in (`powershell -NoProfile -Command "if ($env:AGENTS_PLATFORM -eq 'windows') { if ($env:WS_ABS -match '^[cC]:\\') { 'C:' + $env:WS_ABS.Substring(2).TrimEnd('\') } else { 'C:\workspace' } } else { $p = $env:WS_ABS.Replace('\', '/'); if ($p.Length -ge 2 -and $p[1] -eq ':') { '/' + $p.Substring(0, 1).ToLower() + $p.Substring(2).TrimEnd('/') } else { '/workspace' } }"`) do set "AGENTS_WORKSPACE_TARGET=%%T"

rem State dirs, so docker doesn't create them as root. The launch dir is made here (not in the
rem container) so this script can delete it afterwards.
set "AGENTS_RUN_ID=%RANDOM%%RANDOM%"
if not exist shared\git mkdir shared\git
if not exist shared\remote-docker mkdir shared\remote-docker
if not exist shared\.launch\%AGENTS_RUN_ID% mkdir shared\.launch\%AGENTS_RUN_ID%
rem Your instructions live in a directory (a single file can't be mounted on Windows containers);
rem an older shared\AGENTS.md moves there once.
if not exist shared\instructions mkdir shared\instructions
if not exist shared\instructions\AGENTS.md (
    if exist shared\AGENTS.md (move /y shared\AGENTS.md shared\instructions\AGENTS.md >nul) else type nul > shared\instructions\AGENTS.md
)
rem Leftovers of a killed launcher (Ctrl-C ends a batch file without cleanup).
forfiles /p shared\.launch /d -1 /c "cmd /c if @isdir==TRUE rd /s /q @path" >nul 2>&1
call :seedgit

rem The core (options, harness menu, last-harness) runs in the base image, ensured first, with
rem every argument untouched.
call :ensure base "%BASE_DF%" "%BASE_DF2%" || goto :fail
rem Without a terminal the core must not swallow stdin meant for the harness.
if defined TTYFLAG goto :corenostdin
docker compose run --rm base %*
goto :coredone
:corenostdin
docker compose run --rm -T base %* <nul
:coredone
if errorlevel 1 goto :fail
set "RESULT="
if exist shared\.launch\%AGENTS_RUN_ID%\result set /p RESULT=<shared\.launch\%AGENTS_RUN_ID%\result
if "%RESULT%"=="done" goto :done
if not "%RESULT%"=="launch" goto :noresult

set /p HARNESS=<shared\.launch\%AGENTS_RUN_ID%\harness
rem The workspace path after the core's guard list.
set /p AGENTS_WORKSPACE_TARGET=<shared\.launch\%AGENTS_RUN_ID%\target
call :mkdirs
call :ensure %HARNESS% "%BASE_DF%" "%BASE_DF2%" "agents\%HARNESS%\Dockerfile%DF_EXT%" || goto :fail

rem Recorded only now, so a failed pull or build isn't (the core only computed the content).
move /y shared\.launch\%AGENTS_RUN_ID%\last-harness shared\.last-harness >nul
rem The harness reads its arguments from the launch dir.
docker compose run --rm %TTYFLAG% %HARNESS%
set "RC=%errorlevel%"
rd /s /q shared\.launch\%AGENTS_RUN_ID%
exit /b %RC%

:noresult
>&2 echo Launcher core produced no result
rd /s /q shared\.launch\%AGENTS_RUN_ID%
exit /b 1

:done
rd /s /q shared\.launch\%AGENTS_RUN_ID%
exit /b 0

:fail
set "RC=%errorlevel%"
rd /s /q shared\.launch\%AGENTS_RUN_ID%
exit /b %RC%

rem :mkdirs  creates the harness's state dirs, listed on the dirs="..." line of its harness.sh
:mkdirs
for /f "usebackq tokens=1,* delims==" %%A in (`findstr /b "dirs=" "agents\%HARNESS%\harness.sh"`) do for %%D in (%%~B) do if not exist "agents\%HARNESS%\%%D" mkdir "agents\%HARNESS%\%%D"
exit /b 0

rem :seedgit  seeds the git config from the host once; delete shared\git\config to re-seed.
:seedgit
setlocal enabledelayedexpansion
if exist shared\git\config exit /b 0
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
exit /b 0

rem :ensure NAME FILE FILE FILE  (NAME is base or a harness; the files make up the image, empty ones are skipped)
rem Update an image only when its Dockerfiles changed since the last time (much faster than
rem asking docker). The hash is also the ghcr tag, so a pull gets exactly this checkout's
rem image; an edited Dockerfile misses the registry and builds locally. Docker's layer cache
rem keeps a local rebuild short.
:ensure
setlocal enabledelayedexpansion
set "E_NAME=%~1"
set "F1=%~2"
set "F2=%~3"
set "F3=%~4"
set "HASHFILE=agents\%E_NAME%\.build%IMG_SUFFIX%.sha256"
for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "$b = [byte[]]@(); foreach ($f in $env:F1, $env:F2, $env:F3) { if ($f) { $b += [IO.File]::ReadAllBytes($f) } }; [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b)).Replace('-', '').ToLower()"`) do set "NEW_HASH=%%H"
set "OLD_HASH="
if exist "%HASHFILE%" set /p OLD_HASH=<"%HASHFILE%"
set "CHANGED="
if not "%NEW_HASH%"=="%OLD_HASH%" set "CHANGED=1"
rem A matching hash with the image gone (pruned) counts as changed.
if not defined CHANGED docker image inspect agent-workspace-%E_NAME%%IMG_SUFFIX% >nul 2>&1 || set "CHANGED=1"
if not defined CHANGED exit /b 0
set "REF=%AGENTS_IMAGE_PREFIX%-%E_NAME%:%NEW_HASH%%IMG_SUFFIX%"
set "PULLED="
if not defined AGENTS_LOCAL_BUILD (
    echo Pulling %E_NAME% image...
    docker pull "!REF!"
    if errorlevel 1 (
        echo No prebuilt %E_NAME% image available, building locally.
    ) else (
        docker tag "!REF!" agent-workspace-%E_NAME%%IMG_SUFFIX% || exit /b 1
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
        call :ensure base "%BASE_DF%" "%BASE_DF2%" || exit /b 1
        docker compose build %E_NAME% || exit /b 1
    )
)
>"%HASHFILE%" echo %NEW_HASH%
exit /b 0
