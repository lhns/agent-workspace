# shellcheck shell=bash
# What agent-workspace needs to know about cline (see agents/claude/harness.sh for the format).
# shellcheck disable=SC2034 # dirs and picker are read by the scripts that source this

dirs="config"
picker=(cline history)
# Where the harness reads global instructions; start.sh writes the generated file there.
instructions="$HOME/.agents/AGENTS.md"

# cline reads no API settings from the environment. On start, make its provider from the environment:
# anthropic from ANTHROPIC_API_KEY (or ANTHROPIC_AUTH_TOKEN), ANTHROPIC_BASE_URL and ANTHROPIC_MODEL, else
# openai-compatible from OPENAI_API_KEY, OPENAI_BASE_URL (default https://api.openai.com/v1) and
# OPENAI_MODEL. A first setup without a model uses cline's default for the provider. .env stays the source
# of truth: a set variable overwrites the stored value on every start, an unset model keeps the stored one.
# A provider picked in cline is left alone (a Cline account login counts as none).
# The file is only created by `cline auth` (a hand-written one is reset); jq patches it afterwards.
prepare() {
    local file="$HOME/.cline/data/settings/providers.json" id auth default key url model tmp last
    if [ -n "${ANTHROPIC_API_KEY:-${ANTHROPIC_AUTH_TOKEN:-}}" ]; then
        id=anthropic auth=anthropic default=claude-sonnet-5-5 model=${ANTHROPIC_MODEL:-} url=""
        key=${ANTHROPIC_API_KEY:-$ANTHROPIC_AUTH_TOKEN}
        # cline's baseUrl includes /v1; ANTHROPIC_BASE_URL (Claude Code) does not.
        [ -z "${ANTHROPIC_BASE_URL:-}" ] || url="${ANTHROPIC_BASE_URL%/}/v1"
    elif [ -n "${OPENAI_API_KEY:-}" ]; then
        # `cline auth -p openai` makes the openai-compatible provider; OPENAI_BASE_URL includes /v1 already.
        id=openai-compatible auth=openai default=gpt-4o model=${OPENAI_MODEL:-} key=$OPENAI_API_KEY
        url=${OPENAI_BASE_URL:-https://api.openai.com/v1}
    else
        return 0
    fi
    last=$(jq -r '.lastUsedProvider // "cline"' "$file" 2>/dev/null || echo cline)
    case $last in cline | anthropic | openai-compatible) ;; *) return 0 ;; esac
    if ! CLINE_ID=$id jq -e '.providers[env.CLINE_ID]' "$file" >/dev/null 2>&1; then
        cline auth -p "$auth" -k "$key" -m "${model:-$default}" >/dev/null 2>&1 \
            || { echo "cline: could not set up the $id provider from the environment." >&2; return 0; }
    fi
    tmp=$(mktemp "$file.XXXXXX") || return 0
    # The values reach jq through its environment only, not its arguments (visible in ps).
    if CLINE_ID=$id CLINE_KEY=$key CLINE_URL=$url CLINE_MODEL=$model jq \
        '.lastUsedProvider = env.CLINE_ID
        | .providers[env.CLINE_ID].settings |= (.apiKey = env.CLINE_KEY
            | if env.CLINE_URL == "" then del(.baseUrl) else .baseUrl = env.CLINE_URL end
            | if env.CLINE_MODEL == "" then . else .model = env.CLINE_MODEL end)' "$file" >"$tmp" 2>/dev/null \
        && mv -f "$tmp" "$file"; then
        return 0
    fi
    rm -f "$tmp"
    echo "cline: could not update the $id provider from the environment." >&2
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
