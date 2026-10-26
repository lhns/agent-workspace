# Installs the `agent-workspace` command for this user (no admin) and an Explorer entry
# "Open with agent-workspace" for folders. Called by install.bat / uninstall.bat.
#   install.ps1 [-Update | -Uninstall]
# It writes:
#   %LOCALAPPDATA%\agent-workspace\bin\agent-workspace.cmd   the shim: current folder = workspace
#   that bin folder on the user PATH
#   HKCU\Software\Classes\Directory\shell\agent-workspace and ...\Directory\Background\shell\...
# Already installed: asks to update (default, e.g. after moving this repo), remove or cancel;
# without a terminal it updates. -Update / -Uninstall skip the question.
#
# Test overrides (environment), so tests never touch the real machine:
#   AW_INSTALL_BIN_DIR    shim folder            AW_INSTALL_REG_ROOT  registry root, default HKCU:\Software\Classes
#   AW_INSTALL_PATH_FILE  file standing in for the user PATH   AW_INSTALL_WT  'none' or the wt.exe to use
param([switch]$Update, [switch]$Uninstall)
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path "$PSScriptRoot\..").Path
$binDir = if ($env:AW_INSTALL_BIN_DIR) { $env:AW_INSTALL_BIN_DIR } else { Join-Path $env:LOCALAPPDATA 'agent-workspace\bin' }
$shim = Join-Path $binDir 'agent-workspace.cmd'
$regRoot = if ($env:AW_INSTALL_REG_ROOT) { $env:AW_INSTALL_REG_ROOT } else { 'HKCU:\Software\Classes' }
$regKeys = 'Directory\shell\agent-workspace', 'Directory\Background\shell\agent-workspace' | ForEach-Object { "$regRoot\$_" }

function Get-UserPath {
    if ($env:AW_INSTALL_PATH_FILE) {
        if (Test-Path $env:AW_INSTALL_PATH_FILE) { return (Get-Content $env:AW_INSTALL_PATH_FILE -Raw).Trim() } else { return '' }
    }
    # Unexpanded, so %VARS% in existing entries survive the write back.
    $key = (Get-Item 'HKCU:\Environment')
    $v = $key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    return "$v"
}
function Set-UserPath([string]$value) {
    if ($env:AW_INSTALL_PATH_FILE) { Set-Content $env:AW_INSTALL_PATH_FILE $value -Encoding ASCII; return }
    $key = Get-Item 'HKCU:\Environment'
    $kind = try { $key.GetValueKind('Path') } catch { [Microsoft.Win32.RegistryValueKind]::ExpandString }
    Set-ItemProperty -Path 'HKCU:\Environment' -Name Path -Value $value -Type $kind
    # Setting and clearing a variable through .NET makes it tell running programs to re-read the environment.
    [Environment]::SetEnvironmentVariable('AGENT_WORKSPACE_NOTIFY', '1', 'User')
    [Environment]::SetEnvironmentVariable('AGENT_WORKSPACE_NOTIFY', $null, 'User')
}
function Test-SameDir([string]$a, [string]$b) { $a.TrimEnd('\') -ieq $b.TrimEnd('\') }
function Test-OnPath { (Get-UserPath) -split ';' | Where-Object { $_ -and (Test-SameDir $_ $binDir) } | Select-Object -First 1 }

# The repo the shim points to.
function Get-Current {
    $m = [regex]::Match((Get-Content $shim -Raw), 'call "(.+)\\run-agent\.bat"')
    if ($m.Success) { $m.Groups[1].Value } else { '?' }
}

function Invoke-Uninstall {
    $removed = @()
    if (Test-Path $shim) {
        Remove-Item $shim
        $removed += $shim
        if (-not (Get-ChildItem $binDir -Force)) { Remove-Item $binDir }
    }
    if (Test-OnPath) {
        $kept = (Get-UserPath) -split ';' | Where-Object { $_ -and -not (Test-SameDir $_ $binDir) }
        Set-UserPath ($kept -join ';')
        $removed += "$binDir from the user PATH"
    }
    foreach ($k in $regKeys) {
        if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse; $removed += $k }
    }
    if ($removed) { $removed | ForEach-Object { Write-Host "Removed $_" } } else { Write-Host 'agent-workspace is not installed' }
}

function Invoke-Install {
    New-Item -ItemType Directory -Force $binDir | Out-Null
    # CRLF, in the OEM code page cmd reads batch files in. The current folder becomes the workspace;
    # an explicit --workdir still wins (run.bat applies it last).
    $text = "@echo off`r`nsetlocal`r`nset `"WORKSPACE_DIR=%CD%`"`r`ncall `"$repo\run-agent.bat`" %*`r`n"
    $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
    [IO.File]::WriteAllText($shim, $text, $oem)
    Write-Host "Installed $shim -> $repo"

    if (-not (Test-OnPath)) {
        $p = Get-UserPath
        Set-UserPath ($(if ($p) { $p.TrimEnd(';') + ';' } else { '' }) + $binDir)
        Write-Host "Added $binDir to the user PATH (open a new terminal to use agent-workspace)"
    }

    # wt.exe if there is one, else a plain cmd window. /k keeps the shell open after the agent exits,
    # so errors stay readable. pushd also handles network folders. "%V." because wt mangles a
    # trailing backslash (a drive root) before the closing quote.
    $wt = if ($env:AW_INSTALL_WT) { $env:AW_INSTALL_WT } elseif (Get-Command wt.exe -ErrorAction SilentlyContinue) { 'wt.exe' } else { 'none' }
    $command = if ($wt -ne 'none') { "$wt -d `"%V.`" cmd /k `"$shim`"" } else { "cmd.exe /k pushd `"%V`" && `"$shim`"" }
    foreach ($k in $regKeys) {
        New-Item -Path $k -Force | Out-Null
        Set-ItemProperty -LiteralPath $k -Name '(default)' -Value 'Open with agent-workspace'
        Set-ItemProperty -LiteralPath $k -Name 'Icon' -Value 'cmd.exe'
        New-Item -Path "$k\command" -Force | Out-Null
        Set-ItemProperty -LiteralPath "$k\command" -Name '(default)' -Value $command
    }
    Write-Host "Added the Explorer entry 'Open with agent-workspace' (Windows 11: under Show more options)"
}

if ($Uninstall) { Invoke-Uninstall; exit 0 }
if (-not $Update -and (Test-Path $shim)) {
    if (-not [Console]::IsInputRedirected) {
        $answer = Read-Host "agent-workspace is already installed (-> $(Get-Current)). [U]pdate / [r]emove / [c]ancel?"
        if ($answer -match '^[rR]') { Invoke-Uninstall; exit 0 }
        if ($answer -match '^[^uU]') { Write-Host 'Nothing changed'; exit 0 }
    }
}
Invoke-Install
