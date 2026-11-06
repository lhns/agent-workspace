#!/bin/bash
# Startup smoke test, run inside the harness container (see .github/workflows/ci.yml):
#   ./run-agent.sh --harness <h> --exec bash -c "$(cat tests/smoke.sh)" smoke <h> [expected-workspace-path]
# No API keys are available, so a login/onboarding screen counts as started.
# A Windows container has no script(1) and no Docker: there the CI job starts the TUI with
# `docker run -dt` (a pseudo-console) instead, and that part is skipped here.
set -u
h=${1:?usage: smoke.sh <harness> [expected-workspace-path]}
expected_pwd=${2:-}
windows=; [ "$(uname -o 2>/dev/null)" != Msys ] || windows=1
# Paths compared in one form: a Windows program reports C:\..., the shell has /c/...
norm() { if command -v cygpath >/dev/null; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }

case $h in
    claude)   bin=claude;   state=$HOME/.claude;           noupdate=DISABLE_AUTOUPDATER ;;
    opencode) bin=opencode; state=$HOME/.config/opencode;  noupdate=OPENCODE_DISABLE_AUTOUPDATE ;;
    pi)       bin=pi;       state=$HOME/.pi/agent;         noupdate=PI_SKIP_VERSION_CHECK ;;
    cline)    bin=cline;    state=$HOME/.cline;            noupdate=CLINE_NO_AUTO_UPDATE ;;
    hermes)   bin=hermes;   state=$HOME/.hermes;           noupdate= ;;  # set in config.yaml by the entrypoint
    *) echo "unknown harness $h" >&2; exit 2 ;;
esac
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

# The workspace is mounted at its host path, which is also the working directory.
if [ -n "$expected_pwd" ]; then
    echo "== $h: working directory is $expected_pwd"
    [ "$PWD" = "$expected_pwd" ] || bad "working directory is $PWD, expected $expected_pwd"
fi

echo "== $h: self-update disabled"
if [ -n "$noupdate" ]; then
    [ "${!noupdate:-}" = 1 ] || bad "$noupdate is not set to 1"
else
    grep -A3 '^updates:' "$state/config.yaml" 2>/dev/null | grep -qi 'check: false' || bad "updates.check is not false in $state/config.yaml"
fi

echo "== $h: --version"
"$bin" --version || bad "$bin --version exited $?"

if [ -z "$windows" ]; then
    echo "== $h: docker and compose are installed"
    docker --version || bad "docker --version exited $?"
    docker compose version || bad "docker compose version exited $?"
fi

echo "== $h: state dir $state writable"
if touch "$state/.smoke" 2>/dev/null; then rm -f "$state/.smoke"; else bad "$state not writable"; fi

echo "== $h: cache volume ~/.cache"
if touch "$HOME/.cache/.smoke" 2>/dev/null; then rm -f "$HOME/.cache/.smoke"; else bad "$HOME/.cache not writable"; fi
[ "$(norm "$(npm config get cache)")" = "$(norm "$HOME/.cache/npm")" ] || bad "npm cache is $(npm config get cache), expected $HOME/.cache/npm"
case :$PATH: in *:"$HOME/.cache/bin":*) ;; *) bad "$HOME/.cache/bin is not on PATH" ;; esac

# The TUI must still be running when the timeout hits (exit 124), without crash output.
echo "== $h: TUI stays up"
if ! command -v script >/dev/null; then
    echo "skipped: no script(1) here"
    exit $fail
fi
out=$(mktemp)
sleep 30 | timeout 25 script -qec "$bin" /dev/null > "$out" 2>&1
rc=$?
if [ "$rc" -ne 124 ]; then bad "TUI exited early with $rc"; fi
if grep -aEi 'traceback|panic|uncaught|unhandled|segmentation|cannot find module|SyntaxError' "$out"; then
    bad "crash output from TUI"
fi
if [ ! -s "$out" ]; then bad "TUI printed nothing"; fi
exit $fail
