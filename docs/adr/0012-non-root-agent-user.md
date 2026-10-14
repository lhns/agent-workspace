# 12. Non-root `agent` user with uid 1000

Status: Accepted

## Context
Agents shouldn't run as root. Bind-mounted files must be writable by the container user: on Linux hosts that means a matching uid, usually 1000. In the `node` image, uid 1000 is already taken by the `node` user. On Docker Desktop for Windows, mounted files appear to belong to a different owner, which makes git refuse to work on them ("dubious ownership").

## Decision
The base image replaces the `node` user with `agent` (uid 1000), shared by every harness, so all paths are `/home/agent/...`. Git's `safe.directory` is set to `*` system-wide.

## Consequences
- Files created by agents belong to the typical host user on Linux.
- A host user with a different uid needs a `user:` override in `compose.override.yaml`.
- The ownership check is disabled. That's acceptable because the container exists only to work on the mounted repos.
