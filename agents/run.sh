#!/usr/bin/env bash
# Host side of the launcher: agents/run.sh [--workdir DIR] [options] [harness] [harness args...]. It does what must
# run on the host (.env, workspace path, image pull/build, docker compose); the options, the
# harness menu and shared/.last-harness are agents/launch.sh, run in the base image with the
# arguments untouched. Its result comes back in shared/.launch/<id>. Writes only gitignored paths.
set -eu
# A leading --workdir DIR is the workspace (beats the shell and .env). It is resolved against the
# caller's folder, so before the cd below. The arguments stay untouched: the core skips it.
if [ "${1:-}" = --workdir ]; then
    [ $# -ge 2 ] || { echo "--workdir needs a folder" >&2; exit 1; }
    [ -d "$2" ] || { echo "--workdir '$2' does not exist" >&2; exit 1; }
    WORKSPACE_DIR=$(cd "$2" && pwd -P)
fi
cd "$(dirname "$0")/.."

# .env: created from the example, and refused until the user has edited it.
[ -f .env ] || cp .env.example .env
if cmp -s .env.example .env; then echo "Edit .env first" >&2; exit 1; fi
sed -n 's/^\([A-Z_]*\)=.*/\1/p' .env.example | while read -r k; do
    grep -q "^$k=" .env || echo "Warning: $k is missing in .env (see .env.example)" >&2
done

# Settings: a non-empty shell variable wins over .env, like compose's own interpolation.
envval() { sed -n "s/^$1=//p" .env | tail -n1 | tr -d '\r"'; }
ws=${WORKSPACE_DIR:-$(envval WORKSPACE_DIR)}
if [ -z "$ws" ]; then
    mkdir -p workspace
elif [ ! -d "$ws" ]; then
    echo "WORKSPACE_DIR '$ws' does not exist" >&2; exit 1
fi

# The workspace is mounted at its host path (the container side guards it, see launch.sh).
AGENTS_WORKSPACE_TARGET=$(cd "${ws:-workspace}" && pwd -P)
export AGENTS_WORKSPACE_TARGET
# Git Bash on Windows would hand docker C:/... instead; this is a container path.
export MSYS2_ENV_CONV_EXCL="AGENTS_WORKSPACE_TARGET${MSYS2_ENV_CONV_EXCL:+;$MSYS2_ENV_CONV_EXCL}"

# Prebuilt images come from ghcr.io unless AGENTS_LOCAL_BUILD is non-empty.
local_build=${AGENTS_LOCAL_BUILD:-$(envval AGENTS_LOCAL_BUILD)}
# Prebuilt images are <prefix>-<harness>:<hash>; the base image is <prefix>-base:<hash>.
prefix=${AGENTS_IMAGE_PREFIX:-$(envval AGENTS_IMAGE_PREFIX)}
prefix=${prefix:-ghcr.io/lhns/agent-workspace}

# Without a terminal (CI, pipes) compose can't allocate a tty and fails; -T skips it.
tty=; [ -t 0 ] || tty=-T

# Update an image (base or a harness) only when its Dockerfiles changed since the last time
# (much faster than asking docker). The hash is also the ghcr tag, so a pull gets exactly this
# checkout's image; an edited Dockerfile misses the registry and builds locally. Docker's layer
# cache keeps a local rebuild short. Usage: ensure_image <base|harness> <Dockerfile>...
ensure_image() {
    local name=$1 hashfile new ref pulled=
    shift
    hashfile=agents/$name/.build.sha256
    new=$(cat "$@" | sha256sum | cut -d' ' -f1)
    # A matching hash with the image gone (pruned) counts as changed.
    if [ "$new" = "$(cat "$hashfile" 2>/dev/null)" ] && docker image inspect "agent-workspace-$name" >/dev/null 2>&1; then
        return
    fi
    ref=$prefix-$name:$new
    if [ -z "$local_build" ]; then
        echo "Pulling $name image..."
        if docker pull "$ref"; then
            docker tag "$ref" "agent-workspace-$name"
            docker rmi "$ref" >/dev/null || true
            pulled=1
        else
            echo "No prebuilt $name image available, building locally."
        fi
    fi
    if [ -z "$pulled" ]; then
        echo "Building $name image..."
        if [ "$name" = base ]; then
            docker compose build base
        else
            # Build on the published (or already local) base so the layers are shared.
            ensure_image base agents/base/Dockerfile
            docker compose build "$name"
        fi
    fi
    echo "$new" > "$hashfile"
}

# State dirs, so docker doesn't create them as root. The launch dir is made here (not in the
# container) so this script can delete it afterwards.
AGENTS_RUN_ID=$RANDOM$RANDOM$$
export AGENTS_RUN_ID
launch=shared/.launch/$AGENTS_RUN_ID
mkdir -p shared/git "$launch"
# The container user (uid 1000) writes here, whoever the host user is.
chmod 777 "$launch"
# Leftovers of a killed launcher.
find shared/.launch -mindepth 1 -maxdepth 1 -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
[ -e shared/AGENTS.md ] || : > shared/AGENTS.md
trap 'rm -rf "$launch"' EXIT
trap 'exit 130' INT TERM

# Seed git config from the host once; delete shared/git/config to re-seed.
if [ ! -e shared/git/config ]; then
    : > shared/git/config
    for src in "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config"; do
        if [ -f "$src" ]; then cp "$src" shared/git/config; break; fi
    done
fi

# The core (options, harness menu, last-harness) runs in the base image, with every argument
# untouched: Git Bash must not convert them (env conversion stays).
ensure_image base agents/base/Dockerfile
# Without a terminal the core must not swallow stdin meant for the harness (echo hi | run-agent claude -p).
if [ -n "$tty" ]; then
    MSYS2_ARG_CONV_EXCL='*' docker compose run --rm -T base "$@" </dev/null || exit $?
else
    MSYS2_ARG_CONV_EXCL='*' docker compose run --rm base "$@" || exit $?
fi
result=$(cat "$launch/result" 2>/dev/null || true)
case $result in
    launch) ;;
    done) exit 0 ;; # --help
    *) echo "Launcher core produced no result" >&2; exit 1 ;;
esac

h=$(cat "$launch/harness")
# The workspace path after the core's guard list.
AGENTS_WORKSPACE_TARGET=$(cat "$launch/target")
dirs=$(sed -n 's/^dirs="\(.*\)"$/\1/p' "agents/$h/harness.sh")
for d in $dirs; do mkdir -p "agents/$h/$d"; done
ensure_image "$h" agents/base/Dockerfile "agents/$h/Dockerfile"

# Recorded only now, so a failed pull or build isn't (mv is atomic; the core only computed the content).
mv -f "$launch/last-harness" shared/.last-harness
# Not exec'd: the launch dir is removed afterwards. The harness reads its arguments from it.
rc=0
MSYS2_ARG_CONV_EXCL='*' docker compose run --rm ${tty:+"$tty"} "$h" || rc=$?
exit "$rc"
