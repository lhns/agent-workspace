# Tests agents/run.bat against a stub `docker.exe` (compiled below; a .cmd stub would end the
# calling batch file) that logs its arguments and fails `pull` when STUB_PULL_FAIL=1 (or names failing refs) and
# `image inspect` when STUB_INSPECT_FAIL=1; `compose run` also records AGENTS_WORKSPACE_TARGET and AGENTS_NONINTERACTIVE. Runs on
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
    var shown = new System.Collections.Generic.List<string>();
    foreach (var s in a) shown.Add(s.Contains(" ") ? "\"" + s + "\"" : s);
    System.IO.File.AppendAllText(System.Environment.GetEnvironmentVariable("STUB_LOG"), string.Join(" ", shown) + "\n");
    var target = System.Environment.GetEnvironmentVariable("AGENTS_WORKSPACE_TARGET");
    if (a.Length > 1 && a[0] == "compose" && a[1] == "run") {
        System.IO.File.AppendAllText(System.Environment.GetEnvironmentVariable("STUB_LOG") + ".target", target + "\n");
        System.IO.File.AppendAllText(System.Environment.GetEnvironmentVariable("STUB_LOG") + ".ni", "[" + System.Environment.GetEnvironmentVariable("AGENTS_NONINTERACTIVE") + "]\n");
    }
    // The harness picker (compose run ... base): STUB_PICK is the choice it records, STUB_PICK_CODE its exit code.
    if (a.Length > 2 && a[0] == "compose" && a[1] == "run" && System.Array.IndexOf(a, "base") > 1) {
        var pick = System.Environment.GetEnvironmentVariable("STUB_PICK");
        if (!string.IsNullOrEmpty(pick)) System.IO.File.WriteAllText("shared\\.last-harness", target + "\t" + pick + "\n*\t" + pick + "\n");
        var code = System.Environment.GetEnvironmentVariable("STUB_PICK_CODE");
        if (!string.IsNullOrEmpty(code)) System.Environment.Exit(int.Parse(code));
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
Remove-Item Env:WORKSPACE_DIR, Env:AGENTS_HARNESS, Env:AGENTS_NONINTERACTIVE, Env:AGENTS_LOCAL_BUILD, Env:AGENTS_IMAGE_PREFIX, Env:STUB_PULL_FAIL, Env:STUB_INSPECT_FAIL -ErrorAction SilentlyContinue
$failures = 0
$hash = (Get-FileHash -Algorithm SHA256 -InputStream ([IO.MemoryStream]::new([byte[]]([IO.File]::ReadAllBytes("$work\agents\base\Dockerfile") + [IO.File]::ReadAllBytes("$work\agents\claude\Dockerfile"))))).Hash.ToLower()
$S = 'bash /usr/local/lib/agents-start.sh'
$ref = "ghcr.io/lhns/agent-workspace-claude:$hash"
$pulled = "pull $ref|tag $ref agent-workspace-claude|rmi $ref|compose run --rm -T claude bash /usr/local/lib/agents-start.sh claude"
$built = 'compose build base|compose build claude|compose run --rm -T claude bash /usr/local/lib/agents-start.sh claude'
$unchanged = 'image inspect agent-workspace-claude|compose run --rm -T claude bash /usr/local/lib/agents-start.sh claude'

# Runs the real launcher; stdin from NUL so the `pause` after "Edit .env first" returns.
function Invoke-Launcher([string]$arguments) {
    Remove-Item $log -ErrorAction SilentlyContinue
    Push-Location $work
    try { cmd /c ".\run-agent.bat $arguments < NUL > out.txt 2>&1" } finally { Pop-Location }
    $script:code = $LASTEXITCODE
    $script:calls = if (Test-Path $log) { @(Get-Content $log) } else { @() }
    $script:target = if (Test-Path "$log.target") { @(Get-Content "$log.target")[-1] } else { $null }
    Remove-Item "$log.target" -ErrorAction SilentlyContinue
    $script:ni = if (Test-Path "$log.ni") { @(Get-Content "$log.ni")[-1] } else { $null }
    Remove-Item "$log.ni" -ErrorAction SilentlyContinue
    $script:out = if (Test-Path "$work\out.txt") { Get-Content "$work\out.txt" -Raw } else { '' }
}
# C:\a\b -> /c/a/b, where the launcher mounts the workspace.
function ConvertTo-Mount([string]$path) { '/' + $path.Substring(0, 1).ToLower() + $path.Substring(2).Replace('\', '/') }
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "ok   $name" } else { Write-Host "FAIL $name"; $script:failures++ }
}

try {
    Invoke-Launcher 'claude'
    Check 'fresh checkout: refuses until .env is edited' ($code -eq 1 -and $calls.Count -eq 0 -and (Test-Path "$work\.env"))

    Add-Content "$work\.env" '# edited'
    Invoke-Launcher 'claude'
    Check 'first run pulls, tags and removes the ghcr tag, without building' (($calls -join '|') -eq $pulled)
    Check 'first run writes the same hash as sha256sum' ((Get-Content "$work\agents\claude\.build.sha256") -eq $hash)

    Invoke-Launcher 'claude'
    Check 'unchanged hash: neither pull nor build' (($calls -join '|') -eq $unchanged)

    $env:STUB_INSPECT_FAIL = '1'
    Invoke-Launcher 'claude'
    Remove-Item Env:STUB_INSPECT_FAIL
    Check 'unchanged hash but image pruned: pulls again' (($calls -join '|') -eq "image inspect agent-workspace-claude|$pulled")

    Add-Content "$work\agents\base\Dockerfile" '# changed'
    $env:STUB_PULL_FAIL = '1'
    Invoke-Launcher 'claude'
    Remove-Item Env:STUB_PULL_FAIL
    $newRef = $calls[0] -replace '^pull ', ''
    $baseRef0 = "ghcr.io/lhns/agent-workspace-base:$((Get-FileHash -Algorithm SHA256 "$work\agents\base\Dockerfile").Hash.ToLower())"
    Check 'changed Dockerfile with failing pulls: pulls base too, builds base, then claude' (($calls -join '|') -eq "pull $newRef|pull $baseRef0|$built" -and $newRef -ne $ref)

    Invoke-Launcher 'claude'
    Check 'build is skipped again afterwards' (($calls -join '|') -eq $unchanged)

    # Only the harness is missing on the registry: the pulled base is reused, base is not rebuilt.
    Add-Content "$work\agents\claude\Dockerfile" '# changed'
    Remove-Item "$work\agents\base\.build.sha256"
    $env:STUB_PULL_FAIL = 'agent-workspace-claude'
    Invoke-Launcher 'claude'
    Remove-Item Env:STUB_PULL_FAIL
    $newRef = $calls[0] -replace '^pull ', ''
    Check 'harness pull misses, base pull works: builds the harness on the pulled base' (($calls -join '|') -eq "pull $newRef|pull $baseRef0|tag $baseRef0 agent-workspace-base|rmi $baseRef0|compose build claude|compose run --rm -T claude bash /usr/local/lib/agents-start.sh claude")

    # Base already current locally: no pull or build of base at all.
    Add-Content "$work\agents\claude\Dockerfile" '# changed again'
    $env:STUB_PULL_FAIL = 'agent-workspace-claude'
    Invoke-Launcher 'claude'
    Remove-Item Env:STUB_PULL_FAIL
    $newRef = $calls[0] -replace '^pull ', ''
    Check 'harness pull misses, base current: builds only the harness' (($calls -join '|') -eq "pull $newRef|image inspect agent-workspace-base|compose build claude|compose run --rm -T claude $S claude")
    $builtOnBase = 'image inspect agent-workspace-base|compose build claude|compose run --rm -T claude bash /usr/local/lib/agents-start.sh claude'

    $env:AGENTS_LOCAL_BUILD = '1'
    Remove-Item "$work\agents\claude\.build.sha256"
    Invoke-Launcher 'claude'
    Remove-Item Env:AGENTS_LOCAL_BUILD
    Check 'AGENTS_LOCAL_BUILD in the shell builds without pulling' (($calls -join '|') -eq $builtOnBase)

    Add-Content "$work\.env" 'AGENTS_LOCAL_BUILD=1'
    Remove-Item "$work\agents\claude\.build.sha256"
    Invoke-Launcher 'claude'
    Check 'AGENTS_LOCAL_BUILD in .env builds without pulling' (($calls -join '|') -eq $builtOnBase)

    $env:AGENTS_IMAGE_PREFIX = 'registry.example/me/aw'
    Remove-Item "$work\agents\claude\.build.sha256"
    (Get-Content "$work\.env") -notmatch '^AGENTS_LOCAL_BUILD=' | Set-Content "$work\.env"
    Invoke-Launcher 'claude'
    Remove-Item Env:AGENTS_IMAGE_PREFIX
    Check 'AGENTS_IMAGE_PREFIX sets the pulled image' ($calls[0] -like 'pull registry.example/me/aw-claude:*')

    $env:WORKSPACE_DIR = "$work\does-not-exist"
    Invoke-Launcher 'claude'
    Remove-Item Env:WORKSPACE_DIR
    Check 'missing WORKSPACE_DIR stops before docker' ($code -eq 1 -and $calls.Count -eq 0)

    Invoke-Launcher 'claude'
    Check 'default workspace is mounted at its mirrored host path' ($target -eq (ConvertTo-Mount "$work\workspace"))

    New-Item -ItemType Directory "$work\my proj" | Out-Null
    $env:WORKSPACE_DIR = "$work\my proj"
    Invoke-Launcher 'claude'
    Remove-Item Env:WORKSPACE_DIR
    Check 'WORKSPACE_DIR with a space is mounted at its mirrored host path' ($target -eq (ConvertTo-Mount "$work\my proj"))

    $env:WORKSPACE_DIR = 'workspace'
    Invoke-Launcher 'claude'
    Remove-Item Env:WORKSPACE_DIR
    Check 'relative WORKSPACE_DIR resolves against the repo' ($target -eq (ConvertTo-Mount "$work\workspace"))

    # A path without a drive letter (UNC) can't be mirrored; skipped where the admin share is unavailable.
    $unc = '\\localhost\' + $work.Substring(0, 1) + '$' + $work.Substring(2)
    if (Test-Path $unc) {
        $env:WORKSPACE_DIR = $unc
        Invoke-Launcher 'claude'
        Remove-Item Env:WORKSPACE_DIR
        Check 'UNC WORKSPACE_DIR falls back to /workspace' ($target -eq '/workspace')
    }

    # Arguments with quotes, spaces and ! reach the harness as they were typed.
    Invoke-Launcher 'claude bash -c "echo hi there!" x'
    Check 'arguments with quotes, spaces and ! pass through' ($calls[-1] -eq 'compose run --rm -T claude bash /usr/local/lib/agents-start.sh claude bash -c "echo hi there!" x')

    # A given harness is remembered for this workspace and for anywhere, as tab-separated lines.
    Invoke-Launcher 'pi'
    $last = @(Get-Content "$work\shared\.last-harness")
    Check 'a harness argument is recorded in shared\.last-harness, keeping other workspaces' ($last[-2] -eq ((ConvertTo-Mount "$work\workspace") + "`tpi") -and $last[-1] -eq "*`tpi" -and @($last | Where-Object { $_.StartsWith("*`t") }).Count -eq 1 -and ($last -contains ((ConvertTo-Mount "$work\my proj") + "`tclaude")))
    Check 'a harness argument runs without the menu or the base image' ($calls[-1] -eq 'compose run --rm -T pi bash /usr/local/lib/agents-start.sh pi' -and -not ($calls -match 'base$'))

    # No harness: the base image is ensured first, the picker runs, then the chosen harness
    # starts with all arguments. Base Dockerfile was edited above, so hashes come from the files.
    function Get-Hash([string[]]$files) { (Get-FileHash -Algorithm SHA256 -InputStream ([IO.MemoryStream]::new([byte[]]($files | ForEach-Object { [IO.File]::ReadAllBytes("$work\$_") })))).Hash.ToLower() }
    Remove-Item "$work\agents\pi\.build.sha256", "$work\agents\base\.build.sha256" -ErrorAction SilentlyContinue
    $env:STUB_PICK = 'pi'
    Invoke-Launcher '-- bash -c "echo hi there!"'
    $baseRef = "ghcr.io/lhns/agent-workspace-base:$(Get-Hash 'agents\base\Dockerfile')"
    $piRef = "ghcr.io/lhns/agent-workspace-pi:$(Get-Hash 'agents\base\Dockerfile', 'agents\pi\Dockerfile')"
    $menuCalls = "pull $baseRef|tag $baseRef agent-workspace-base|rmi $baseRef|compose run --rm -T base|pull $piRef|tag $piRef agent-workspace-pi|rmi $piRef|compose run --rm -T pi bash /usr/local/lib/agents-start.sh pi bash -c `"echo hi there!`""
    Check 'no harness: pulls base, runs the picker, pulls and starts the chosen harness' (($calls -join '|') -eq $menuCalls)

    Invoke-Launcher '--'
    Check 'no harness, base unchanged: picker, then the chosen harness' (($calls -join '|') -eq 'image inspect agent-workspace-base|compose run --rm -T base|image inspect agent-workspace-pi|compose run --rm -T pi bash /usr/local/lib/agents-start.sh pi')

    $env:STUB_PICK_CODE = '130'
    Invoke-Launcher '--'
    Remove-Item Env:STUB_PICK_CODE
    Check 'picker failure (Ctrl-C) stops with its code and starts nothing' ($code -eq 130 -and -not ($calls -match 'run --rm -T pi'))

    Remove-Item Env:STUB_PICK
    Remove-Item "$work\shared\.last-harness"
    Invoke-Launcher '--'
    Check 'picker recording nothing stops with an error' ($code -eq 1 -and -not ($calls -match 'run --rm -T pi'))

    # Options. The state is as left above: images current, so the last call is the launch.
    $run = 'compose run --rm -T'
    Invoke-Launcher '--continue claude'
    Check '--continue passes AGENTS_AUTORESUME=yes' ($calls[-1] -eq "$run -e AGENTS_AUTORESUME=yes claude $S claude")
    Invoke-Launcher '--new --harness pi'
    Check '--new with --harness passes AGENTS_AUTORESUME=no' ($calls[-1] -eq "$run -e AGENTS_AUTORESUME=no pi $S pi" -and -not ($calls -match 'run --rm -T base'))
    Invoke-Launcher '--ask claude'
    Check '--ask passes AGENTS_AUTORESUME=ask' ($calls[-1] -eq "$run -e AGENTS_AUTORESUME=ask claude $S claude")
    Invoke-Launcher 'claude'
    Check 'no resume flag: no -e, so the shell and .env setting applies' ($calls[-1] -eq "$run claude $S claude")
    Invoke-Launcher 'claude --model x'
    Check 'arguments after the harness go to the harness' ($calls[-1] -eq "$run claude $S claude --model x")
    Invoke-Launcher '--continue claude --model x /tmp/y'
    Check 'options before the harness, arguments after (a /path stays as typed)' ($calls[-1] -eq "$run -e AGENTS_AUTORESUME=yes claude $S claude --model x /tmp/y")
    Invoke-Launcher 'claude -- --model x'
    Check 'a -- right after the harness is swallowed' ($calls[-1] -eq "$run claude $S claude --model x")
    Invoke-Launcher '--harness claude --model x'
    Check 'an unknown option after --harness is an error, no docker call' ($code -eq 1 -and $calls.Count -eq 0 -and $out -like '*Unknown option --model*')
    Invoke-Launcher '--harness claude -- --model x'
    Check '--harness with -- forwards the arguments' ($calls[-1] -eq "$run claude $S claude --model x")
    Invoke-Launcher '--harness claude foo'
    Check '--harness: the first non-option starts the harness arguments' ($calls[-1] -eq "$run claude $S claude foo")
    Invoke-Launcher '--foo claude'
    Check 'unknown option before the harness: error that suggests --' ($code -eq 1 -and $calls.Count -eq 0 -and $out -like '*Unknown option --foo*put -- before*')
    Invoke-Launcher 'bash -c x'
    Check 'unknown harness name: error, no docker call' ($code -eq 1 -and $calls.Count -eq 0 -and $out -like '*Unknown harness bash*')
    Invoke-Launcher '--harness nope'
    Check '--harness with an unknown name: error' ($code -eq 1 -and $calls.Count -eq 0 -and $out -like "*Unknown harness 'nope'*")
    Invoke-Launcher '--harness'
    Check '--harness without a name: error' ($code -eq 1 -and $calls.Count -eq 0)
    Invoke-Launcher '-h'
    Check '-h prints the usage and starts nothing' ($code -eq 0 -and $calls.Count -eq 0 -and $out -like '*Usage: run-agent*--exec*')

    Invoke-Launcher '--harness claude --exec bash -c "echo hi there!" /tmp/x'
    Check '--exec runs the command in the harness container instead of the harness' ($calls[-1] -eq "$run claude bash -c `"echo hi there!`" /tmp/x")
    Invoke-Launcher '--exec'
    Check '--exec without a command: error' ($code -eq 1 -and $calls.Count -eq 0)
    $env:STUB_PICK = 'pi'
    Invoke-Launcher '--exec bash'
    Check '--exec without a harness: the menu picks, then the command runs there' ($calls[-1] -eq "$run pi bash" -and ($calls -match 'run --rm -T base').Count -eq 1)
    Invoke-Launcher '-- --model x'
    Check '-- without a harness: the menu picks, arguments go to it' ($calls[-1] -eq "$run pi $S pi --model x")
    Remove-Item Env:STUB_PICK

    Invoke-Launcher '--sessions claude'
    Check '--sessions without a terminal: error' ($code -eq 1 -and $calls.Count -eq 0 -and $out -like '*--sessions needs a terminal*')
    Invoke-Launcher '-y --sessions claude'
    Check '--sessions with -y: error' ($code -eq 1 -and $calls.Count -eq 0 -and $out -like "*can't be combined with -y*")

    Invoke-Launcher 'claude'
    Check 'AGENTS_NONINTERACTIVE is not set by default' ($ni -eq '[]')
    Invoke-Launcher '-y claude'
    Check '-y sets AGENTS_NONINTERACTIVE for compose' ($ni -eq '[1]' -and $calls[-1] -eq "$run claude $S claude")
    Invoke-Launcher '--non-interactive claude'
    Check '--non-interactive is -y' ($ni -eq '[1]')
    $env:AGENTS_NONINTERACTIVE = 'yes'
    Invoke-Launcher 'claude'
    Remove-Item Env:AGENTS_NONINTERACTIVE
    Check 'AGENTS_NONINTERACTIVE in the shell is -y' ($ni -eq '[1]')
    Add-Content "$work\.env" 'AGENTS_NONINTERACTIVE=1'
    Invoke-Launcher 'claude'
    (Get-Content "$work\.env") -notmatch '^AGENTS_NONINTERACTIVE=' | Set-Content "$work\.env"
    Check 'AGENTS_NONINTERACTIVE in .env is -y' ($ni -eq '[1]')

    $env:AGENTS_HARNESS = 'pi'
    Invoke-Launcher '--continue'
    Check 'AGENTS_HARNESS in the shell picks the harness without the menu' ($calls[-1] -eq "$run -e AGENTS_AUTORESUME=yes pi $S pi" -and -not ($calls -match 'run --rm -T base'))
    Invoke-Launcher 'claude'
    Check 'a positional harness beats AGENTS_HARNESS' ($calls[-1] -eq "$run claude $S claude")
    Invoke-Launcher '--harness claude'
    Check '--harness beats AGENTS_HARNESS' ($calls[-1] -eq "$run claude $S claude")
    Invoke-Launcher '-- --model x'
    Check 'AGENTS_HARNESS with --: arguments go to it' ($calls[-1] -eq "$run pi $S pi --model x")
    $env:AGENTS_HARNESS = 'nope'
    Invoke-Launcher ''
    Remove-Item Env:AGENTS_HARNESS
    Check 'AGENTS_HARNESS with an unknown name: error' ($code -eq 1 -and $calls.Count -eq 0)
    Add-Content "$work\.env" 'AGENTS_HARNESS=claude'
    Invoke-Launcher ''
    (Get-Content "$work\.env") -notmatch '^AGENTS_HARNESS=' | Set-Content "$work\.env"
    Check 'AGENTS_HARNESS in .env picks the harness' ($calls[-1] -eq "$run claude $S claude")
}
finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
if ($failures) { Write-Host "$failures check(s) failed"; exit 1 }
exit 0
