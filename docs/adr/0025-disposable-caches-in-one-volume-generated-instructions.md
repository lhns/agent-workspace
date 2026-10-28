# 25. Disposable caches in one Docker volume; generated global instructions

Status: Accepted. Refines [ADR 16](0016-state-in-host-folders.md) (one volume, caches only) and [ADR 3](0003-share-everything-harness-independent.md) (the global instructions are generated at start).

## Context
- With a remote Docker daemon the workspace and every host-folder mount are served over the network, so each write is slow. Agents downloaded tools, caches and scratch data into the workspace. The container filesystem is cheap but `--rm` discards it each run. A named volume lives on the daemon: cheap and persistent.
- Agents did not know any of this. Mounting `shared/AGENTS.md` directly gave them no room for notes the launcher knows (the environment, whether Docker is on).

## Decision
- One named volume `cache` (`agent-workspace_cache`) at `~/.cache` in every harness service. Disposable data only: npm's cache (`npm_config_cache`), `XDG_CACHE_HOME`, and `~/.cache/bin` on PATH for standalone tools. State stays in host folders (ADR 16). `NPM_CONFIG_PREFIX` stays container-local, so global installs follow image updates.
- `agents/environment.md` holds short imperative notes, at most 120 words (CI checks), since they cost tokens in every turn. `agents/start.sh` writes each harness's global instructions file at start, after Docker is up: the notes, one line on whether Docker is on, then the user's `shared/AGENTS.md`. That file is mounted read-only at `/opt/agents-user.md` instead of onto the harness path, so writing the generated file never touches it. Harnesses without an instructions path (hermes) get nothing.

## Consequences
- The volume is hidden from the host; clear it with `docker volume rm agent-workspace_cache`. All harnesses and concurrent runs share it (npm's cache is safe for that).
- Dependencies that must live in the project (`node_modules`, `.venv`) still land in the workspace; the notes only ask agents to install them when needed.
- The generated files in `agents/claude/config` and `agents/pi/config` are overwritten at each start (gitignored); the user's edits go in `shared/AGENTS.md`.
- Changing the notes needs no rebuild; the base image changes once (ENV, `~/.cache`, license label), so CI republishes all images.
