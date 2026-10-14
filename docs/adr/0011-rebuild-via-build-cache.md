# 11. Rebuild only when needed, via Docker's build cache

Status: Accepted

## Context
Rebuilding on every launch is slow, and never rebuilding misses Dockerfile changes after a pull. The old launchers stored a hash of the Dockerfile, which needed custom code per OS and missed changes to other inputs such as the base image. Harness images build on a shared base (ADR 4). Compose's `additional_contexts: service:base` would link the two, but it needs buildx, which not every Docker install has.

## Decision
The base is a compose service with a fixed image name, `agent-workspace-base`, and harness Dockerfiles build `FROM` it. Launchers run `docker compose build base` and then `docker compose run --build <harness>`. Docker's layer cache makes both a quick cache hit when nothing changed (about 4 s including container start). A change to the base or harness Dockerfile rebuilds only the affected layers.

## Consequences
- No hash files or hashing code. Every input to the build is covered, and it works with or without buildx.
- Harness versions are pinned by the cache. Getting a newer release takes an explicit `docker compose build --no-cache <harness>`.
- The `base` service exists only to be built. Starting it does nothing useful.
