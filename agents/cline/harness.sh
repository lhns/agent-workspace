# shellcheck shell=bash
# What agent-workspace needs to know about cline (see agents/claude/harness.sh for the format).
# shellcheck disable=SC2034 # dirs and picker are read by the scripts that source this

dirs="config"
picker=(cline history)

# Uses sql() from start.sh. No continue flag; the session index records each session's folder.
# A session counts once it has written messages (every launch adds a row).
find_session() {
    local rows id sid path
    rows=$(sql "$HOME/.cline/data/db/sessions.db" \
        "SELECT session_id, messages_path FROM sessions WHERE cwd = ? AND is_subagent = 0 AND parent_session_id IS NULL AND COALESCE(messages_path, '') != '' ORDER BY started_at DESC" \
        "$PWD") || return 1
    id=
    while IFS=$'\t' read -r sid path; do
        if [ -s "$path" ]; then id=$sid; break; fi
    done <<<"$rows"
    [ -n "$id" ] || return 1
    resume=(cline --id "$id")
}
