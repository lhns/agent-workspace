# 20. Workspace mounted at its host path; resume the last conversation

Status: Accepted. Supersedes the "always `/workspace`" part of [ADR 8](0008-configurable-workspace.md). Launcher arguments no longer replace the command: they go to the harness after the resume arguments, and `AGENTS_AUTORESUME=pick` opens the harness's session picker (see [ADR 21](0021-one-launcher-with-harness-menu.md) and the README).

## Context
Claude Code, pi, opencode and hermes key their sessions by working directory. With every host folder mounted at `/workspace`, all folders shared one key, so "continue the last conversation" could resume another project's. The images also pin the agent versions (ADR 17), so in-container self-updates are lost on exit and only cost time.

## Decision
- The launchers mount the workspace at the host folder's own path (`/home/me/foo` stays, `C:\code\foo` becomes `/c/code/foo`) and make it the working directory, via `AGENTS_WORKSPACE_TARGET` (default `/workspace`, so plain `docker compose run` is unchanged). A path that would hide container directories (`/`, `/home/agent`, `/usr`, `/etc`, ...) falls back to `/workspace` with a note.
- `agents/start.sh`, bind-mounted like the hermes entrypoint, is every service's command. `AGENTS_AUTORESUME` is `ask` (default), `yes` or `no`. It resumes only when the harness has a conversation for the current folder: a session file for claude and pi, a row in the session database for opencode, cline and hermes. `ask` shows an arrow-key menu on a terminal and resumes without one. Launcher arguments replace the command, so they never resume.
- Self-updates are switched off in the Dockerfiles (hermes: `updates.check` in its synced config, set by the entrypoint).

## Consequences
- Conversations are kept per host folder; sessions stored under the old `/workspace` key are not migrated.
- Paths agents print match the host on Linux and macOS.
- Detection reads each harness's storage layout, which can change with a version bump; a failed lookup means a fresh start, never an error. cline's lookup relies on its session index recording the folder.
- Guarded paths, and folder paths over 200 characters for claude (it hashes those names), never resume.
