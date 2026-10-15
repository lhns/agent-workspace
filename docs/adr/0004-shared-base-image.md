# 4. Shared base image with identical tools

Status: Accepted. The "no Python" part is superseded by [ADR 15](0015-python-in-base.md).

## Context
The old repos each had their own apt list and base image, which drifted apart: different base images, and Python in some but not others. An agent's ability to work on a project shouldn't depend on which harness runs it.

## Decision
`agents/base/Dockerfile` holds the OS, the tools, the user and the git setup. Each harness Dockerfile builds `FROM agent-workspace-base` and adds only its own install. Global npm installs go to the agent's home, so harness layers need no root. The base has no Python. Hermes is a Python app, and its installer brings its own managed Python (plus `libatomic1` for its bundled Node) into the hermes image only.

## Consequences
- Tools are added or removed in one place and stay identical everywhere.
- Changing the base rebuilds every harness image on its next launch.
- Projects that need Python (or other runtimes) need it added to the base, or installed by the agent at runtime.
