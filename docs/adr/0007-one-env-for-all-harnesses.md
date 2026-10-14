# 7. One `.env` for all harnesses

Status: Accepted

## Context
Each old repo had its own `.env` with the same keys. Harnesses read different variables (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`), but none of them is secret from the others.

## Decision
One root `.env`, passed whole to every service with `env_file`. Shell variables still override it for a single run.

## Consequences
- A key is set once, and a new variable reaches all harnesses with no compose change.
- Every harness sees every variable in `.env`, including ones meant for another harness.
