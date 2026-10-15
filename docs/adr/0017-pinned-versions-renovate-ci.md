# 17. Pinned versions, updated by Renovate, tested in CI

Status: Accepted. Supersedes the "newer releases need `--no-cache`" consequence of [ADR 14](0014-rebuild-on-dockerfile-hash.md).

## Context
Agents were installed at whatever version was current when the image was first built. Getting a newer one needed a manual `--no-cache` rebuild, nothing told anyone an update existed, and nothing checked that an update still starts. Dependabot can bump `FROM` lines but not versions inside `RUN` lines.

## Decision
Every dependency is pinned in the Dockerfiles: the base image by digest, each npm agent by version, hermes by release tag and commit. Renovate, run on a schedule in GitHub Actions, opens one PR per update. CI builds each image through the real Linux launcher and checks that each agent starts, on every PR and push to `main`. It also tests the Windows launcher logic with a stub `docker`.

## Consequences
- An update changes a Dockerfile, so after `git pull` the next launch rebuilds (ADR 14). No `--no-cache` needed.
- Every update is reviewed and smoke-tested before it reaches users. Merging Renovate PRs is a manual step unless automerge is enabled.
- Renovate needs a `RENOVATE_TOKEN` secret (a personal access token). PRs created with the default `GITHUB_TOKEN` wouldn't trigger CI.
- apt packages stay unpinned and change only when the base layer is rebuilt.
