# 15. Python 3 in the base image

Status: Accepted. Supersedes the "no Python" part of [ADR 4](0004-shared-base-image.md).

## Context
ADR 4 left Python out of the base. That misread the requirement: the claude and pi images had `python3`, and opencode lacking it was one of the ways it had fallen behind. Agents often write small Python scripts for one-off tasks, and many repos have Python tooling.

## Decision
The base image installs Debian's `python3`, so every agent has it. Hermes keeps its own uv-managed Python for itself.

## Consequences
- Agents can run Python scripts in every harness.
- Images grow by a few tens of MB.
- Only the interpreter is installed, without pip or venv. Projects that need more get it added to the base.
