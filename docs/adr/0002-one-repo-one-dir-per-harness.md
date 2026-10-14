# 2. One repo, one directory per harness, launchers in the root

Status: Accepted

## Context
Each harness used to have its own repo (`workspace-claude-cli`, `workspace-opencode`, `workspace-pi`). They were nearly identical copies, drifted apart (opencode fell behind), and each had its own workspace.

## Decision
One repo, `agent-workspace`. Each harness gets a directory under `agents/` with its Dockerfile and its runtime state, which keeps the root short, and the root has a `run-<harness>` launcher per harness. A single `compose.yaml` defines all services.

## Consequences
- A fix or tool change is made once and reaches every harness.
- Adding a harness means a directory with a small Dockerfile, a compose service and two one-line launchers.
- Users who want only one harness still clone all of them, which costs only a few small files.
