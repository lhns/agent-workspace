FROM agent-workspace-base
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_VERSION=2.1.316
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude
# The image pins the version (Renovate); an in-container update is lost on exit.
ENV DISABLE_AUTOUPDATER=1
RUN mkdir -p ~/.claude
CMD ["claude"]
