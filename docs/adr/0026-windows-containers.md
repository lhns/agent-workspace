# 26. Windows containers: the same launcher core, detected from the daemon

Status: Accepted. Refines [ADR 4](0004-shared-base-image.md) (a second base image), [ADR 12](0012-non-root-agent-user.md) (the user), [ADR 20](0020-workspace-at-host-path.md) (the host path) and [ADR 24](0024-docker-for-agents-through-remote-docker.md) (not available).

## Context
Some machines have only a Windows Docker daemon (no WSL2, no Linux VM), so the agents must run in Windows containers. They should behave like the Linux ones: one launcher, menus, resume, `--exec`, `--workdir`, the generated instructions, the cache volume, prebuilt images on ghcr. A spike on GitHub's `windows-2025` runners (process isolation) decided the open points:
- Only directories can be mounted. A bind target outside `C:` fails (`hcs::CreateComputeSystem: The parameter is incorrect`). `read_only` works.
- `ContainerUser` cannot even list a workspace under `C:\Users\<you>`: the host's ACLs decide. `ContainerAdministrator` works everywhere and stays inside the container boundary.
- An npm `.cmd` shim cannot be a container command; `bash.exe` can. Git Bash has no `HOME` unless it is given one (it falls back to `/`, Git's own folder), and an absolute `/opt/...` resolves into Git's folder.
- `docker stop` ends a container in about a second without running traps (exit `0xC000013A`). Exit codes do propagate through `compose run`.
- claude, opencode and pi use Git Bash for their tools when told where it is; cline hardcodes PowerShell on Windows. Sessions and config live under the home, as on Linux; only the folder keys differ (claude `C--x`, pi `--C--x--`, opencode and cline store `C:\x`).
- `servercore:ltsc2025` is 5.6 GB, not cached on runners (about 5 minutes to pull); the base image is 6.1 GB, with a harness 8.8 GB. The classic builder is used (no BuildKit).

## Decision
- **Detection, not configuration.** Both host launchers read `docker info -f '{{.OSType}}'` once; `AGENTS_PLATFORM=linux|windows` overrides it. For `windows` they use `Dockerfile.windows`, the local image `agent-workspace-<name>-windows`, the hash file `agents/<name>/.build-windows.sha256` and the ghcr tag `<prefix>-<name>:<hash>-windows`. The hash covers the Windows Dockerfiles and the base's `install.ps1`. Linux names and behavior do not change.
- **One `compose.yaml`**, driven by variables with Linux defaults: image names (`AGENTS_IMAGE_SUFFIX`), `build.dockerfile` (`AGENTS_DOCKERFILE`), `isolation` (`AGENTS_ISOLATION`, default `default` = the daemon's choice, accepted by both daemons), `HOME` (`AGENTS_HOME`). All mounts are directories in the long syntax, with in-container paths under `AGENTS_DIR` and `AGENTS_HOME`.
- **The bash core is reused, not ported.** The Windows images run `launch.sh`, `start.sh`, `harness.sh` and the tests under Git Bash (PortableGit), with Node, Python (for `sql()`), ripgrep and jq in the image, on Server Core. Every command is `bash.exe`. `agents/os.sh` is the one place that knows the platform (`AGENTS_PLATFORM`, else `uname -o`) and converts between `C:\x` and `/c/x`.
- **Admin user (exception to ADR 12).** The images run as `ContainerAdministrator`, home `C:\Users\ContainerAdministrator`. No Windows Dockerfile bakes any other user's paths.
- **Workspace at its host path when on `C:`**, as `C:\x` (ADR 20); a workspace on another drive is mounted at `C:\workspace`, like the guard list in `launch.sh` (system folders, Git, Node, Python, the tools, the home and `AGENTS_DIR`, matched case-insensitively) does for paths that would hide the container's own folders. Harness sessions are keyed by the Windows folder: `start.sh` and the `harness.sh` files use `native_cwd` (`cygpath -wa .`).
- **Harnesses without a `Dockerfile.windows` are unavailable** (hermes): the launch core hides them from the menu and refuses them by name. Docker for the agents (ADR 24) is not available either: `AGENTS_DOCKER` prints one line and the agent starts without it. The seed lock falls back to a lock directory where `flock` is missing.
- **Generated notes** are OS-neutral in `environment.md`; `start.sh` adds an OS line (Linux: user `agent`, no root; Windows: Server Core, Git Bash, and that cline runs tools in PowerShell).
- **CI** builds the four Windows images through the real launcher on `windows-2025`, runs the smoke, start and launch tests inside them, and on main publishes the `-windows` tags and checks the layer-prefix property and the pull path. It runs on main and, on pull requests, only when Windows-relevant paths change.

## Consequences
- Windows images are large (about 9 GB) and the first pull is slow; the README says so. `ltsc2025` needs a Windows Server 2025 / 24H2 host in process isolation, else `AGENTS_ISOLATION=hyperv`.
- Windows containers have no `script(1)`: the menus cannot be tested in CI and are a manual check on a real host. Stopping a container runs no traps, which is harmless without Docker for the agents.
- An agent in a Windows container is a local admin inside it. That is the container boundary, not the host's.
- Two Dockerfiles per image to keep in step (the versions of the harnesses; CI compares them). Renovate updates both; the checksums of PortableGit and Python are updated by hand with their versions.
- cline's tool calls run in PowerShell, so shell-script instructions for the other harnesses do not apply to it.
