# 20. Renovate as the GitHub App

Status: Accepted. Supersedes the Renovate workflow of [ADR 17](0017-pinned-versions-renovate-ci.md).

## Context
ADR 17 ran Renovate as a scheduled GitHub Actions workflow. PRs opened with the default `GITHUB_TOKEN` don't trigger CI and can't change workflow files, so it needed a personal access token as a repository secret: one more credential to create, scope and rotate.

## Decision
Renovate runs as the hosted Renovate GitHub App, installed on the repository. It reads the same `renovate.json`. The workflow and the `RENOVATE_TOKEN` secret are dropped.

## Consequences
- No token to manage; the app's PRs trigger CI and can update workflow files (pinned action digests).
- Renovate's schedule and runs are hosted by Mend, outside this repo's Actions; its logs are on the Mend dashboard.
- A fork has to install the app itself to get update PRs.
