# 5. Public images, no site-specific config

Status: Accepted. Refined by [ADR 18](0018-proxy-from-environment.md) (proxy) and [ADR 19](0019-prebuilt-images-on-ghcr.md) (ghcr images).

## Context
The old repos hardcoded a corporate HTTP proxy, an internal registry mirror and a company-specific model gateway. That stops the setup from working anywhere else, and it puts internal infrastructure details in the repo.

## Decision
Use public Docker Hub images only. The repo contains no proxies, registries or provider-specific configuration. Site-specific settings go in the ignored `.env` or `compose.override.yaml` (ADR 6).

## Consequences
- It works out of the box on any machine with internet access.
- Behind a proxy, users configure Docker's own proxy settings or add build args in `compose.override.yaml`.
