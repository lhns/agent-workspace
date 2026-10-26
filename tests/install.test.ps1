# Tests install.bat / uninstall.bat (agents/install.ps1) on a temp copy of the repo with a stub launcher.
# Default: a scratch target (shim folder, registry key and user-PATH file under the temp dir), so the
# machine is not touched. With -Real (CI) it uses the real %LOCALAPPDATA%, HKCU\Software\Classes and
# user PATH, and cleans up through uninstall.bat; it refuses to run if agent-workspace is installed.
#   ./tests/install.test.ps1 [-Real]
param([switch]$Real)
$ErrorActionPreference = 'Stop'
$src = (Resolve-Path "$PSScriptRoot\..").Path
$work = Join-Path ([IO.Path]::GetTempPath()) "install-test-$PID"
$repo = "$work\re po"
New-Item -ItemType Directory "$repo\agents" | Out-Null
Copy-Item "$src\install.bat", "$src\uninstall.bat" $repo
Copy-Item "$src\agents\install.ps1" "$repo\agents"
# The stub launcher the shim calls.
Set-Content "$repo\run-agent.bat" -Encoding ASCII -Value '@echo WS=%WORKSPACE_DIR%', '@echo ARGS=%*'

Remove-Item Env:AW_INSTALL_BIN_DIR, Env:AW_INSTALL_REG_ROOT, Env:AW_INSTALL_PATH_FILE, Env:AW_INSTALL_WT -ErrorAction SilentlyContinue
$regScratch = 'HKCU:\Software\agent-workspace-test'
if ($Real) {
    $binDir = Join-Path $env:LOCALAPPDATA 'agent-workspace\bin'
    $regRoot = 'HKCU:\Software\Classes'
    if (Test-Path "$binDir\agent-workspace.cmd") { throw 'agent-workspace is installed on this machine; refusing to run -Real' }
    function Get-Path { [Environment]::GetEnvironmentVariable('Path', 'User') }
} else {
    $binDir = "$work\bin"
    $regRoot = "$regScratch\Classes"
    $pathFile = "$work\userpath.txt"
    Set-Content $pathFile 'C:\Windows;C:\Tools' -Encoding ASCII
    $env:AW_INSTALL_BIN_DIR = $binDir
    $env:AW_INSTALL_REG_ROOT = $regRoot
    $env:AW_INSTALL_PATH_FILE = $pathFile
    function Get-Path { (Get-Content $pathFile -Raw).Trim() }
}
$shim = "$binDir\agent-workspace.cmd"
$keys = "$regRoot\Directory\shell\agent-workspace", "$regRoot\Directory\Background\shell\agent-workspace"
$failures = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:failures++ }
}
# Runs a batch file with stdin from NUL (no terminal: install updates without asking); sets $code and $out.
function Invoke-Bat([string]$cmdline) {
    # Started directly so the command line reaches cmd exactly as written (outer quotes get stripped).
    $p = Start-Process cmd.exe -ArgumentList "/c `"$cmdline < NUL > `"$work\out.txt`" 2>&1`"" -Wait -PassThru -NoNewWindow
    $script:code = $p.ExitCode
    $script:out = Get-Content "$work\out.txt" -Raw
}
function Get-Cmd([string]$key) { (Get-Item -LiteralPath "$key\command").GetValue('') }
function Count-OnPath { @((Get-Path) -split ';' | Where-Object { $_.TrimEnd('\') -ieq $binDir.TrimEnd('\') }).Count }

try {
    Invoke-Bat """$repo\uninstall.bat"""
    Check 'uninstall with nothing installed: not installed, exit 0' ($code -eq 0 -and $out -like '*not installed*')

    $env:AW_INSTALL_WT = 'none'
    Invoke-Bat """$repo\install.bat"""
    Check 'install: exit 0' ($code -eq 0)
    $text = [IO.File]::ReadAllText($shim)
    Check 'the shim calls the launcher with the current folder as the workspace, CRLF' ($text.Contains("set `"WORKSPACE_DIR=%CD%`"`r`n") -and $text.Contains("call `"$repo\run-agent.bat`" %*`r`n") -and ($text -notmatch "[^`r]`n"))
    Check 'the bin folder is on the user PATH once' ((Count-OnPath) -eq 1)
    if (-not $Real) { Check 'existing PATH entries are kept' ((Get-Path) -like 'C:\Windows;C:\Tools;*') }
    foreach ($k in $keys) {
        Check "registry: $($k.Split('\')[-3..-1] -join '\') name, icon, cmd command" ((Get-Item -LiteralPath $k).GetValue('') -eq 'Open with agent-workspace' -and (Get-Item -LiteralPath $k).GetValue('Icon') -eq 'cmd.exe' -and (Get-Cmd $k) -eq "cmd.exe /k pushd `"%V`" && `"$shim`"")
    }

    New-Item -ItemType Directory "$work\my proj" | Out-Null
    Push-Location "$work\my proj"
    try { Invoke-Bat """$shim"" a ""b c""" } finally { Pop-Location }
    Check 'the shim runs the launcher in the current folder with the arguments' ($code -eq 0 -and $out -like "*WS=$work\my proj*" -and $out -like '*ARGS=a "b c"*')

    Invoke-Bat """$repo\install.bat"""
    Check 'install again (no terminal): updates, PATH not duplicated' ($code -eq 0 -and $out -like '*Installed*' -and (Count-OnPath) -eq 1)
    Invoke-Bat """$repo\install.bat"" -Update"
    Check 'install -Update: same' ($code -eq 0 -and (Count-OnPath) -eq 1)

    $env:AW_INSTALL_WT = 'wt.exe'
    Invoke-Bat """$repo\install.bat"""
    Check 'with Windows Terminal: wt.exe -d "%V." cmd /k shim' ((Get-Cmd $keys[0]) -eq "wt.exe -d `"%V.`" cmd /k `"$shim`"" -and (Get-Cmd $keys[1]) -eq (Get-Cmd $keys[0]))
    Remove-Item Env:AW_INSTALL_WT

    # The repo moved: installing from the new place re-points the shim.
    Copy-Item $repo "$work\moved" -Recurse
    Invoke-Bat """$work\moved\install.bat"""
    Check 'install from another folder re-points the shim' ($code -eq 0 -and ([IO.File]::ReadAllText($shim)).Contains("call `"$work\moved\run-agent.bat`""))

    Invoke-Bat """$repo\uninstall.bat"""
    Check 'uninstall: exit 0, reports what it removed' ($code -eq 0 -and $out -like '*Removed*')
    Check 'uninstall: shim, PATH entry and both registry keys are gone' (-not (Test-Path $shim) -and (Count-OnPath) -eq 0 -and -not (Test-Path -LiteralPath $keys[0]) -and -not (Test-Path -LiteralPath $keys[1]))
    if (-not $Real) { Check 'uninstall: other PATH entries are kept' ((Get-Path) -eq 'C:\Windows;C:\Tools') }
    Invoke-Bat """$repo\uninstall.bat"""
    Check 'uninstall again: not installed, exit 0' ($code -eq 0 -and $out -like '*not installed*')
}
finally {
    if ($Real) { Invoke-Bat """$repo\uninstall.bat""" }
    Remove-Item $regScratch -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
exit 0
