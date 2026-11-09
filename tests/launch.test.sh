#!/bin/bash
# Tests agents/launch.sh in the base container (see .github/workflows/ci.yml):
#   docker compose run --rm -T --entrypoint bash base -c "$(cat tests/launch.test.sh)" launch-test
# The state and the launch dir are scratch ones; the result is read back from the files it writes,
# as the host launchers do. It runs in a Windows container too: there the workspace paths are
# Windows ones, and the menu tests, which need script(1), are skipped. The Windows rules are also
# played on Linux with AGENTS_PLATFORM=windows.
set -u
core=${AGENTS_DIR:-/opt/agent-workspace}/agents/launch.sh
# shellcheck source=agents/os.sh
. "$(dirname "$core")/os.sh"
# Workspace paths the tests use.
A=/a B=/b C=/c NEW=/new
if is_windows; then A='C:\a' B='C:\b' C='C:\c' NEW='C:\new'; fi
# The menu tests drive a terminal through script(1), which a Windows container lacks.
have_script=; ! command -v script >/dev/null || have_script=1
export AGENTS_SHARED=/tmp/aw-launch-shared AGENTS_RUN_ID=t1
state=$AGENTS_SHARED/.last-harness
launch=$AGENTS_SHARED/.launch/$AGENTS_RUN_ID
unset AGENTS_HARNESS AGENTS_NONINTERACTIVE
fail=0
check() { # name, actual, expected
    if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', expected '$3'" >&2; fail=1; fi
}
has() { # name, text, expected substring ("no" as 4th argument: expected absent)
    if [ "${4:-}" = no ]; then
        case $2 in *"$3"*) echo "FAIL $1: unexpected '$3' in: $2" >&2; fail=1 ;; *) echo "ok   $1" ;; esac
    else
        case $2 in *"$3"*) echo "ok   $1" ;; *) echo "FAIL $1: expected '$3' in: $2" >&2; fail=1 ;; esac
    fi
}
fresh() { rm -rf "$launch"; mkdir -p "$launch"; }
# The harness the state records for a key.
recorded() { K=$1 awk -F'\t' '$1 == ENVIRON["K"] { print $2; exit }' "$state"; }
# The hand-off: one file's content, whether it exists, and the NUL-separated arguments one per line, ">" before each.
field() { cat "$launch/$1" 2>/dev/null; }
exists() { [ -e "$launch/$1" ] && echo yes || echo no; }
argv() { local a; while IFS= read -r -d '' a; do printf '>%s\n' "$a"; done <"$launch/args"; }
# Without a terminal: sets `out`, `code`.
run() {
    fresh
    out=$(AGENTS_WORKSPACE_TARGET=${WS:-$A} bash "$core" "$@" </dev/null 2>&1); code=$?
    settle
}
# What the host launcher does once the harness image is ready: moves the new state into place.
settle() { if [ -f "$launch/last-harness" ]; then mv -f "$launch/last-harness" "$state"; fi; }
# With a terminal and scripted keys (printf format); sets `out`, `code`. Args: keys, then launcher args.
pty() {
    local keys=$1 key2=$2
    shift 2
    fresh
    # shellcheck disable=SC2059 # keys are printf escapes
    out=$({ sleep 1; printf "$keys"; sleep 1; printf "$key2"; sleep 1; } | AGENTS_WORKSPACE_TARGET=${WS:-$A} timeout 20 script -qec "bash $core $*" /dev/null 2>&1)
    code=$?
    settle
}
DOWN='\033[B' ENTER='\n'

rm -rf "$AGENTS_SHARED"; mkdir -p "$AGENTS_SHARED"

# Option grammar.
run claude
check "harness: the hand-off names it" "$(field harness)" claude
check "harness: exit code" "$code" 0
check "harness: no arguments" "$(argv)" ""
check "harness: no resume mode, so AGENTS_AUTORESUME applies" "$(exists mode)" no
check "harness: not an exec" "$(exists exec)" no
check "harness: the target" "$(field target)" "$A"
check "harness: result marker" "$(field result)" launch
run --continue claude --model x /tmp/y
check "--continue, args after the harness: mode" "$(field mode)" yes
check "--continue, args after the harness: args" "$(argv)" $'>--model\n>x\n>/tmp/y'
run --new --harness pi;                check "--new --harness: mode" "$(field mode)-$(field harness)" no-pi
run --ask claude;                      check "--ask: mode" "$(field mode)" ask
run claude -- --model x;               check "-- right after the harness is swallowed" "$(argv)" $'>--model\n>x'
run --harness claude -- --model x;     check "--harness with -- forwards the args" "$(field harness)$(argv)" $'claude>--model\n>x'
run --harness claude --exec bash -c 'echo "a b"'
check "--exec: marked" "$(exists exec)" yes
check "--exec: the command is the args" "$(argv)" $'>bash\n>-c\n>echo "a b"'
check "--exec: the harness" "$(field harness)" claude
run --harness claude --model x
check "unknown option after --harness: error" "$code-$(exists harness)" 1-no
has "unknown option after --harness: message" "$out" "Unknown option --model"
run --foo claude;                      has "unknown option suggests --" "$out" "put -- before"; check "unknown option: exit code" "$code" 1
run bash -c x;                         has "unknown harness" "$out" "Unknown harness 'bash'"; check "unknown harness: nothing handed off" "$(exists harness)" no
run --harness nope;                    has "--harness with an unknown name" "$out" "Unknown harness 'nope'"
run --harness;                         check "--harness without a name: exit code" "$code" 1
run --exec;                            has "--exec without a command" "$out" "--exec needs a command"
run -h
has "-h prints the usage" "$out" "Usage: run-agent"; check "-h: nothing to launch" "$code-$(exists harness)-$(field result)" 0-no-done
run --help;                            check "--help: nothing to launch" "$code-$(exists harness)" 0-no

# --workdir is applied by the host; the core accepts it only first, and skips it.
run --workdir /some/dir --continue claude --model x
check "--workdir first: skipped, the rest parses" "$code-$(field harness)-$(field mode)-$(argv)" $'0-claude-yes->--model\n>x'
run --workdir /some/dir claude;        check "--workdir then the harness: accepted" "$code-$(field harness)" 0-claude
run --workdir;                       has "--workdir without a value" "$out" "--workdir needs a folder"; check "--workdir without a value: exit code" "$code-$(exists harness)" 1-no
run --continue --workdir /d claude;    has "--workdir after another option" "$out" "--workdir must come first"; check "--workdir after another option: nothing handed off" "$code-$(exists harness)" 1-no
run --harness claude --workdir /d;     has "--workdir after --harness" "$out" "--workdir must come first"
run claude --workdir /d;               check "--workdir after the harness is a harness argument" "$(argv)" $'>--workdir\n>/d'
run claude -- --workdir /d;            check "--workdir after -- is a harness argument" "$(argv)" $'>--workdir\n>/d'
run --workdir /d --workdir /e claude;  has "a second --workdir" "$out" "--workdir must come first"

# A launch dir that can't be written is an error, not "nothing to launch" (permissions mean
# nothing to the admin account of a Windows container, so only there it is skipped).
if ! is_windows; then
    fresh; chmod 555 "$launch"
    out=$(AGENTS_WORKSPACE_TARGET=$A bash "$core" claude </dev/null 2>&1); code=$?
    chmod 755 "$launch"
    check "unwritable launch dir: exit code" "$code" 1
    has "unwritable launch dir: message" "$out" "Cannot write to"
    check "unwritable launch dir: no result marker" "$(exists result)" no
fi
fresh
printf '/zz\tpi\n' >"$state"
out=$(AGENTS_WORKSPACE_TARGET=$A bash "$core" claude </dev/null 2>&1)
check "the state file itself is left alone" "$(cat "$state")" "$(printf '/zz\tpi')"
check "the new state is only in the launch dir until the host moves it" "$(exists last-harness)" yes

# Arguments survive the NUL-separated file: spaces, quotes, !, empty, a newline, a leading dash.
run claude 'a b' "it's" '"q"' 'x!y' '' $'line1\nline2' -- '-z' '*'
check "args round-trip" "$(argv)" $'>a b\n>it\'s\n>"q"\n>x!y\n>\n>line1\nline2\n>--\n>-z\n>*'
run claude
check "no args: empty file" "$([ -s "$launch/args" ] && echo nonempty || echo empty)" empty

# -y and AGENTS_NONINTERACTIVE; AGENTS_HARNESS; precedence.
run -y claude;                         check "-y: marked" "$(exists noninteractive)" yes
run --non-interactive claude;          check "--non-interactive: marked" "$(exists noninteractive)" yes
run claude;                            check "not non-interactive by default" "$(exists noninteractive)" no
AGENTS_NONINTERACTIVE=1 run claude;    check "AGENTS_NONINTERACTIVE: marked" "$(exists noninteractive)" yes
AGENTS_HARNESS=pi run --continue;      check "AGENTS_HARNESS picks the harness, no menu" "$(field harness)-$(field mode)" pi-yes
AGENTS_HARNESS=pi run claude;          check "a positional harness beats AGENTS_HARNESS" "$(field harness)" claude
AGENTS_HARNESS=pi run --harness opencode; check "--harness beats AGENTS_HARNESS" "$(field harness)" opencode
AGENTS_HARNESS=nope run;               has "AGENTS_HARNESS with an unknown name" "$out" "Unknown harness 'nope'"; check "AGENTS_HARNESS unknown: nothing handed off" "$(exists harness)" no
AGENTS_HARNESS=pi run -- --model x;    check "AGENTS_HARNESS with --: args go to it" "$(field harness)$(argv)" $'pi>--model\n>x'

# --sessions.
run --sessions claude;                 has "--sessions without a terminal" "$out" "--sessions needs a terminal"; check "--sessions without a terminal: exit code" "$code" 1
run -y --sessions claude;              has "--sessions with -y" "$out" "can't be combined with -y"
if [ -n "$have_script" ]; then
    pty "" "" --sessions opencode;     has "--sessions for opencode" "$out" "opencode has no session picker"; check "--sessions for opencode: nothing handed off" "$(exists harness)" no
    pty "" "" --sessions claude;       check "--sessions with a terminal: mode" "$(field mode)-$(field harness)" pick-claude
else
    echo "skipped: --sessions with a terminal (no script(1))"
fi

# The guard list: a workspace that would hide a container directory falls back to /workspace.
if ! is_windows; then
    WS=/home/agent/proj run claude
    check "guard: hidden directory falls back" "$(field target)" /workspace
    has "guard: says so" "$out" "would hide a container directory"
    check "guard: the fallback is what is recorded" "$(recorded /workspace)" claude
    WS=/home/agent run claude;         check "guard: the home directory" "$(field target)" /workspace
    WS=/c/Users/me/proj run claude;    check "guard: a mirrored Windows path stays" "$(field target)" /c/Users/me/proj
    WS=/opt run claude;                check "guard: /opt" "$(field target)" /workspace
    WS=/workspace run claude;          check "guard: /workspace stays" "$(field target)" /workspace
    WS=$A run claude;                  has "guard: no note for a normal path" "$out" "would hide" no
fi

# Windows containers: the target stays a Windows path (also when the container's environment turned
# it into /c/...), guarded case-insensitively; only C: can be mounted at its own path. Played on
# every OS through AGENTS_PLATFORM.
win() { AGENTS_PLATFORM=windows run "$@"; }
win_target() { # path, expected target, expected: kept | fallback
    WS=$1 win claude
    check "windows guard: $1" "$(field target)" "$2"
    if [ "$3" = fallback ]; then has "windows guard: $1 says so" "$out" "mounting the workspace at C:\\workspace"
    else has "windows guard: $1 has no note" "$out" "would hide" no; fi
}
win_target 'C:\Users\me\proj' 'C:\Users\me\proj' kept
win_target 'c:\Users\me\proj' 'C:\Users\me\proj' kept
win_target '/c/Users/me/proj' 'C:\Users\me\proj' kept
win_target 'C:/Users/me/proj' 'C:\Users\me\proj' kept
win_target 'C:\code\my proj (x86)' 'C:\code\my proj (x86)' kept
win_target 'C:\github\proj' 'C:\github\proj' kept
win_target 'C:\Windowsy' 'C:\Windowsy' kept
win_target 'C:\Users\me' 'C:\Users\me' kept
win_target 'D:\proj' 'C:\workspace' fallback
win_target "C:\\" 'C:\workspace' fallback
win_target 'C:\Windows' 'C:\workspace' fallback
win_target 'c:\windows\system32' 'C:\workspace' fallback
win_target 'C:\Program Files (x86)\a' 'C:\workspace' fallback
win_target 'C:\ProgramData' 'C:\workspace' fallback
win_target 'C:\git\usr' 'C:\workspace' fallback
win_target 'C:\Users' 'C:\workspace' fallback
win_target 'C:\Users\ContainerAdministrator' 'C:\workspace' fallback
win_target 'C:\Users\ContainerAdministrator\proj' 'C:\workspace' fallback
win_target 'C:\npm-global\lib' 'C:\workspace' fallback
win_target 'C:\node' 'C:\workspace' fallback
win_target 'C:\python' 'C:\workspace' fallback
win_target 'C:\tools' 'C:\workspace' fallback
if is_windows; then
    win_target "$(win_path "$(posix_path "$AGENTS_DIR")")/x" 'C:\workspace' fallback
    win_target "$(win_path "$(posix_path "${AGENTS_HOME:-/c/Users/ContainerAdministrator}")")\\proj" 'C:\workspace' fallback
fi
WS=/workspace win claude;              check "windows: the plain-compose default becomes C:\\workspace" "$(field target)" 'C:\workspace'
check "windows: the fallback is what is recorded" "$(recorded 'C:\workspace')" claude

# Harnesses without a Dockerfile.windows are refused on Windows, by name; elsewhere they are fine.
# Every harness has one now, so a scratch copy of agents/ gets a made-up one (nowin) that lacks it.
fakedir=/tmp/aw-fake-agents
rm -rf "$fakedir"; mkdir -p "$fakedir"
mkdir "$fakedir/agents"; cp "$(dirname "$core")"/*.sh "$fakedir/agents/"
for h in "$(dirname "$core")"/*/harness.sh; do
    d=$fakedir/agents/$(basename "$(dirname "$h")"); mkdir "$d"; cp "$h" "$d/"
    ! [ -f "$(dirname "$h")/Dockerfile.windows" ] || : >"$d/Dockerfile.windows"
done
mkdir "$fakedir/agents/nowin"; cp "$fakedir/agents/claude/harness.sh" "$fakedir/agents/nowin/harness.sh"
real_core=$core real_dir=${AGENTS_DIR:-}
core=$fakedir/agents/launch.sh; export AGENTS_DIR=$fakedir
win nowin;                             has "windows: nowin is refused" "$out" "'nowin' is not available in Windows containers (available: claude cline hermes opencode pi)"
check "windows: nowin is refused: exit code, nothing handed off" "$code-$(exists harness)" 1-no
win --harness nowin;                   has "windows: --harness nowin is refused" "$out" "not available in Windows containers"
AGENTS_HARNESS=nowin win;              has "windows: AGENTS_HARNESS=nowin is refused" "$out" "not available in Windows containers"
win nope;                              has "windows: an unknown name is still unknown" "$out" "Unknown harness 'nope'"
printf '%s\tnowin\n*\tnowin\n' "$A" >"$state"
win;                                   has "windows: a recorded nowin is not offered (no terminal)" "$out" "No terminal and no harness recorded; pass one: claude cline hermes opencode pi"
if ! is_windows; then run nowin;       check "linux: nowin launches" "$(field harness)" nowin; fi
core=$real_core; if [ -n "$real_dir" ]; then export AGENTS_DIR=$real_dir; else unset AGENTS_DIR; fi
win hermes;                            check "windows: hermes is available" "$(field harness)" hermes
win opencode;                          check "windows: an available harness launches" "$(field harness)" opencode

# shared/.last-harness: per folder and overall, written by named launches too.
rm -f "$state"
WS=$A run claude;                      check "named launch: recorded for the folder" "$(recorded "$A")" claude
check "named launch: recorded for anywhere" "$(recorded '*')" claude
WS=$B run pi
check "named launch: another folder keeps the first" "$(recorded "$A")/$(recorded "$B")/$(recorded '*')" claude/pi/pi
check "named launch: one line per key" "$(grep -c . "$state")" 3
# Without a terminal and without a harness: the last used one.
WS=$A run;                             check "no harness, no terminal: this folder's last used" "$(field harness)" claude
WS=$B run;                             check "no harness, no terminal: another folder's own" "$(field harness)" pi
WS=$C run;                             check "no harness, no terminal: a new folder gets the last used anywhere" "$(field harness)" pi
check "that choice is recorded for the new folder" "$(recorded "$C")" pi
WS=$A run -y;                          check "-y without a harness: the last used" "$(field harness)" claude
rm -f "$state"
WS=$A run;                             has "no history, no terminal: error" "$out" "No terminal and no harness recorded"; check "no history: exit code" "$code" 1
check "no history: nothing recorded" "$([ -e "$state" ] && echo yes || echo no)" no
printf '%s\tgone\n*\tnope\n' "$A" >"$state"
WS=$A run;                             check "a recorded harness that no longer exists is an error" "$code" 1

# The menus need a terminal; in a Windows container there is no script(1), so they are a manual check (README).
if [ -z "$have_script" ]; then
    echo "skipped: menu tests (no script(1))"
    exit $fail
fi

# AGENTS_NONINTERACTIVE counts as no terminal, even with one.
printf '%s\tpi\n*\tpi\n' "$A" >"$state"
AGENTS_NONINTERACTIVE=1 pty "$DOWN$ENTER" ""
check "non-interactive with a terminal: takes the recorded harness" "$(field harness)" pi
has "non-interactive with a terminal: no menu" "$out" "Up/Down to move" no

# Menu: the last used one is first and marked; the rest follow alphabetically.
printf '%s\tpi\n*\tpi\n' "$A" >"$state"
pty "$ENTER" ""
check "menu: Enter picks the last used" "$(field harness)" pi
check "menu: Enter exits 0" "$code" 0
check "menu: the choice is recorded" "$(recorded "$A")" pi
has "menu: shows (last used)" "$out" "pi (last used)"
has "menu: title" "$out" "Select the agent harness to run in $A"
has "menu: key hint" "$out" "Up/Down to move"
has "menu: clears the screen first" "$out" "$(printf '\033[H\033[2J')"
case ${out%%claude*} in *"pi (last used)"*) echo "ok   menu: last used is listed before claude" ;; *) echo "FAIL menu: order in: $out" >&2; fail=1 ;; esac
case $out in *claude*cline*hermes*opencode*) echo "ok   menu: the rest in alphabetical order" ;; *) echo "FAIL menu: alphabetical order in: $out" >&2; fail=1 ;; esac
pty "$DOWN$ENTER" "";                  check "menu: Down+Enter picks the next one, claude" "$(field harness)" claude
check "menu: the choice is remembered for anywhere" "$(recorded '*')" claude
printf '*\tpi\n' >"$state"
WS=$NEW pty "$ENTER" "";               check "menu: a new folder starts on the last used anywhere" "$(field harness)" pi
rm -f "$state"
pty "$ENTER" "";                       check "menu: no history, Enter picks the first one" "$(field harness)" claude
pty "$DOWN$ENTER" "" --continue -- --model x
check "menu: with options, args after -- go to the chosen harness" "$(field mode)-$(field harness)$(argv)" $'yes-cline>--model\n>x'

printf '%s\tpi\n*\tpi\n' "$A" >"$state"
pty "$DOWN" '\003';                    check "menu: Ctrl-C exits 130" "$code" 130
check "menu: Ctrl-C hands nothing off" "$(exists harness)" no
check "menu: Ctrl-C records nothing" "$(recorded "$A")" pi

# The menu of a Windows container lists only the available harnesses.
printf '%s\tpi\n*\tpi\n' "$A" >"$state"
core=$fakedir/agents/launch.sh; export AGENTS_DIR=$fakedir
AGENTS_PLATFORM=windows pty "$ENTER" ""
case $out in *nowin*) echo "FAIL windows menu: lists nowin: $out" >&2; fail=1 ;; *claude*cline*hermes*opencode*) echo "ok   windows menu: only the available ones" ;; *) echo "FAIL windows menu: $out" >&2; fail=1 ;; esac
core=$real_core
exit $fail
