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
RUN curl -fsSL https://hermes-agent.nousresearch.com/install.sh \
    | bash -s -- --non-interactive --skip-browser --skip-computer-use
CMD ["hermes"]
