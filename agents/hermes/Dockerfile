FROM agent-workspace-base
# The installer brings its own Python (uv) and Node; that Node needs libatomic.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends libatomic1 \
    && rm -rf /var/lib/apt/lists/*
USER agent
# Code and tool runtime live outside ~/.hermes; its dependency environment (venv symlinks)
# stays in ~/.hermes, which compose backs with a named volume seeded from this image.
ENV HERMES_INSTALL_DIR=/home/agent/.local/share/hermes/code \
    HERMES_RUNTIME_DIR=/home/agent/.local/share/hermes/runtime
# Releases are commits on release/<version> branches, not on main; the installer wants both.
# renovate: datasource=github-tags depName=NousResearch/hermes-agent
ARG HERMES_VERSION=v0.22.2
ARG HERMES_COMMIT=d923a5eb487a17c0a68801bba9ef0f56c81040a8
# Download first: piped into bash, a failed download (e.g. HTTP 429) would build an empty image.
RUN curl -fsSL --retry 5 --retry-all-errors -o /tmp/install.sh \
        https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh \
    && bash /tmp/install.sh --non-interactive --skip-browser --skip-computer-use \
        --branch release/${HERMES_VERSION#v} --commit ${HERMES_COMMIT} \
    && rm /tmp/install.sh
CMD ["hermes"]
