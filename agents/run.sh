#!/usr/bin/env bash
# Shared launcher: agents/run.sh [options] [harness] [harness args...] (see usage below).
# Writes only gitignored paths.
set -eu
cd "$(dirname "$0")/.."

usage() {
    cat <<'USAGE'
Usage: run-agent [options] [harness] [harness args...]
       run-agent [options] -- [harness args...]

Without a harness, a menu picks one. Everything after the harness (or after --) goes to the
harness itself, e.g. run-agent claude --model sonnet.

Options (before the harness):
  --harness NAME           the harness to run, like the positional one (env AGENTS_HARNESS)
  --continue               resume the last conversation for this folder, no menu
  --new                    start a new conversation, no menu
  --sessions               open the harness's own session picker (not for opencode)
  --ask                    show the resume menu (the default)
  -y, --non-interactive    never show a menu: last used harness, resume if there is a conversation
                           (env AGENTS_NONINTERACTIVE)
  --exec CMD [ARGS...]     run CMD in the harness container instead of the harness
  -h, --help               this text
USAGE
}
die() { echo "$*" >&2; exit 1; }
known_harness() { grep -q "^$1 " agents/harness-dirs 2>/dev/null; }

h='' hflag='' resume='' nonint='' dashdash='' exec_cmd=()
while [ $# -gt 0 ]; do
    case $1 in
        -h | --help) usage; exit 0 ;;
        --harness) [ $# -ge 2 ] || die "--harness needs a name"; h=$2; hflag=1; shift 2 ;;
        --continue) resume=yes; shift ;;
        --new) resume=no; shift ;;
        --sessions) resume=pick; shift ;;
        --ask) resume=ask; shift ;;
        -y | --non-interactive) nonint=1; shift ;;
        --exec) shift; [ $# -gt 0 ] || die "--exec needs a command"; exec_cmd=("$@"); set --; break ;;
        --) dashdash=1; shift; break ;;
        -*) die "Unknown option $1 (put -- before arguments meant for the harness)" ;;
        *) break ;;
    esac
done
# The first remaining argument is the harness, unless --harness or -- already ended the options.
if [ -z "$hflag" ] && [ -z "$dashdash" ] && [ ${#exec_cmd[@]} -eq 0 ] && [ $# -gt 0 ]; then
    known_harness "$1" || die "Unknown harness '$1' (put -- before arguments meant for the harness)"
    h=$1; shift
    if [ "${1:-}" = -- ]; then shift; fi
fi
hargs=("$@")

# .env: created from the example, and refused until the user has edited it.
[ -f .env ] || cp .env.example .env
if cmp -s .env.example .env; then echo "Edit .env first" >&2; exit 1; fi
sed -n 's/^\([A-Z_]*\)=.*/\1/p' .env.example | while read -r k; do
    grep -q "^$k=" .env || echo "Warning: $k is missing in .env (see .env.example)" >&2
done

# Settings: a non-empty shell variable wins over .env, like compose's own interpolation.
envval() { sed -n "s/^$1=//p" .env | tail -n1 | tr -d '\r"'; }
# A flag or positional harness beats AGENTS_HARNESS; -y beats AGENTS_NONINTERACTIVE (any non-empty value).
[ -n "$h" ] || h=${AGENTS_HARNESS:-$(envval AGENTS_HARNESS)}
[ -z "$h" ] || known_harness "$h" || die "Unknown harness '$h'"
nonint=${nonint:-${AGENTS_NONINTERACTIVE:-$(envval AGENTS_NONINTERACTIVE)}}
# Exported so compose passes it to the picker and the harness.
if [ -n "$nonint" ]; then export AGENTS_NONINTERACTIVE=1; else unset AGENTS_NONINTERACTIVE; fi
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

# --sessions needs a terminal; checked before the harness menu so it fails early.
if [ "$resume" = pick ]; then
    [ -z "$nonint" ] || die "--sessions can't be combined with -y"
    [ -z "$tty" ] || die "--sessions needs a terminal"
fi

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

# shared/.last-harness: "<workspace><TAB><harness>" for this workspace and "*<TAB>..." for
# anywhere, so the menu offers the last used one first; the picker writes the same format.
state=shared/.last-harness
if [ -z "$h" ]; then
    ensure_image base agents/base/Dockerfile
    MSYS2_ARG_CONV_EXCL='*' docker compose run --rm ${tty:+"$tty"} base || exit $?
    h=$(K=$target awk -F'\t' '$1 == ENVIRON["K"] { print $2; exit }' "$state" 2>/dev/null || true)
    grep -q "^$h " agents/harness-dirs 2>/dev/null || { echo "No harness chosen" >&2; exit 1; }
else
    new=$({ [ -f "$state" ] && K=$target awk -F'\t' '$1 != ENVIRON["K"] && $1 != "*"' "$state"; printf '%s\t%s\n%s\t%s\n' "$target" "$h" '*' "$h"; })
    printf '%s\n' "$new" > "$state"
fi

# --sessions also needs a harness with a picker (known now).
[ "$resume" != pick ] || [ "$h" != opencode ] || die "opencode has no session picker at startup; use /sessions inside it"

dirs=$(sed -n "s/^$h //p" agents/harness-dirs)
for d in $dirs; do mkdir -p "agents/$h/$d"; done
ensure_image "$h" agents/base/Dockerfile "agents/$h/Dockerfile"

# The resume mode is passed only when a flag asked for it, so AGENTS_AUTORESUME from the shell or .env still applies.
env_args=(); [ -z "$resume" ] || env_args=(-e "AGENTS_AUTORESUME=$resume")
# Every argument is for the container: Git Bash must not convert them (env conversion stays).
if [ ${#exec_cmd[@]} -gt 0 ]; then
    MSYS2_ARG_CONV_EXCL='*' exec docker compose run --rm ${tty:+"$tty"} "$h" "${exec_cmd[@]}"
fi
MSYS2_ARG_CONV_EXCL='*' exec docker compose run --rm ${tty:+"$tty"} ${env_args[@]+"${env_args[@]}"} "$h" bash /usr/local/lib/agents-start.sh "$h" ${hargs[@]+"${hargs[@]}"}
