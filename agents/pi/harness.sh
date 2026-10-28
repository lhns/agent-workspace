# shellcheck shell=bash
# What agent-workspace needs to know about pi (see agents/claude/harness.sh for the format).
# shellcheck disable=SC2034 # dirs and picker are read by the scripts that source this

dirs="config"
picker=(pi --resume)
# Where the harness reads global instructions; start.sh writes the generated file there.
instructions="$HOME/.pi/agent/AGENTS.md"

# Sessions live in a folder named after the working directory.
find_session() {
    local key
    key=${PWD#/}
    key=${key//[\/\\:]/-}
    compgen -G "$HOME/.pi/agent/sessions/--$key--/*" >/dev/null || return 1
    resume=(pi --continue)
}
