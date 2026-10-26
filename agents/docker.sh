#!/usr/bin/env bash
# Sourced by start.sh (ADR 24). With AGENTS_DOCKER=remote-docker, docker_up gives this container its
# own remote-docker client: a key enrolled in the user's account, a background session, DOCKER_HOST.
# docker_down ends the session and removes the key again.
#
# One key per container, because a key is one client of the workspace: two sessions on one key
# collide on the workspace's tunnel port. The "seed" key (shared/remote-docker/seed, enrolled once
# with AGENTS_DOCKER_TOKEN) only mints single-use tokens; each container redeems one for a fresh
# key in a container-local state dir. Without Docker (not set, not enrolled, any failure) the agent
# still starts; docker_up prints one line and leaves docker_active empty.
#
# Overridable for tests: AGENTS_DOCKER_SEED, AGENTS_DOCKER_TIMEOUT (seconds to wait, default 60).

# shellcheck disable=SC2034 # read by start.sh
docker_active=
docker_dir=
docker_fp=

docker_say() { echo "agent-workspace docker: $*" >&2; }

# remote-docker commands as the seed key (token minting) or as this container's key.
rd_seed() { REMOTE_DOCKER_STATE_DIR=$docker_seed REMOTE_DOCKER_ENDPOINT=$docker_dir/seed.sock remote-docker "$@"; }
rd_own() { REMOTE_DOCKER_STATE_DIR=$docker_dir/state REMOTE_DOCKER_ENDPOINT=$docker_dir/docker.sock remote-docker "$@"; }

# A token out of whatever was pasted: the bare rdt1.… or the whole `docker remote create … --token rdt1.…` line.
docker_token() { grep -Eo 'rdt1\.[^[:space:]]+' <<<"$1" | head -n 1; }

docker_up() {
    [ "${AGENTS_DOCKER:-}" = remote-docker ] || return 0
    docker_seed=${AGENTS_DOCKER_SEED:-/home/agent/.remote-docker/seed}
    local token note
    token=$(docker_token "${AGENTS_DOCKER_TOKEN:-}")
    # The agent must not see the token; it is spent below or stale.
    unset AGENTS_DOCKER_TOKEN
    command -v remote-docker >/dev/null || { docker_say "remote-docker is not installed in this image; continuing without Docker."; return 0; }
    mkdir -p "$docker_seed" || { docker_say "cannot write $docker_seed; continuing without Docker."; return 0; }

    if [ ! -e "$docker_seed/enrolled" ]; then
        if [ -z "$token" ]; then
            docker_say "not enrolled; continuing without Docker. On your computer run 'remote-docker remote token create', put the rdt1.… token in .env as AGENTS_DOCKER_TOKEN, and start again."
            return 0
        fi
        # The invite carries the workspace's address, REMOTE_DOCKER_HOST overrides it.
        if ! out=$(rd_seed remote create aw --token "$token" --no-context 2>&1 </dev/null); then
            docker_say "enrolling the seed key failed; continuing without Docker: $(tail -n 3 <<<"$out" | tr '\n' ' ' | sed "s/$token/<token>/g")"
            return 0
        fi
        cp "$HOME/.remote-docker.json" "$docker_seed/remote-docker.json" 2>/dev/null
        : >"$docker_seed/enrolled"
        docker_say "enrolled; you can remove AGENTS_DOCKER_TOKEN from .env."
    fi

    if ! docker_dir=$(mktemp -d /tmp/remote-docker.XXXXXX) || ! mkdir -p "$docker_dir/state"; then
        docker_say "no scratch space; continuing without Docker."
        docker_cleanup_dir
        return 0
    fi
    # Workspace address, user and host key of the seed enrolment; REMOTE_DOCKER_* variables still win.
    [ -f "$docker_seed/remote-docker.json" ] && [ ! -e "$HOME/.remote-docker.json" ] && cp "$docker_seed/remote-docker.json" "$HOME/.remote-docker.json"
    [ -f "$docker_seed/known_hosts" ] && cp "$docker_seed/known_hosts" "$docker_dir/state/known_hosts"

    # The note and the hostname-based key comment name this container in `remote token ls` and `remote key ls`.
    note=${HOSTNAME:-aw-container}
    if ! out=$(rd_seed remote token create --note "$note" 2>&1 </dev/null) || ! token=$(docker_token "$out") || [ -z "$token" ]; then
        docker_say "minting a token failed; continuing without Docker: $(tail -n 3 <<<"$out" | tr '\n' ' ')"
        docker_cleanup_dir
        return 0
    fi
    if ! out=$(rd_own remote create aw --token "$token" --no-context 2>&1 </dev/null); then
        docker_say "enrolling this container failed; continuing without Docker: $(tail -n 3 <<<"$out" | tr '\n' ' ' | sed "s/$token/<token>/g")"
        docker_cleanup_dir
        return 0
    fi
    docker_active=1
    docker_fp=$(rd_own remote key ls 2>/dev/null | awk '/this machine/ { print $1; exit }')

    export REMOTE_DOCKER_STATE_DIR=$docker_dir/state REMOTE_DOCKER_ENDPOINT=$docker_dir/docker.sock
    if ! rd_own remote start >/dev/null 2>&1 </dev/null; then
        docker_say "starting the session failed; continuing without Docker."
        docker_down
        return 0
    fi
    local waited=0 timeout=${AGENTS_DOCKER_TIMEOUT:-60}
    until rd_own remote status >/dev/null 2>&1 </dev/null; do
        if [ "$waited" -ge "$timeout" ]; then
            docker_say "the workspace did not answer within ${timeout}s (see 'remote-docker remote status'); continuing without Docker."
            docker_down
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    export DOCKER_HOST=unix://$docker_dir/docker.sock
}

docker_cleanup_dir() { [ -z "$docker_dir" ] || rm -rf "$docker_dir"; docker_dir=; }

# Ends the session and removes this container's key from the account (needs -f: it is the key in use).
docker_down() {
    [ -n "$docker_dir" ] || return 0
    rd_own remote stop -f >/dev/null 2>&1 </dev/null
    if [ -n "$docker_fp" ]; then
        rd_own remote key rm "$docker_fp" -f >/dev/null 2>&1 </dev/null ||
            docker_say "could not remove this container's key $docker_fp; 'remote-docker remote key rm' on your computer does."
    fi
    docker_cleanup_dir
    docker_active=
    unset DOCKER_HOST REMOTE_DOCKER_STATE_DIR REMOTE_DOCKER_ENDPOINT
}
