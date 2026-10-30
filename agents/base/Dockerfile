# Shared by every harness image: OS, tools, user. Harness images build FROM it.
# CI publishes this image once and builds the harness images on that published image, so they share its layers.
FROM node:24-slim@sha256:55fb5f5a527ea2c5c4a95f963e48ef90aa38c7b346054fdc8ee9957a2b55d205

LABEL org.opencontainers.image.source=https://github.com/lhns/agent-workspace \
      org.opencontainers.image.licenses=Apache-2.0

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        git-lfs \
        jq \
        less \
        procps \
        python3 \
        ripgrep \
        tar \
        unzip \
        vim \
        zip \
    && rm -rf /var/lib/apt/lists/*

# The remote-docker client is the docker CLI (with compose) plus a session that serves the workspace
# to a remote Docker daemon; agents/docker.sh starts it when AGENTS_DOCKER is set (ADR 24).
# renovate: datasource=github-releases depName=lhns/remote-docker
ARG REMOTE_DOCKER_VERSION=v0.16.4
RUN set -eu; \
    file="remote-docker_${REMOTE_DOCKER_VERSION#v}_linux_$(dpkg --print-architecture).tar.gz"; \
    url="https://github.com/lhns/remote-docker/releases/download/${REMOTE_DOCKER_VERSION}"; \
    cd /tmp; \
    curl -fsSLO "$url/$file"; \
    curl -fsSLO "$url/checksums.txt"; \
    grep " $file\$" checksums.txt | sha256sum -c -; \
    tar -xzf "$file" --no-same-owner -C /usr/local/bin remote-docker; \
    ln -s remote-docker /usr/local/bin/docker; \
    rm -f "$file" checksums.txt

# Bind mounts from Docker Desktop show up owned by another user; without this git refuses them.
RUN git config --system --add safe.directory '*'

# Credentials live in the shared git dir so every harness (and every restart) reuses them.
# Set via env, not git config: it applies last, so a host-copied empty
# "credential.<url>.helper =" cannot reset it.
ENV GIT_CONFIG_COUNT=1 \
    GIT_CONFIG_KEY_0=credential.helper \
    GIT_CONFIG_VALUE_0="store --file /home/agent/.config/git/credentials"

# uid 1000 keeps bind mounts writable on Linux hosts; the node image's own user has that uid.
RUN userdel -r node && useradd --create-home --uid 1000 --shell /bin/bash agent
USER agent
# Global npm installs and tool binaries go in the agent home, so harness images need no root.
ENV NPM_CONFIG_PREFIX=/home/agent/.npm-global \
    PATH=/home/agent/.npm-global/bin:/home/agent/.local/bin:/home/agent/.cache/bin:$PATH
# ~/.cache is a named volume (compose.yaml, ADR 25): downloads, caches and standalone tools survive
# runs without going through the workspace mount. Created here so a new volume gets agent's ownership.
ENV npm_config_cache=/home/agent/.cache/npm \
    XDG_CACHE_HOME=/home/agent/.cache
RUN mkdir -p ~/.config/git ~/.cache/bin
WORKDIR /workspace
