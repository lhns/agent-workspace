# 14. Rebuild only when a Dockerfile hash changes

Status: Accepted. Supersedes [ADR 11](0011-rebuild-via-build-cache.md).

## Context
ADR 11 let Docker's build cache decide on every launch (`build base` + `run --build`). In practice that is slow on each start and doesn't reliably skip work. The original per-repo launchers skipped the build entirely unless the Dockerfile had changed, which made starting near-instant.

## Decision
The launchers hash `agents/base/Dockerfile` together with `agents/<harness>/Dockerfile` and keep the hash in the ignored `agents/<harness>/.build.sha256`. Only when it differs do they build `base` and then the harness, in that order. Harness images build `FROM agent-workspace-base`, the fixed image name of the `base` service, as in ADR 11. The hash is saved after a successful build. Otherwise they go straight to `docker compose run`. When a rebuild happens, Docker's layer cache still keeps it short.

## Consequences
- An unchanged setup starts without any build step.
- A pull that changes either Dockerfile triggers a rebuild on the next launch.
- Only the two Dockerfiles are hashed. A change to anything else in a build context needs a forced rebuild: delete `.build.sha256`.
- Newer agent releases still need an explicit `docker compose build --no-cache <harness>`.
