# 1. Run coding agents in Docker containers

Status: Accepted

## Context
Coding agents run shell commands, install packages and edit files on their own. On the host they can touch anything the user can: other projects, SSH keys, cloud credentials, system settings. Their toolchains also differ between machines and OSes, so the same agent behaves differently for different people.

## Decision
Every agent runs in its own Docker container. The container sees only the mounted workspace, its own state dir and the shared files in `shared/`.

## Consequences
- An agent can be given broad permissions with low risk to the host. The worst case is damage to the workspace, which git can undo.
- The toolchain is the same on Windows and Linux hosts and for everyone using the repo.
- Several harnesses can be tried side by side on the same code.
- Docker is required. Host tools and credentials aren't available unless they're wired in explicitly (see ADR 10).
