# 29. The container user takes the host uid on Linux hosts

Status: Accepted. Refines [ADR 12](0012-non-root-agent-user.md).

## Context
ADR 12 fixes the `agent` user at uid 1000. A Linux host user with another uid can't write the bind mounts (project, `shared/`, `agents/*/config`). The advised `user:` override broke ssh (no passwd entry), `~/.cache` and hermes, which refuses a home it doesn't own (ADR 16). Docker has no generally available idmapped bind mounts (Podman does), so the mounts can't be translated. CI hid the problem with `umask 000`.

## Decision
- `run.sh` builds a thin local image `agent-workspace-<name>:uid-<uid>-<gid>` on top of the base and each harness image: `groupmod`/`usermod` plus a `chown -h` of everything owned by uid or gid 1000. The compose `image:` names end in `${AGENTS_IMAGE_TAG:-}`, which is set only on `docker compose run`; `compose build` keeps building the plain images the harness Dockerfiles use `FROM`.
- Target: `AGENTS_UID=<uid>[:<gid>]` (shell beats `.env`), else on a Linux host `id -u`:`id -g`. Uid 1000 (also `AGENTS_UID=1000`) means no remap. Git Bash, macOS, `run.bat` and Windows containers keep 1000.
- Uid 0 and rootless Docker (which maps uids itself) get one warning and no remap.
- The derived image is labelled with the source image id and rebuilt only when that changes. A rebuilt base also chowns the existing `cache` volume once.
- The image runs as `agent` from the start; nothing runs as root at runtime, and the entrypoints are unchanged.

## Consequences
- Files agents create belong to the host user; the `user:` override is no longer needed.
- Costs a local build per image update and a layer that duplicates the chowned files (large for hermes).
- Podman and rootless Docker are out of scope; `AGENTS_UID=1000` is the escape if the remap misfires.
- CI runs as uid 1001 without `umask 000` and checks file ownership.
