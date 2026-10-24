# Tests agents/run.bat (the host side) against a stub `docker.exe` (compiled below; a .cmd stub would
# end the calling batch file) that logs its arguments and fails `pull` when STUB_PULL_FAIL=1 (or names
# failing refs) and `image inspect` when STUB_INSPECT_FAIL=1. For the base service it plays the core
# (agents/launch.sh, tested by tests/launch.test.sh): it records its arguments and writes the hand-off
# files from STUB_HARNESS (default claude) and STUB_TARGET, or exits with STUB_CORE_CODE, or writes
# nothing for STUB_NO_HARNESS=1. `compose run` also records AGENTS_WORKSPACE_TARGET and AGENTS_RUN_ID.
# Runs on a temp copy of the repo, so it leaves no state behind. Needs Windows PowerShell 5.1
# (Add-Type -OutputAssembly).
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
    var shown = new System.Collections.Generic.List<string>();
    foreach (var s in a) shown.Add(s.Contains(" ") ? "\"" + s + "\"" : s);
    var logf = System.Environment.GetEnvironmentVariable("STUB_LOG");
    System.IO.File.AppendAllText(logf, string.Join(" ", shown) + "\n");
    var target = System.Environment.GetEnvironmentVariable("AGENTS_WORKSPACE_TARGET");
    var id = System.Environment.GetEnvironmentVariable("AGENTS_RUN_ID");
    if (a.Length > 1 && a[0] == "compose" && a[1] == "run") {
        System.IO.File.AppendAllText(logf + ".target", target + "\n");
        System.IO.File.AppendAllText(logf + ".id", id + "\n");
        var bi = System.Array.IndexOf(a, "base");
        if (bi > 1) {
            var d = "shared\\.launch\\" + id;
            System.IO.File.AppendAllText(logf + ".dir", (System.IO.Directory.Exists(d) ? "dir" : "nodir") + "\n");
            var args = "";
            for (var i = bi + 1; i < a.Length; i++) args += "[" + a[i] + "]";
            System.IO.File.WriteAllText(logf + ".base", args);
            var code = System.Environment.GetEnvironmentVariable("STUB_CORE_CODE");
            if (!string.IsNullOrEmpty(code)) System.Environment.Exit(int.Parse(code));
            if (System.Environment.GetEnvironmentVariable("STUB_NO_RESULT") == "1") System.Environment.Exit(0);
            if (System.Environment.GetEnvironmentVariable("STUB_NO_HARNESS") == "1") { System.IO.File.WriteAllText(d + "\\result", "done\n"); System.Environment.Exit(0); }
            var t = System.Environment.GetEnvironmentVariable("STUB_TARGET");
            var h = System.Environment.GetEnvironmentVariable("STUB_HARNESS");
            System.IO.File.WriteAllText(d + "\\target", (string.IsNullOrEmpty(t) ? target : t) + "\n");
            System.IO.File.WriteAllText(d + "\\harness", (string.IsNullOrEmpty(h) ? "claude" : h) + "\n");
            System.IO.File.WriteAllText(d + "\\last-harness", "new-state\n");
            System.IO.File.WriteAllText(d + "\\result", "launch\n");
        }
    }
    if (a.Length > 0 && a[0] == "pull" && PullFails(a[1])) System.Environment.Exit(1);
    if (a.Length > 1 && a[0] == "image" && a[1] == "inspect" && System.Environment.GetEnvironmentVariable("STUB_INSPECT_FAIL") == "1") System.Environment.Exit(1);
}
    // STUB_PULL_FAIL: "1" fails every pull, otherwise a comma-separated list of substrings of the refs that fail.
    static bool PullFails(string r) {
        var f = System.Environment.GetEnvironmentVariable("STUB_PULL_FAIL");
        if (string.IsNullOrEmpty(f)) return false;
        if (f == "1") return true;
        foreach (var x in f.Split(',')) if (r.Contains(x)) return true;
        return false;
    }
}
'@
Add-Type -OutputType ConsoleApplication -OutputAssembly "$work\stub\docker.exe" -TypeDefinition $stub
$env:PATH = "$work\stub;$env:PATH"
Remove-Item Env:WORKSPACE_DIR, Env:AGENTS_HARNESS, Env:AGENTS_NONINTERACTIVE, Env:AGENTS_LOCAL_BUILD, Env:AGENTS_IMAGE_PREFIX, Env:STUB_PULL_FAIL, Env:STUB_INSPECT_FAIL, Env:STUB_HARNESS, Env:STUB_TARGET, Env:STUB_CORE_CODE, Env:STUB_NO_HARNESS, Env:STUB_NO_RESULT -ErrorAction SilentlyContinue
$failures = 0
function Get-Hash([string[]]$files) { (Get-FileHash -Algorithm SHA256 -InputStream ([IO.MemoryStream]::new([byte[]]($files | ForEach-Object { [IO.File]::ReadAllBytes("$work\$_") })))).Hash.ToLower() }
$baseDf = 'agents\base\Dockerfile'
$prefix = 'ghcr.io/lhns/agent-workspace'
$run = 'compose run --rm -T'

# Runs the real launcher; stdin from NUL so the `pause` after "Edit .env first" returns.
function Invoke-Launcher([string]$arguments) {
    Remove-Item $log, "$log.target", "$log.id", "$log.dir", "$log.base" -ErrorAction SilentlyContinue
    Push-Location $work
    try { cmd /c ".\run-agent.bat $arguments < NUL > out.txt 2>&1" } finally { Pop-Location }
    $script:code = $LASTEXITCODE
    $script:calls = if (Test-Path $log) { @(Get-Content $log) } else { @() }
    $script:targets = if (Test-Path "$log.target") { @(Get-Content "$log.target") } else { @() }
    $script:ids = if (Test-Path "$log.id") { @(Get-Content "$log.id") } else { @() }
    $script:dirseen = if (Test-Path "$log.dir") { @(Get-Content "$log.dir")[-1] } else { $null }
    $script:baseargs = if (Test-Path "$log.base") { Get-Content "$log.base" -Raw } else { $null }
    $script:out = if (Test-Path "$work\out.txt") { Get-Content "$work\out.txt" -Raw } else { '' }
}
# C:\a\b -> /c/a/b, where the launcher mounts the workspace.
function ConvertTo-Mount([string]$path) { '/' + $path.Substring(0, 1).ToLower() + $path.Substring(2).Replace('\', '/') }
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:failures++ }
}
function Pull([string]$name, [string[]]$files) { $r = "${prefix}-${name}:$(Get-Hash $files)"; "pull $r|tag $r agent-workspace-$name|rmi $r" }

try {
    Invoke-Launcher '--help'
    Check 'fresh checkout: refuses until .env is edited, even for --help' ($code -eq 1 -and $calls.Count -eq 0 -and (Test-Path "$work\.env"))

    Add-Content "$work\.env" '# edited'
    $pulledBase = Pull 'base' $baseDf
    $pulledClaude = Pull 'claude' $baseDf, 'agents\claude\Dockerfile'
    Invoke-Launcher 'claude'
    Check 'first run pulls base, runs the core, pulls the harness, runs it' (($calls -join '|') -eq "$pulledBase|$run base claude|$pulledClaude|$run claude")
    Check 'first run writes the same hashes as sha256sum' ((Get-Content "$work\agents\claude\.build.sha256") -eq (Get-Hash $baseDf, 'agents\claude\Dockerfile') -and (Get-Content "$work\agents\base\.build.sha256") -eq (Get-Hash $baseDf))
    Check 'the core runs with the launch dir in place, both runs share its id' ($dirseen -eq 'dir' -and $ids.Count -eq 2 -and $ids[0] -eq $ids[1] -and $ids[0])
    Check 'the launch dir is removed afterwards' (-not (Test-Path "$work\shared\.launch\$($ids[0])"))

    $unchanged = "image inspect agent-workspace-base|$run base claude|image inspect agent-workspace-claude|$run claude"
    Invoke-Launcher 'claude'
    Check 'unchanged hashes: neither pull nor build' (($calls -join '|') -eq $unchanged)

    $env:STUB_INSPECT_FAIL = '1'
    Invoke-Launcher 'claude'
    Remove-Item Env:STUB_INSPECT_FAIL
    Check 'unchanged hashes but images pruned: pulls again' (($calls -join '|') -eq "image inspect agent-workspace-base|$pulledBase|$run base claude|image inspect agent-workspace-claude|$pulledClaude|$run claude")

    Add-Content "$work\$baseDf" '# changed'
    $env:STUB_PULL_FAIL = '1'
    Invoke-Launcher 'claude'
    Remove-Item Env:STUB_PULL_FAIL
    $baseRef = "${prefix}-base:$(Get-Hash $baseDf)"
    $claudeRef = "${prefix}-claude:$(Get-Hash $baseDf, 'agents\claude\Dockerfile')"
    Check 'changed base Dockerfile with failing pulls: builds base, core, builds the harness on it' (($calls -join '|') -eq "pull $baseRef|compose build base|$run base claude|pull $claudeRef|image inspect agent-workspace-base|compose build claude|$run claude")

    Invoke-Launcher 'claude'
    Check 'build is skipped again afterwards' (($calls -join '|') -eq $unchanged)

    # Only the harness is missing on the registry: the base is pulled, the harness built on it.
    Add-Content "$work\agents\claude\Dockerfile" '# changed'
    Remove-Item "$work\agents\base\.build.sha256"
    $env:STUB_PULL_FAIL = 'agent-workspace-claude'
    Invoke-Launcher 'claude'
    Remove-Item Env:STUB_PULL_FAIL
    $claudeRef = "${prefix}-claude:$(Get-Hash $baseDf, 'agents\claude\Dockerfile')"
    Check 'harness pull misses, base pull works: builds the harness on the pulled base' (($calls -join '|') -eq "$(Pull 'base' $baseDf)|$run base claude|pull $claudeRef|image inspect agent-workspace-base|compose build claude|$run claude")

    $env:AGENTS_LOCAL_BUILD = '1'
    Remove-Item "$work\agents\claude\.build.sha256", "$work\agents\base\.build.sha256"
    Invoke-Launcher 'claude'
    Remove-Item Env:AGENTS_LOCAL_BUILD
    $localBuild = "compose build base|$run base claude|image inspect agent-workspace-base|compose build claude|$run claude"
    Check 'AGENTS_LOCAL_BUILD in the shell builds without pulling' (($calls -join '|') -eq $localBuild)

    Add-Content "$work\.env" 'AGENTS_LOCAL_BUILD=1'
    Remove-Item "$work\agents\claude\.build.sha256", "$work\agents\base\.build.sha256"
    Invoke-Launcher 'claude'
    Check 'AGENTS_LOCAL_BUILD in .env builds without pulling' (($calls -join '|') -eq $localBuild)

    $env:AGENTS_IMAGE_PREFIX = 'registry.example/me/aw'
    Remove-Item "$work\agents\claude\.build.sha256", "$work\agents\base\.build.sha256"
    (Get-Content "$work\.env") -notmatch '^AGENTS_LOCAL_BUILD=' | Set-Content "$work\.env"
    Invoke-Launcher 'claude'
    Remove-Item Env:AGENTS_IMAGE_PREFIX
    Check 'AGENTS_IMAGE_PREFIX sets the pulled images' ($calls[0] -like 'pull registry.example/me/aw-base:*' -and $calls -like 'pull registry.example/me/aw-claude:*')

    $env:WORKSPACE_DIR = "$work\does-not-exist"
    Invoke-Launcher 'claude'
    Remove-Item Env:WORKSPACE_DIR
    Check 'missing WORKSPACE_DIR stops before docker' ($code -eq 1 -and $calls.Count -eq 0)

    Invoke-Launcher 'claude'
    Check 'default workspace is mounted at its mirrored host path' ($targets[0] -eq (ConvertTo-Mount "$work\workspace"))

    New-Item -ItemType Directory "$work\my proj" | Out-Null
    $env:WORKSPACE_DIR = "$work\my proj"
    Invoke-Launcher 'claude'
    Remove-Item Env:WORKSPACE_DIR
    Check 'WORKSPACE_DIR with a space is mounted at its mirrored host path' ($targets[0] -eq (ConvertTo-Mount "$work\my proj"))

    New-Item -ItemType Directory "$work\paren (x86)" | Out-Null
    $env:WORKSPACE_DIR = "$work\paren (x86)"
    Invoke-Launcher 'claude'
    Remove-Item Env:WORKSPACE_DIR
    Check 'WORKSPACE_DIR with parentheses works' ($code -eq 0 -and $targets[0] -eq (ConvertTo-Mount "$work\paren (x86)"))

    $env:WORKSPACE_DIR = 'workspace'
    Invoke-Launcher 'claude'
    Remove-Item Env:WORKSPACE_DIR
    Check 'relative WORKSPACE_DIR resolves against the repo' ($targets[0] -eq (ConvertTo-Mount "$work\workspace"))

    # A path without a drive letter (UNC) can't be mirrored; skipped where the admin share is unavailable.
    $unc = '\\localhost\' + $work.Substring(0, 1) + '$' + $work.Substring(2)
    if (Test-Path $unc) {
        $env:WORKSPACE_DIR = $unc
        Invoke-Launcher 'claude'
        Remove-Item Env:WORKSPACE_DIR
        Check 'UNC WORKSPACE_DIR falls back to /workspace' ($targets[0] -eq '/workspace')
    }

    # Every argument reaches the core as typed (the core parses them): quotes, spaces, !, empty ones, dashes.
    Invoke-Launcher 'claude bash -c "echo hi there!" x'
    Check 'arguments with quotes, spaces and ! pass to the core untouched' ($baseargs -eq '[claude][bash][-c][echo hi there!][x]')
    Invoke-Launcher '--continue --harness claude "" x'
    Check 'an empty argument does not end the argument list' ($baseargs -eq '[--continue][--harness][claude][][x]')
    Invoke-Launcher '--harness claude --exec bash -c "echo a ! b" /tmp/x'
    Check '--exec arguments, a ! and a /path pass untouched' ($baseargs -eq '[--harness][claude][--exec][bash][-c][echo a ! b][/tmp/x]')
    Invoke-Launcher ''
    Check 'no arguments: the core gets none, its choice is launched' (-not $baseargs -and $calls[-1] -eq "$run claude")

    # The core's answer decides what is launched.
    $env:STUB_HARNESS = 'opencode'
    Invoke-Launcher '--'
    Remove-Item Env:STUB_HARNESS
    Check 'the harness the core chose is ensured and run' ($calls[-1] -eq "$run opencode" -and ($calls -like 'pull *-opencode:*').Count -eq 1)
    Check 'its state dirs from the dirs= line are created' ((Test-Path "$work\agents\opencode\config") -and (Test-Path "$work\agents\opencode\data"))
    $env:STUB_TARGET = '/guarded'
    Invoke-Launcher 'claude'
    Remove-Item Env:STUB_TARGET
    Check 'the target the core wrote is exported for the harness run' ($targets[-1] -eq '/guarded' -and $targets[0] -ne '/guarded')

    $env:STUB_NO_HARNESS = '1'
    Invoke-Launcher '--help'
    Remove-Item Env:STUB_NO_HARNESS
    Check '--help: only the core runs, exit 0' ($code -eq 0 -and $calls[-1] -eq "$run base --help")
    Check '--help: the launch dir is removed' (-not (Test-Path "$work\shared\.launch\$($ids[0])"))
    $env:STUB_NO_RESULT = '1'
    Invoke-Launcher 'claude'
    Remove-Item Env:STUB_NO_RESULT
    Check 'exit 0 without a result: error, nothing launched' ($code -eq 1 -and -not ($calls -contains "$run claude") -and $out -like '*produced no result*')

    Remove-Item "$work\shared\.last-harness" -ErrorAction SilentlyContinue
    Invoke-Launcher 'claude'
    Check 'the core''s new state is moved to shared\.last-harness' ((Get-Content "$work\shared\.last-harness") -eq 'new-state')
    foreach ($c in 1, 3, 130) {
        $env:STUB_CORE_CODE = "$c"
        Invoke-Launcher 'claude'
        Remove-Item Env:STUB_CORE_CODE
        Check "core exit ${c}: passed through, nothing launched, launch dir removed" ($code -eq $c -and -not ($calls -contains "$run claude") -and -not (Test-Path "$work\shared\.launch\$($ids[0])"))
    }
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
exit 0
