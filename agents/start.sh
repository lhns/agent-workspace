#!/usr/bin/env bash
# Compose's command for every harness: agents-start.sh <harness>. Resumes the last conversation
# for the current folder (the workspace is mounted at its host path, so folders differ) or
# starts fresh, depending on the resume mode (ask, the default | yes | no | pick). Arguments for
# the harness go after the resume or picker arguments (claude --continue --model x).
# Never asks without a terminal or with AGENTS_NONINTERACTIVE (non-empty): resumes if there is a session.
#
# The launcher's choices arrive in the launch dir (agents/launch.sh writes it, mounted at
# /opt/launch/$AGENTS_RUN_ID): args (NUL-separated), mode, noninteractive, exec. Without one
# (plain `docker compose run`) there are no arguments and AGENTS_AUTORESUME decides.
# Per-harness knowledge (find_session, picker) comes from the mounted agents/<harness>/harness.sh.
set -u
h=${1:?usage: agents-start.sh <harness>}

# docker_up / docker_down: Docker for the agent when AGENTS_DOCKER is set (agents/docker.sh).
# shellcheck source=agents/docker.sh
. /usr/local/lib/agents-docker.sh

# Starts the command in place of this script. With a Docker session it runs as a child instead, so the
# session and this container's key can be ended after it; SIGTERM (docker stop) is passed on.
launch_cmd() {
    # Stopped while waiting for the workspace: still remove the key.
    trap 'docker_down; exit 143' TERM HUP INT
    docker_up
    trap - TERM HUP INT
    [ -n "$docker_active" ] || exec "$@"
    "$@" <&0 &
    local child=$! status
    trap 'kill -TERM "$child" 2>/dev/null' TERM HUP
    trap : INT
    while true; do
        wait "$child"; status=$?
        kill -0 "$child" 2>/dev/null || break
    done
    docker_down
    exit "$status"
}

launch=${AGENTS_LAUNCH_DIR:-/opt/launch/${AGENTS_RUN_ID:-none}}
args=()
mode=${AGENTS_AUTORESUME:-}
if [ -d "$launch" ]; then
    [ ! -f "$launch/args" ] || while IFS= read -r -d '' a; do args+=("$a"); done <"$launch/args"
    # --exec: run the command instead of the harness (still inside compose's entrypoint).
    if [ -e "$launch/exec" ]; then launch_cmd "${args[@]}"; fi
    [ ! -f "$launch/mode" ] || mode=$(<"$launch/mode")
    [ ! -e "$launch/noninteractive" ] || AGENTS_NONINTERACTIVE=1
fi

# Rows of a SQLite query, columns tab-separated; fails on a missing db, no rows or any error.
# shellcheck disable=SC2329 # called from the harness.sh files, which shellcheck cannot follow from here
sql() {
    [ -f "$1" ] || return 1
    python3 - "$@" <<'PY' 2>/dev/null
import sqlite3, sys
db, query, *args = sys.argv[1:]
rows = sqlite3.connect("file:" + db + "?mode=ro", uri=True).execute(query, args).fetchall()
if not rows:
    sys.exit(1)
for row in rows:
    print("\t".join(map(str, row)))
PY
}

# find_session and picker for this harness.
# shellcheck source=agents/claude/harness.sh
. "${AGENTS_HARNESS_FILE:-/usr/local/lib/agents-harness.sh}"

# choose(): arrow-key menu, shared with launch.sh.
# shellcheck source=agents/menu.sh
. /usr/local/lib/agents-menu.sh

raw=$mode
mode=$(tr '[:upper:]' '[:lower:]' <<<"$mode")
case $mode in
    '' | ask) mode=ask ;;
    yes | no | pick) ;;
    *) echo "AGENTS_AUTORESUME='$raw' is not ask, yes, no or pick; asking." >&2; mode=ask ;;
esac

cmd=("$h")
resume=()
if [ "$mode" = pick ]; then
    [ ${#picker[@]} -gt 0 ] || { echo "$h has no session picker at startup; use /sessions inside it." >&2; exit 1; }
    { [ -t 0 ] && [ -z "${AGENTS_NONINTERACTIVE:-}" ]; } || { echo "--sessions needs a terminal and can't be combined with -y." >&2; exit 1; }
    cmd=("${picker[@]}")
elif [ "$mode" != no ] && find_session; then
    # Without a terminal (CI, pipes) or non-interactive there is nobody to ask: resume.
    if [ "$mode" = yes ] || ! [ -t 0 ] || [ -n "${AGENTS_NONINTERACTIVE:-}" ]; then
        cmd=("${resume[@]}")
    else
        title="$h has an earlier conversation in $PWD"
        if [ ${#picker[@]} -gt 0 ]; then
            choose "$title" "Resume last conversation" "Choose another conversation" "Start new conversation"
        else
            choose "$title" "Resume last conversation" "Start new conversation"
        fi
        # The last item, new, keeps the plain command.
        case $sel in
            0) cmd=("${resume[@]}") ;;
            1) [ ${#picker[@]} -eq 0 ] || cmd=("${picker[@]}") ;;
        esac
    fi
fi
launch_cmd "${cmd[@]}" ${args[@]+"${args[@]}"}
