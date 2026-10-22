#!/bin/bash
# Tests agents/start.sh inside a harness container (see .github/workflows/ci.yml):
#   ./run-claude.sh bash -c "$(cat tests/start.test.sh)" start-test
# The harness binaries are stubs that print their arguments; HOME is a scratch directory.
set -u
start=${START:-/usr/local/lib/agents-start.sh}
fail=0
check() { # name, command output, expected substring, "no" to expect its absence
    if [ "${4:-}" = no ]; then
        if grep -qF -- "$3" <<<"$2"; then echo "FAIL $1: unexpected '$3' in: $2" >&2; fail=1; else echo "ok   $1"; fi
    elif grep -qF -- "$3" <<<"$2"; then echo "ok   $1"
    else echo "FAIL $1: expected '$3' in: $2" >&2; fail=1; fi
}

HOME=$(mktemp -d); export HOME
unset CLAUDE_CONFIG_DIR XDG_DATA_HOME HERMES_HOME
stubs=$(mktemp -d)
for b in claude pi opencode cline hermes; do
    printf '#!/bin/sh\necho "STUB %s $*"\n' "$b" > "$stubs/$b"
    chmod +x "$stubs/$b"
done
export PATH=$stubs:$PATH
work=/tmp/aw-start-test
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
mkdir -p "$HOME/.claude/projects/-tmp-aw-start-test"
out=$(plain claude ask);  check "claude: no .jsonl yet, still fresh" "$out" "--continue" no
touch "$HOME/.claude/projects/-tmp-aw-start-test/x.jsonl"
out=$(plain claude "");   check "claude: session, empty setting, no terminal resumes" "$out" "STUB claude --continue"
out=$(plain claude ask);  check "claude: session, ask, no terminal resumes" "$out" "STUB claude --continue"
out=$(plain claude YES);  check "claude: yes (upper case) resumes" "$out" "STUB claude --continue"
out=$(plain claude no);   check "claude: no starts fresh" "$out" "--continue" no
out=$(plain claude NO);   check "claude: NO starts fresh" "$out" "--continue" no
out=$(plain claude maybe); check "unknown value warns" "$out" "is not ask, yes or no"; check "unknown value asks, so resumes without terminal" "$out" "STUB claude --continue"

out=$(pty "$ENTER" claude);              check "menu: Enter resumes" "$out" "STUB claude --continue"
out=$(pty "$DOWN$ENTER" claude);         check "menu: Down+Enter starts fresh" "$out" "STUB claude" ; check "menu: Down+Enter, no --continue" "$out" "--continue" no
out=$(pty "$DOWN$UP$ENTER" claude);      check "menu: Down+Up+Enter resumes" "$out" "STUB claude --continue"
out=$(pty "y$ENTER" claude);             check "menu: y is no shortcut, Enter resumes" "$out" "STUB claude --continue"
check "menu: shows both items" "$out" "Start new conversation"
out=$(pty '\033' claude "$DOWN$ENTER");   check "menu: a lone Esc does not hang or select; Down+Enter then starts fresh" "$out" "--continue" no
out=$(pty "$DOWN" claude '\003');         check "menu: Ctrl-C starts nothing" "$out" "STUB" no ; check "menu: Ctrl-C shows the cursor again" "$out" "$(printf '\033[?25h')"
out=$(AGENTS_AUTORESUME=yes timeout 10 script -qec "bash $start claude" /dev/null </dev/null 2>&1)
check "yes: no menu" "$out" "Start new conversation" no

# pi: sessions live in a folder named after the working directory.
out=$(pty "" pi);                        check "pi: no session starts without a menu" "$out" "Resume last" no ; check "pi: no session starts fresh" "$out" "STUB pi"
mkdir -p "$HOME/.pi/agent/sessions/--tmp-aw-start-test--"
touch "$HOME/.pi/agent/sessions/--tmp-aw-start-test--/s.jsonl"
out=$(plain pi ask);                     check "pi: session resumes" "$out" "STUB pi --continue"

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
    "INSERT INTO session VALUES ('a', '/elsewhere', NULL, NULL)" "INSERT INTO session VALUES ('b', '$work', NULL, 1)" "INSERT INTO session VALUES ('c', '$work', 'a', NULL)"
out=$(plain opencode ask);               check "opencode: only other folder, archived or child sessions: fresh" "$out" "--continue" no
db "$oc" "INSERT INTO session VALUES ('d', '$work', NULL, NULL)"
out=$(plain opencode ask);               check "opencode: session resumes" "$out" "STUB opencode --continue"

cl=$HOME/.cline/data/db/sessions.db
msgs=$HOME/cline-messages
mkdir -p "$msgs"
echo '[{}]' > "$msgs/old.json"; echo '[{}]' > "$msgs/other.json"; echo '[{}]' > "$msgs/sub.json"; : > "$msgs/empty.json"
db "$cl" "CREATE TABLE sessions (session_id TEXT, cwd TEXT, is_subagent INTEGER, parent_session_id TEXT, started_at TEXT, messages_path TEXT)"     "INSERT INTO sessions VALUES ('other', '/elsewhere', 0, NULL, '2030-01-01', '$msgs/other.json')"
out=$(plain cline ask);                  check "cline: only other folder: fresh" "$out" "--id" no
db "$cl" "INSERT INTO sessions VALUES ('empty', '$work', 0, NULL, '2019-01-01', '$msgs/empty.json')"     "INSERT INTO sessions VALUES ('nopath', '$work', 0, NULL, '2019-06-01', NULL)"     "INSERT INTO sessions VALUES ('missing', '$work', 0, NULL, '2019-07-01', '$msgs/gone.json')"
out=$(plain cline ask);                  check "cline: sessions without messages: fresh" "$out" "--id" no
db "$cl" "INSERT INTO sessions VALUES ('old', '$work', 0, NULL, '2020-01-01', '$msgs/old.json')"     "INSERT INTO sessions VALUES ('stub', '$work', 0, NULL, '2021-01-01', '$msgs/empty.json')"     "INSERT INTO sessions VALUES ('sub', '$work', 1, NULL, '2022-01-01', '$msgs/sub.json')"
out=$(plain cline ask);                  check "cline: resumes the newest session of this folder that has messages" "$out" "STUB cline --id old"

hm=$HOME/.hermes/state.db
db "$hm" "CREATE TABLE sessions (source TEXT, message_count INTEGER, git_repo_root TEXT, cwd TEXT)" \
    "INSERT INTO sessions VALUES ('cli', 3, NULL, '/elsewhere')" "INSERT INTO sessions VALUES ('cli', 0, NULL, '$work')" "INSERT INTO sessions VALUES ('cron', 3, NULL, '$work')"
out=$(plain hermes ask);                 check "hermes: other folder, empty or non-cli sessions: fresh" "$out" "-c" no
db "$hm" "INSERT INTO sessions VALUES ('cli', 3, NULL, '$work')"
out=$(plain hermes ask);                 check "hermes: session resumes" "$out" "STUB hermes -c"
exit $fail
