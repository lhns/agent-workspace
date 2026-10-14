FROM agent-workspace-base
RUN npm install -g @anthropic-ai/claude-code
ENV CLAUDE_CONFIG_DIR=/home/agent/.claude
RUN mkdir -p ~/.claude
CMD ["claude"]
