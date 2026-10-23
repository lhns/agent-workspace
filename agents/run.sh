#!/usr/bin/env bash
# Shared launcher: agents/run.sh [harness] [args...]. Without a harness (first argument not
# listed in agents/harness-dirs) a menu picks one and all arguments go to it. Writes only
# gitignored paths.
set -eu
cd "$(dirname "$0")/.."
h=
if [ $# -gt 0 ] && grep -q "^$1 " agents/harness-dirs 2>/dev/null; then h=$1; shift; fi

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

# The workspace is mounted at its host path, so harnesses that key sessions by directory keep
# them per host folder. Paths that would hide the container's own directories fall back to /workspace.
target=$(cd "${ws:-workspace}" && pwd -P)
case $target in
    / | /home | /home/agent | /home/agent/* | /usr | /usr/* | /etc | /etc/* | /bin | /bin/* | /sbin | /sbin/* \
        | /lib* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /opt | /opt/* | /var | /var/*)
        echo "Note: $target would hide a container directory; mounting the workspace at /workspace, so conversations are not kept per folder." >&2
        target=/workspace ;;
esac
export AGENTS_WORKSPACE_TARGET=$target
# Git Bash on Windows would hand docker C:/... instead; this is a container path.
export MSYS2_ENV_CONV_EXCL="AGENTS_WORKSPACE_TARGET${MSYS2_ENV_CONV_EXCL:+;$MSYS2_ENV_CONV_EXCL}"

# Prebuilt images come from ghcr.io unless AGENTS_LOCAL_BUILD is non-empty.
local_build=${AGENTS_LOCAL_BUILD:-$(envval AGENTS_LOCAL_BUILD)}
# Prebuilt images are <prefix>-<harness>:<hash>; the base image is <prefix>-base:<hash>.
prefix=${AGENTS_IMAGE_PREFIX:-$(envval AGENTS_IMAGE_PREFIX)}
prefix=${prefix:-ghcr.io/lhns/agent-workspace}

# Without a terminal (CI, pipes) compose can't allocate a tty and fails; -T skips it.
tty=; [ -t 0 ] || tty=-T

# State dirs, so docker doesn't create them as root.
mkdir -p shared/git
[ -e shared/AGENTS.md ] || : > shared/AGENTS.md

# Seed git config from the host once; delete shared/git/config to re-seed.
if [ ! -e shared/git/config ]; then
    : > shared/git/config
    for src in "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config"; do
        if [ -f "$src" ]; then cp "$src" shared/git/config; break; fi
    done
fi

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
        docker compose build base
        [ "$name" = base ] || docker compose build "$name"
    fi
    echo "$new" > "$hashfile"
}

# shared/.last-harness: "<workspace><TAB><harness>" for this workspace and "*<TAB>..." for
# anywhere, so the menu offers the last used one first; the picker writes the same format.
state=shared/.last-harness
if [ -z "$h" ]; then
    ensure_image base agents/base/Dockerfile
    docker compose run --rm ${tty:+"$tty"} base || exit $?
    h=$(K=$target awk -F'\t' '$1 == ENVIRON["K"] { print $2; exit }' "$state" 2>/dev/null || true)
    grep -q "^$h " agents/harness-dirs 2>/dev/null || { echo "No harness chosen" >&2; exit 1; }
else
    new=$({ [ -f "$state" ] && K=$target awk -F'\t' '$1 != ENVIRON["K"] && $1 != "*"' "$state"; printf '%s\t%s\n%s\t%s\n' "$target" "$h" '*' "$h"; })
    printf '%s\n' "$new" > "$state"
fi

dirs=$(sed -n "s/^$h //p" agents/harness-dirs)
for d in $dirs; do mkdir -p "agents/$h/$d"; done
ensure_image "$h" agents/base/Dockerfile "agents/$h/Dockerfile"

exec docker compose run --rm ${tty:+"$tty"} "$h" "$@"
