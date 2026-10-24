#!/bin/bash
# Tests agents/run.sh (the host side) against a stub `docker` on PATH that logs its arguments and,
# for the base service, plays the core (agents/launch.sh): it writes the hand-off files from
# STUB_HARNESS (default claude), STUB_TARGET, or exits with STUB_CORE_CODE / writes nothing for
# STUB_NO_HARNESS=1. The core's own logic is tested by tests/launch.test.sh.
# Runs on a temp copy of the repo with a scratch .env, so it leaves no state behind.
#   bash tests/run-sh.test.sh
# shellcheck disable=SC2319 # check's second argument is the exit code of the condition just before it
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
    echo "$AGENTS_WORKSPACE_TARGET" >> "$STUB_LOG.target"
    echo "$AGENTS_RUN_ID" >> "$STUB_LOG.id"
    shift 2
    while [ $# -gt 0 ] && [ "$1" != base ]; do shift; done
    if [ "${1:-}" = base ]; then
        shift
        d=shared/.launch/$AGENTS_RUN_ID
        { [ -d "$d" ] && echo dir || echo nodir; } >> "$STUB_LOG.dir"
        printf '[%s]' "$@" > "$STUB_LOG.base"
        [ -z "${STUB_SLEEP:-}" ] || sleep "$STUB_SLEEP"
        [ -z "${STUB_CORE_CODE:-}" ] || exit "$STUB_CORE_CODE"
        [ -z "${STUB_NO_HARNESS:-}" ] || exit 0
        printf '%s\n' "${STUB_TARGET:-$AGENTS_WORKSPACE_TARGET}" > "$d/target"
        printf '%s\n' "${STUB_HARNESS:-claude}" > "$d/harness"
    fi
fi
exit 0
STUB
chmod +x stub/docker
export PATH=$work/stub:$PATH STUB_LOG=$work/docker.log AGENTS_LOCAL_BUILD=1
unset AGENTS_HARNESS AGENTS_NONINTERACTIVE AGENTS_AUTORESUME WORKSPACE_DIR STUB_HARNESS STUB_TARGET STUB_CORE_CODE STUB_NO_HARNESS STUB_SLEEP

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

# SIGTERM (what Ctrl-C leaves to the shell): the launch dir goes, the code is 130.
rm -f "$STUB_LOG" "$STUB_LOG".*
STUB_SLEEP=2 bash agents/run.sh claude </dev/null >/dev/null 2>&1 &
pid=$!
for _ in $(seq 1 50); do [ -e "$STUB_LOG.dir" ] && break; sleep 0.1; done
kill -TERM "$pid"; wait "$pid"; code=$?
out=; calls=
check "SIGTERM: exit 130 and the launch dir removed" "$([ "$code" = 130 ] && [ -z "$(ls -A shared/.launch)" ]; echo $?)"

# Host-side checks, before any docker call.
WORKSPACE_DIR=$work/does-not-exist run claude
check "missing WORKSPACE_DIR stops before docker" "$([ "$code" = 1 ] && [ -z "$calls" ]; echo $?)"
mkdir -p "$work/my proj"
WORKSPACE_DIR="$work/my proj" run claude
check "WORKSPACE_DIR is the target the core gets" "$([ "$(head -n1 "$STUB_LOG.target")" = "$(cd "$work/my proj" && pwd -P)" ]; echo $?)"
mv .env .env.edited
run --help
check "fresh checkout: creates .env and refuses, even for --help" "$([ "$code" = 1 ] && [ -z "$calls" ] && [ -f .env ] && case $out in *"Edit .env first"*) true ;; *) false ;; esac; echo $?)"
mv .env.edited .env
grep -v '^AGENTS_LOCAL_BUILD=' .env > .env.tmp; mv .env.tmp .env
run claude
check "a key missing from .env warns" "$(case $out in *"Warning: AGENTS_LOCAL_BUILD is missing"*) true ;; *) false ;; esac; echo $?)"
exit $fail
