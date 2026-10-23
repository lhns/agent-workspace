#!/bin/bash
# Tests the option parsing of agents/run.sh against a stub `docker` on PATH that logs its arguments.
# Runs on a temp copy of the repo with a scratch .env, so it leaves no state behind.
#   bash tests/run-sh.test.sh
set -u
src=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -C "$src" --exclude=.git --exclude=.env --exclude=shared --exclude='.build.sha256' -cf - . | tar -C "$work" -xf -
cd "$work" || exit 1
{ cat .env.example; echo '# edited'; } > .env
mkdir -p stub
cat > stub/docker <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
if [ "${1:-}" = compose ] && [ "${2:-}" = run ]; then
    echo "[$AGENTS_NONINTERACTIVE]" >> "$STUB_LOG.ni"
    case " $* " in *" base "*) [ -z "${STUB_PICK:-}" ] || printf '%s\t%s\n*\t%s\n' "$AGENTS_WORKSPACE_TARGET" "$STUB_PICK" "$STUB_PICK" > shared/.last-harness ;; esac
fi
exit 0
STUB
chmod +x stub/docker
export PATH=$work/stub:$PATH STUB_LOG=$work/docker.log AGENTS_LOCAL_BUILD=1
unset AGENTS_HARNESS AGENTS_NONINTERACTIVE AGENTS_AUTORESUME WORKSPACE_DIR STUB_PICK

fail=0
S='bash /usr/local/lib/agents-start.sh'
# run <args...>: sets `out` (stdout+stderr), `code`, `last` (the last compose run) and `ni`.
run() {
    rm -f "$STUB_LOG" "$STUB_LOG.ni"
    out=$(bash agents/run.sh "$@" </dev/null 2>&1); code=$?
    last=$(grep '^compose run' "$STUB_LOG" 2>/dev/null | tail -n1)
    ni=$(tail -n1 "$STUB_LOG.ni" 2>/dev/null)
}
check() { # name, ok (0 = pass)
    if [ "$2" = 0 ]; then echo "ok   $1"; else echo "FAIL $1 (code=$code last='$last' out='$out')" >&2; fail=1; fi
}
is() { [ "$last" = "$1" ]; }

run claude;                               check "harness: runs start.sh" "$(is "compose run --rm -T claude $S claude"; echo $?)"
run --continue claude --model x /tmp/y;   check "--continue, args after the harness" "$(is "compose run --rm -T -e AGENTS_AUTORESUME=yes claude $S claude --model x /tmp/y"; echo $?)"
run --new --harness pi;                   check "--new --harness" "$(is "compose run --rm -T -e AGENTS_AUTORESUME=no pi $S pi"; echo $?)"
run --ask claude;                         check "--ask" "$(is "compose run --rm -T -e AGENTS_AUTORESUME=ask claude $S claude"; echo $?)"
run claude -- --model x;                  check "-- right after the harness is swallowed" "$(is "compose run --rm -T claude $S claude --model x"; echo $?)"
run --harness claude -- --model x;        check "--harness with -- forwards the args" "$(is "compose run --rm -T claude $S claude --model x"; echo $?)"
run --harness claude --exec bash -c 'echo "a b"'
check "--exec runs the command in the container" "$(is 'compose run --rm -T claude bash -c echo "a b"'; echo $?)"
run --harness claude --model x;           check "unknown option after --harness" "$([ "$code" = 1 ] && [ -z "$last" ] && case $out in *"Unknown option --model"*) echo 0 ;; *) echo 1 ;; esac)"
run --foo claude;                         check "unknown option suggests --" "$([ "$code" = 1 ] && case $out in *"put -- before"*) echo 0 ;; *) echo 1 ;; esac)"
run bash -c x;                            check "unknown harness" "$([ "$code" = 1 ] && case $out in *"Unknown harness 'bash'"*) echo 0 ;; *) echo 1 ;; esac)"
run --harness nope;                       check "--harness with an unknown name" "$([ "$code" = 1 ] && [ -z "$last" ] && echo 0 || echo 1)"
run --sessions claude;                    check "--sessions without a terminal" "$([ "$code" = 1 ] && case $out in *"needs a terminal"*) echo 0 ;; *) echo 1 ;; esac)"
run -y claude;                            check "-y sets AGENTS_NONINTERACTIVE" "$([ "$ni" = '[1]' ] && echo 0 || echo 1)"
AGENTS_NONINTERACTIVE=1 run claude;       check "AGENTS_NONINTERACTIVE in the shell" "$([ "$ni" = '[1]' ] && echo 0 || echo 1)"
run claude;                               check "AGENTS_NONINTERACTIVE unset by default" "$([ "$ni" = '[]' ] && echo 0 || echo 1)"
AGENTS_HARNESS=pi run --continue;         check "AGENTS_HARNESS picks the harness, no menu" "$(is "compose run --rm -T -e AGENTS_AUTORESUME=yes pi $S pi"; echo $?)"
AGENTS_HARNESS=pi run claude;             check "a positional harness beats AGENTS_HARNESS" "$(is "compose run --rm -T claude $S claude"; echo $?)"
run -h;                                   check "-h prints the usage" "$([ "$code" = 0 ] && [ -z "$last" ] && case $out in *"Usage: run-agent"*) echo 0 ;; *) echo 1 ;; esac)"
STUB_PICK=pi run -- --model x;            check "-- without a harness: the menu picks, args go to it" "$(is "compose run --rm -T pi $S pi --model x"; echo $?)"
exit $fail
