# 22. Launcher core in the base image

Status: Accepted. Refines [ADR 13](0013-launchers-per-os.md) (the launchers keep only OS-specific work) and [ADR 21](0021-one-launcher-with-harness-menu.md) (the base container now runs on every launch and owns `shared/.last-harness`).

## Context
`run.sh` and `run.bat` both parsed the options, validated the harness, wrote `shared/.last-harness` (together with `pick-harness.sh`) and applied the workspace guard list, once in bash and once in cmd. The cmd parser was fragile (an empty `""` argument or a `!` broke it), and knowledge about one harness was spread over `harness-dirs`, `start.sh` and the launchers.

## Decision
- The OS-independent half is one bash script, `agents/launch.sh`, the entrypoint of the compose `base` service. It parses the options, shows the harness menu, owns `shared/.last-harness` (the only reader and writer; `pick-harness.sh` is gone), applies the guard list and validates `--sessions`.
- The host launchers keep what must run on the host: `.env` creation and refusal (compose needs `.env` for every call), the workspace path mapping, image hashing, pull and build, tty detection and the `docker compose run` calls. They pass their arguments to the core untouched, so `run.bat` has no option parser.
- The core's result goes back in `shared/.launch/<id>/` (`harness`, `target`, `args` NUL-separated, `mode`, `noninteractive`, `exec`), created and removed by the host and mounted read-only into the harness container, where `start.sh` reads it. The host exports `target` as `AGENTS_WORKSPACE_TARGET` for the harness run. Exit codes are not usable for this: compose exits 1 on its own errors.
- One file per harness, `agents/<harness>/harness.sh`: state `dirs`, session `picker`, `find_session`. `start.sh` is generic; the harness list is every folder with a `harness.sh`. `agents/harness-dirs` is deleted. Still per harness elsewhere: the compose service, the CI matrix entry and hermes's entrypoint.
- Settings reach the core through compose interpolation (`AGENTS_HARNESS`, `AGENTS_NONINTERACTIVE`), so a shell variable still beats `.env`, and a flag beats both.

## Consequences
- Every launch starts the base container first (about 3 seconds measured on Docker Desktop for Windows; less on Linux) and always ensures the base image, even with a harness named. Harness images share its layers, so this adds no download.
- Options, the menu and the state file exist once; adding a harness is a folder (`Dockerfile`, `harness.sh`), a compose service and a CI matrix entry.
- The Windows `""` and `!` limits are gone. `%` in arguments is still expanded by cmd.
- An error in the options is reported after the base image is ensured, not before.
- The menu is alphabetical (the last used harness stays first).
- The host and the core are coupled by the files in `shared/.launch/<id>/`; a launcher killed before cleanup leaves a small directory, which the next launches remove after a day.
