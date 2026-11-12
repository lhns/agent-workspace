# shellcheck shell=bash
# What agent-workspace needs to know about claude. Sourced by start.sh (harness container) and
# launch.sh (base container); the host launchers read the dirs= line, so keep it a plain one.
# shellcheck disable=SC2034 # dirs and picker are read by the scripts that source this

# State dirs under agents/claude/ that compose bind-mounts; the launchers create them.
dirs="config"
# The harness's own session picker; empty if it has none at startup.
picker=(claude --resume)
# Where the harness reads global instructions; start.sh writes the generated file there.
instructions="$HOME/.claude/CLAUDE.md"

# Optional: prepare() runs in the harness container (start.sh only, not launch.sh) before the harness
# starts, also with --exec. Use it to derive the harness's config from the environment; see cline.

# Sets `resume` (the command) when there is a conversation for $PWD, else returns 1.
# A harness's own "continue" fails or falls back to another folder's session when there is none.
find_session() {
    local key
    # The folder in the OS's own form (C:\x on Windows) with every other character replaced;
    # Claude shortens names over 200 characters with a hash, which isn't reproduced: no resume then.
    key=$(native_cwd)
    key=${key//[^a-zA-Z0-9]/-}
    [ ${#key} -le 200 ] || return 1
    compgen -G "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$key/*.jsonl" >/dev/null || return 1
    resume=(claude --continue)
}
