FROM agent-workspace-base
# renovate: datasource=npm depName=@anthropic-ai/claude-code
ARG CLAUDE_VERSION=2.1.300
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_VERSION}
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude
RUN mkdir -p ~/.claude
CMD ["claude"]
