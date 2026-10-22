FROM agent-workspace-base
# The installer brings its own Python (uv) and Node; that Node needs libatomic.
# rsync copies hermes state to and from the host folder (entrypoint.sh).
USER root
RUN apt-get update && apt-get install -y --no-install-recommends libatomic1 rsync \
    && rm -rf /var/lib/apt/lists/*
USER agent
# The installer clones a branch, checks the pinned commit is on it and checks that out. Release
# commits end up on main; release/<version> branches exist only for some releases.
# renovate: datasource=github-tags depName=NousResearch/hermes-agent
ARG HERMES_VERSION=v0.22.4
ARG HERMES_COMMIT=4d04303818b61bf3aa09278af48356315515965b
# Download first: piped into bash, a failed download (e.g. HTTP 429) would build an empty image.
RUN curl -fsSL --retry 5 --retry-all-errors -o /tmp/install.sh \
        https://raw.githubusercontent.com/NousResearch/hermes-agent/${HERMES_COMMIT}/scripts/install.sh \
    && bash /tmp/install.sh --non-interactive --skip-browser --skip-computer-use \
        --branch main --commit ${HERMES_COMMIT} \
    && rm /tmp/install.sh
# Without bytecode every new container compiles thousands of modules before the gateway is up.
# Hermes deletes bytecode at its first launch of a checkout, so launch once, then compile.
RUN hermes --help >/dev/null \
    && ~/.hermes/tools/python-*/bin/python3 -m compileall -q -j0 -x /node_modules/ ~/.hermes/hermes-agent >/dev/null
# The dependency generations this image ships; entrypoint.sh restores saved plugin
# dependencies only into the image they were built for.
RUN cd ~/.hermes && ls -d installs/*/environments/* installs/*/pm-runtime/generations/* \
    > ~/.hermes-image-generations
CMD ["hermes"]
