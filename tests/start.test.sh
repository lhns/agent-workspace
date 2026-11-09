#!/bin/bash
# Tests agents/start.sh inside a harness container (see .github/workflows/ci.yml):
#   docker compose run --rm -T claude bash -c "$(cat tests/start.test.sh)" start-test
# The harness binaries are stubs that print their arguments; HOME is a scratch directory. The mounted
# agents/ gives every harness's harness.sh, not only the container's own.
# It runs in a Windows container too (Git Bash): the folder is C:\aw-start-test there, which the
# harnesses key their sessions by in their own way; the tests that drive a terminal through
# script(1) are skipped (a manual check, README), and so is Docker for the agents.
set -u
AGENTS_DIR=${AGENTS_DIR:-/opt/agent-workspace}
start=$AGENTS_DIR/agents/start.sh
# shellcheck source=agents/os.sh
. "$AGENTS_DIR/agents/os.sh"
fail=0
check() { # name, command output, expected substring, "no" to expect its absence
    if [ "${4:-}" = no ]; then
        if grep -qF -- "$3" <<<"$2"; then echo "FAIL $1: unexpected '$3' in: $2" >&2; fail=1; else echo "ok   $1"; fi
    elif grep -qF -- "$3" <<<"$2"; then echo "ok   $1"
    else echo "FAIL $1: expected '$3' in: $2" >&2; fail=1; fi
}
# check, for the tests that need a terminal.
tcheck() {
    if command -v script >/dev/null; then check "$@"; else echo "skipped: $1 (no script(1))"; fi
}

HOME=$(mktemp -d); export HOME
# The launcher's own run (--exec) sets some of these: the tests make their own.
unset CLAUDE_CONFIG_DIR XDG_DATA_HOME HERMES_HOME AGENTS_RUN_ID AGENTS_LAUNCH_DIR AGENTS_AUTORESUME AGENTS_NONINTERACTIVE AGENTS_DOCKER AGENTS_DOCKER_TOKEN
stubs=$(mktemp -d)
for b in claude pi opencode cline hermes; do
    printf '#!/bin/sh\necho "STUB %s $*"\n' "$b" > "$stubs/$b"
    chmod +x "$stubs/$b"
done
export PATH=$stubs:$PATH
# The folder, as the harnesses see it ($nwork), and the session folders they derive from it.
if is_windows; then
    work=/c/aw-start-test nwork='C:\aw-start-test' ckey=C--aw-start-test pikey=--C--aw-start-test--
else
    work=/tmp/aw-start-test nwork=/tmp/aw-start-test ckey=-tmp-aw-start-test pikey=--tmp-aw-start-test--
fi
mkdir -p "$work"
cd "$work" || exit 1

# Without a terminal: how the harness is started.
plain() { # harness, AGENTS_AUTORESUME
    AGENTS_AUTORESUME=$2 bash "$start" "$1" </dev/null 2>&1
}
# With a terminal and scripted keys (printf format) for the menu.
pty() { # keys, harness, keys sent a second later
    # shellcheck disable=SC2059 # keys are printf escapes
    { sleep 1; printf "$1"; sleep 1; printf "${3:-}"; sleep 1; } | AGENTS_AUTORESUME=ask timeout 20 script -qec "bash $start $2" /dev/null 2>&1
}
UP='\033[A' DOWN='\033[B' ENTER='\n'

out=$(plain claude ask);  check "claude: no session starts fresh" "$out" "STUB claude" ; check "claude: no session, no --continue" "$out" "--continue" no
mkdir -p "$HOME/.claude/projects/$ckey"
out=$(plain claude ask);  check "claude: no .jsonl yet, still fresh" "$out" "--continue" no
touch "$HOME/.claude/projects/$ckey/x.jsonl"
out=$(plain claude "");   check "claude: session, empty setting, no terminal resumes" "$out" "STUB claude --continue"
out=$(plain claude ask);  check "claude: session, ask, no terminal resumes" "$out" "STUB claude --continue"
out=$(plain claude YES);  check "claude: yes (upper case) resumes" "$out" "STUB claude --continue"
out=$(plain claude no);   check "claude: no starts fresh" "$out" "--continue" no
out=$(plain claude NO);   check "claude: NO starts fresh" "$out" "--continue" no
out=$(plain claude maybe); check "unknown value warns" "$out" "is not ask, yes, no or pick"; check "unknown value asks, so resumes without terminal" "$out" "STUB claude --continue"

# Arguments for the harness come from the launch dir, after the resume (or picker) arguments.
withargs() { # harness, AGENTS_AUTORESUME, harness args...
    local h=$1 m=$2 d
    shift 2
    d=$(mktemp -d)
    printf '%s\0' "$@" >"$d/args"
    AGENTS_LAUNCH_DIR=$d AGENTS_AUTORESUME=$m bash "$start" "$h" </dev/null 2>&1
}
modelx=$(mktemp -d)
printf '%s\0' --model x >"$modelx/args"
out=$(withargs claude yes --model x);    check "args: after the resume arguments" "$out" "STUB claude --continue --model x"
out=$(withargs claude ask --model x);    check "args: ask without a terminal resumes, then the args" "$out" "STUB claude --continue --model x"
out=$(withargs claude no --model x "a b");  check "args: new conversation, args only" "$out" "STUB claude --model x a b" ; check "args: new conversation, no --continue" "$out" "--continue" no
out=$(AGENTS_AUTORESUME=ask AGENTS_NONINTERACTIVE=1 timeout 10 script -qec "AGENTS_LAUNCH_DIR=$modelx bash $start claude" /dev/null 2>&1)
tcheck "non-interactive with a terminal resumes without a menu" "$out" "STUB claude --continue --model x" ; tcheck "non-interactive: no menu" "$out" "Start new conversation" no
out=$(AGENTS_AUTORESUME=pick timeout 10 script -qec "AGENTS_LAUNCH_DIR=$modelx bash $start claude" /dev/null 2>&1)
tcheck "pick: the harness's own session picker, then the args" "$out" "STUB claude --resume --model x"
out=$(AGENTS_AUTORESUME=pick timeout 10 script -qec "bash $start hermes" /dev/null 2>&1)
tcheck "pick: hermes" "$out" "STUB hermes sessions browse"
out=$(withargs claude pick)
check "pick without a terminal is an error" "$out" "--sessions needs a terminal" ; check "pick without a terminal starts nothing" "$out" "STUB" no
out=$(AGENTS_NONINTERACTIVE=1 AGENTS_AUTORESUME=pick timeout 10 script -qec "bash $start claude" /dev/null 2>&1)
tcheck "pick with non-interactive is an error" "$out" "can't be combined with -y"
out=$(AGENTS_AUTORESUME=pick timeout 10 script -qec "bash $start opencode" /dev/null 2>&1)
tcheck "pick for opencode is an error" "$out" "no session picker" ; tcheck "pick for opencode starts nothing" "$out" "STUB" no

out=$(pty "$ENTER" claude);              tcheck "menu: Enter resumes" "$out" "STUB claude --continue"
out=$(pty "$DOWN$ENTER" claude);         tcheck "menu: Down+Enter opens the picker" "$out" "STUB claude --resume"
out=$(pty "$DOWN$DOWN$ENTER" claude);    tcheck "menu: Down+Down+Enter starts fresh" "$out" "STUB claude" ; tcheck "menu: Down+Down+Enter, no --continue/--resume" "$out" "--" no
out=$(pty "$DOWN$DOWN$DOWN$ENTER" claude); tcheck "menu: Down past the end stays on new" "$out" "STUB claude" ; tcheck "menu: Down past the end, no --continue/--resume" "$out" "--" no
out=$(pty "$DOWN$UP$ENTER" claude);      tcheck "menu: Down+Up+Enter resumes" "$out" "STUB claude --continue"
out=$(pty "$UP$ENTER" claude);           tcheck "menu: Up past the start stays on resume" "$out" "STUB claude --continue"
out=$(pty "y$ENTER" claude);             tcheck "menu: y is no shortcut, Enter resumes" "$out" "STUB claude --continue"
tcheck "menu: shows the picker item" "$out" "Choose another conversation"
tcheck "menu: shows the new item" "$out" "Start new conversation"
tcheck "menu: title" "$out" "claude has an earlier conversation in $work" ; tcheck "menu: key hint" "$out" "Up/Down to move"
tcheck "menu: clears the screen first" "$out" "$(printf '[H[2J')"
out=$(pty '\033' claude "$DOWN$DOWN$ENTER"); tcheck "menu: a lone Esc does not hang or select; Down+Down+Enter then starts fresh" "$out" "--continue" no
out=$(pty "$DOWN" claude '\003');         tcheck "menu: Ctrl-C starts nothing" "$out" "STUB" no ; tcheck "menu: Ctrl-C shows the cursor again" "$out" "$(printf '\033[?25h')"
out=$(AGENTS_AUTORESUME=yes timeout 10 script -qec "bash $start claude" /dev/null </dev/null 2>&1)
tcheck "yes: no menu" "$out" "Start new conversation" no

# pi: sessions live in a folder named after the working directory.
out=$(pty "" pi);                        tcheck "pi: no session starts without a menu" "$out" "Resume last" no ; tcheck "pi: no session starts fresh" "$out" "STUB pi"
mkdir -p "$HOME/.pi/agent/sessions/$pikey"
touch "$HOME/.pi/agent/sessions/$pikey/s.jsonl"
out=$(plain pi ask);                     check "pi: session resumes" "$out" "STUB pi --continue"
out=$(pty "$DOWN$ENTER" pi);             tcheck "pi: picker" "$out" "STUB pi --resume"

# opencode, cline, hermes: SQLite indexes.
db() { python3 - "$@" <<'PY'
import sqlite3, sys
path, *stmts = sys.argv[1:]
import os
os.makedirs(os.path.dirname(path), exist_ok=True)
c = sqlite3.connect(path)
for s in stmts:
    c.execute(s)
c.commit()
PY
}
oc=$HOME/.local/share/opencode/opencode.db
db "$oc" "CREATE TABLE session (id TEXT, directory TEXT, parent_id TEXT, time_archived INTEGER)" \
    "INSERT INTO session VALUES ('a', '/elsewhere', NULL, NULL)" "INSERT INTO session VALUES ('b', '$nwork', NULL, 1)" "INSERT INTO session VALUES ('c', '$nwork', 'a', NULL)"
out=$(plain opencode ask);               check "opencode: only other folder, archived or child sessions: fresh" "$out" "--continue" no
db "$oc" "INSERT INTO session VALUES ('d', '$nwork', NULL, NULL)"
out=$(plain opencode ask);               check "opencode: session resumes" "$out" "STUB opencode --continue"
out=$(pty "$DOWN$ENTER" opencode);       tcheck "opencode: no picker item" "$out" "Choose another" no ; tcheck "opencode: Down+Enter starts fresh" "$out" "--continue" no

cl=$HOME/.cline/data/db/sessions.db
msgs=$HOME/cline-messages
mkdir -p "$msgs"
# The harness records the path in its own form (C:... on Windows).
msgw=$msgs; ! is_windows || msgw=$(cygpath -w "$msgs")
echo '[{}]' > "$msgs/old.json"; echo '[{}]' > "$msgs/other.json"; echo '[{}]' > "$msgs/sub.json"; : > "$msgs/empty.json"
db "$cl" "CREATE TABLE sessions (session_id TEXT, cwd TEXT, is_subagent INTEGER, parent_session_id TEXT, started_at TEXT, messages_path TEXT)"     "INSERT INTO sessions VALUES ('other', '/elsewhere', 0, NULL, '2030-01-01', '$msgw/other.json')"
out=$(plain cline ask);                  check "cline: only other folder: fresh" "$out" "--id" no
db "$cl" "INSERT INTO sessions VALUES ('empty', '$nwork', 0, NULL, '2019-01-01', '$msgw/empty.json')"     "INSERT INTO sessions VALUES ('nopath', '$nwork', 0, NULL, '2019-06-01', NULL)"     "INSERT INTO sessions VALUES ('missing', '$nwork', 0, NULL, '2019-07-01', '$msgw/gone.json')"
out=$(plain cline ask);                  check "cline: sessions without messages: fresh" "$out" "--id" no
db "$cl" "INSERT INTO sessions VALUES ('old', '$nwork', 0, NULL, '2020-01-01', '$msgw/old.json')"     "INSERT INTO sessions VALUES ('stub', '$nwork', 0, NULL, '2021-01-01', '$msgw/empty.json')"     "INSERT INTO sessions VALUES ('sub', '$nwork', 1, NULL, '2022-01-01', '$msgw/sub.json')"
out=$(plain cline ask);                  check "cline: resumes the newest session of this folder that has messages" "$out" "STUB cline --id old"
out=$(pty "$DOWN$ENTER" cline);          tcheck "cline: picker" "$out" "STUB cline history"

hm=$HOME/.hermes/state.db
db "$hm" "CREATE TABLE sessions (source TEXT, message_count INTEGER, git_repo_root TEXT, cwd TEXT)" \
    "INSERT INTO sessions VALUES ('cli', 3, NULL, '/elsewhere')" "INSERT INTO sessions VALUES ('cli', 0, NULL, '$nwork')" "INSERT INTO sessions VALUES ('cron', 3, NULL, '$nwork')"
out=$(plain hermes ask);                 check "hermes: other folder, empty or non-cli sessions: fresh" "$out" "-c" no
db "$hm" "INSERT INTO sessions VALUES ('cli', 3, NULL, '$nwork')"
out=$(plain hermes ask);                 check "hermes: session resumes" "$out" "STUB hermes -c"
out=$(pty "$DOWN$ENTER" hermes);         tcheck "hermes: picker" "$out" "STUB hermes sessions browse"

# The database may sit in a folder with a space (a file URI must quote it); sql() hands Python the
# path in its own form.
spacey="$HOME/data dir"
out=$(XDG_DATA_HOME=$spacey plain opencode ask); check "sql: no database in a folder with a space: fresh" "$out" "--continue" no
mkdir -p "$spacey/opencode"
cp "$oc" "$spacey/opencode/opencode.db"
out=$(XDG_DATA_HOME=$spacey plain opencode ask); check "sql: a database in a folder with a space is read" "$out" "STUB opencode --continue"

# Windows: the harnesses key sessions by the Windows folder (C:\x), not the MSYS one (/c/x).
if is_windows; then
    mkdir -p "$HOME/.claude/projects/C--" "$HOME/.pi/agent/sessions/--C----"
    touch "$HOME/.claude/projects/C--/x.jsonl" "$HOME/.pi/agent/sessions/--C----/s.jsonl"
    out=$(cd /c && plain claude ask);    check "windows: claude's key for C:\\ is C--" "$out" "STUB claude --continue"
    out=$(cd /c && plain pi ask);        check "windows: pi's key for C:\\ is --C----" "$out" "STUB pi --continue"
fi

# The launch dir that agents/launch.sh writes: args (NUL-separated), mode, noninteractive, exec.
ld=$(mktemp -d)
launched() { # harness, AGENTS_AUTORESUME: starts with the launch dir, no terminal
    AGENTS_LAUNCH_DIR=$ld AGENTS_AUTORESUME=$2 bash "$start" "$1" </dev/null 2>&1
}
printf '%s\0' --model 'a b' '' $'x\ny' >"$ld/args"
out=$(launched claude no)
check "launch dir: args reach the harness" "$out" "STUB claude --model a b  x"
printf '%s\0' printf '[%s]' 'a b' '' $'x\ny' "it's" '!' >"$ld/args"
: >"$ld/exec"
out=$(launched claude yes)
check "launch dir: --exec runs the command, args intact" "$out" "$(printf '[a b][][x\ny][it'"'"'s][!]')"
check "launch dir: --exec does not start the harness" "$out" "STUB" no
rm "$ld/exec"
: >"$ld/args"
echo yes >"$ld/mode"
out=$(launched claude no);               check "launch dir: the mode file beats AGENTS_AUTORESUME (yes over no)" "$out" "STUB claude --continue"
echo no >"$ld/mode"
out=$(launched claude yes);              check "launch dir: the mode file beats AGENTS_AUTORESUME (no over yes)" "$out" "--continue" no
echo pick >"$ld/mode"
out=$(launched claude no);               check "launch dir: pick without a terminal is an error" "$out" "--sessions needs a terminal"
rm "$ld/mode"
out=$(launched claude yes);              check "launch dir: no mode file, AGENTS_AUTORESUME applies" "$out" "STUB claude --continue"
: >"$ld/noninteractive"
out=$(AGENTS_LAUNCH_DIR=$ld AGENTS_AUTORESUME=ask timeout 10 script -qec "bash $start claude" /dev/null 2>&1)
tcheck "launch dir: noninteractive resumes without a menu" "$out" "STUB claude --continue" ; tcheck "launch dir: noninteractive, no menu" "$out" "Start new conversation" no
out=$(AGENTS_RUN_ID=nope AGENTS_AUTORESUME=yes bash "$start" claude </dev/null 2>&1)
check "a run id without a launch dir is ignored" "$out" "STUB claude --continue"

# Docker for the agent (agents/docker.sh): a stub remote-docker logs its calls; the claude stub shows DOCKER_HOST.
if is_windows; then
    # Not available there: one line, and the agent starts without it.
    out=$(AGENTS_AUTORESUME=no AGENTS_DOCKER=remote-docker AGENTS_DOCKER_TOKEN=rdt1.x.y bash "$start" claude </dev/null 2>&1)
    check "docker: Windows containers say it is not available" "$out" "Docker for the agents is not available in Windows containers"
    check "docker: said once" "$(grep -c 'not available in Windows' <<<"$out")" "1"
    check "docker: the harness still starts" "$out" "STUB claude"
    check "docker: the token is not printed" "$out" "rdt1." no
else
dstubs=$(mktemp -d)
cat >"$dstubs/claude" <<'STUB'
#!/bin/sh
echo "STUB claude DH=${DOCKER_HOST:-none} TOKEN=${AGENTS_DOCKER_TOKEN:-unset} $*"
STUB
cat >"$dstubs/remote-docker" <<'STUB'
#!/bin/bash
echo "[state=${REMOTE_DOCKER_STATE_DIR##*/}] $*" >>"$STUB_LOG"
case "$1 $2" in
    "remote token") [ -z "${STUB_MINT_FAIL:-}" ] || { echo refused >&2; exit 1; }
        printf 'docker remote create ws --token rdt1.minted.secret\nsingle use, for account alice\n' ;;
    "remote create") [ -z "${STUB_SLOW_ENROL:-}" ] || sleep 2; touch "$REMOTE_DOCKER_STATE_DIR/id_ed25519"; echo known >"$REMOTE_DOCKER_STATE_DIR/known_hosts"
        echo '{"workspaces":{"aw":{"host":"h","user":"alice"}}}' >"$HOME/.remote-docker.json"; echo added ;;
    "remote start") echo started ;;
    "remote status") n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); echo $((n + 1)) >"$STUB_COUNT"
        [ "${STUB_READY_AFTER:-0}" != never ] && [ "$n" -ge "${STUB_READY_AFTER:-0}" ] ;;
    "remote key") if [ "$3" = ls ]; then printf 'FINGERPRINT  COMMENT  DIRECTORY\nSHA256:other  x  d\nSHA256:mine  c  d  this machine\n'; else echo removed; fi ;;
    "remote stop") echo stopped ;;
esac
STUB
chmod +x "$dstubs/claude" "$dstubs/remote-docker"
export STUB_LOG=$dstubs/calls STUB_COUNT=$dstubs/count
dock() { # env assignments...: starts claude through start.sh with the stubs
    rm -f "$HOME/.remote-docker.json" "$STUB_LOG" "$STUB_COUNT"
    env PATH="$dstubs:$PATH" AGENTS_AUTORESUME=no \
        AGENTS_DOCKER_SEED="$seed" "$@" bash "$start" claude </dev/null 2>&1
}
calls() { cat "$STUB_LOG" 2>/dev/null; }
seed=$(mktemp -d)/seed
TOKEN='docker remote create ws --token rdt1.seedtoken.xyz'

out=$(dock);                             check "docker: unset: the harness starts without DOCKER_HOST" "$out" "DH=none"
check "docker: unset: remote-docker is never called" "$(calls)" "[" no
out=$(dock AGENTS_DOCKER=remote-docker); check "docker: not enrolled, no token: a hint" "$out" "not enrolled; continuing without Docker"
check "docker: not enrolled: the harness still starts" "$out" "STUB claude DH=none"
check "docker: not enrolled: one hint line" "$(grep -c 'not enrolled' <<<"$out")" "1"
check "docker: not enrolled: remote-docker is never called" "$(calls)" "[" no

out=$(STUB_READY_AFTER=2 dock AGENTS_DOCKER=remote-docker AGENTS_DOCKER_TOKEN="$TOKEN")
check "docker: the seed is enrolled once and says so" "$out" "enrolled; you can remove AGENTS_DOCKER_TOKEN from .env"
check "docker: the token is not printed" "$out" "rdt1." no
check "docker: the seed enrolment used the token" "$(calls)" "[state=seed] remote create aw --token rdt1.seedtoken.xyz"
check "docker: the seed mints the container's token" "$(calls)" "[state=seed] remote token create --note $HOSTNAME"
check "docker: the container enrols its own key" "$(calls)" "[state=state] remote create aw --token rdt1.minted.secret"
check "docker: the session is started" "$(calls)" "remote start"
check "docker: waits for the workspace (three status calls)" "$(grep -c 'remote status' "$STUB_LOG")" "3"
check "docker: DOCKER_HOST is the container's socket" "$out" "STUB claude DH=unix:///tmp/remote-docker."
check "docker: the harness does not see the token" "$out" "TOKEN=unset"
check "docker: the session ends after the harness" "$(calls)" "remote stop -f"
check "docker: the container's own key is removed" "$(calls)" "[state=state] remote key rm SHA256:mine -f"
check "docker: the seed is marked enrolled" "$([ -e "$seed/enrolled" ] && echo yes)" "yes"
check "docker: the seed keeps the workspace config" "$(cat "$seed/remote-docker.json")" '"host":"h"'

out=$(dock AGENTS_DOCKER=remote-docker AGENTS_DOCKER_TOKEN="$TOKEN")
check "docker: an enrolled seed ignores the token" "$(calls)" "--token rdt1.seedtoken" no
check "docker: an enrolled seed does not announce it again" "$out" "enrolled; you can" no
check "docker: a second run still starts a session" "$out" "STUB claude DH=unix://"
check "docker: the second run reads the seed's workspace config" "$([ -f "$HOME/.remote-docker.json" ] && echo yes)" "yes"

out=$(STUB_READY_AFTER=never dock AGENTS_DOCKER=remote-docker AGENTS_DOCKER_TIMEOUT=2)
check "docker: timeout is reported" "$out" "did not answer within 2s"
check "docker: after a timeout the harness starts without Docker" "$out" "STUB claude DH=none"
check "docker: after a timeout the key is removed" "$(calls)" "remote key rm SHA256:mine -f"
check "docker: no scratch dir is left behind" "$(find /tmp -maxdepth 1 -name 'remote-docker.*' | wc -l | tr -d ' ')" "0"

out=$(STUB_MINT_FAIL=1 dock AGENTS_DOCKER=remote-docker)
check "docker: a refused token is reported" "$out" "minting a token failed"
check "docker: a refused token still starts the harness" "$out" "STUB claude DH=none"

# Two containers starting together with the same token: one enrols the seed, the other uses it.
seed=$(mktemp -d)/seed; rm -f "$HOME/.remote-docker.json" "$STUB_LOG" "$STUB_COUNT"
for i in 1 2; do
    env PATH="$dstubs:$PATH" AGENTS_AUTORESUME=no STUB_SLOW_ENROL=1 \
        AGENTS_DOCKER_SEED="$seed" AGENTS_DOCKER=remote-docker AGENTS_DOCKER_TOKEN='rdt1.a.b*c/d&e' \
        bash "$start" claude </dev/null >"$dstubs/race$i" 2>&1 &
done
wait
check "docker: concurrent starts spend the seed token once" "$(grep -c '\[state=seed\] remote create' "$STUB_LOG")" "1"
check "docker: concurrent starts both get Docker" "$(cat "$dstubs"/race1 "$dstubs"/race2 | grep -c 'DH=unix://')" "2"
check "docker: the token is not printed, metacharacters or not" "$(cat "$dstubs"/race1 "$dstubs"/race2)" "rdt1.a" no

# Without flock (Git Bash has none) the seed lock is a directory.
nolock=$(
    . "$AGENTS_DIR/agents/docker.sh"
    docker_seed=$(mktemp -d)
    # shellcheck disable=SC2317,SC2329 # called by docker_locked (SC2317 on older shellcheck)
    command() { if [ "$*" = "-v flock" ]; then return 1; fi; builtin command "$@"; }
    # shellcheck disable=SC2016 # the child shell expands it
    docker_locked bash -c 'test -d "$1/.lock.d" || exit 3; touch "$1/ran"' x "$docker_seed"
    echo "rc=$? ran=$([ -e "$docker_seed/ran" ] && echo yes) lock=$([ -e "$docker_seed/.lock.d" ] && echo left || echo gone)"
)
check "docker: without flock the lock is a directory, taken and released" "$nolock" "rc=0 ran=yes lock=gone"

ld2=$(mktemp -d)
# shellcheck disable=SC2016 # the child shell expands it
printf '%s\0' sh -c 'echo "EXEC DH=$DOCKER_HOST"; exit 7' >"$ld2/args"
: >"$ld2/exec"
out=$(dock AGENTS_DOCKER=remote-docker AGENTS_LAUNCH_DIR="$ld2"); code=$?
check "docker: --exec gets DOCKER_HOST too" "$out" "EXEC DH=unix:///tmp/remote-docker."
check "docker: --exec keeps the command's exit status" "$code" "7"
check "docker: --exec ends the session and removes the key" "$(calls)" "remote key rm SHA256:mine -f"
fi

# Generated global instructions (ADR 25): environment notes, the Docker line, then the user's file.
user=$(mktemp -d)/user.md
printf 'MY RULES\nline two\n' >"$user"
cp "$user" "$user.orig"
notes=$HOME/.claude/CLAUDE.md
rm -f "$notes"
out=$(plain claude no)
check "notes: the harness still starts" "$out" "STUB claude"
rm -f "$notes"
out=$(AGENTS_USER_INSTRUCTIONS=$user plain claude no)
check "notes: written at the harness path" "$(cat "$notes")" "# Environment"
if is_windows; then
    check "notes: the OS line says Windows" "$(cat "$notes")" "- Windows container (Server Core), shell Git Bash; cline runs tools in PowerShell."
    check "notes: no Linux line on Windows" "$(cat "$notes")" "- Linux container" no
else
    check "notes: the OS line says Linux" "$(cat "$notes")" "- Linux container, user \`agent\`: no root, sudo or apt."
    check "notes: no Windows line on Linux" "$(cat "$notes")" "- Windows container" no
fi
check "notes: the Docker line says none without Docker" "$(cat "$notes")" "- Docker: none."
check "notes: the Docker 'on' line is absent without Docker" "$(cat "$notes")" "- Docker: on." no
check "notes: the user's file is appended" "$(cat "$notes")" "MY RULES"
lineno() { grep -nE "$1" "$notes" | head -n 1 | cut -d: -f1; }
e=$(lineno '^# Environment'); d=$(lineno '^- Docker:'); u=$(lineno '^MY RULES')
check "notes: order is environment, Docker, user" "$([ "$e" -lt "$d" ] && [ "$d" -lt "$u" ] && echo ordered)" "ordered"
check "notes: the user's file is untouched" "$(cmp "$user" "$user.orig" && echo same)" "same"
check "notes: no temp file is left behind" "$(find "$HOME/.claude" -maxdepth 1 -name '.instructions.*' | wc -l | tr -d ' ')" "0"

: >"$user"
rm -f "$notes"
AGENTS_USER_INSTRUCTIONS=$user plain claude no >/dev/null
check "notes: an empty user file adds nothing" "$(tail -n 1 "$notes")" "- Docker: none."

if ! is_windows; then # Docker for the agents is off there
rm -f "$notes"
out=$(dock AGENTS_DOCKER=remote-docker AGENTS_DOCKER_TOKEN="$TOKEN" AGENTS_USER_INSTRUCTIONS="$user.orig")
check "notes: Docker on is written when a session runs" "$(cat "$notes")" "- Docker: on."
check "notes: Docker none is absent when a session runs" "$(cat "$notes")" "- Docker: none." no
fi

# Every harness with an instructions path gets the file there; hermes has none and writes nothing.
for hh in opencode:.config/opencode/AGENTS.md pi:.pi/agent/AGENTS.md cline:.agents/AGENTS.md; do
    rm -f "$HOME/${hh#*:}"
    AGENTS_USER_INSTRUCTIONS=$user.orig plain "${hh%%:*}" no >/dev/null
    check "notes: ${hh%%:*} gets the file at ~/${hh#*:}" "$(cat "$HOME/${hh#*:}")" "MY RULES"
done
before=$(find "$HOME" -type f | sort)
AGENTS_USER_INSTRUCTIONS=$user.orig plain hermes no >/dev/null
check "notes: hermes writes no instructions file" "$(find "$HOME" -type f | sort | diff - <(echo "$before") && echo unchanged)" "unchanged"

ld3=$(mktemp -d)
printf '%s\0' true >"$ld3/args"
: >"$ld3/exec"
rm -f "$notes"
AGENTS_LAUNCH_DIR=$ld3 AGENTS_USER_INSTRUCTIONS=$user.orig bash "$start" claude </dev/null >/dev/null 2>&1
check "notes: --exec writes them too" "$(cat "$notes")" "MY RULES"
exit $fail
