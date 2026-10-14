# 13. Windows and Linux launchers sharing one script per OS

Status: Accepted

## Context
Users run this on Windows and Linux hosts. The old per-repo `.bat` files were copies of each other, and Linux had no launcher.

## Decision
All launch logic lives once per OS, in `agents/run.bat` and `agents/run.sh`. The root `run-<harness>.bat`/`.sh` files are one-line wrappers. Each run does the following: prepare `.env`, create the mount directories, seed the git config, then build and run (ADR 11). Per-harness state dirs come from one table, `agents/harness-dirs`, which both scripts read, so neither has per-harness branches.

## Consequences
- Each change is made in two places (one per OS), not once per harness per OS.
- The two scripts must be kept in step by hand.
