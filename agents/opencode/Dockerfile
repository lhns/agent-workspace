FROM agent-workspace-base
# renovate: datasource=npm depName=opencode-ai
ARG OPENCODE_VERSION=1.19.3
RUN npm install -g opencode-ai@${OPENCODE_VERSION}
# The image pins the version (Renovate); an in-container update is lost on exit.
ENV OPENCODE_DISABLE_AUTOUPDATE=1
RUN mkdir -p ~/.config/opencode ~/.local/share/opencode
CMD ["opencode"]
