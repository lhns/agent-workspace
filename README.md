# agent-workspace

Run a coding agent in Docker, with only a workspace folder and its own state mounted. One repo, one folder per harness, shared tools and settings.

Harnesses: `claude` (Claude Code), `opencode`, `pi`, `cline`, `hermes`. Docker with Compose is required.

## Run

| Windows | Linux |
|---|---|
| `run-claude.bat` | `./run-claude.sh` |

Same for `opencode`, `pi`, `cline`, `hermes`. Extra arguments go to the agent, or start a shell with `run-claude.bat bash`.

The first run creates `.env` from `.env.example` and stops until you edit it (uncomment the keys you use).

The first run, and the first run after a `git pull` that changed a Dockerfile, pulls the matching prebuilt image from ghcr.io (tagged with a hash of the Dockerfiles, kept in `agents/<harness>/.build.sha256`; delete it to redo this). If there is none (edited Dockerfile, non-amd64 machine, offline), it builds locally instead. `LOCAL_BUILD=1` (in `.env` or the shell) always builds locally.

## Layout

```
agents/base/          shared image: OS, tools, user (uid 1000 "agent")
agents/<harness>/     Dockerfile (only the harness install, FROM base) + its local state
agents/run.*          launch logic, one file per OS; agents/harness-dirs lists state dirs
run-<harness>.*       one-line launchers
compose.yaml          one service per harness
tests/                CI smoke test (agent starts) and run.bat test
shared/               local, gitignored: git config + credentials, AGENTS.md
workspace/            default workspace
docs/adr/             design decisions
```

| Shared by all harnesses | Per harness |
|---|---|
| workspace, `.env`, tools | the agent binary (image) |
| git config and credentials | config, sessions, login (`agents/<harness>/config`, opencode also `data`; hermes: Docker volume `agent-workspace_hermes-home`) |
| `shared/AGENTS.md` (global instructions) | |

## Settings

- `.env`: one file for all harnesses. Add API keys there or log in inside the container.
- `WORKSPACE_DIR` in `.env`: the folder the agent works in; empty means `./workspace`. A shell variable overrides it per run: `WORKSPACE_DIR=~/code/foo ./run-claude.sh`. The folder must exist.
- `compose.override.yaml`: your own compose tweaks (extra mounts, ports). Gitignored, merged automatically.

## Git

On first run your host git config is copied to `shared/git/config` (on Windows, values containing Windows paths are dropped) and mounted read-write, so `git config --global` works in the container. Delete the file to re-seed.

Host credential helpers can't run in the container. Instead git uses `credential.helper store`: enter a token once on the first push or pull; it is kept in `shared/git/credentials` (plaintext, gitignored) and reused by every harness.

## Global instructions

Write `shared/AGENTS.md` once; it is mounted where each harness reads global instructions:

| Harness | Path in the container |
|---|---|
| claude | `~/.claude/CLAUDE.md` |
| opencode | `~/.config/opencode/AGENTS.md` |
| pi | `~/.pi/agent/AGENTS.md` |
| cline | `~/.agents/AGENTS.md` |
| hermes | not mounted: its only global file, `SOUL.md`, is a persona, not instructions |

## Update

`git pull`. Local files are all gitignored, so this never conflicts. Agent versions (and the base image digest) are pinned in the Dockerfiles; [Renovate](renovate.json) opens a PR for each new release. Once merged, `git pull` changes the Dockerfile, so the next launch pulls the new image (CI publishes it after the merge; until then it builds locally). Apt packages are only refreshed when a Dockerfile changes; to force it, `LOCAL_BUILD=1` plus `docker compose build --no-cache <harness>`.

CI (`.github/workflows/ci.yml`) builds every image through the real launcher and checks that each agent starts; on `main` it then publishes the tested image to ghcr.io (the packages must be set public once) and checks the pull path; it also runs shellcheck/actionlint and tests `run.bat` against a stub docker. For Renovate to run, add a `RENOVATE_TOKEN` repository secret (a personal access token, so its PRs trigger CI).

Hermes keeps its Python environment in its Docker volume, which is filled from the image only on first use. After rebuilding hermes, run `hermes pm repair` inside so the dependencies match the new code, or delete the volume to start fresh (`docker volume rm agent-workspace_hermes-home`, which also loses hermes state). On first run, if it asks for setup, run `hermes setup` inside.

Design decisions: [docs/adr](docs/adr/).
