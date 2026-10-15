#!/usr/bin/env bash
# Shared launcher: agents/run.sh <harness> [args...]. Writes only gitignored paths.
set -eu
h=$1; shift
cd "$(dirname "$0")/.."

# .env: created from the example, and refused until the user has edited it.
[ -f .env ] || cp .env.example .env
if cmp -s .env.example .env; then echo "Edit .env first" >&2; exit 1; fi
for k in $(sed -n 's/^\([A-Z_]*\)=.*/\1/p' .env.example); do
    grep -q "^$k=" .env || echo "Warning: $k is missing in .env (see .env.example)" >&2
done

# Workspace: shell env wins over .env, like compose's own interpolation.
ws=${WORKSPACE_DIR-$(sed -n 's/^WORKSPACE_DIR=//p' .env | tail -n1 | tr -d '\r"')}
if [ -z "$ws" ]; then
    mkdir -p workspace
elif [ ! -d "$ws" ]; then
    echo "WORKSPACE_DIR '$ws' does not exist" >&2; exit 1
fi

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

# Rebuild only when a Dockerfile changed since the last build (much faster than asking
# docker); docker's layer cache still keeps that rebuild short.
hashfile=agents/$h/.build.sha256
new=$(cat agents/base/Dockerfile "agents/$h/Dockerfile" | sha256sum | cut -d' ' -f1)
if [ "$new" != "$(cat "$hashfile" 2>/dev/null)" ]; then
    docker compose build base
    docker compose build "$h"
    echo "$new" > "$hashfile"
fi

exec docker compose run --rm "$h" "$@"
