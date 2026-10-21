# 19. Prebuilt images on ghcr.io, tagged by Dockerfile hash

Status: Accepted. Refines [ADR 14](0014-rebuild-on-dockerfile-hash.md).

## Context
Building an image takes minutes on first use and after every Dockerfile change; hermes is about 3 GB. CI already builds and smoke-tests every image, so the same image can be handed to users.

## Decision
CI pushes each tested image to `ghcr.io/lhns/agent-workspace-<harness>:<hash>` on `main`, where `<hash>` is the lowercase sha256 of `agents/base/Dockerfile` followed by `agents/<harness>/Dockerfile`. Both launchers compute that same string and store it in `.build.sha256` (ADR 14). When it changed they pull that tag, retag it as the local `agent-workspace-<harness>` that compose uses, and drop the ghcr tag. The prefix `ghcr.io/lhns/agent-workspace` can be changed with `IMAGE_PREFIX` (fork, mirror); CI publishes under its own owner and tests the pull with that prefix. They build locally instead if `LOCAL_BUILD` is set or the pull fails. The tag is the content hash, so a checkout always gets the image its own Dockerfiles describe, and an edited Dockerfile just misses the registry and builds.

## Consequences
- First start and updates take a pull instead of a build.
- Only tested images are published; PRs build locally in CI and publish nothing.
- amd64 only: other architectures fail the pull and build locally.
- The packages must be made public once, or pulls fail and fall back to building.
- Apt packages inside a tag are not refreshed until a Dockerfile changes.
- Forks pull the `lhns` images unless their Dockerfiles differ or they set `IMAGE_PREFIX`.
