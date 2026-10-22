#!/usr/bin/env bash
# Compose's command for every harness: agents-start.sh <harness>. Resumes the last conversation
# for the current folder (the workspace is mounted at its host path, so folders differ) or
# starts fresh, depending on AGENTS_AUTORESUME (ask, the default | yes | no). Launcher
# arguments replace this command, so passing the harness command yourself never resumes.
set -u
h=${1:?usage: agents-start.sh <harness>}

# First value of a SQLite query; fails on a missing db, no match or any error.
sql1() {
    [ -f "$1" ] || return 1
    python3 - "$@" <<'PY' 2>/dev/null
import sqlite3, sys
db, query, *args = sys.argv[1:]
row = sqlite3.connect("file:" + db + "?mode=ro", uri=True).execute(query, args).fetchone()
if not row:
    sys.exit(1)
print(row[0])
PY
}

# Sets `resume` (the command) when this harness has a conversation for $PWD, else returns 1.
# A harness's own "continue" fails or falls back to another folder's session when there is none.
find_session() {
    local key dir id
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
            sql1 "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db" \
                "SELECT 1 FROM session WHERE directory = ? AND parent_id IS NULL AND time_archived IS NULL" \
                "$PWD" >/dev/null || return 1
            resume=(opencode --continue) ;;
        cline)
            # No continue flag; the session index records each session's folder.
            id=$(sql1 "$HOME/.cline/data/db/sessions.db" \
                "SELECT session_id FROM sessions WHERE cwd = ? AND is_subagent = 0 AND parent_session_id IS NULL ORDER BY started_at DESC" \
                "$PWD") || return 1
            resume=(cline --id "$id") ;;
        hermes)
            # Bare -c falls back to the newest session of any folder. Hermes' workspace is the
            # git root, else the folder; empty launch stubs don't count.
            dir=$(git rev-parse --show-toplevel 2>/dev/null) || dir=$PWD
            sql1 "${HERMES_HOME:-$HOME/.hermes}/state.db" \
                "SELECT 1 FROM sessions WHERE source IN ('cli', 'oneshot') AND message_count > 0 AND (git_repo_root = ?1 OR (COALESCE(git_repo_root, '') = '' AND cwd = ?1))" \
                "$dir" >/dev/null || return 1
            resume=(hermes -c) ;;
        *) return 1 ;;
    esac
}

# Arrow-key menu; returns 0 for resume, 1 for new. Drawn on the terminal, cleared afterwards.
choose() {
    local sel=0 key rest out=/dev/tty
    { : >/dev/tty; } 2>/dev/null || out=/dev/stderr
    draw() {
        local i
        for i in 0 1; do
            if [ "$i" = "$sel" ]; then printf '\e[7m> %s\e[0m\e[K\n' "${items[i]}"; else printf '  %s\e[K\n' "${items[i]}"; fi
        done
    }
    local items=("Resume last conversation" "Start new conversation")
    trap 'printf "\e[?25h" >"$out"; exit 130' INT
    { printf '\e[?25l'; draw; } >"$out"
    while IFS= read -rsn1 key; do
        if [ "$key" = $'\e' ]; then
            # Arrow keys are ESC [ A/B (ESC O A/B in application mode).
            read -rsn2 -t 0.1 rest
            case $rest in
                '[A' | 'OA') sel=0 ;;
                '[B' | 'OB') sel=1 ;;
            esac
        elif [ -z "$key" ]; then
            break
        fi
        { printf '\e[2A'; draw; } >"$out"
    done
    printf '\e[2A\e[J\e[?25h' >"$out"
    trap - INT
    [ "$sel" = 0 ]
}

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
    if [ "$mode" = yes ] || ! [ -t 0 ] || choose; then cmd=("${resume[@]}"); fi
fi
exec "${cmd[@]}"
