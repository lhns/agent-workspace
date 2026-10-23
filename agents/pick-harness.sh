#!/usr/bin/env bash
# Compose's command for the base service: menu to pick the harness, run from the launchers when
# none is given. Records the choice in shared/.last-harness, which the launcher reads back
# (exit codes are not usable: compose exits 1 on its own errors).
# State lines are "<workspace key><TAB><harness>", one for this workspace and one "*" for anywhere,
# so the first menu entry is the harness last used here, else the one last used anywhere.
# Exit: 0 chosen, 2 no terminal and nothing to default to, 130 Ctrl-C.
set -u
dir=${AGENTS_DIR:-/opt/agents}
state=${AGENTS_STATE:-/opt/shared/.last-harness}
key=${AGENTS_WORKSPACE_TARGET:?AGENTS_WORKSPACE_TARGET is not set}
# shellcheck source=agents/menu.sh
. "$dir/menu.sh"

names=()
while read -r name _; do
    case $name in '' | '#'*) ;; *) names+=("$name") ;; esac
done <"$dir/harness-dirs"

# The harness recorded for a key, if it still exists.
recorded() {
    local h
    [ -f "$state" ] || return 1
    h=$(K=$1 awk -F'\t' '$1 == ENVIRON["K"] { print $2; exit }' "$state")
    printf '%s\n' "${names[@]}" | grep -qxF -- "$h" || return 1
    printf '%s\n' "$h"
}
last=$(recorded "$key") || last=$(recorded '*') || last=

if [ -t 0 ]; then
    order=() labels=()
    if [ -n "$last" ]; then order+=("$last") labels+=("$last (last used)"); fi
    for name in "${names[@]}"; do
        [ "$name" = "$last" ] || { order+=("$name"); labels+=("$name"); }
    done
    choose "Select the agent harness to run in $key" "${labels[@]}"
    pick=${order[sel]}
else
    # Without a terminal (CI, pipes) there is nobody to ask: the last used one.
    [ -n "$last" ] || { echo "No terminal and no harness recorded; pass one: ${names[*]}" >&2; exit 2; }
    pick=$last
fi

new=$({ [ -f "$state" ] && K=$key awk -F'\t' '$1 != ENVIRON["K"] && $1 != "*"' "$state"; printf '%s\t%s\n%s\t%s\n' "$key" "$pick" '*' "$pick"; })
printf '%s\n' "$new" >"$state"
