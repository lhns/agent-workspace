# 16. All state in host folders, no Docker volumes

Status: Accepted. Supersedes the hermes volume in [ADR 3](0003-share-everything-harness-independent.md). [ADR 25](0025-disposable-caches-in-one-volume-generated-instructions.md) adds one volume for disposable caches only; state stays in host folders.

## Context
Hermes state was a named Docker volume. A volume hides state from the user: it can't be browsed, backed up or deleted with the repo, and it outlived image rebuilds with a stale venv. But hermes can't simply use a bind mount as its home: it refuses a home it doesn't own privately (Windows bind mounts are uid 10000, mode 0777), keeps its gateway's Unix socket there, and refuses state that resolves outside the home, so symlinking state into a mount fails too. Plugins with Python dependencies make it build a whole venv generation (symlinks, ~350 MB) under `installs/`, which Windows bind mounts refuse.

## Decision
No Docker volumes; every harness keeps its state under `agents/<harness>/`. Hermes is a stock install with its home `~/.hermes` in the image. Compose runs `agents/hermes/entrypoint.sh` (bind-mounted, so edits need no rebuild) as entrypoint: it rsyncs `agents/hermes/config` into the home before the command and back after it, skipping the image's code and dependency store and per-process files (pids, locks, socket). If the command changed the selected dependency generation, it is saved as `config/.plugin-deps/installs.tar` and unpacked at the next start, only into the image it was built for. The image precompiles hermes's bytecode, otherwise each new container misses the gateway's startup deadline.

## Consequences
- All local state is a browsable, gitignored host folder.
- State is saved when the command exits: a killed container loses that run's changes, and concurrent hermes containers overwrite each other's state.
- Plugins with Python dependencies cost a few hundred MB in the folder and about a minute per start on Windows (seconds on Linux). After an image update hermes rebuilds them once (minutes).
- `hermes update` inside the container doesn't persist; a new image comes with a Dockerfile change (ADR 17, 19).
