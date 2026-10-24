# shellcheck shell=bash
# What agent-workspace needs to know about opencode (see agents/claude/harness.sh for the format).
# shellcheck disable=SC2034 # dirs and picker are read by the scripts that source this

dirs="config data"
# No session picker at startup; use /sessions inside opencode.
picker=()

# Uses sql() from start.sh.
find_session() {
    sql "${XDG_DATA_HOME:-$HOME/.local/share}/opencode/opencode.db" \
        "SELECT 1 FROM session WHERE directory = ? AND parent_id IS NULL AND time_archived IS NULL" \
        "$PWD" >/dev/null || return 1
    resume=(opencode --continue)
}
