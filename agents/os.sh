#!/usr/bin/env bash
# Sourced by launch.sh and start.sh. Windows containers run the same scripts under Git Bash
# (MSYS); this is the one place that knows (ADR 26).
# AGENTS_PLATFORM (linux|windows, set by the launchers) wins; the tests use it to play Windows
# on Linux. Without it (plain `docker compose run`) the shell tells: `uname -o` is Msys.

aw_platform=${AGENTS_PLATFORM:-}
if [ -z "$aw_platform" ]; then
    case $(uname -o 2>/dev/null) in Msys) aw_platform=windows ;; *) aw_platform=linux ;; esac
fi
is_windows() { [ "$aw_platform" = windows ]; }

# C:\a\b or C:/a/b -> /c/a/b, the form the scripts compare and the shell uses. Other input stays.
posix_path() {
    local p=${1//\\//} d
    case $p in
        [A-Za-z]:*) d=${p:0:1}; p=/${d,,}${p:2}; printf '%s\n' "${p%/}" ;;
        *) printf '%s\n' "$p" ;;
    esac
}

# /c/a/b -> C:\a\b, what compose and the harnesses are given. Other input stays.
win_path() {
    local d p
    case $1 in
        /[A-Za-z] | /[A-Za-z]/*)
            d=${1:1:1} p=${1:2}
            p=${p:-/}
            printf '%s:%s\n' "${d^^}" "${p//\//\\}" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

# The working directory as the harnesses see it: they key sessions by it, in the OS's own form
# (C:\x on Windows, where $PWD is /c/x).
native_cwd() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -wa .; else pwd; fi
}
