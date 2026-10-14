# Shared by every harness image: OS, tools, user. Harness images build FROM it.
FROM node:24-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        git-lfs \
        jq \
        less \
        procps \
        ripgrep \
        tar \
        unzip \
        vim \
        zip \
    && rm -rf /var/lib/apt/lists/*

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
    PATH=/home/agent/.npm-global/bin:/home/agent/.local/bin:$PATH
RUN mkdir -p ~/.config/git
WORKDIR /workspace
