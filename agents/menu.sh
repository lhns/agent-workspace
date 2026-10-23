#!/usr/bin/env bash
# Sourced by start.sh (harness containers) and pick-harness.sh (base container).

# Arrow-key menu over the arguments; sets `sel` to the chosen index. Drawn on the terminal,
# cleared afterwards.
choose() {
    local items=("$@") key rest out=/dev/tty n=$#
    sel=0
    { : >/dev/tty; } 2>/dev/null || out=/dev/stderr
    draw() {
        local i
        for ((i = 0; i < n; i++)); do
            if [ "$i" = "$sel" ]; then printf '\e[7m> %s\e[0m\e[K\n' "${items[i]}"; else printf '  %s\e[K\n' "${items[i]}"; fi
        done
    }
    trap 'printf "\e[?25h" >"$out"; exit 130' INT
    { printf '\e[?25l'; draw; } >"$out"
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
        { printf '\e[%dA' "$n"; draw; } >"$out"
    done
    printf '\e[%dA\e[J\e[?25h' "$n" >"$out"
    trap - INT
}
