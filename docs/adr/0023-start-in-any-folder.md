# 23. Start in any folder: `--workdir`, a command on PATH, an Explorer entry

Status: Accepted. Refines [ADR 8](0008-configurable-workspace.md), [ADR 13](0013-launchers-per-os.md) and [ADR 22](0022-launcher-core-in-base-image.md).

## Context
The workspace was fixed per `.env` (or a shell variable), and the launcher had to be started from this repo. Working on another project meant editing `.env` or typing a path. Wanted: `cd project && agent-workspace` from any terminal, the folder as an argument, and a right-click entry in Windows Explorer.

## Decision
- `--workdir DIR` as the first launcher argument. The host reads it itself (`agents/run.sh`, `agents/run.bat`) because the mount source must be known before the core runs, and `run.bat` can't remove arguments from `%*`, so it only peeks at the first two and leaves all arguments untouched. It resolves DIR against the caller's folder before the launcher changes into the repo, and it beats both a shell `WORKSPACE_DIR` and `.env`. The core (`agents/launch.sh`) skips it when first and rejects it among the other options ("must come first").
- Per-user install scripts, no admin and no Docker: `install.bat` (via `agents/install.ps1`) and `install.sh`, with `uninstall.bat` and `uninstall.sh`. They write a shim `agent-workspace` that sets `WORKSPACE_DIR` to the current folder and calls `run-agent`. Windows: `%LOCALAPPDATA%\agent-workspace\bin` on the user PATH, plus the Explorer entries "Open with agent-workspace" under `HKCU\Software\Classes\Directory\shell` and `...\Directory\Background\shell` (Windows Terminal if present, else `cmd /k`). Linux/macOS: `~/.local/bin/agent-workspace`.
- Install detects an existing install (the shim exists) and asks Update, remove or cancel; without a terminal it updates. `-Update`/`--update` and `-Uninstall`/`--uninstall` skip the question.

## Consequences
- Install writes outside the repo (user PATH, HKCU), which is new for this repo. It is opt-in, per user and reversible with the uninstall script, which reports what it removed.
- The shim holds the repo's path: re-run install after moving the repo.
- Precedence of the workspace: `--workdir` > the command's current folder > a shell `WORKSPACE_DIR` > `.env`.
- Windows 11 shows the entry under "Show more options": the compact menu only accepts packaged app extensions.
- No Linux or macOS file-manager entry: it differs per desktop environment.
- The install scripts are tested in CI: on the Windows runner against its own user PATH and HKCU, on Linux with a temp HOME.
