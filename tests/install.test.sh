#!/bin/bash
# Tests install.sh and uninstall.sh with a temp HOME and a stub launcher; nothing outside the temp
# dir is touched. The prompt is driven through `script` (util-linux), skipped when it is missing.
#   bash tests/install.test.sh
# shellcheck disable=SC2319 # check's second argument is the exit code of the condition just before it
set -u
src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export HOME=$work/home
mkdir -p "$HOME"
shim=$HOME/.local/bin/agent-workspace
fail=0
check() { # name, ok (0 = pass)
    if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1 (code=$code out='$out')" >&2; fail=1; fi
}
has() { case $out in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# A copy of the repo's install files that points at a stub launcher; the name has a space and a quote.
mkrepo() { # dir
    mkdir -p "$1"
    cp "$src/install.sh" "$src/uninstall.sh" "$1/"
    # shellcheck disable=SC2016 # the stub expands its own variables
    printf '#!/bin/sh\necho "WS=$WORKSPACE_DIR"\nfor a in "$@"; do echo "arg=$a"; done\n' >"$1/run-agent.sh"
    chmod +x "$1"/*.sh
}
repo=$work/re\ po\'s
mkrepo "$repo"
run() { out=$("$@" </dev/null 2>&1); code=$?; }

run "$repo/uninstall.sh"
check "uninstall with nothing installed: not installed, exit 0" "$({ [ "$code" = 0 ] && has "not installed"; } && echo 0 || echo 1)"

PATH=/usr/bin:/bin run "$repo/install.sh"
check "install: shim written and executable" "$([ "$code" = 0 ] && [ -x "$shim" ]; echo $?)"
check "install: warns when ~/.local/bin is not on PATH" "$(has "not on your PATH" && echo 0 || echo 1)"
PATH=$HOME/.local/bin:$PATH run "$repo/install.sh" --update
check "update: no warning when it is on PATH" "$({ [ "$code" = 0 ] && ! has "not on your PATH"; } && echo 0 || echo 1)"

mkdir -p "$work/my proj"
out=$(cd "$work/my proj" && "$shim" claude --model 'a b' 2>&1); code=$?
check "the shim runs the launcher with the current folder as the workspace" "$([ "$code" = 0 ] && [ "$(sed -n 1p <<<"$out")" = "WS=$(cd "$work/my proj" && pwd)" ] && [ "$(sed -n '2,$p' <<<"$out" | paste -sd'|')" = 'arg=claude|arg=--model|arg=a b' ]; echo $?)"

run "$repo/install.sh"
check "install again without a terminal: updates, no prompt" "$({ [ "$code" = 0 ] && has "Installed" && ! has "already installed"; } && echo 0 || echo 1)"

# The repo moved: installing from the new place re-points the shim.
repo2=$work/moved
mkrepo "$repo2"
run "$repo2/install.sh"
out=$("$shim" 2>&1); code=$?
check "install from another folder re-points the shim" "$([ "$code" = 0 ] && [ -x "$repo2/run-agent.sh" ] && grep -qF "$repo2/run-agent.sh" "$shim"; echo $?)"

# The prompt, with a terminal: Enter updates, r removes, c cancels.
if command -v script >/dev/null 2>&1; then
    ask() { # keys
        out=$(printf '%s' "$1" | timeout 20 script -qec "$(printf '%q' "$repo/install.sh")" /dev/null 2>&1); code=$?
    }
    ask $'\n'
    check "prompt: Enter updates and shows where it points" "$({ has "already installed (-> $repo2)" && has "Installed $shim -> $repo"; } && echo 0 || echo 1)"
    ask $'c\n'
    check "prompt: c does nothing" "$({ has "Nothing changed" && [ -e "$shim" ]; } && echo 0 || echo 1)"
    ask $'r\n'
    check "prompt: r removes" "$({ has "Removed" && [ ! -e "$shim" ]; } && echo 0 || echo 1)"
else
    echo "skip the prompt tests: script is not installed"
fi

run "$repo/install.sh"
run "$repo/uninstall.sh"
check "uninstall removes the shim" "$({ [ "$code" = 0 ] && has "Removed" && [ ! -e "$shim" ]; } && echo 0 || echo 1)"
run "$repo/uninstall.sh"
check "uninstall again: not installed, exit 0" "$({ [ "$code" = 0 ] && has "not installed"; } && echo 0 || echo 1)"
run "$repo/install.sh" --bogus
check "an unknown option is an error" "$([ "$code" = 1 ]; echo $?)"
exit $fail
