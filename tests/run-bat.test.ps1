# Tests agents/run.bat against a stub `docker.exe` (compiled below; a .cmd stub would end the
# calling batch file) that only logs its arguments. Runs on a temp copy of the repo, so it
# leaves no state behind. Needs Windows PowerShell 5.1 (Add-Type -OutputAssembly).
$ErrorActionPreference = 'Stop'
$src = (Resolve-Path "$PSScriptRoot\..").Path
$work = Join-Path ([IO.Path]::GetTempPath()) "run-bat-test-$PID"
robocopy $src $work /E /XD .git workspace shared config data /XF .git .env .build.sha256 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }

$log = Join-Path $work 'docker.log'
$env:STUB_LOG = $log
New-Item -ItemType Directory "$work\stub" | Out-Null
$stub = @'
public class P { public static void Main(string[] a) {
    System.IO.File.AppendAllText(System.Environment.GetEnvironmentVariable("STUB_LOG"), string.Join(" ", a) + "\n");
} }
'@
Add-Type -OutputType ConsoleApplication -OutputAssembly "$work\stub\docker.exe" -TypeDefinition $stub
$env:PATH = "$work\stub;$env:PATH"
Remove-Item Env:WORKSPACE_DIR -ErrorAction SilentlyContinue
$failures = 0

# Runs the real launcher; stdin from NUL so the `pause` after "Edit .env first" returns.
function Invoke-Launcher([string]$arguments) {
    Remove-Item $log -ErrorAction SilentlyContinue
    Push-Location $work
    try { cmd /c ".\run-claude.bat $arguments < NUL > out.txt 2>&1" } finally { Pop-Location }
    $script:code = $LASTEXITCODE
    $script:calls = if (Test-Path $log) { @(Get-Content $log) } else { @() }
}
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:failures++ }
}

try {
    Invoke-Launcher 'bash'
    Check 'fresh checkout: refuses until .env is edited' ($code -eq 1 -and $calls.Count -eq 0 -and (Test-Path "$work\.env"))

    Add-Content "$work\.env" '# edited'
    Invoke-Launcher 'bash'
    Check 'first run builds base, then claude, then runs' (($calls -join '|') -eq 'compose build base|compose build claude|compose run --rm claude bash')
    Check 'first run writes the hash' (Test-Path "$work\agents\claude\.build.sha256")

    Invoke-Launcher 'bash'
    Check 'second run skips the build' (($calls -join '|') -eq 'compose run --rm claude bash')

    Add-Content "$work\agents\base\Dockerfile" '# changed'
    Invoke-Launcher 'bash'
    Check 'changed base Dockerfile rebuilds' (($calls -join '|') -eq 'compose build base|compose build claude|compose run --rm claude bash')

    Invoke-Launcher 'bash'
    Check 'build is skipped again afterwards' (($calls -join '|') -eq 'compose run --rm claude bash')

    $env:WORKSPACE_DIR = "$work\does-not-exist"
    Invoke-Launcher 'bash'
    Remove-Item Env:WORKSPACE_DIR
    Check 'missing WORKSPACE_DIR stops before docker' ($code -eq 1 -and $calls.Count -eq 0)
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
exit 0
