# shellcheck shell=bash
# What agent-workspace needs to know about hermes (see agents/claude/harness.sh for the format).
# shellcheck disable=SC2034 # dirs and picker are read by the scripts that source this

dirs="config"
picker=(hermes sessions browse)

# Uses sql() from start.sh. Bare -c falls back to the newest session of any folder. Hermes'
# workspace is the git root, else the folder; empty launch stubs don't count.
find_session() {
    local dir
    dir=$(git rev-parse --show-toplevel 2>/dev/null) || dir=$PWD
    sql "${HERMES_HOME:-$HOME/.hermes}/state.db" \
        "SELECT 1 FROM sessions WHERE source IN ('cli', 'oneshot') AND message_count > 0 AND (git_repo_root = ?1 OR (COALESCE(git_repo_root, '') = '' AND cwd = ?1))" \
        "$dir" >/dev/null || return 1
    resume=(hermes -c)
}
