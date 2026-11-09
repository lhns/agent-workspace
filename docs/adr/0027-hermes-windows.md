# 27. Hermes in Windows containers: the state folder is mounted as a profile

Status: Accepted. Refines [ADR 16](0016-state-in-host-folders.md) (state in a folder, without the copy) and [ADR 26](0026-windows-containers.md) (hermes is available; the host requirement is corrected).

## Context
On Linux hermes refuses a home it does not own privately, keeps a Unix socket there and builds symlinked venvs, so ADR 16 copies its state in and out with rsync, which loses a run's state when the container is killed. Hermes' own Windows installer (PowerShell) puts everything under `%LOCALAPPDATA%\hermes`. A spike on `windows-2025` showed that on Windows none of the three problems exists: no ownership check, no Unix socket (Python there has no `AF_UNIX`), symlinks work on the mount. But a home other than the install's root gets its own dependency environment (about 400 MB, built at the first start inside the mount). A root is the parent of a `profiles/<name>` home, which hermes documents as the Docker layout.

## Decision
- The image runs hermes' installer pinned to the Linux image's release commit, stage by stage. Between stages a one-line patch marks hermes' ffmpeg unavailable: it needs Media Foundation, which Server Core lacks, and fails the install. Long paths are enabled in the image.
- The image keeps the hermes root (code, tools, dependency environments). `agents/hermes/config` is mounted at `<root>\profiles\agent` (compose variable `AGENTS_HERMES_STATE`, set by both launchers) and `HERMES_HOME` points there. No copying, no rsync: a killed container loses nothing.
- `entrypoint.sh` on Windows only sets `updates.check false` and `gateway.standalone true` (hermes refuses a profile its own gateway otherwise) and runs the command. The Linux path is unchanged.
- Correction to ADR 26: `ltsc2025` images need a host on build 26100 (Server 2025, Windows 11 24H2). `AGENTS_ISOLATION=hyperv` is for newer hosts; older ones cannot run them at all.

## Consequences
- Hermes state is a profile, not the default home; a Linux state folder is not reused as is.
- Plugin dependencies are built in the container and lost with it (no `.plugin-deps` archive); hermes rebuilds them on demand.
- Hermes has no ffmpeg on Windows (voice features); the image is large (hermes' own Git, Python, Node, ripgrep and the app builds, about 2.7 GB on top of the base).
- The patch of hermes' `pm/packages.py` and the profile layout depend on hermes' internals; a hermes bump can break them and CI says so.
