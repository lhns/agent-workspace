# Tests agents/run.bat against a stub `docker.exe` (compiled below; a .cmd stub would end the
# calling batch file) that logs its arguments and fails `pull` when STUB_PULL_FAIL=1 and
# `image inspect` when STUB_INSPECT_FAIL=1; `compose run` also records AGENTS_WORKSPACE_TARGET. Runs on
# a temp copy of the repo, so it leaves no state behind. Needs Windows PowerShell 5.1 (Add-Type -OutputAssembly).
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
    if (a.Length > 1 && a[0] == "compose" && a[1] == "run") System.IO.File.AppendAllText(System.Environment.GetEnvironmentVariable("STUB_LOG") + ".target", System.Environment.GetEnvironmentVariable("AGENTS_WORKSPACE_TARGET") + "\n");
    if (a.Length > 0 && a[0] == "pull" && System.Environment.GetEnvironmentVariable("STUB_PULL_FAIL") == "1") System.Environment.Exit(1);
    if (a.Length > 1 && a[0] == "image" && a[1] == "inspect" && System.Environment.GetEnvironmentVariable("STUB_INSPECT_FAIL") == "1") System.Environment.Exit(1);
} }
'@
Add-Type -OutputType ConsoleApplication -OutputAssembly "$work\stub\docker.exe" -TypeDefinition $stub
$env:PATH = "$work\stub;$env:PATH"
Remove-Item Env:WORKSPACE_DIR, Env:AGENTS_LOCAL_BUILD, Env:AGENTS_IMAGE_PREFIX, Env:STUB_PULL_FAIL, Env:STUB_INSPECT_FAIL -ErrorAction SilentlyContinue
$failures = 0
$hash = (Get-FileHash -Algorithm SHA256 -InputStream ([IO.MemoryStream]::new([byte[]]([IO.File]::ReadAllBytes("$work\agents\base\Dockerfile") + [IO.File]::ReadAllBytes("$work\agents\claude\Dockerfile"))))).Hash.ToLower()
$ref = "ghcr.io/lhns/agent-workspace-claude:$hash"
$pulled = "pull $ref|tag $ref agent-workspace-claude|rmi $ref|compose run --rm claude bash"
$built = 'compose build base|compose build claude|compose run --rm claude bash'
$unchanged = 'image inspect agent-workspace-claude|compose run --rm claude bash'

# Runs the real launcher; stdin from NUL so the `pause` after "Edit .env first" returns.
function Invoke-Launcher([string]$arguments) {
    Remove-Item $log -ErrorAction SilentlyContinue
    Push-Location $work
    try { cmd /c ".\run-claude.bat $arguments < NUL > out.txt 2>&1" } finally { Pop-Location }
    $script:code = $LASTEXITCODE
    $script:calls = if (Test-Path $log) { @(Get-Content $log) } else { @() }
    $script:target = if (Test-Path "$log.target") { @(Get-Content "$log.target")[-1] } else { $null }
    Remove-Item "$log.target" -ErrorAction SilentlyContinue
}
# C:\a\b -> /c/a/b, where the launcher mounts the workspace.
function ConvertTo-Mount([string]$path) { '/' + $path.Substring(0, 1).ToLower() + $path.Substring(2).Replace('\', '/') }
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:failures++ }
}

try {
    Invoke-Launcher 'bash'
    Check 'fresh checkout: refuses until .env is edited' ($code -eq 1 -and $calls.Count -eq 0 -and (Test-Path "$work\.env"))

    Add-Content "$work\.env" '# edited'
    Invoke-Launcher 'bash'
    Check 'first run pulls, tags and removes the ghcr tag, without building' (($calls -join '|') -eq $pulled)
    Check 'first run writes the same hash as sha256sum' ((Get-Content "$work\agents\claude\.build.sha256") -eq $hash)

    Invoke-Launcher 'bash'
    Check 'unchanged hash: neither pull nor build' (($calls -join '|') -eq $unchanged)

    $env:STUB_INSPECT_FAIL = '1'
    Invoke-Launcher 'bash'
    Remove-Item Env:STUB_INSPECT_FAIL
    Check 'unchanged hash but image pruned: pulls again' (($calls -join '|') -eq "image inspect agent-workspace-claude|$pulled")

    Add-Content "$work\agents\base\Dockerfile" '# changed'
    $env:STUB_PULL_FAIL = '1'
    Invoke-Launcher 'bash'
    Remove-Item Env:STUB_PULL_FAIL
    $newRef = $calls[0] -replace '^pull ', ''
    Check 'changed Dockerfile with failing pull builds base, then claude' (($calls -join '|') -eq "pull $newRef|$built" -and $newRef -ne $ref)

    Invoke-Launcher 'bash'
    Check 'build is skipped again afterwards' (($calls -join '|') -eq $unchanged)

    $env:AGENTS_LOCAL_BUILD = '1'
    Remove-Item "$work\agents\claude\.build.sha256"
    Invoke-Launcher 'bash'
    Remove-Item Env:AGENTS_LOCAL_BUILD
    Check 'AGENTS_LOCAL_BUILD in the shell builds without pulling' (($calls -join '|') -eq $built)

    Add-Content "$work\.env" 'AGENTS_LOCAL_BUILD=1'
    Remove-Item "$work\agents\claude\.build.sha256"
    Invoke-Launcher 'bash'
    Check 'AGENTS_LOCAL_BUILD in .env builds without pulling' (($calls -join '|') -eq $built)

    $env:AGENTS_IMAGE_PREFIX = 'registry.example/me/aw'
    Remove-Item "$work\agents\claude\.build.sha256"
    (Get-Content "$work\.env") -notmatch '^AGENTS_LOCAL_BUILD=' | Set-Content "$work\.env"
    Invoke-Launcher 'bash'
    Remove-Item Env:AGENTS_IMAGE_PREFIX
    Check 'AGENTS_IMAGE_PREFIX sets the pulled image' ($calls[0] -like 'pull registry.example/me/aw-claude:*')

    $env:WORKSPACE_DIR = "$work\does-not-exist"
    Invoke-Launcher 'bash'
    Remove-Item Env:WORKSPACE_DIR
    Check 'missing WORKSPACE_DIR stops before docker' ($code -eq 1 -and $calls.Count -eq 0)

    Invoke-Launcher 'bash'
    Check 'default workspace is mounted at its mirrored host path' ($target -eq (ConvertTo-Mount "$work\workspace"))

    New-Item -ItemType Directory "$work\my proj" | Out-Null
    $env:WORKSPACE_DIR = "$work\my proj"
    Invoke-Launcher 'bash'
    Remove-Item Env:WORKSPACE_DIR
    Check 'WORKSPACE_DIR with a space is mounted at its mirrored host path' ($target -eq (ConvertTo-Mount "$work\my proj"))

    $env:WORKSPACE_DIR = 'workspace'
    Invoke-Launcher 'bash'
    Remove-Item Env:WORKSPACE_DIR
    Check 'relative WORKSPACE_DIR resolves against the repo' ($target -eq (ConvertTo-Mount "$work\workspace"))

    # A path without a drive letter (UNC) can't be mirrored; skipped where the admin share is unavailable.
    $unc = '\\localhost\' + $work.Substring(0, 1) + '$' + $work.Substring(2)
    if (Test-Path $unc) {
        $env:WORKSPACE_DIR = $unc
        Invoke-Launcher 'bash'
        Remove-Item Env:WORKSPACE_DIR
        Check 'UNC WORKSPACE_DIR falls back to /workspace' ($target -eq '/workspace')
    }

    Remove-Item $log -ErrorAction SilentlyContinue
    Push-Location $work
    try { cmd /c "set HARNESS=nope& call agents\run.bat < NUL > out.txt 2>&1" } finally { Pop-Location }
    Check 'unknown harness stops before docker' ($LASTEXITCODE -eq 1 -and -not (Test-Path $log))
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
exit 0
