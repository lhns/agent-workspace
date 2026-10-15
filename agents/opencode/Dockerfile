FROM agent-workspace-base
# renovate: datasource=npm depName=opencode-ai
ARG OPENCODE_VERSION=1.19.0
RUN npm install -g opencode-ai@${OPENCODE_VERSION}
RUN mkdir -p ~/.config/opencode ~/.local/share/opencode
CMD ["opencode"]
