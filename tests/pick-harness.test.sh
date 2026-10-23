#!/bin/bash
# Tests agents/pick-harness.sh in the base container (see .github/workflows/ci.yml):
#   docker compose run --rm -T base bash -c "$(cat tests/pick-harness.test.sh)" pick-test
# The state file is a scratch one; the choice is read back from it, as the launchers do.
set -u
pick=${PICK:-/opt/agents/pick-harness.sh}
export AGENTS_STATE=/tmp/aw-pick-state
fail=0
check() { # name, actual, expected
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', expected '$3'" >&2; fail=1; fi
}
recorded() { # key: the harness recorded for it
    K=$1 awk -F'\t' '$1 == ENVIRON["K"] { print $2; exit }' "$AGENTS_STATE"
}
# Without a terminal, for a workspace key.
plain() { AGENTS_WORKSPACE_TARGET=$1 bash "$pick" </dev/null 2>&1; }
# With a terminal and scripted keys (printf format); the exit code is the picker's.
pty() { # keys, key, keys sent a second later
    # shellcheck disable=SC2059 # keys are printf escapes
    { sleep 1; printf "$1"; sleep 1; printf "${3:-}"; sleep 1; } | AGENTS_WORKSPACE_TARGET=$2 timeout 20 script -qec "bash $pick" /dev/null 2>&1
    return "${PIPESTATUS[1]}"
}
DOWN='\033[B' ENTER='\n'

rm -f "$AGENTS_STATE"
out=$(plain /a); rc=$?
check "no history, no terminal: exit code" "$rc" 2
check "no history, no terminal: nothing recorded" "$(test -e "$AGENTS_STATE" && echo yes || echo no)" no

printf '/a\tpi\n/b\tclaude\n*\tclaude\n' > "$AGENTS_STATE"
plain /a >/dev/null; check "no terminal: folder A gets its own harness" "$(recorded /a)" pi
plain /b >/dev/null; check "no terminal: folder B gets its own harness" "$(recorded /b)" claude
check "no terminal: a pick is remembered for anywhere too" "$(recorded '*')" claude
plain /c >/dev/null; check "no terminal: a new folder gets the last used anywhere" "$(recorded /c)" claude
printf '/a\tgone\n*\tnope\n' > "$AGENTS_STATE"
plain /a >/dev/null; rc=$?
check "no terminal: a recorded harness that no longer exists exits 2" "$rc" 2

# Menu: the last used one is first and marked; the rest follow in harness-dirs order.
printf '/a\tpi\n*\tpi\n' > "$AGENTS_STATE"
out=$(pty "$ENTER" /a); rc=$?
check "menu: Enter picks the last used" "$(recorded /a)" pi
check "menu: Enter exits 0" "$rc" 0
case $out in *"pi (last used)"*) echo "ok   menu: shows (last used)" ;; *) echo "FAIL menu: no '(last used)' in: $out" >&2; fail=1 ;; esac
case ${out%%claude*} in *"pi (last used)"*) echo "ok   menu: last used is listed before claude" ;; *) echo "FAIL menu: order in: $out" >&2; fail=1 ;; esac
case $out in *"Select the agent harness to run in"*"Up/Down to move"*) echo "ok   menu: title and key hint" ;; *) echo "FAIL menu: no title or hint in: $out" >&2; fail=1 ;; esac
pty "$DOWN$ENTER" /a >/dev/null; check "menu: Down+Enter picks the next one, claude" "$(recorded /a)" claude
check "menu: the choice is remembered for anywhere" "$(recorded '*')" claude
printf '*\tpi\n' > "$AGENTS_STATE"
pty "$ENTER" /new >/dev/null; check "menu: a new folder starts on the last used anywhere" "$(recorded /new)" pi
rm -f "$AGENTS_STATE"
pty "$ENTER" /a >/dev/null; check "menu: no history, Enter picks the first of harness-dirs" "$(recorded /a)" claude

printf '/a\tpi\n*\tpi\n' > "$AGENTS_STATE"
pty "$DOWN" /a '\003' >/dev/null; rc=$?
check "menu: Ctrl-C exits 130" "$rc" 130
check "menu: Ctrl-C records nothing" "$(recorded /a)" pi
exit $fail
