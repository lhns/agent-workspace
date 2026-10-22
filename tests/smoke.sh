#!/bin/bash
# Startup smoke test, run inside the harness container (see .github/workflows/ci.yml):
#   ./run-<h>.sh bash -c "$(cat tests/smoke.sh)" smoke <h>
# No API keys are available, so a login/onboarding screen counts as started.
set -u
h=${1:?usage: smoke.sh <harness>}

case $h in
    claude)   bin=claude;   state=$HOME/.claude ;;
    opencode) bin=opencode; state=$HOME/.config/opencode ;;
    pi)       bin=pi;       state=$HOME/.pi/agent ;;
    cline)    bin=cline;    state=$HOME/.cline ;;
    hermes)   bin=hermes;   state=$HOME/.hermes ;;
    *) echo "unknown harness $h" >&2; exit 2 ;;
esac
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }

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
