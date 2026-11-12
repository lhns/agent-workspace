# shellcheck shell=bash
# What agent-workspace needs to know about cline (see agents/claude/harness.sh for the format).
# shellcheck disable=SC2034 # dirs and picker are read by the scripts that source this

dirs="config"
picker=(cline history)
# Where the harness reads global instructions; start.sh writes the generated file there.
instructions="$HOME/.agents/AGENTS.md"

# cline reads no API settings from the environment. On start, make its anthropic provider from
# ANTHROPIC_API_KEY (or ANTHROPIC_AUTH_TOKEN) and ANTHROPIC_BASE_URL; .env stays the source of truth
# for the key and URL, the model is kept once chosen. A provider picked in cline is left alone.
# The file is only created by `cline auth` (a hand-written one is reset); jq patches it afterwards.
prepare() {
    local file="$HOME/.cline/data/settings/providers.json" tmp last
    export CLINE_KEY=${ANTHROPIC_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}
    [ -n "$CLINE_KEY" ] || return 0
    # cline's baseUrl includes /v1; ANTHROPIC_BASE_URL (Claude Code) does not.
    export CLINE_URL=
    [ -z "${ANTHROPIC_BASE_URL:-}" ] || CLINE_URL="${ANTHROPIC_BASE_URL%/}/v1"
    if ! jq -e '.providers.anthropic' "$file" >/dev/null 2>&1; then
        last=$(jq -r '.lastUsedProvider // "cline"' "$file" 2>/dev/null || echo cline)
        [ "$last" = cline ] || return 0
        cline auth -p anthropic -k "$CLINE_KEY" -m "${ANTHROPIC_MODEL:-claude-sonnet-5-5}" >/dev/null 2>&1 \
            || { echo "cline: could not set up the anthropic provider from the environment." >&2; return 0; }
    fi
    tmp=$(mktemp "$file.XXXXXX") || return 0
    if jq '.providers.anthropic.settings.apiKey = env.CLINE_KEY
           | if env.CLINE_URL == "" then del(.providers.anthropic.settings.baseUrl)
             else .providers.anthropic.settings.baseUrl = env.CLINE_URL end' "$file" >"$tmp" 2>/dev/null \
        && mv -f "$tmp" "$file"; then :
    else
        rm -f "$tmp"
        echo "cline: could not update the anthropic provider from the environment." >&2
    fi
    unset CLINE_KEY CLINE_URL
}

# Uses sql() from start.sh. No continue flag; the session index records each session's folder.
# A session counts once it has written messages (every launch adds a row).
find_session() {
    local rows id sid path
    rows=$(sql "$HOME/.cline/data/db/sessions.db" \
        "SELECT session_id, messages_path FROM sessions WHERE cwd = ? AND is_subagent = 0 AND parent_session_id IS NULL AND COALESCE(messages_path, '') != '' ORDER BY started_at DESC" \
        "$(native_cwd)") || return 1
    id=
    while IFS=$'\t' read -r sid path; do
        # messages_path is in the harness's own form: C:\... on Windows.
        if [ -s "$(posix_path "$path")" ]; then id=$sid; break; fi
    done <<<"$rows"
    [ -n "$id" ] || return 1
    resume=(cline --id "$id")
}
