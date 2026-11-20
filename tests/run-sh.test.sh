#!/bin/bash
# Tests agents/run.sh (the host side) against a stub `docker` on PATH that logs its arguments and,
# for the base service, plays the core (agents/launch.sh): it writes the hand-off files from
# STUB_HARNESS (default claude), STUB_TARGET, or exits with STUB_CORE_CODE / writes nothing for
# STUB_NO_HARNESS=1 (result "done"), or writes no result for STUB_NO_RESULT=1. The core's own logic is tested by tests/launch.test.sh.
# `docker info` answers STUB_OSTYPE (default linux), or STUB_SECOPTS for the SecurityOptions query, and is not logged;
# stub `uname -s` / `id` answer STUB_UNAME_S, STUB_UID and STUB_GID (default Linux 1000:1000, so the host user doesn't matter);
# `image inspect` gives STUB_IMAGE_ID for the source image and STUB_LABEL (else fails: no derived image) for the label;
# STUB_VOLUME=1 makes the cache volume exist; a stub `cygpath` answers
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
if [ "${1:-}" = info ]; then
    case "$*" in *SecurityOptions*) echo "${STUB_SECOPTS:-[\"name=seccomp,profile=default\"]}" ;; *) echo "${STUB_OSTYPE:-linux}" ;; esac
    exit 0
fi
echo "$*" >> "$STUB_LOG"
case "$*" in
    "image inspect -f {{.Id}} "*) echo "${STUB_IMAGE_ID:-sha256:src}" ;;
    "image inspect -f "*Labels*) [ -n "${STUB_LABEL:-}" ] || exit 1; echo "$STUB_LABEL" ;;
    "volume inspect "*) [ -n "${STUB_VOLUME:-}" ] || exit 1 ;;
esac
if [ "${1:-}" = compose ]; then echo "$2 ${AGENTS_IMAGE_TAG-unset}" >> "$STUB_LOG.tag"; fi
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
cat > stub/uname <<'STUB'
#!/bin/sh
if [ "${1:-}" = -s ]; then echo "${STUB_UNAME_S:-Linux}"; exit 0; fi
if [ "${1:-}" = -o ] && [ -n "${STUB_UNAME:-}" ]; then echo "$STUB_UNAME"; exit 0; fi
exec "$REAL_UNAME" "$@"
STUB
cat > stub/id <<'STUB'
#!/bin/sh
case "${1:-}" in -u) echo "${STUB_UID:-1000}" ;; -g) echo "${STUB_GID:-1000}" ;; *) exec "$REAL_ID" "$@" ;; esac
STUB
REAL_UNAME=$(command -v uname); REAL_ID=$(command -v id); export REAL_UNAME REAL_ID
chmod +x stub/docker stub/cygpath stub/uname stub/id
export PATH=$work/stub:$PATH STUB_LOG=$work/docker.log AGENTS_LOCAL_BUILD=1
unset AGENTS_HARNESS AGENTS_NONINTERACTIVE AGENTS_AUTORESUME WORKSPACE_DIR STUB_HARNESS STUB_TARGET STUB_CORE_CODE STUB_NO_HARNESS STUB_NO_RESULT STUB_BUILD_FAIL STUB_SLEEP STUB_OSTYPE STUB_WINPATH AGENTS_PLATFORM AGENTS_UID AGENTS_IMAGE_TAG STUB_UNAME_S STUB_UID STUB_GID STUB_SECOPTS STUB_LABEL STUB_VOLUME STUB_IMAGE_ID

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

# Git (ADR 28): seeding on a Windows host (Git Bash) and the opt-in copy of the host's login. Fake values
# only; the "host's credential helper" is a script of ours, nothing contacts a host.
export HOME=$work/home GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=$work/hostgit
unset XDG_CONFIG_HOME AGENTS_GIT_CREDENTIALS
export STUB_UNAME=Linux # also when this test runs under Git Bash
mkdir -p "$HOME"
printf '[core]\n\teditor = "C:/Program Files/Editor/ed.exe"\n[url "https://git.example.com/"]\n\tinsteadOf = ex:\n[http]\n\tsslBackend = schannel\n' > "$HOME/.gitconfig"
rm -rf shared/git; run claude
check "seed on a Linux host: copied as is" "$([ "$(cat shared/git/config)" = "$(cat "$HOME/.gitconfig")" ]; echo $?)"
rm -rf shared/git; STUB_UNAME=Msys run claude
check "seed under Git Bash: values with Windows paths are dropped" "$(! grep -q 'C:/' shared/git/config; echo $?)"
check "seed under Git Bash: https URLs and other settings stay" "$(grep -q 'insteadOf = ex:' shared/git/config && grep -q 'sslBackend = schannel' shared/git/config; echo $?)"
rm -f "$HOME/.gitconfig"
rm -rf shared/git; STUB_UNAME=Msys run claude
check "seed under Git Bash without a host config: empty file, no error" "$([ "$code" = 0 ] && [ -f shared/git/config ] && [ ! -s shared/git/config ]; echo $?)"

# The host's helper, a shell function that answers like Git Credential Manager would (extra attributes
# included). FAKE_NO_LOGIN: no answer.
cat > "$work/hostgit" <<'HOSTGIT'
[credential]
	helper = "!f() { test \"$1\" = get || return 0; cat >/dev/null; test -z \"$FAKE_NO_LOGIN\" || return 0; echo username=fake-user; echo password=${FAKE_PASSWORD:-fake-secret-1}; echo password_expiry_utc=1999999999; echo oauth_refresh_token=fake-refresh; echo capability[]=state; }; f"
HOSTGIT
# Anything that asks for a login marks itself here.
cat > "$work/askpass.sh" <<'ASK'
#!/bin/sh
echo asked >> "$ASKED_LOG"
exit 1
ASK
chmod +x "$work/askpass.sh"
export ASKED_LOG=$work/asked GIT_ASKPASS=$work/askpass.sh SSH_ASKPASS=$work/askpass.sh
rm -rf "$work/gws" "$work/nows" "$work/sshws" "$work/plainws"
mkdir -p "$work/nows" "$work/plainws"
for r in gws:https://git.example.com/org/repo.git nows: sshws:git@git.example.com:org/repo.git; do
    git init -q "$work/${r%%:*}"
    [ -z "${r#*:}" ] || git -C "$work/${r%%:*}" remote add origin "${r#*:}"
done
creds=shared/git/credentials
secrets() { case $out in *fake-secret*|*fake-user*|*fake-refresh*) return 0 ;; esac; return 1; }

rm -rf shared/git; WORKSPACE_DIR=$work/gws run claude
check "credentials: off by default, nothing is copied" "$([ ! -e $creds ]; echo $?)"
rm -rf shared/git; AGENTS_GIT_CREDENTIALS=host WORKSPACE_DIR=$work/gws run claude
check "credentials: host, the login is stored for the origin" "$([ "$(cat $creds)" = 'https://fake-user:fake-secret-1@git.example.com' ]; echo $?)"
check "credentials: nothing is printed" "$(! secrets; echo $?)"
check "credentials: the harness still launches" "$([ "$code" = 0 ] && grep -q "run --rm -T claude" "$STUB_LOG"; echo $?)"
FAKE_PASSWORD=fake-secret-2 AGENTS_GIT_CREDENTIALS=host WORKSPACE_DIR=$work/gws run claude
check "credentials: the next launch replaces the entry" "$([ "$(cat $creds)" = 'https://fake-user:fake-secret-2@git.example.com' ]; echo $?)"
printf 'https://other:fake-other@other.example.com\n' >> $creds
FAKE_PASSWORD=fake-secret-3 AGENTS_GIT_CREDENTIALS=host WORKSPACE_DIR=$work/gws run claude
check "credentials: other hosts' entries are kept" "$(grep -q 'fake-other@other.example.com' $creds && grep -q 'fake-secret-3@git.example.com' $creds && [ "$(wc -l < $creds)" -eq 2 ]; echo $?)"
rm -rf shared/git; echo 'AGENTS_GIT_CREDENTIALS=host' >> .env
WORKSPACE_DIR=$work/gws run claude
check "credentials: the setting is read from .env" "$([ -s $creds ]; echo $?)"
rm -rf shared/git; AGENTS_GIT_CREDENTIALS='' WORKSPACE_DIR=$work/gws run claude
check "credentials: an empty shell value does not beat .env (like compose)" "$([ -s $creds ]; echo $?)"
grep -v '^AGENTS_GIT_CREDENTIALS=' .env > .env.tmp; mv .env.tmp .env
for w in nows sshws plainws; do
    rm -rf shared/git; AGENTS_GIT_CREDENTIALS=host WORKSPACE_DIR=$work/$w run claude
    check "credentials: $w (no https origin) copies nothing" "$([ "$code" = 0 ] && [ ! -e $creds ]; echo $?)"
done
rm -rf shared/git; rm -f "$ASKED_LOG"; FAKE_NO_LOGIN=1 AGENTS_GIT_CREDENTIALS=host WORKSPACE_DIR=$work/gws run claude
check "credentials: no login on the host writes nothing" "$([ "$code" = 0 ] && [ ! -s $creds ]; echo $?)"
check "credentials: no login, no prompt and no askpass program" "$([ ! -e "$ASKED_LOG" ] && ! secrets; echo $?)"
unset ASKED_LOG GIT_ASKPASS SSH_ASKPASS GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL

# The container user takes the host uid (ADR 29): a derived image agent-workspace-<name>:uid-<uid>-<gid>, used by the run calls only.
rm -f agents/*/.build*.sha256
bargs='--build-arg HTTP_PROXY --build-arg HTTPS_PROXY --build-arg NO_PROXY --build-arg http_proxy --build-arg https_proxy --build-arg no_proxy'
lbl='image inspect -f {{index .Config.Labels "agent-workspace.uid-source"}}'
remapped() { grep -q '^build ' "$STUB_LOG" || grep -q ':uid' "$STUB_LOG.tag"; }
b=agent-workspace-base:uid-1001-1002; c=agent-workspace-claude:uid-1001-1002
STUB_UID=1001 STUB_GID=1002 run claude
check "linux host, uid 1001: base and harness are adapted before their runs" "$(is "compose build base|image inspect -f {{.Id}} agent-workspace-base|$lbl $b|build -t $b --label agent-workspace.uid-source=sha256:src $bargs -|volume inspect agent-workspace_cache|compose run --rm -T base claude|image inspect agent-workspace-base|compose build claude|image inspect -f {{.Id}} agent-workspace-claude|$lbl $c|build -t $c --label agent-workspace.uid-source=sha256:src $bargs -|compose run --rm -T claude"; echo $?)"
check "the tag reaches the run calls only, never compose build" "$([ "$(paste -sd'|' "$STUB_LOG.tag")" = 'build |run :uid-1001-1002|build |run :uid-1001-1002' ]; echo $?)"
check "the adapting line is printed" "$(case $out in *"Adapting base image to uid 1001..."*) true ;; *) false ;; esac; echo $?)"
check "no cache volume: nothing is chowned" "$(! grep -q 'chown' "$STUB_LOG"; echo $?)"
STUB_UID=1001 STUB_GID=1002 STUB_VOLUME=1 run claude
check "a rebuilt base also chowns the existing cache volume once" "$([ "$(grep -cF "run --rm -u 0 -v agent-workspace_cache:/c $b sh -c [ \"\$(stat -c %u:%g /c)\" = \"\$1\" ] || chown -R \"\$1\" /c sh 1001:1002" "$STUB_LOG")" = 1 ]; echo $?)"
STUB_UID=1001 STUB_GID=1002 STUB_VOLUME=1 STUB_LABEL=sha256:src run claude
check "a matching label skips the derived build and the volume chown" "$(! grep -q '^build \|chown' "$STUB_LOG" && [ "$(grep -c 'run :uid-1001-1002' "$STUB_LOG.tag")" = 2 ]; echo $?)"
STUB_UID=1001 STUB_GID=1002 STUB_LABEL=sha256:other run claude
check "a label of another source image rebuilds" "$(grep -q "^build -t $b" "$STUB_LOG"; echo $?)"
STUB_UID=1000 STUB_GID=1000 run claude
check "linux host, uid 1000: no remap, no extra docker calls" "$(is 'image inspect agent-workspace-base|compose run --rm -T base claude|image inspect agent-workspace-claude|compose run --rm -T claude' && ! grep -q ':uid' "$STUB_LOG.tag"; echo $?)"
STUB_UID=1000 AGENTS_UID=2000:2001 run claude
check "AGENTS_UID forces uid and gid" "$(grep -q 'build -t agent-workspace-base:uid-2000-2001' "$STUB_LOG"; echo $?)"
STUB_UID=1000 STUB_GID=1005 AGENTS_UID=2000 run claude
check "AGENTS_UID without a gid takes the host's gid on Linux" "$(grep -q 'build -t agent-workspace-base:uid-2000-1005' "$STUB_LOG"; echo $?)"
STUB_UID=1001 AGENTS_UID=1000 run claude
check "AGENTS_UID=1000 turns the remap off" "$(! remapped; echo $?)"
echo 'AGENTS_UID=3000:3000' >> .env
STUB_UID=1001 run claude
check "AGENTS_UID in .env is used" "$(grep -q 'build -t agent-workspace-base:uid-3000-3000' "$STUB_LOG"; echo $?)"
STUB_UID=1001 AGENTS_UID=4000:4000 run claude
check "a shell AGENTS_UID beats .env" "$(grep -q 'build -t agent-workspace-base:uid-4000-4000' "$STUB_LOG"; echo $?)"
grep -v '^AGENTS_UID=' .env > .env.tmp; mv .env.tmp .env
AGENTS_UID=abc run claude
check "a bad AGENTS_UID stops before docker" "$([ "$code" = 1 ] && [ -z "$calls" ]; echo $?)"
for u in Msys Darwin; do
    STUB_UNAME_S=$u STUB_UID=1001 run claude
    check "$u host: no remap without AGENTS_UID" "$(! remapped; echo $?)"
done
STUB_UNAME_S=MINGW64_NT-10.0 STUB_UID=1001 AGENTS_UID=2000 run claude
check "a non-Linux host with AGENTS_UID: the gid defaults to the uid" "$(grep -q 'build -t agent-workspace-base:uid-2000-2000' "$STUB_LOG"; echo $?)"
STUB_OSTYPE=windows STUB_WINPATH='C:\x' STUB_UID=1001 AGENTS_UID=2000 run claude
check "windows containers: never remapped" "$(! remapped; echo $?)"
STUB_UID=1001 STUB_SECOPTS='["name=seccomp,profile=builtin","name=rootless"]' run claude
check "rootless docker: one warning, no remap" "$(! remapped && [ "$(printf '%s\n' "$out" | grep -c rootless)" = 1 ] && [ "$code" = 0 ]; echo $?)"
STUB_UID=0 STUB_GID=0 run claude
check "uid 0: one warning, no remap" "$(! remapped && [ "$(printf '%s\n' "$out" | grep -c 'host user is root')" = 1 ] && [ "$code" = 0 ]; echo $?)"
rm -f agents/*/.build*.sha256

mv .env .env.edited
run --help
check "fresh checkout: creates .env and refuses, even for --help" "$([ "$code" = 1 ] && [ -z "$calls" ] && [ -f .env ] && case $out in *"Edit .env first"*) true ;; *) false ;; esac; echo $?)"
mv .env.edited .env
grep -v '^AGENTS_LOCAL_BUILD=' .env > .env.tmp; mv .env.tmp .env
run claude
check "a key missing from .env warns" "$(case $out in *"Warning: AGENTS_LOCAL_BUILD is missing"*) true ;; *) false ;; esac; echo $?)"
exit $fail
