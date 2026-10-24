# shellcheck shell=bash
# What agent-workspace needs to know about claude. Sourced by start.sh (harness container) and
# launch.sh (base container); the host launchers read the dirs= line, so keep it a plain one.
# shellcheck disable=SC2034 # dirs and picker are read by the scripts that source this

# State dirs under agents/claude/ that compose bind-mounts; the launchers create them.
dirs="config"
# The harness's own session picker; empty if it has none at startup.
picker=(claude --resume)

# Sets `resume` (the command) when there is a conversation for $PWD, else returns 1.
# A harness's own "continue" fails or falls back to another folder's session when there is none.
find_session() {
    local key
    # Folder name with every other character replaced; Claude shortens names over
    # 200 characters with a hash, which isn't reproduced: no resume then.
    key=${PWD//[^a-zA-Z0-9]/-}
    [ ${#key} -le 200 ] || return 1
    compgen -G "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$key/*.jsonl" >/dev/null || return 1
    resume=(claude --continue)
}
