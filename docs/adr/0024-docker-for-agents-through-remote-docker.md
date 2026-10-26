# 24. Docker for agents through a remote-docker client in each container

Status: Accepted. Refines [ADR 3](0003-share-everything-harness-independent.md) (shared state: `shared/remote-docker`) and [ADR 4](0004-shared-base-image.md) (the shared base image now ships the client).

## Context
Agents could not build or run containers: no docker CLI, no daemon. Giving the container the host's Docker socket hands over the host, and a privileged Docker-in-Docker container needs privileges the launcher should not ask for. [remote-docker](https://github.com/lhns/remote-docker) is a docker CLI (with compose) that talks to a remote workspace daemon over SSH or WebSocket. Facts that shaped the design (checked against v0.16.1):
- Its Docker endpoint is local only (a unix socket, mode 0600), and a bind mount source is a path on the machine running the client session, served to the workspace over NFS. So the session has to run inside the agent container, where the workspace is mounted at its host path.
- The client needs no privileges. `remote start` returns at once; `remote status` exits 1 until the workspace answers.
- A key is one client of the workspace. Two sessions on one key collide on the workspace's tunnel port (remote-docker ADR 29), so one shared key cannot serve concurrent containers.
- An account can mint single-use tokens for itself (`remote token create`, needs `WORKSPACE_USER_TOKENS` true, the default), enrol a key with one (`remote create --token`) and remove one of its own keys (`remote key rm`). A token command opens a query session that takes neither the endpoint nor the tunnel port, so it works beside a running session.
- Local `remote machine` workspaces (WSL, Hyper-V) are found through host tools and cannot be reached from a container.

## Decision
- Opt-in: `AGENTS_DOCKER=remote-docker`. Unset, nothing starts and agents have no Docker, as before. The client is in the base image (pinned, checksum-verified, `docker` is a symlink to it). `agents/docker.sh` is sourced by `start.sh` in both the normal and `--exec` paths.
- The user's own account, so agents share the user's daemon, images and containers.
- A seed key in `shared/remote-docker/seed`, enrolled once with a token the user passes as `AGENTS_DOCKER_TOKEN`. The seed only mints tokens.
- Each container mints a token with the seed, enrols a fresh key in a container-local state dir, starts its own session (socket under `/tmp`, `DOCKER_HOST` exported), and on exit stops the session and removes its key. The key comment carries the container's hostname (`aw-<run id>`), so leftovers of a killed container are recognisable.
- Anything failing (not enrolled, workspace unreachable, token refused) prints one line and the agent starts without Docker.

## Consequences
- The agent can do anything the account can: see, stop and remove the user's containers. Opt-in and documented.
- A killed container leaves its key in the account until the user removes it (`remote key rm`); the README says how to find them.
- The seed key stays valid in `shared/remote-docker` (plaintext, gitignored): whoever reads it can mint keys for the account. Revoke it with `remote key rm`.
- Start-up takes a few seconds more: token, enrolment, session. The harness runs as a child of `start.sh` during a Docker session, so cleanup can run.
- Bind mounts go through an extra NFS hop and only work for paths that exist in the agent container (the workspace, `/tmp`). Published ports appear on the container's own localhost. `docker buildx` is not part of the client; `docker build` works.
- The base image grows by the client (about 76 MB), and its hash changes, so CI republishes all images.
