# 18. Proxy settings passed through from the environment

Status: Accepted. Refines [ADR 5](0005-public-images-no-site-config.md).

## Context
Some users sit behind an HTTP proxy. The old repos hardcoded one site's proxy as `ENV` in every Dockerfile, which ADR 5 removed. Builds (apt, npm, the hermes installer) and the agents at runtime both need network access.

## Decision
`compose.yaml` reads `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` (either case) from the shell that starts the launcher, or from `.env`, and passes both spellings as build args (Docker's predefined proxy args) and as container environment. `NODE_USE_ENV_PROXY=1` makes Node's built-in `fetch` honor them. Nothing proxy-specific is in the repo.

## Consequences
- Behind a proxy, set the variables once in the shell or `.env`; without them nothing changes.
- Images built behind a proxy don't keep it: predefined proxy args aren't stored in the image.
- Docker's own image pulls (base images, the prebuilt images of ADR 19) use the Docker daemon's proxy settings. TLS-intercepting proxies that need a custom CA are not covered.
