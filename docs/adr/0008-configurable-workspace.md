# 8. Configurable workspace directory

Status: Accepted

## Context
A fixed `./workspace` forces users to clone their projects inside this repo, or to move existing checkouts there.

## Decision
The workspace mount source is `${WORKSPACE_DIR:-./workspace}`. It's set in `.env`, or per run from the shell, and inside the container it's always `/workspace`. The launcher stops with an error if a configured directory doesn't exist, instead of letting Docker create an empty one.

## Consequences
- Agents can work on existing checkouts anywhere on the host.
- One `WORKSPACE_DIR` is shared by all harnesses. A shell override covers running on a different project once.
