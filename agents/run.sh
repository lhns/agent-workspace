#!/usr/bin/env bash
# Shared launcher: agents/run.sh <harness> [args...]. Writes only gitignored paths.
set -eu
h=${1:-}
cd "$(dirname "$0")/.."
grep -q "^$h " agents/harness-dirs 2>/dev/null || { echo "Usage: agents/run.sh <harness> [args...]; unknown harness '$h' (see agents/harness-dirs)" >&2; exit 1; }
shift

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

# Prebuilt images come from ghcr.io unless AGENTS_LOCAL_BUILD is non-empty.
local_build=${AGENTS_LOCAL_BUILD:-$(envval AGENTS_LOCAL_BUILD)}
# Prebuilt images are <prefix>-<harness>:<hash>.
prefix=${AGENTS_IMAGE_PREFIX:-$(envval AGENTS_IMAGE_PREFIX)}
prefix=${prefix:-ghcr.io/lhns/agent-workspace}

# State dirs, so docker doesn't create them as root.
mkdir -p shared/git
[ -e shared/AGENTS.md ] || : > shared/AGENTS.md
dirs=$(sed -n "s/^$h //p" agents/harness-dirs)
for d in $dirs; do mkdir -p "agents/$h/$d"; done

# Seed git config from the host once; delete shared/git/config to re-seed.
if [ ! -e shared/git/config ]; then
    : > shared/git/config
    for src in "$HOME/.gitconfig" "${XDG_CONFIG_HOME:-$HOME/.config}/git/config"; do
        if [ -f "$src" ]; then cp "$src" shared/git/config; break; fi
    done
fi

# Update the image only when a Dockerfile changed since the last time (much faster than
# asking docker). The hash is also the ghcr tag, so a pull gets exactly this checkout's
# image; an edited Dockerfile misses the registry and builds locally. Docker's layer cache
# keeps a local rebuild short.
hashfile=agents/$h/.build.sha256
new=$(cat agents/base/Dockerfile "agents/$h/Dockerfile" | sha256sum | cut -d' ' -f1)
# A matching hash with the image gone (pruned) counts as changed.
if [ "$new" != "$(cat "$hashfile" 2>/dev/null)" ] || ! docker image inspect "agent-workspace-$h" >/dev/null 2>&1; then
    ref=$prefix-$h:$new
    pulled=
    if [ -z "$local_build" ]; then
        echo "Pulling $h image..."
        if docker pull "$ref"; then
            docker tag "$ref" "agent-workspace-$h"
            docker rmi "$ref" >/dev/null || true
            pulled=1
        else
            echo "No prebuilt $h image available, building locally."
        fi
    fi
    if [ -z "$pulled" ]; then
        echo "Building $h image..."
        docker compose build base
        docker compose build "$h"
    fi
    echo "$new" > "$hashfile"
fi

# Without a terminal (CI, pipes) compose can't allocate a tty and fails; -T skips it.
tty=; [ -t 0 ] || tty=-T
exec docker compose run --rm ${tty:+"$tty"} "$h" "$@"
