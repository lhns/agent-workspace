#!/bin/bash
# Tests agents/run.sh (the host side) against a stub `docker` on PATH that logs its arguments and,
# for the base service, plays the core (agents/launch.sh): it writes the hand-off files from
# STUB_HARNESS (default claude), STUB_TARGET, or exits with STUB_CORE_CODE / writes nothing for
# STUB_NO_HARNESS=1 (result "done"), or writes no result for STUB_NO_RESULT=1. The core's own logic is tested by tests/launch.test.sh.
# `docker info` answers STUB_OSTYPE (default linux) and is not logged; a stub `cygpath` answers
# STUB_WINPATH (or fails), so Windows containers can be played on any OS.
# Runs on a temp copy of the repo with a scratch .env, so it leaves no state behind.
#   bash tests/run-sh.test.sh
# shellcheck disable=SC2319 # check's second argument is the exit code of the condition just before it
set -u
src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -C "$src" --exclude=.git --exclude=.env --exclude=shared --exclude='.build*.sha256' -cf - . | tar -C "$work" -xf -
cd "$work" || exit 1
{ cat .env.example; echo '# edited'; } > .env
mkdir -p stub
cat > stub/docker <<'STUB'
#!/bin/sh
if [ "${1:-}" = info ]; then echo "${STUB_OSTYPE:-linux}"; exit 0; fi
echo "$*" >> "$STUB_LOG"
if [ "${1:-}" = compose ] && [ "${2:-}" = run ]; then
    echo "$AGENTS_PLATFORM|$AGENTS_IMAGE_SUFFIX|$AGENTS_DOCKERFILE|$AGENTS_DIR|$AGENTS_HOME" >> "$STUB_LOG.env"
    echo "$AGENTS_WORKSPACE_TARGET" >> "$STUB_LOG.target"
    echo "$AGENTS_RUN_ID" >> "$STUB_LOG.id"
    echo "${WORKSPACE_DIR:-}" >> "$STUB_LOG.ws"
    shift 2
    while [ $# -gt 0 ] && [ "$1" != base ]; do shift; done
    if [ "${1:-}" = base ]; then
        shift
        d=shared/.launch/$AGENTS_RUN_ID
        { [ -d "$d" ] && echo dir || echo nodir; } >> "$STUB_LOG.dir"
        printf '[%s]' "$@" > "$STUB_LOG.base"
        [ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
        [ -z "${STUB_CORE_CODE:-}" ] || exit "$STUB_CORE_CODE"
        cat > "$STUB_LOG.stdin.base"
        [ -z "${STUB_NO_RESULT:-}" ] || exit 0
        [ -z "${STUB_NO_HARNESS:-}" ] || { echo done > "$d/result"; exit 0; }
        printf '%s\n' "${STUB_TARGET:-$AGENTS_WORKSPACE_TARGET}" > "$d/target"
        printf '%s\n' "${STUB_HARNESS:-claude}" > "$d/harness"
        printf 'new-state\n' > "$d/last-harness"
        echo launch > "$d/result"
    else
        cat > "$STUB_LOG.stdin.harness"
    fi
fi
[ "${STUB_BUILD_FAIL:-}" != 1 ] || [ "${1:-}" != compose ] || [ "${2:-}" != build ] || [ "${3:-}" = base ] || exit 1
exit 0
STUB
cat > stub/cygpath <<'STUB'
#!/bin/sh
[ -n "${STUB_WINPATH:-}" ] || exit 1
echo "$STUB_WINPATH"
STUB
chmod +x stub/docker stub/cygpath
export PATH=$work/stub:$PATH STUB_LOG=$work/docker.log AGENTS_LOCAL_BUILD=1
unset AGENTS_HARNESS AGENTS_NONINTERACTIVE AGENTS_AUTORESUME WORKSPACE_DIR STUB_HARNESS STUB_TARGET STUB_CORE_CODE STUB_NO_HARNESS STUB_NO_RESULT STUB_BUILD_FAIL STUB_SLEEP STUB_OSTYPE STUB_WINPATH AGENTS_PLATFORM

fail=0
# run <args...>: sets `out` (stdout+stderr), `code` and `calls` (the docker calls, "|"-separated).
run() {
    rm -f "$STUB_LOG" "$STUB_LOG".*
    out=$(bash agents/run.sh "$@" </dev/null 2>&1); code=$?
    calls=$(paste -sd'|' "$STUB_LOG" 2>/dev/null)
}
check() { # name, ok (0 = pass)
    if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1 (code=$code calls='$calls' out='$out')" >&2; fail=1; fi
}
is() { [ "$calls" = "$1" ]; }
log() { tail -n1 "$STUB_LOG.$1" 2>/dev/null; }

# Order: base ensured, the core with the arguments untouched, then the harness ensured and run.
run claude
check "first launch: builds base, core, builds the harness, runs it" "$(is 'compose build base|compose run --rm -T base claude|image inspect agent-workspace-base|compose build claude|compose run --rm -T claude'; echo $?)"
check "first launch: exit code" "$([ "$code" = 0 ]; echo $?)"
run claude
check "second launch: nothing built" "$(is 'image inspect agent-workspace-base|compose run --rm -T base claude|image inspect agent-workspace-claude|compose run --rm -T claude'; echo $?)"
check "the core has the launch dir, the harness run gets no arguments" "$([ "$(log dir)" = dir ]; echo $?)"
check "the same run id for both runs" "$([ "$(sort -u "$STUB_LOG.id" | wc -l)" = 1 ] && [ -n "$(log id)" ]; echo $?)"
check "the launch dir is removed afterwards" "$([ -z "$(ls -A shared/.launch)" ]; echo $?)"
check "your instructions file is created in shared/instructions" "$([ -f shared/instructions/AGENTS.md ] && [ ! -e shared/AGENTS.md ]; echo $?)"
# An older shared/AGENTS.md moves there once; an existing new file is never overwritten.
rm -rf shared/instructions; echo mine > shared/AGENTS.md
run claude
check "an older shared/AGENTS.md is moved to shared/instructions" "$([ "$(cat shared/instructions/AGENTS.md)" = mine ] && [ ! -e shared/AGENTS.md ]; echo $?)"
echo old > shared/AGENTS.md
run claude
check "an existing shared/instructions/AGENTS.md is kept" "$([ "$(cat shared/instructions/AGENTS.md)" = mine ] && [ -e shared/AGENTS.md ]; echo $?)"
rm shared/AGENTS.md

# Arguments reach the core untouched, whatever they are.
run --continue claude --model x 'a b' '' '!' '"q"' '-z'
check "arguments are passed to the core untouched" "$([ "$(log base)" = '[--continue][claude][--model][x][a b][][!]["q"][-z]' ]; echo $?)"
run --harness claude --exec bash -c 'echo "a b"'
check "--exec arguments are passed to the core untouched" "$([ "$(log base)" = '[--harness][claude][--exec][bash][-c][echo "a b"]' ]; echo $?)"
check "a path-like argument is not converted" "$(run /tmp/y; [ "$(log base)" = '[/tmp/y]' ]; echo $?)"

# What the core hands back.
STUB_HARNESS=opencode run
check "no arguments: the core's choice is launched" "$(is 'image inspect agent-workspace-base|compose run --rm -T base|image inspect agent-workspace-base|compose build opencode|compose run --rm -T opencode'; echo $?)"
check "the state dirs of the harness's dirs= line are created" "$([ -d agents/opencode/config ] && [ -d agents/opencode/data ]; echo $?)"
STUB_TARGET=/guarded run claude
check "the host re-exports the target the core wrote" "$([ "$(log target | tail -n1)" = /guarded ] && [ "$(head -n1 "$STUB_LOG.target")" != /guarded ]; echo $?)"
STUB_NO_HARNESS=1 run --help
check "--help: only the core runs, exit 0" "$(is 'image inspect agent-workspace-base|compose run --rm -T base --help' && [ "$code" = 0 ]; echo $?)"
check "--help: the launch dir is removed" "$([ -z "$(ls -A shared/.launch)" ]; echo $?)"
for c in 1 3 130; do
    STUB_CORE_CODE=$c run claude
    check "core exit $c: passed through, nothing launched" "$([ "$code" = "$c" ] && ! grep -q 'run --rm -T claude' "$STUB_LOG" && [ -z "$(ls -A shared/.launch)" ]; echo $?)"
done

# No result from the core is an error, not "nothing to launch".
STUB_NO_RESULT=1 run claude
check "exit 0 without a result: error" "$([ "$code" = 1 ] && ! grep -q 'run --rm -T claude' "$STUB_LOG" && case $out in *"produced no result"*) true ;; *) false ;; esac; echo $?)"

# shared/.last-harness: the core's new content is moved in only after the harness image is ready.
rm -f shared/.last-harness
STUB_HARNESS=hermes STUB_BUILD_FAIL=1 run --harness hermes
check "a failed harness build records nothing" "$([ "$code" != 0 ] && [ ! -e shared/.last-harness ]; echo $?)"
run claude
check "the new state is moved into place before the harness runs" "$([ "$(cat shared/.last-harness)" = new-state ]; echo $?)"

# stdin: without a terminal it belongs to the harness, not the core.
rm -f "$STUB_LOG" "$STUB_LOG".*
echo hello | bash agents/run.sh claude >/dev/null 2>&1
check "piped stdin reaches the harness, not the core" "$([ -z "$(cat "$STUB_LOG.stdin.base")" ] && [ "$(cat "$STUB_LOG.stdin.harness")" = hello ]; echo $?)"

# SIGTERM (Ctrl-C ends the shell the same way): the launch dir goes, the code is 130. The signal
# is not forwarded, so the core finishes first (that is what STUB_SLEEP stands for).
rm -f "$STUB_LOG" "$STUB_LOG".*
STUB_SLEEP=2 bash agents/run.sh claude </dev/null >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 50); do [ -e "$STUB_LOG.dir" ] && break; sleep 0.1; done
kill -TERM "$pid"; wait "$pid"; code=$?
out=; calls=
check "SIGTERM after the core finishes: exit 130 and the launch dir removed" "$([ "$code" = 130 ] && [ -z "$(ls -A shared/.launch)" ]; echo $?)"

# Host-side checks, before any docker call.
WORKSPACE_DIR=$work/does-not-exist run claude
check "missing WORKSPACE_DIR stops before docker" "$([ "$code" = 1 ] && [ -z "$calls" ]; echo $?)"
mkdir -p "$work/my proj"
WORKSPACE_DIR="$work/my proj" run claude
check "WORKSPACE_DIR is the target the core gets" "$([ "$(head -n1 "$STUB_LOG.target")" = "$(cd "$work/my proj" && pwd -P)" ]; echo $?)"

# --workdir: a leading option the host applies; the core still gets it untouched.
mkdir -p "$work/other/sub dir"
rm -f "$STUB_LOG" "$STUB_LOG".*
out=$(cd "$work/other" && bash "$work/agents/run.sh" --workdir 'sub dir' claude --model x </dev/null 2>&1); code=$?
check "--workdir resolves against the caller's folder" "$([ "$code" = 0 ] && [ "$(head -n1 "$STUB_LOG.target")" = "$(cd "$work/other/sub dir" && pwd -P)" ]; echo $?)"
check "--workdir is exported for compose's mount source" "$([ "$(head -n1 "$STUB_LOG.ws")" = "$(cd "$work/other/sub dir" && pwd -P)" ]; echo $?)"
check "--workdir is passed to the core untouched" "$([ "$(log base)" = '[--workdir][sub dir][claude][--model][x]' ]; echo $?)"
mkdir -p "$work/shellws"
WORKSPACE_DIR="$work/shellws" run --workdir "$work/my proj" claude
check "--workdir beats a shell WORKSPACE_DIR" "$([ "$(head -n1 "$STUB_LOG.target")" = "$(cd "$work/my proj" && pwd -P)" ]; echo $?)"
run --workdir "$work/does-not-exist" claude
check "--workdir with a missing folder stops before docker" "$([ "$code" = 1 ] && [ -z "$calls" ] && case $out in *"does not exist"*) true ;; *) false ;; esac; echo $?)"
run --workdir
check "--workdir without a value stops before docker" "$([ "$code" = 1 ] && [ -z "$calls" ] && case $out in *"needs a folder"*) true ;; *) false ;; esac; echo $?)"
run claude --workdir "$work/my proj"
check "--workdir not first is left to the core" "$([ "$(log base)" = "[claude][--workdir][$work/my proj]" ]; echo $?)"

# Windows containers: the daemon's OSType (or AGENTS_PLATFORM) picks the -windows names, hash files, tags and paths.
sha() { cat "$@" | sha256sum | cut -d' ' -f1; }
env_of() { tail -n1 "$STUB_LOG.env" 2>/dev/null; }
winenv='windows|-windows|Dockerfile.windows|C:/agent-workspace|C:/Users/ContainerAdministrator'
base_files=(agents/base/Dockerfile.windows agents/base/install.ps1)
rm -f agents/*/.build*.sha256
run claude
check "linux: no platform variables for compose" "$([ "$(env_of)" = 'linux||||' ]; echo $?)"
rm -f agents/*/.build*.sha256
STUB_OSTYPE=windows STUB_WINPATH='C:\Users\me\proj' run claude
check "windows: base and harness are built under their -windows names" "$(is 'compose build base|compose run --rm -T base claude|image inspect agent-workspace-base-windows|compose build claude|compose run --rm -T claude'; echo $?)"
check "windows: compose gets the Windows variables" "$([ "$(env_of)" = "$winenv" ]; echo $?)"
check "windows: the hash files are .build-windows.sha256, over the Windows files" "$([ "$(cat agents/base/.build-windows.sha256)" = "$(sha "${base_files[@]}")" ] && [ "$(cat agents/claude/.build-windows.sha256)" = "$(sha "${base_files[@]}" agents/claude/Dockerfile.windows)" ] && [ ! -e agents/base/.build.sha256 ]; echo $?)"
check "windows: a C: workspace is mounted at its own path" "$([ "$(head -n1 "$STUB_LOG.target")" = 'C:\Users\me\proj' ]; echo $?)"
STUB_OSTYPE=windows STUB_WINPATH='D:\work\proj' run claude
check "windows: another drive falls back to C:\\workspace" "$([ "$(head -n1 "$STUB_LOG.target")" = 'C:\workspace' ]; echo $?)"
STUB_OSTYPE=windows run claude
check "windows: no path from cygpath falls back to C:\\workspace" "$([ "$(head -n1 "$STUB_LOG.target")" = 'C:\workspace' ]; echo $?)"
STUB_OSTYPE=windows STUB_WINPATH='c:\lower' run claude
check "windows: a lower-case drive letter counts as C:" "$([ "$(head -n1 "$STUB_LOG.target")" = 'c:\lower' ]; echo $?)"
STUB_OSTYPE=windows STUB_WINPATH='C:\x' run claude
check "windows: a second launch builds nothing" "$(is 'image inspect agent-workspace-base-windows|compose run --rm -T base claude|image inspect agent-workspace-claude-windows|compose run --rm -T claude'; echo $?)"
# The tag is the hash plus -windows.
rm -f agents/*/.build*.sha256
bh=$(sha "${base_files[@]}")
ch=$(sha "${base_files[@]}" agents/claude/Dockerfile.windows)
p=ghcr.io/lhns/agent-workspace
STUB_OSTYPE=windows STUB_WINPATH='C:\x' AGENTS_LOCAL_BUILD='' run claude
check "windows: prebuilt images are pulled as <prefix>-<name>:<hash>-windows" "$(is "pull $p-base:$bh-windows|tag $p-base:$bh-windows agent-workspace-base-windows|rmi $p-base:$bh-windows|compose run --rm -T base claude|pull $p-claude:$ch-windows|tag $p-claude:$ch-windows agent-workspace-claude-windows|rmi $p-claude:$ch-windows|compose run --rm -T claude"; echo $?)"
STUB_WINPATH='C:\x' AGENTS_PLATFORM=windows run claude
check "AGENTS_PLATFORM=windows beats a Linux daemon" "$([ "$(env_of)" = "$winenv" ]; echo $?)"
STUB_OSTYPE=windows AGENTS_PLATFORM=linux run claude
check "AGENTS_PLATFORM=linux beats a Windows daemon" "$([ "$(env_of)" = 'linux||||' ]; echo $?)"
echo 'AGENTS_PLATFORM=windows' >> .env
STUB_WINPATH='C:\x' run claude
check "AGENTS_PLATFORM in .env is used" "$([ "$(env_of)" = "$winenv" ]; echo $?)"
AGENTS_PLATFORM=linux run claude
check "a shell AGENTS_PLATFORM beats .env" "$([ "$(env_of)" = 'linux||||' ]; echo $?)"
grep -v '^AGENTS_PLATFORM=' .env > .env.tmp; mv .env.tmp .env
rm -f agents/*/.build*.sha256

mv .env .env.edited
run --help
check "fresh checkout: creates .env and refuses, even for --help" "$([ "$code" = 1 ] && [ -z "$calls" ] && [ -f .env ] && case $out in *"Edit .env first"*) true ;; *) false ;; esac; echo $?)"
mv .env.edited .env
grep -v '^AGENTS_LOCAL_BUILD=' .env > .env.tmp; mv .env.tmp .env
run claude
check "a key missing from .env warns" "$(case $out in *"Warning: AGENTS_LOCAL_BUILD is missing"*) true ;; *) false ;; esac; echo $?)"
exit $fail
