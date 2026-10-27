# agent-workspace

Run a coding agent in Docker, with only a workspace folder and its own state mounted. One repo, one folder per harness, shared tools and settings.

Harnesses: `claude` (Claude Code), `opencode`, `pi`, `cline`, `hermes`. Docker with Compose is required.

## Run

| Windows | Linux |
|---|---|
| `run-agent.bat [--workdir DIR] [options] [harness] [harness args...]` | `./run-agent.sh [--workdir DIR] [options] [harness] [harness args...]` |

### Choosing the harness

With a harness (`claude`, `opencode`, `pi`, `cline`, `hermes`) that agent starts. Without one, an arrow-key menu picks it (Up/Down, Enter, Ctrl-C to quit), with the harness you used last in this workspace folder first, else the last used anywhere, then the others alphabetically, remembered in `shared/.last-harness`. Without a terminal and without a harness, the last used one starts.

### Arguments for the agent

Everything after the harness goes to the agent, e.g. `./run-agent.sh claude --model sonnet`; after `--` alone the menu still picks the harness: `./run-agent.sh -- --model sonnet`. The arguments come after the launcher's own resume arguments (`claude --continue --model sonnet`).

### Where the options run

The options and the menu run in a container from the base image, so they behave the same on Windows and Linux. That container starts on every launch, even with a harness named, and adds about 3 seconds on Docker Desktop for Windows; `--help` and option errors need Docker running too.

### Options

Options go before the harness (`./run-agent.sh -h` lists them):

| Option | Effect |
|---|---|
| `--workdir DIR` | the folder the agent works in, instead of `WORKSPACE_DIR`; relative to where you run the launcher. Must be the first argument |
| `--harness NAME` | the harness to run, like the positional one |
| `--continue` | resume the last conversation for this folder, no menu |
| `--new` | start a new conversation, no menu |
| `--sessions` | open the harness's own session picker (not for opencode; needs a terminal) |
| `--ask` | show the resume menu (the default) |
| `-y`, `--non-interactive` | never show a menu: the given or last used harness, resuming a conversation if there is one unless `--new`; an error with `--sessions` |
| `--exec CMD [ARGS...]` | run CMD in the harness container instead of the agent, e.g. a shell: `./run-agent.sh --harness claude --exec bash` |
| `-h`, `--help` | usage |

### Notes

Option parsing stops at the first argument that is not an option or at `--`. An unknown option before the harness is an error; put `--` before arguments meant for the agent. The launcher does not detect the agent's own session flags: pass `--new` when you supply your own session flags, e.g. `./run-agent.sh --new claude --resume <id>`; otherwise a resume menu or `--continue` may come first.

Breaking changes: the per-harness launchers are gone; `run-claude.sh` is now `./run-agent.sh claude` (likewise `run-claude.bat` and the other harnesses). Arguments after the harness now go to the agent instead of replacing its command: `run-agent claude bash` passes `bash` to claude; use `--exec` for a shell or any other command.

On Windows, `%` in arguments is expanded by cmd (twice, via the root launcher). `--harness=NAME` is not recognized on either OS (use a space).

### First run and images

The first run creates `.env` from `.env.example` and stops until you edit it (uncomment the keys you use).

The first run, and any run after a `git pull` that changed a Dockerfile (or after the image was pruned), pulls the matching prebuilt image from ghcr.io, tagged with a hash of the Dockerfiles (kept in `agents/<harness>/.build.sha256`; delete it to redo this). The base image (`agents/base/.build.sha256`) is pulled the same way on every launch first: harness images are built on it, and it runs the launcher's options and harness menu. If there is none (edited Dockerfile, non-amd64 machine, offline), it builds locally instead.

## Use in any folder

The workspace is the folder you start in, not only the one in `.env`. Run `install.bat` (Windows) or `./install.sh` (Linux, macOS) once; it needs no admin rights and no Docker, and writes only per-user files:

- the command `agent-workspace`, which starts the launcher with the current folder as the workspace: `cd ~/code/foo && agent-workspace claude`. Windows: `%LOCALAPPDATA%\agent-workspace\bin`, added to your user PATH (open a new terminal). Linux/macOS: `~/.local/bin/agent-workspace`; the script says so if that folder is not on your PATH.
- Windows only: a right-click entry "Open with agent-workspace" on folders and on a folder's empty background (registry keys under `HKCU\Software\Classes\Directory`). It opens Windows Terminal if installed, else a cmd window, in that folder; the usual harness and resume menus follow, and the shell stays open after the agent exits. On Windows 11 it is under "Show more options" (the classic menu): the compact menu only takes packaged apps. There is no file-manager entry on Linux or macOS.
- Windows, where a policy disables the registry tools (reg.exe refuses to run): the installer respects that and uses no registry, setx or PowerShell instead. The command then goes into `%LOCALAPPDATA%\Microsoft\WindowsApps` (already on your PATH; if it is not, the shim stays in the bin folder above and the installer tells you how to add it), and the folder entry becomes "Send to > agent-workspace" in the folder's right-click menu (the SendTo folder; a selected file opens its folder). The installer says which mode it used. `uninstall.bat` removes both kinds of install.

Any launcher also takes the folder as an argument: `./run-agent.sh --workdir ~/code/foo claude`. An explicit `--workdir` beats the command's current folder, which beats a `WORKSPACE_DIR` in the shell, which beats `.env`. A relative `--workdir` is relative to where you run it; a relative `WORKSPACE_DIR` in the shell is relative to this repo, so use an absolute one.

The command holds the path of this repo: after moving it, run the install script again. Running it on an existing install asks `[U]pdate / [r]emove / [c]ancel` (Enter updates; without a terminal it updates). `install.bat -Update` / `./install.sh --update` skip the question. `uninstall.bat` / `./uninstall.sh` remove everything the install wrote and say what they removed. `install.bat` is plain batch (reg.exe, setx), no PowerShell script, so a machine policy that only allows signed scripts (`AllSigned`) doesn't block it.

## Layout

```
agents/base/                   shared image: OS, tools, user (uid 1000 "agent")
agents/<harness>/              Dockerfile (only the harness install, FROM base), harness.sh + its local state
agents/<harness>/harness.sh    what the scripts need to know about the harness: state dirs, session lookup, session picker
agents/launch.sh               options, harness menu and shared/.last-harness; runs in the base image on every launch
agents/start.sh                resumes or starts the agent (AGENTS_AUTORESUME), in the harness container
agents/menu.sh                 arrow-key menu, used by launch.sh and start.sh
agents/docker.sh               Docker for the agent (AGENTS_DOCKER): enrols a key per container and runs the remote-docker session
agents/hermes/entrypoint.sh    copies hermes state around each run (see Hermes state)
agents/run.*                   host side of the launcher, one file per OS: .env, workspace path, image pull/build, docker compose
run-agent.*                    one-line launchers
install.*, uninstall.*         the `agent-workspace` command and Explorer entry (install.bat does all the Windows work itself, uninstall.bat calls it with -Uninstall)
compose.yaml                   base service plus one service per harness
.env.example                   template for .env
tests/                         CI smoke test (agent starts), launch.sh, start.sh, run.sh, run.bat and install tests
shared/                        local, gitignored: git config + credentials, AGENTS.md, remote-docker seed key
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

## Adding a harness

A folder `agents/<name>/` with a `Dockerfile` (`FROM` the base image) and a `harness.sh` (copy one: `dirs`, `picker`, `find_session`), plus three things that stay per harness: its service in `compose.yaml` (the mount paths differ per harness; mount its `harness.sh` like the others), its entry in the CI matrix, and an entrypoint if it needs one (hermes). The menu, the option checks and the state dirs follow from `harness.sh`.

## Settings

- `.env`: one file for all harnesses. A non-empty shell variable overrides the same name in `.env`. Add API keys there or log in inside the container.
- `WORKSPACE_DIR` in `.env`: the folder the agent works in; empty means `./workspace`. A shell variable overrides it per run: `WORKSPACE_DIR=~/code/foo ./run-agent.sh claude`, and `--workdir` overrides both (see [Use in any folder](#use-in-any-folder)). The folder must exist.
- Proxy: set `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` (either case; each sets both spellings) in the shell before starting a launcher, or in `.env`. They are used for image builds and passed to the agent. A proxy on the host itself is `host.docker.internal`, not `localhost`. Pulls of the prebuilt images are done by Docker itself and use Docker's proxy settings; if a pull fails, the local build uses these variables.
- `AGENTS_LOCAL_BUILD`: non-empty (e.g. `1`) always builds the image locally instead of pulling it.
- `AGENTS_IMAGE_PREFIX`: where prebuilt images are pulled from, default `ghcr.io/lhns/agent-workspace`; set it for a fork or mirror.
- `AGENTS_WORKSPACE_CONSISTENCY`: mount consistency options for the workspace, passed to Docker as is (e.g. for remote Docker with caching mounts). Empty means Docker's default.
- `AGENTS_AUTORESUME`: `ask` (default, also when empty) offers to resume the last conversation for the workspace folder with an arrow-key menu (or to choose another one in the harness's own picker; opencode has none at startup, use `/sessions` there), `yes` resumes without asking, `no` always starts fresh (any case). It only applies when the harness has a conversation for this folder, and `--new` starts fresh. `pick` (the launcher's `--sessions`) opens the harness's session picker instead. The launcher's `--continue`, `--new`, `--sessions` and `--ask` override this setting. The workspace is mounted at its host path (`C:\code\foo` becomes `/c/code/foo`) so conversations are kept per folder; use `/clear`, `/new` or the harness's own picker (`claude --resume`, `pi --resume`, `hermes sessions browse`, `cline history`) for older ones. Conversations stored earlier under `/workspace` don't resume.
- `AGENTS_HARNESS`: the harness to run when none is given on the command line (a flag or positional harness wins); with it the menu never shows. Shell beats `.env`, so it can be set system-wide.
- `AGENTS_DOCKER`, `AGENTS_DOCKER_TOKEN`, `AGENTS_DOCKER_TIMEOUT`: Docker for the agents, see [Docker inside the agents](#docker-inside-the-agents).
- `AGENTS_NONINTERACTIVE`: any non-empty value is `-y`: no menu is ever shown. Shell beats `.env`.
- Plain `docker compose run <harness>` (without a launcher) works only after one launcher run created `shared/.launch`; it then starts the harness without arguments, resuming as `AGENTS_AUTORESUME` says, and keeps `/workspace`.
- `compose.override.yaml`: your own compose tweaks (extra mounts, ports). Gitignored, merged automatically.

## Docker inside the agents

Off by default. With `AGENTS_DOCKER=remote-docker` the agent gets `docker` and `docker compose` (no `buildx`; `docker build` works) through a [remote-docker](https://github.com/lhns/remote-docker) workspace: bind mounts of the workspace folder work (through an extra NFS hop), and published ports (`-p 8080:80`) appear on the agent container's own localhost. It needs no privileges for the agent container. See [ADR 24](docs/adr/0024-docker-for-agents-through-remote-docker.md).

Setup:

1. You need a remote-docker workspace reachable from the containers: an `ssh://`, `ws://` or `wss://` address. A local `remote machine` workspace (WSL, Hyper-V) does not work from a container. Your account on it must be allowed to create tokens (`WORKSPACE_USER_TOKENS`, true by default).
2. On your computer, with remote-docker enrolled there: `remote-docker remote token create`. Put the `rdt1.…` token (or the whole line it prints) in `.env` as `AGENTS_DOCKER_TOKEN`, next to `AGENTS_DOCKER=remote-docker`. Add `REMOTE_DOCKER_HOST`, `REMOTE_DOCKER_USER` or `REMOTE_DOCKER_CA_FILE` only if the address in the token does not work from the container, or for a private CA. Any `REMOTE_DOCKER_*` setting works (it reaches every harness).
3. Start an agent. The first start enrols a seed key in `shared/remote-docker/seed` and prints `enrolled; you can remove AGENTS_DOCKER_TOKEN from .env`. Remove the token; it is single use. Later starts do not need it. (Agents started together on the first run are fine: one enrols, the others wait for it.)

How it works: the seed key only mints tokens. Every container enrols a fresh key of its own (the key comment contains the container's hostname, `aw-<run id>`), starts its own session, exports `DOCKER_HOST` (so Docker SDKs and tools work too, not only the `docker` command), and removes the key when it exits, also for `--exec`. One key per container is needed because two sessions on one key collide on the workspace. The first start takes a few seconds longer.

Troubleshooting: when Docker cannot be set up, one line starting `agent-workspace docker:` is printed and the agent starts without Docker.

- `not enrolled`: no token yet or the seed was reset; do step 2 again.
- `enrolling the seed key failed` / `minting a token failed` / `enrolling this container failed`: the end of remote-docker's message follows. Typical causes: an expired or used token (create a new one), a workspace address the container cannot reach (set `REMOTE_DOCKER_HOST`), or `WORKSPACE_USER_TOKENS` off.
- `the workspace did not answer within 60s`: the workspace is down, unreachable from the container or slow to start; raise `AGENTS_DOCKER_TIMEOUT`.
- `could not remove this container's key`: remove it by hand, see below.

To turn Docker off, unset `AGENTS_DOCKER`. To start over (new account or workspace), delete `shared/remote-docker/seed` and the seed's key on your computer, then redo the setup.

Things to know:

- The agents act on your account. They see, stop and remove your containers and images, and containers started by agents keep running after the agent exits. Anyone who can read `shared/remote-docker` can mint keys for the account; revoke the seed by removing its key.
- Bind mounts only work for paths that exist inside the agent container (the workspace, `/tmp`).
- Compose project names default to the folder name, so an agent and you in the same project share compose projects (and two agent containers in one folder do too). Set `COMPOSE_PROJECT_NAME` where that matters.
- The seed key is stored unencrypted in `shared/remote-docker/seed` (gitignored).
- A killed container (`docker kill`, a crash) leaves its key behind. List them on your computer with `remote-docker remote key ls` (stale ones have `aw-` in the comment and are not marked "this machine"; the seed's public key is in `shared/remote-docker/seed/id_ed25519.pub`, keep that one) and remove with `remote-docker remote key rm <fingerprint>`.

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

CI (`.github/workflows/ci.yml`) builds every image through the real launcher and checks that each agent starts; on `main` it then publishes the tested image to ghcr.io (the packages must be set public once) and checks the pull path. CI builds the base image once and the harness images on top of it, so they share its layers (checked against the registry). It also runs shellcheck/actionlint and tests `run.sh` and `run.bat` against a stub docker, the install scripts (on the Windows runner's own user PATH and registry), and `launch.sh` and `start.sh` in containers. Renovate runs from a scheduled workflow and needs a `RENOVATE_TOKEN` repository secret (a personal access token, so its PRs trigger CI); see [ADR 17](docs/adr/0017-pinned-versions-renovate-ci.md) and [ADR 19](docs/adr/0019-prebuilt-images-on-ghcr.md).

Design decisions: [docs/adr](docs/adr/).
