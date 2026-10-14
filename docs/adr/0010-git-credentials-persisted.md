# 10. Git credentials persisted in the shared git dir

Status: Accepted

## Context
Pushing and pulling private repos needs credentials. Passing them through from the host is unreliable. Windows Git Credential Manager and `gh.exe` can't run in a Linux container, and Docker Desktop on Windows doesn't forward an ssh-agent. A token in `.env` covers only one host.

## Decision
The base image sets `credential.helper store`, writing to `~/.config/git/credentials` in the shared git dir. It's set through `GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_0`/`GIT_CONFIG_VALUE_0` env vars, not `git config --system`. Env config applies last, so an empty `credential.<url>.helper =` in the copied host config (which resets the helper list) can't disable it. The user enters a token once, on the first authenticated git operation.

## Consequences
- One login serves every harness and survives restarts. It works the same on Windows and Linux hosts.
- Credentials sit in plaintext in the ignored `shared/git/credentials`, like `~/.git-credentials`. Use scoped tokens.
- Agents can push with these credentials. That's intended, but worth keeping in mind when granting permissions.
