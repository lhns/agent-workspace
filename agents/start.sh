#!/usr/bin/env bash
# Compose's command for every harness: agents-start.sh <harness>. Resumes the last conversation
# for the current folder (the workspace is mounted at its host path, so folders differ) or
# starts fresh, depending on AGENTS_AUTORESUME (ask, the default | yes | no). Launcher
# arguments replace this command, so passing the harness command yourself never resumes.
set -u
h=${1:?usage: agents-start.sh <harness>}

# Rows of a SQLite query, columns tab-separated; fails on a missing db, no rows or any error.
sql() {
    [ -f "$1" ] || return 1
    python3 - "$@" <<'PY' 2>/dev/null
import sqlite3, sys
db, query, *args = sys.argv[1:]
rows = sqlite3.connect("file:" + db + "?mode=ro", uri=True).execute(query, args).fetchall()
if not rows:
    sys.exit(1)
for row in rows:
    print("\t".join(map(str, row)))
PY
}

# Sets `resume` (the command) when this harness has a conversation for $PWD, else returns 1.
# A harness's own "continue" fails or falls back to another folder's session when there is none.
find_session() {
    local key dir id rows sid path
    case $h in
        claude)
            # Folder name with every other character replaced; Claude shortens names over
            # 200 characters with a hash, which isn't reproduced: no resume then.
            key=${PWD//[^a-zA-Z0-9]/-}
            [ ${#key} -le 200 ] || return 1
            compgen -G "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$key/*.jsonl" >/dev/null || return 1
            resume=(claude --continue) ;;
        pi)
            key=${PWD#/}
            key=${key//[\/\\:]/-}
            compgen -G "$HOME/.pi/agent/sessions/--$key--/*" >/dev/null || return 1
            resume=(pi --continue) ;;
        opencode)
            sql "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db" \
                "SELECT 1 FROM session WHERE directory = ? AND parent_id IS NULL AND time_archived IS NULL" \
                "$PWD" >/dev/null || return 1
            resume=(opencode --continue) ;;
        cline)
            # No continue flag; the session index records each session's folder.
            # A session counts once it has written messages (every launch adds a row).
            rows=$(sql "$HOME/.cline/data/db/sessions.db" \
                "SELECT session_id, messages_path FROM sessions WHERE cwd = ? AND is_subagent = 0 AND parent_session_id IS NULL AND COALESCE(messages_path, '') != '' ORDER BY started_at DESC" \
                "$PWD") || return 1
            id=
            while IFS=$'\t' read -r sid path; do
                if [ -s "$path" ]; then id=$sid; break; fi
            done <<<"$rows"
            [ -n "$id" ] || return 1
            resume=(cline --id "$id") ;;
        hermes)
            # Bare -c falls back to the newest session of any folder. Hermes' workspace is the
            # git root, else the folder; empty launch stubs don't count.
            dir=$(git rev-parse --show-toplevel 2>/dev/null) || dir=$PWD
            sql "${HERMES_HOME:-$HOME/.hermes}/state.db" \
                "SELECT 1 FROM sessions WHERE source IN ('cli', 'oneshot') AND message_count > 0 AND (git_repo_root = ?1 OR (COALESCE(git_repo_root, '') = '' AND cwd = ?1))" \
                "$dir" >/dev/null || return 1
            resume=(hermes -c) ;;
        *) return 1 ;;
    esac
}

# choose(): arrow-key menu, shared with the harness picker.
# shellcheck source=agents/menu.sh
. "${AGENTS_MENU:-/usr/local/lib/agents-menu.sh}"

mode=$(tr '[:upper:]' '[:lower:]' <<<"${AGENTS_AUTORESUME:-}")
case $mode in
    '' | ask) mode=ask ;;
    yes | no) ;;
    *) echo "AGENTS_AUTORESUME='$AGENTS_AUTORESUME' is not ask, yes or no; asking." >&2; mode=ask ;;
esac

cmd=("$h")
resume=()
if [ "$mode" != no ] && find_session; then
    # Without a terminal (CI, pipes) there is nobody to ask: resume.
    if [ "$mode" = yes ] || ! [ -t 0 ]; then
        cmd=("${resume[@]}")
    else
        # The harness's own session picker, for older conversations; opencode has none at startup.
        case $h in
            claude | pi) pick=("$h" --resume) ;;
            cline) pick=(cline history) ;;
            hermes) pick=(hermes sessions browse) ;;
            *) pick=() ;;
        esac
        if [ ${#pick[@]} -gt 0 ]; then
            choose "Resume last conversation" "Choose another conversation" "Start new conversation"
        else
            choose "Resume last conversation" "Start new conversation"
        fi
        # The last item, new, keeps the plain command.
        case $sel in
            0) cmd=("${resume[@]}") ;;
            1) [ ${#pick[@]} -eq 0 ] || cmd=("${pick[@]}") ;;
        esac
    fi
fi
exec "${cmd[@]}"
