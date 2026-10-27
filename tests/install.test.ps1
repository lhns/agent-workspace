# Tests install.bat / uninstall.bat on a temp copy of the repo with a stub launcher.
# Default: a scratch target (shim folder, registry key and user-PATH file under the temp dir), so the
# machine is not touched. With -Real (CI) it uses the real %LOCALAPPDATA%, HKCU\Software\Classes and
# user PATH, and cleans up through uninstall.bat; it refuses to run if agent-workspace is installed.
#   ./tests/install.test.ps1 [-Real]
param([switch]$Real)
$ErrorActionPreference = 'Stop'
$src = (Resolve-Path "$PSScriptRoot\..").Path
$work = Join-Path ([IO.Path]::GetTempPath()) "install-test-$PID"
# Spaces and & ( ) ! in the repo and shim paths: messages and generated files must not choke on them.
$repo = "$work\re po & (x)!"
New-Item -ItemType Directory $repo | Out-Null
Copy-Item "$src\install.bat", "$src\uninstall.bat" $repo
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
    $binDir = "$work\bin & (y)!"
    $regRoot = "$regScratch\Classes"
    $pathFile = "$work\userpath.txt"
    # Entries with spaces, parentheses, & and an unexpanded variable must survive the round trip.
    $seed = 'C:\Windows;C:\Program Files (x86)\A & B;%SystemRoot%\x;C:\Tools'
    Set-Content $pathFile $seed -Encoding ASCII
    $env:AW_INSTALL_BIN_DIR = $binDir
    $env:AW_INSTALL_REG_ROOT = $regRoot.Replace(':', '')   # a reg.exe key path, not a PowerShell drive path
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
    Check 'install: exit 0, messages print the paths verbatim' ($code -eq 0 -and $out.Contains("Installed $shim -> $repo") -and $out.Contains("Added $binDir to the user PATH") -and $out.Contains('Added the Explorer entry'))
    $text = [IO.File]::ReadAllText($shim)
    Check 'the shim calls the launcher with the current folder as the workspace, CRLF' ($text.Contains("set `"WORKSPACE_DIR=%CD%`"`r`n") -and $text.Contains("call `"$repo\run-agent.bat`" %*`r`n") -and ($text -notmatch "[^`r]`n"))
    Check 'the bin folder is on the user PATH once' ((Count-OnPath) -eq 1)
    if (-not $Real) { Check 'existing PATH entries are kept' ((Get-Path) -eq "$seed;$binDir") }
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
    Check 'uninstall: exit 0, reports what it removed' ($code -eq 0 -and $out.Contains("Removed $shim") -and $out.Contains("Removed $binDir from the user PATH") -and $out.Contains('Removed ') -and $out -like '*shell\agent-workspace*')
    Check 'uninstall: shim, PATH entry and both registry keys are gone' (-not (Test-Path $shim) -and (Count-OnPath) -eq 0 -and -not (Test-Path -LiteralPath $keys[0]) -and -not (Test-Path -LiteralPath $keys[1]))
    if (-not $Real) { Check 'uninstall: other PATH entries are kept' ((Get-Path) -eq $seed) }
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
