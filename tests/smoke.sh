#!/bin/bash
# Startup smoke test, run inside the harness container (see .github/workflows/ci.yml):
#   ./run-agent.sh --harness <h> --exec bash -c "$(cat tests/smoke.sh)" smoke <h> [expected-workspace-path]
# No API keys are available, so a login/onboarding screen counts as started.
set -u
h=${1:?usage: smoke.sh <harness> [expected-workspace-path]}
expected_pwd=${2:-}

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

echo "== $h: state dir $state writable"
if touch "$state/.smoke" 2>/dev/null; then rm -f "$state/.smoke"; else bad "$state not writable"; fi

# The TUI must still be running when the timeout hits (exit 124), without crash output.
echo "== $h: TUI stays up"
out=$(mktemp)
sleep 30 | timeout 25 script -qec "$bin" /dev/null > "$out" 2>&1
rc=$?
if [ "$rc" -ne 124 ]; then bad "TUI exited early with $rc"; fi
if grep -aEi 'traceback|panic|uncaught|unhandled|segmentation|cannot find module|SyntaxError' "$out"; then
    bad "crash output from TUI"
fi
if [ ! -s "$out" ]; then bad "TUI printed nothing"; fi
exit $fail
