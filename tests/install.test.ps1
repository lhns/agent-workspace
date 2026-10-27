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
Set-Content "$repo\run-agent.bat" -Encoding ASCII -Value '@echo "WS=%WORKSPACE_DIR%"', '@echo ARGS=%*'

Remove-Item Env:AW_INSTALL_BIN_DIR, Env:AW_INSTALL_REG_ROOT, Env:AW_INSTALL_PATH_FILE, Env:AW_INSTALL_WT, Env:AW_INSTALL_WINAPPS, Env:AW_INSTALL_SENDTO, Env:AW_INSTALL_NOREG -ErrorAction SilentlyContinue
# Fallback targets are always scratch folders, also with -Real.
$wa = "$work\apps & (z)"
$st = "$work\sendto"
$env:AW_INSTALL_WINAPPS = $wa
$env:AW_INSTALL_SENDTO = $st
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

    # --- Fallback without the registry (a DisableRegistryTools policy): AW_INSTALL_NOREG=1 ---
    $env:AW_INSTALL_WT = 'none'
    $waShim = "$wa\agent-workspace.cmd"
    $stFile = "$st\agent-workspace.cmd"
    $origPath = $env:PATH
    New-Item -ItemType Directory $wa | Out-Null
    $noRegKeys = { -not (Test-Path -LiteralPath $keys[0]) -and -not (Test-Path -LiteralPath $keys[1]) }

    # WindowsApps on the PATH: the shim goes there, and the SendTo entry opens a terminal.
    $env:PATH = "$wa;$origPath"
    $env:AW_INSTALL_NOREG = '1'
    Invoke-Bat """$repo\install.bat"""
    Check 'fallback: exit 0, says it is without the registry' ($code -eq 0 -and $out.Contains('without the registry') -and $out.Contains("Installed $waShim -> $repo"))
    Check 'fallback: shim in WindowsApps, none in bin, no PATH entry, no registry keys' ((Test-Path $waShim) -and -not (Test-Path $shim) -and (Count-OnPath) -eq 0 -and (& $noRegKeys))
    $send = [IO.File]::ReadAllText($stFile)
    Check 'fallback: SendTo entry starts the shim in the selected folder' ($send.Contains("set `"D=%~1`"`r`n") -and $send.Contains("if not defined D set `"D=%CD%`"`r`n") -and $send.Contains("cmd /k pushd `"%D%`" ^&^& `"$waShim`"`r`n") -and ($send -notmatch "[^`r]`n"))
    Invoke-Bat """$waShim"" x"
    Check 'fallback: the shim runs the launcher' ($code -eq 0 -and $out -like '*ARGS=x*')
    Invoke-Bat """$repo\install.bat"""
    Check 'fallback: install again updates' ($code -eq 0 -and $out -like '*Installed*')
    # Run the generated SendTo script. Terminal windows are avoided: the cmd branch is run with
    # `start "" cmd /k` swapped for `cmd /c` (same pushd && shim), the wt branch with a stub that records its arguments.
    $sel = "$work\sel & (d)!\proj x"
    New-Item -ItemType Directory $sel, "$work\other" | Out-Null
    Set-Content "$sel\a file.txt" 'x'
    $send = [IO.File]::ReadAllText($stFile)
    Check 'fallback: SendTo uses start for the cmd branch' ($send.Contains('start "" cmd /k pushd'))
    $sendRun = "$work\sendto-run.cmd"
    [IO.File]::WriteAllText($sendRun, $send.Replace('start "" cmd /k', 'cmd /c'))
    Invoke-Bat """$sendRun"" ""$sel"""
    Check 'SendTo script, folder with spaces & ( ) !: shim runs with the folder as workspace' ($code -eq 0 -and $out -like "*WS=$sel*")
    Invoke-Bat """$sendRun"" ""$sel\a file.txt"""
    Check 'SendTo script, file selected: its folder is the workspace' ($code -eq 0 -and $out -like "*WS=$sel*")
    Invoke-Bat """$sendRun"" ""$sel"" ""$work\other"""
    Check 'SendTo script, several items: only the first is opened' ($code -eq 0 -and $out -like "*WS=$sel*" -and $out -notlike '*other*')
    Push-Location "$work\other"
    try { Invoke-Bat """$sendRun""" } finally { Pop-Location }
    Check 'SendTo script, no argument: the current folder' ($code -eq 0 -and $out -like "*WS=$work\other*")

    $stub = "$work\stub wt & (w).cmd"
    $rec = "$work\wt-args.txt"
    Set-Content $stub -Encoding ASCII -Value '@echo off', '>"%AW_REC%" echo(%*'
    $env:AW_REC = $rec
    $env:AW_INSTALL_WT = $stub
    Invoke-Bat """$repo\install.bat"""
    $send = [IO.File]::ReadAllText($stFile)
    Check 'fallback with a terminal: SendTo calls it as wt -d folder cmd /k shim' ($send.Contains("`"$stub`" -d `"%D%.`" cmd /k `"$waShim`"`r`n"))
    Invoke-Bat """$stFile"" ""$sel\a file.txt"""
    $args1 = (Get-Content $rec -Raw).Trim()
    Check 'SendTo script runs the terminal stub with -d "<folder>\." cmd /k "<shim>"' ($code -eq 0 -and $args1 -eq "-d `"$sel\.`" cmd /k `"$waShim`"")
    Remove-Item Env:AW_REC
    $env:AW_INSTALL_WT = 'none'
    Invoke-Bat """$repo\uninstall.bat"""
    Check 'fallback uninstall (registry tools off): both files removed, no registry note' ($code -eq 0 -and -not (Test-Path $waShim) -and -not (Test-Path $stFile) -and $out.Contains("Removed $waShim") -and -not $out.Contains('reg.exe is disabled'))

    # WindowsApps not on the PATH: the shim stays in the bin folder and the message says how to add it.
    $env:PATH = $origPath
    Invoke-Bat """$repo\install.bat"""
    Check 'fallback, WindowsApps not on PATH: shim in bin, how to add it, SendTo entry' ($code -eq 0 -and (Test-Path $shim) -and -not (Test-Path $waShim) -and (Test-Path $stFile) -and $out.Contains('EditEnvironmentVariables') -and (Count-OnPath) -eq 0)
    Invoke-Bat """$repo\uninstall.bat"""
    Check 'uninstall with registry tools off: files removed, notes the PATH/Explorer entries were not checked' ($code -eq 0 -and -not (Test-Path $shim) -and -not (Test-Path $stFile) -and $out.Contains('reg.exe is disabled'))

    # Registry writes fail after a successful probe: nothing half-installed is left, the fallback is used.
    $env:PATH = "$wa;$origPath"
    $env:AW_INSTALL_NOREG = 'add'
    Invoke-Bat """$repo\install.bat"""
    Check 'registry write fails: undone, fallback installed' ($code -eq 0 -and $out.Contains('undoing') -and (Test-Path $waShim) -and -not (Test-Path $shim) -and (Test-Path $stFile) -and (Count-OnPath) -eq 0 -and (& $noRegKeys))
    Remove-Item Env:AW_INSTALL_NOREG
    Invoke-Bat """$repo\uninstall.bat"""
    Check 'uninstall removes the fallback files' ($code -eq 0 -and -not (Test-Path $waShim) -and -not (Test-Path $stFile))

    # Both modes present (installed on an open PC, then the policy was switched on).
    Invoke-Bat """$repo\install.bat"""
    Check 'registry install, WindowsApps on PATH: no fallback files' ($code -eq 0 -and (Test-Path $shim) -and -not (Test-Path $stFile) -and (Count-OnPath) -eq 1 -and -not (& $noRegKeys))
    Copy-Item $shim $waShim
    New-Item -ItemType Directory $st -Force | Out-Null
    Copy-Item $shim $stFile
    $env:AW_INSTALL_NOREG = '1'
    Invoke-Bat """$repo\uninstall.bat"""
    Check 'uninstall with registry tools off: all three files go, registry parts are left and reported' ($code -eq 0 -and -not (Test-Path $shim) -and -not (Test-Path $waShim) -and -not (Test-Path $stFile) -and $out.Contains('reg.exe is disabled') -and (Count-OnPath) -eq 1 -and -not (& $noRegKeys))
    Remove-Item Env:AW_INSTALL_NOREG
    Invoke-Bat """$repo\uninstall.bat"""
    Check 'uninstall without the policy: PATH entry and Explorer keys go too' ($code -eq 0 -and (Count-OnPath) -eq 0 -and (& $noRegKeys))

    Invoke-Bat """$repo\install.bat"""
    Copy-Item $shim $waShim
    Copy-Item $shim $stFile
    Invoke-Bat """$repo\uninstall.bat"""
    Check 'uninstall with everything present: all removed' ($code -eq 0 -and -not (Test-Path $shim) -and -not (Test-Path $waShim) -and -not (Test-Path $stFile) -and (Count-OnPath) -eq 0 -and (& $noRegKeys))
    if (-not $Real) { Check 'PATH entries are as before' ((Get-Path) -eq $seed) }
    $env:PATH = $origPath
}
finally {
    if ($Real) { Invoke-Bat """$repo\uninstall.bat""" }
    Remove-Item $regScratch -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
exit 0
