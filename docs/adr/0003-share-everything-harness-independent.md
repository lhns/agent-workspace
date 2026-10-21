# 3. Share everything that isn't harness-specific

Status: Accepted. The hermes Docker volume (last consequence) is superseded by [ADR 16](0016-state-in-host-folders.md).

## Context
Much of an agent's environment doesn't depend on which harness runs it: the code, API keys, tools, git identity and credentials, and personal instructions. Keeping a copy per harness means configuring things several times and watching them drift apart.

## Decision
Shared by all harnesses: the workspace, the root `.env`, the base image's tools, `shared/git/` (git config and credentials) and `shared/AGENTS.md` (global instructions, mounted where each harness looks for them). Only what's harness-specific stays per harness: its config, sessions and auth, whose formats differ.

## Consequences
- Configure once, then switch harnesses freely.
- A change made inside one container (e.g. `git config --global`) shows up in all the others.
- Harnesses with no documented global instructions path don't get `AGENTS.md`: hermes only has a persona file (`SOUL.md`). Cline gets it at the cross-tool `~/.agents/AGENTS.md`.
- Hermes state is a Docker volume, not a host dir, because its dependency environment needs symlinks, which Windows bind mounts refuse.
