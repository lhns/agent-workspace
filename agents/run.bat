@echo off
rem Shared launcher, called by run-<harness>.bat with HARNESS set. Writes only gitignored paths.
setlocal enabledelayedexpansion
cd /d "%~dp0.."

rem .env: created from the example, and refused until the user has edited it.
if not exist .env copy .env.example .env >nul
fc .env.example .env >nul && (echo Edit .env first & pause & exit /b 1)
for /f "delims==" %%K in ('findstr /r /b "[A-Z_]*=" .env.example') do (
    findstr /b /c:"%%K=" .env >nul || echo Warning: %%K is missing in .env ^(see .env.example^)
)

rem Workspace: shell env wins over .env, like compose's own interpolation.
if not defined WORKSPACE_DIR for /f "usebackq tokens=1,* delims==" %%A in (".env") do if "%%A"=="WORKSPACE_DIR" if not "%%B"=="" set "WORKSPACE_DIR=%%~B"
rem Prebuilt images come from ghcr.io unless AGENTS_LOCAL_BUILD is non-empty (shell env wins over .env).
if not defined AGENTS_LOCAL_BUILD for /f "usebackq tokens=1,* delims==" %%A in (".env") do if "%%A"=="AGENTS_LOCAL_BUILD" if not "%%B"=="" set "AGENTS_LOCAL_BUILD=%%~B"
rem Prebuilt images are <prefix>-<harness>:<hash>; shell env wins over .env.
if not defined AGENTS_IMAGE_PREFIX for /f "usebackq tokens=1,* delims==" %%A in (".env") do if "%%A"=="AGENTS_IMAGE_PREFIX" if not "%%B"=="" set "AGENTS_IMAGE_PREFIX=%%~B"
if not defined AGENTS_IMAGE_PREFIX set "AGENTS_IMAGE_PREFIX=ghcr.io/lhns/agent-workspace"
if defined WORKSPACE_DIR (
    if not exist "!WORKSPACE_DIR!\" (echo WORKSPACE_DIR '!WORKSPACE_DIR!' does not exist & exit /b 1)
) else (
    if not exist workspace mkdir workspace
)

rem State dirs, so docker doesn't create them as root.
if not exist shared\git mkdir shared\git
if not exist shared\AGENTS.md type nul > shared\AGENTS.md
for /f "usebackq eol=# tokens=1,*" %%H in ("agents\harness-dirs") do if "%%H"=="%HARNESS%" for %%D in (%%I) do if not exist "agents\%HARNESS%\%%D" mkdir "agents\%HARNESS%\%%D"

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

rem Update the image only when a Dockerfile changed since the last time (much faster than
rem asking docker). The hash is also the ghcr tag, so a pull gets exactly this checkout's
rem image; an edited Dockerfile misses the registry and builds locally. Docker's layer cache
rem keeps a local rebuild short.
set "HASHFILE=agents\%HARNESS%\.build.sha256"
for /f "usebackq delims=" %%H in (`powershell -NoProfile -Command "$b = [IO.File]::ReadAllBytes('agents\base\Dockerfile') + [IO.File]::ReadAllBytes('agents\%HARNESS%\Dockerfile'); [BitConverter]::ToString([Security.Cryptography.SHA256]::Create().ComputeHash($b)).Replace('-', '').ToLower()"`) do set "NEW_HASH=%%H"
set "OLD_HASH="
if exist "%HASHFILE%" set /p OLD_HASH=<"%HASHFILE%"
if not "%NEW_HASH%"=="%OLD_HASH%" (
    set "REF=%AGENTS_IMAGE_PREFIX%-%HARNESS%:%NEW_HASH%"
    set "PULLED="
    if not defined AGENTS_LOCAL_BUILD (
        echo Pulling %HARNESS% image...
        docker pull "!REF!"
        if errorlevel 1 (
            echo No prebuilt %HARNESS% image available, building locally.
        ) else (
            docker tag "!REF!" agent-workspace-%HARNESS% || exit /b 1
            docker rmi "!REF!" >nul
            set "PULLED=1"
        )
    )
    if not defined PULLED (
        echo Building %HARNESS% image...
        docker compose build base || exit /b 1
        docker compose build %HARNESS% || exit /b 1
    )
    >"%HASHFILE%" echo %NEW_HASH%
)

docker compose run --rm %HARNESS% %*
