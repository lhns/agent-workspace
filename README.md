# agent-workspace

Run a coding agent in Docker, with only a workspace folder and its own state mounted. One repo, one folder per harness, shared tools and settings.

Harnesses: `claude` (Claude Code), `opencode`, `pi`, `cline`, `hermes`. Docker with Compose is required.

## Run

| Windows | Linux |
|---|---|
| `run-claude.bat` | `./run-claude.sh` |

Same for `opencode`, `pi`, `cline`, `hermes`. Extra arguments go to the agent, or start a shell with `run-claude.bat bash`.

The first run creates `.env` from `.env.example` and stops until you edit it (uncomment the keys you use).

The first run, and any run after a `git pull` that changed a Dockerfile (or after the image was pruned), pulls the matching prebuilt image from ghcr.io, tagged with a hash of the Dockerfiles (kept in `agents/<harness>/.build.sha256`; delete it to redo this). If there is none (edited Dockerfile, non-amd64 machine, offline), it builds locally instead.

## Layout

```
agents/base/                   shared image: OS, tools, user (uid 1000 "agent")
agents/<harness>/              Dockerfile (only the harness install, FROM base) + its local state
agents/start.sh                resumes or starts the agent (AGENTS_AUTORESUME)
agents/hermes/entrypoint.sh    copies hermes state around each run (see Hermes state)
agents/run.*                   launch logic, one file per OS; agents/harness-dirs lists state dirs
run-<harness>.*                one-line launchers
compose.yaml                   one service per harness
.env.example                   template for .env
tests/                         CI smoke test (agent starts), start.sh test and run.bat test
shared/                        local, gitignored: git config + credentials, AGENTS.md
workspace/                     default workspace
docs/adr/                      design decisions
renovate.json                  dependency updates
.github/                       CI and Renovate workflows
```

| Shared by all harnesses | Per harness |
|---|---|
| workspace, `.env`, tools | the agent binary (image) |
| git config and credentials | config, sessions, login (`agents/<harness>/config`, opencode also `data`) |
| `shared/AGENTS.md` (global instructions) | |

## Settings

- `.env`: one file for all harnesses. A non-empty shell variable overrides the same name in `.env`. Add API keys there or log in inside the container.
- `WORKSPACE_DIR` in `.env`: the folder the agent works in; empty means `./workspace`. A shell variable overrides it per run: `WORKSPACE_DIR=~/code/foo ./run-claude.sh`. The folder must exist.
- Proxy: set `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` (either case; each sets both spellings) in the shell before starting a launcher, or in `.env`. They are used for image builds and passed to the agent. A proxy on the host itself is `host.docker.internal`, not `localhost`. Pulls of the prebuilt images are done by Docker itself and use Docker's proxy settings; if a pull fails, the local build uses these variables.
- `AGENTS_LOCAL_BUILD`: non-empty (e.g. `1`) always builds the image locally instead of pulling it.
- `AGENTS_IMAGE_PREFIX`: where prebuilt images are pulled from, default `ghcr.io/lhns/agent-workspace`; set it for a fork or mirror.
- `AGENTS_WORKSPACE_CONSISTENCY`: mount consistency options for the workspace, passed to Docker as is (e.g. for remote Docker with caching mounts). Empty means Docker's default.
- `AGENTS_AUTORESUME`: `ask` (default, also when empty) offers to resume the last conversation for the workspace folder with an arrow-key menu (or to choose another one in the harness's own picker; opencode has none at startup, use `/sessions` there), `yes` resumes without asking, `no` always starts fresh (any case). It only applies when the harness has a conversation for this folder, and arguments to the launcher (`./run-claude.sh claude`) start fresh. The workspace is mounted at its host path (`C:\code\foo` becomes `/c/code/foo`) so conversations are kept per folder; use `/clear`, `/new` or the harness's own picker (`claude --resume`, `pi --resume`, `hermes sessions browse`, `cline history`) for older ones. Conversations from before this change were stored under `/workspace` and don't resume.
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

## Hermes state

Hermes refuses a home folder it can't keep private, so its home (`~/.hermes`) stays inside the container. It is copied from `agents/hermes/config` at start and back when the command exits (rsync, changes only). So:

- Changes are saved on exit. A container that is killed (`docker kill`, a crashed host) loses that run's changes. Two hermes containers running at once overwrite each other's state on exit.
- Plugins that need Python packages: hermes builds a whole Python environment for them, which can't live in a Windows bind mount. It is saved as `agents/hermes/config/.plugin-deps/installs.tar` (a few hundred MB) and unpacked at every start, which adds about a minute on Windows (seconds on Linux). After a hermes image update hermes rebuilds it once, which takes a few minutes.

## Update

`git pull`. Local files are all gitignored, so this never conflicts. Agent versions (and the base image digest) are pinned in the Dockerfiles; [Renovate](renovate.json) opens a PR for each new release. Once merged, `git pull` changes the Dockerfile, so the next launch pulls the new image (CI publishes it after the merge; until then it builds locally). Apt packages are only refreshed when a Dockerfile changes; to force it: `docker compose build --no-cache base`, then `docker compose build --no-cache <harness>`.

## Development

CI (`.github/workflows/ci.yml`) builds every image through the real launcher and checks that each agent starts; on `main` it then publishes the tested image to ghcr.io (the packages must be set public once) and checks the pull path. It also runs shellcheck/actionlint and tests `run.bat` against a stub docker. Renovate runs from a scheduled workflow and needs a `RENOVATE_TOKEN` repository secret (a personal access token, so its PRs trigger CI); see [ADR 17](docs/adr/0017-pinned-versions-renovate-ci.md) and [ADR 19](docs/adr/0019-prebuilt-images-on-ghcr.md).

Design decisions: [docs/adr](docs/adr/).
