#!/usr/bin/env bash
# The launcher's OS-independent half, run in the base container (compose's base service has it as
# entrypoint) by agents/run.sh and run.bat: agents/launch.sh [options] [harness] [harness args...].
# Parses the options, picks the harness (menu or last used) and works out the new content of
# shared/.last-harness (this script is the only reader; the host moves the new file into place).
# The result goes to the host launcher, and on to agents/start.sh in the harness container, in
# shared/.launch/$AGENTS_RUN_ID/ (created by the host, world-writable):
#   result           written last: `launch`, or `done` when there is nothing to launch (--help)
#   last-harness     the new content of shared/.last-harness
#   harness          the harness name
#   target           the workspace path in the container, after the guard list below
#   args             the arguments for the harness (or the --exec command), NUL-separated
#   mode             the resume mode, only when a flag set it, so AGENTS_AUTORESUME still applies
#   noninteractive   present for -y or AGENTS_NONINTERACTIVE
#   exec             present for --exec
# Settings come from the environment (compose interpolation, so a shell variable beats .env):
# AGENTS_HARNESS, AGENTS_NONINTERACTIVE (non-empty = -y), AGENTS_WORKSPACE_TARGET, AGENTS_RUN_ID.
# Exit 0: done (launch if `result` says so), 130: Ctrl-C in the menu, else an error already printed.
set -u
dir=${AGENTS_DIR:-/opt/agents}
shared=${AGENTS_SHARED:-/opt/shared}
# shellcheck source=agents/menu.sh
. "$dir/menu.sh"

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
launch=$shared/.launch/${AGENTS_RUN_ID:?AGENTS_RUN_ID is not set}
[ -d "$launch" ] || die "$launch does not exist"

# Every folder with a harness.sh is a harness (alphabetical, so the menu is stable).
names=()
for f in "$dir"/*/harness.sh; do
    [ -f "$f" ] || continue
    f=${f%/harness.sh}
    names+=("${f##*/}")
done
known_harness() { [ -n "$1" ] && printf '%s\n' "${names[@]}" | grep -qxF -- "$1"; }

h='' hflag='' rmode='' nonint='' dashdash='' exec_cmd=()
while [ $# -gt 0 ]; do
    case $1 in
        -h | --help) usage; printf 'done\n' >"$launch/result" || die "Cannot write to $launch"; exit 0 ;;
        --harness) [ $# -ge 2 ] || die "--harness needs a name"; h=$2; hflag=1; shift 2 ;;
        --continue) rmode=yes; shift ;;
        --new) rmode=no; shift ;;
        --sessions) rmode=pick; shift ;;
        --ask) rmode=ask; shift ;;
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
if [ ${#exec_cmd[@]} -gt 0 ]; then hargs=("${exec_cmd[@]}"); else hargs=("$@"); fi

# A flag or positional harness beats AGENTS_HARNESS; -y beats AGENTS_NONINTERACTIVE (any non-empty value).
[ -n "$h" ] || h=${AGENTS_HARNESS:-}
[ -z "$h" ] || known_harness "$h" || die "Unknown harness '$h'"
nonint=${nonint:-${AGENTS_NONINTERACTIVE:-}}

# The workspace is mounted at its host path, so harnesses that key sessions by directory keep
# them per host folder. Paths that would hide the container's own directories fall back to /workspace.
target=${AGENTS_WORKSPACE_TARGET:?AGENTS_WORKSPACE_TARGET is not set}
case $target in
    / | /home | /home/agent | /home/agent/* | /usr | /usr/* | /etc | /etc/* | /bin | /bin/* | /sbin | /sbin/* \
        | /lib* | /proc | /proc/* | /sys | /sys/* | /dev | /dev/* | /opt | /opt/* | /var | /var/*)
        echo "Note: $target would hide a container directory; mounting the workspace at /workspace, so conversations are not kept per folder." >&2
        target=/workspace ;;
esac

# --sessions needs a terminal; checked before the harness menu so it fails early.
if [ "$rmode" = pick ]; then
    [ -z "$nonint" ] || die "--sessions can't be combined with -y"
    [ -t 0 ] || die "--sessions needs a terminal"
fi

# shared/.last-harness: "<workspace><TAB><harness>" for this workspace and "*<TAB>..." for anywhere,
# so the menu offers the last used one first.
state=$shared/.last-harness
recorded() { # key: the harness recorded for it, if it still exists
    local r
    [ -f "$state" ] || return 1
    r=$(K=$1 awk -F'\t' '$1 == ENVIRON["K"] { print $2; exit }' "$state")
    known_harness "$r" || return 1
    printf '%s\n' "$r"
}
if [ -z "$h" ]; then
    [ ${#names[@]} -gt 0 ] || die "No harness found in $dir"
    last=$(recorded "$target") || last=$(recorded '*') || last=
    if [ -t 0 ] && [ -z "$nonint" ]; then
        order=() labels=()
        if [ -n "$last" ]; then order+=("$last") labels+=("$last (last used)"); fi
        for name in "${names[@]}"; do
            [ "$name" = "$last" ] || { order+=("$name"); labels+=("$name"); }
        done
        choose "Select the agent harness to run in $target" "${labels[@]}"
        h=${order[sel]}
    else
        # Without a terminal (CI, pipes) or non-interactive there is nobody to ask: the last used one.
        [ -n "$last" ] || die "No terminal and no harness recorded; pass one: ${names[*]}"
        h=$last
    fi
fi

# --sessions also needs a harness with a picker (known now).
if [ "$rmode" = pick ]; then
    # shellcheck source=agents/claude/harness.sh
    ( . "$dir/$h/harness.sh"; [ ${#picker[@]} -gt 0 ] ) || die "$h has no session picker at startup; use /sessions inside it"
fi

new=$({ [ -f "$state" ] && K=$target awk -F'\t' '$1 != ENVIRON["K"] && $1 != "*"' "$state"; printf '%s\t%s\n%s\t%s\n' "$target" "$h" '*' "$h"; })
# The container user may not own shared/, so the new state goes to the launch dir; the host moves
# it into place once the harness image is ready.
# A failed write must not look like "nothing to launch": the host needs the result marker.
{
    printf '%s\n' "$new" >"$launch/last-harness" &&
        printf '%s\n' "$target" >"$launch/target" &&
        { [ -z "$rmode" ] || printf '%s\n' "$rmode" >"$launch/mode"; } &&
        { [ -z "$nonint" ] || : >"$launch/noninteractive"; } &&
        { [ ${#exec_cmd[@]} -eq 0 ] || : >"$launch/exec"; } &&
        : >"$launch/args" &&
        { [ ${#hargs[@]} -eq 0 ] || printf '%s\0' "${hargs[@]}" >"$launch/args"; } &&
        printf '%s\n' "$h" >"$launch/harness" &&
        printf 'launch\n' >"$launch/result"
} || die "Cannot write to $launch"
