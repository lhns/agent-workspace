#!/usr/bin/env bash
# Installs the `agent-workspace` command for this user: ~/.local/bin/agent-workspace, which starts
# the launcher with the current folder as the workspace. Writes nothing else. No Docker needed.
#   ./install.sh [--update | --uninstall]
# Already installed: asks whether to update (the default, e.g. after moving this repo), remove or
# cancel; without a terminal it updates. --update / --uninstall skip the question.
# Windows: install.bat. Remove it again with ./uninstall.sh.
set -eu
repo=$(cd "$(dirname "$0")" && pwd -P)
bin=$HOME/.local/bin
shim=$bin/agent-workspace

action=''
case "${1:-}" in
    '') ;;
    --update) action=update ;;
    --uninstall) action=remove ;;
    -h | --help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option $1 (use --update or --uninstall)" >&2; exit 1 ;;
esac

# The repo path the existing shim points to ('\'' is an escaped single quote).
current() {
    sed -n "s/^WORKSPACE_DIR=\$PWD exec '\(.*\)\/run-agent\.sh' \"\$@\"\$/\1/p" "$shim" | sed "s/'\\\\''/'/g"
}

uninstall() {
    if [ ! -e "$shim" ]; then echo "agent-workspace is not installed"; return 0; fi
    rm -f "$shim"
    echo "Removed $shim"
}

install() {
    local quoted
    mkdir -p "$bin"
    quoted=$(printf '%s' "$repo/run-agent.sh" | sed "s/'/'\\\\''/g")
    # shellcheck disable=SC2016 # $PWD and $@ are for the shim to expand
    printf '#!/bin/sh\nWORKSPACE_DIR=$PWD exec '\''%s'\'' "$@"\n' "$quoted" >"$shim"
    chmod +x "$shim"
    echo "Installed $shim -> $repo"
    case ":$PATH:" in
        *":$bin:"*) ;;
        *) echo "Note: $bin is not on your PATH; add it to your shell profile, e.g. export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
    esac
}

if [ "$action" = remove ]; then uninstall; exit 0; fi
if [ -z "$action" ] && [ -e "$shim" ]; then
    if [ -t 0 ]; then
        printf 'agent-workspace is already installed (-> %s). [U]pdate / [r]emove / [c]ancel? ' "$(current)"
        read -r answer || answer=''
        case $answer in
            '' | [Uu]*) ;;
            [Rr]*) uninstall; exit 0 ;;
            *) echo "Nothing changed"; exit 0 ;;
        esac
    fi
fi
install
