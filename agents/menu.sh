#!/usr/bin/env bash
# Sourced by start.sh (harness containers) and pick-harness.sh (base container).

# Arrow-key menu: choose <title> <item>...; sets `sel` to the chosen item's index. Drawn on the
# terminal with a key hint below the items, cleared afterwards.
choose() {
    local title=$1 key rest out=/dev/tty
    shift
    local items=("$@") n=$#
    sel=0
    { : >/dev/tty; } 2>/dev/null || out=/dev/stderr
    draw() {
        local i
        for ((i = 0; i < n; i++)); do
            if [ "$i" = "$sel" ]; then printf '\e[7m> %s\e[0m\e[K\n' "${items[i]}"; else printf '  %s\e[K\n' "${items[i]}"; fi
        done
        # ASCII only: the terminal on the other side of docker may not be UTF-8.
        printf '\e[2m  Up/Down to move, Enter to select, Ctrl-C to cancel\e[0m\e[K
'
    }
    trap 'printf "\e[?25h" >"$out"; exit 130' INT
    { printf '\e[?25l\e[1m%s\e[0m\e[K
' "$title"; draw; } >"$out"
    while IFS= read -rsn1 key; do
        if [ "$key" = $'\e' ]; then
            # Arrow keys are ESC [ A/B (ESC O A/B in application mode).
            read -rsn2 -t 0.1 rest
            case $rest in
                '[A' | 'OA') [ "$sel" = 0 ] || ((sel--)) ;;
                '[B' | 'OB') [ "$sel" = $((n - 1)) ] || ((sel++)) ;;
            esac
        elif [ -z "$key" ]; then
            break
        fi
        { printf '\e[%dA' $((n + 1)); draw; } >"$out"
    done
    printf '\e[%dA\e[J\e[?25h' $((n + 2)) >"$out"
    trap - INT
}
