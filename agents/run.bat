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

docker compose build base || exit /b 1
docker compose run --rm --build %HARNESS% %*
