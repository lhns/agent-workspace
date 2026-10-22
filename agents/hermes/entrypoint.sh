#!/usr/bin/env bash
# Compose's entrypoint for hermes: runs a command with hermes state copied from the host folder
# (mounted at $data) and back. Hermes needs its home to be a private directory: it refuses a
# home owned by someone else or writable by others, keeps its gateway socket there and refuses
# state (state.db, plugins) that resolves outside it. Windows bind mounts are foreign-owned, 0777
# and refuse symlinks and sockets. So the home stays in the container and is synced with the
# mount at start and after the command; rsync copies only what changed.
set -u
home=${HERMES_HOME:-$HOME/.hermes}
data=/home/agent/.hermes-config
# Hermes' bootstrap state lives in the one revision dir under installs/; skipped if that isn't unique.
revisions=("$home"/installs/*/)
bootstrap=
if [ "${#revisions[@]}" = 1 ] && [ -d "${revisions[0]}" ]; then bootstrap=${revisions[0]}bootstrap; fi
deps=$data/.plugin-deps
# Dependency generations the image ships, one per line; differs on every build.
image_generations=/home/agent/.hermes-image-generations

# Not state: the image's code and dependency store, and what belongs to this container's
# processes (pids would collide with the next container's, locks die with their holder).
excludes=(--exclude=/hermes-agent --exclude=/installs --exclude=/tools --exclude=/cache
    --exclude=/gateway.sock --exclude=/gateway.sock.path --exclude=/gateway.pid
    --exclude=/gateway_state.json --exclude=/processes.json --exclude=/spawn-ledger.json
    --exclude='*.lock' --exclude='*-shm' --exclude=/.plugin-deps --exclude=/.bootstrap)
# Mount permissions mean nothing on Windows (0777); keep state private like hermes does.
# Directory times are skipped: the mount root may belong to another uid (CI), which can't set them.
sync_tree() { rsync -rlt --omit-dir-times --delete --chmod=go-rwx "${excludes[@]}" "$1/" "$2/"; }

# Plugin dependencies are a new dependency generation (a venv, so symlinks) under installs/.
# It is saved as a tar after the command and restored at the next start.
selection() { cat "$home"/installs/*/facts.json 2>/dev/null; }

restore_deps() {
    [ -f "$deps/installs.tar" ] || return 0
    if cmp -s "$deps/image-generations" "$image_generations"; then
        echo "Restoring plugin dependencies from the host folder..." >&2
        if ! tar -xf "$deps/installs.tar" -C "$home"; then
            echo "Restoring plugin dependencies failed; hermes rebuilds them when a plugin needs them." >&2
            # Drop what was half-extracted: every generation the image doesn't ship.
            for g in "$home"/installs/*/environments/* "$home"/installs/*/pm-runtime/generations/*; do
                g=${g#"$home"/}
                grep -qxF "$g" "$image_generations" || rm -rf "${home:?}/$g"
            done
        fi
    else
        echo "Plugin dependencies in the host folder are from another hermes image; hermes" \
            "rebuilds them when a plugin needs them (once, a few minutes)." >&2
    fi
}

save_deps() {
    now=$(selection)
    [ "$now" = "$selected_at_start" ] && return 0
    if grep -qF -f "$image_generations" <<<"$now"; then
        rm -rf "$deps"
        return 0
    fi
    echo "Saving plugin dependencies to the host folder..." >&2
    mkdir -p "$deps" &&
        tar -cf "$deps/installs.tar.tmp" -C "$home" --exclude-from="$image_generations" installs &&
        mv -f "$deps/installs.tar.tmp" "$deps/installs.tar" &&
        cp "$image_generations" "$deps/image-generations"
}

# An empty folder (first start) keeps the image's initial state.
if [ -n "$(ls -A "$data")" ]; then
    restore_deps
    # The sync back deletes what the home lacks, so a partial copy must not run hermes.
    sync_tree "$data" "$home" || { echo "Copying hermes state from the host folder failed." >&2; exit 1; }
    # Hermes migrates the home once per installed revision and records that under installs/.
    if [ -n "$bootstrap" ] && [ -d "$data/.bootstrap" ]; then mkdir -p "$bootstrap" && rsync -rt "$data/.bootstrap/" "$bootstrap/"; fi
fi
selected_at_start=$(selection)

# The image pins the version, so the update notice is noise. Set here, not in the image:
# config.yaml is synced state and would overwrite an image default.
hermes config set updates.check false >/dev/null 2>&1 || echo "Could not disable hermes' update check." >&2

# Not exec: state is saved after the command. Ctrl-C must not end this script.
trap : INT
"$@"
status=$?
# Let leftover hermes processes (the gateway) exit before copying what they wrote.
if [ $$ = 1 ]; then
    kill -TERM -1 2>/dev/null
    for _ in $(seq 50); do kill -0 -1 2>/dev/null || break; sleep 0.2; done
    # Never copy files a process still writes; a killed SQLite writer leaves a consistent db+WAL.
    kill -KILL -1 2>/dev/null
fi
sync_tree "$home" "$data" || echo "Saving hermes state to the host folder failed." >&2
if [ -n "$bootstrap" ] && [ -d "$bootstrap" ]; then rsync -rt --delete "$bootstrap/" "$data/.bootstrap/"; fi
save_deps
exit $status
