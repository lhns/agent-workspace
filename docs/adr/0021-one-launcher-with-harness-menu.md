# 21. One launcher with a harness menu, run in the base image

Status: Accepted. Refines [ADR 13](0013-launchers-per-os.md) (root wrappers) and [ADR 19](0019-prebuilt-images-on-ghcr.md) (the base image is published too). Supersedes the `run-<harness>` launchers of [ADR 2](0002-one-repo-one-dir-per-harness.md).

## Context
Ten root files (`run-<harness>.sh`/`.bat`) differed only in the harness name. Users also wanted an arrow-key menu to pick the harness, like the resume menu in `start.sh`. cmd cannot read arrow keys, so a second menu implementation would be needed for Windows.

## Decision
- One root launcher per OS, `run-agent.sh` and `run-agent.bat`, calling `agents/run.*` with `[harness] [args...]`. A first argument listed in `agents/harness-dirs` starts that harness; otherwise a menu picks it and all arguments go to the chosen harness. Without a terminal and without a harness the last used one starts.
- The menu is bash only (`agents/menu.sh`, shared with `start.sh`) and runs in a container from the base image: the compose `base` service's `command` is `agents/pick-harness.sh`. It gets the workspace key from `AGENTS_WORKSPACE_TARGET`, not from the command line, which Git Bash would rewrite as a path.
- The choice comes back through `shared/.last-harness` (lines `<workspace><TAB><harness>` and `*<TAB><harness>`, the latter for the last used anywhere), not through the exit code: compose exits 1 on its own errors. Exit 0 means chosen; anything else aborts. A harness given as an argument is recorded by the launcher.
- The base image is pulled or built like the harness images (hash of `agents/base/Dockerfile`, `agents/base/.build.sha256`, ghcr tag `<prefix>-base:<hash>`), but only on launches that show the menu. CI publishes it from the claude leg and checks the pull. Harness image hashes are unchanged.
- `run.bat` passes `-T` to compose when stdin is redirected, as `run.sh` does.

## Consequences
- Breaking: `run-claude.sh` becomes `./run-agent.sh claude`.
- Launches without a harness argument cost about a second for the menu container, and need Docker to be up before the choice.
- The menu exists once, so Windows and Linux look the same.
- Adding a harness no longer needs launcher files; only `harness-dirs`, a Dockerfile and a compose service.
