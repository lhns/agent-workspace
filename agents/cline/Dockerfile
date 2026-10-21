FROM agent-workspace-base
# renovate: datasource=npm depName=cline
ARG CLINE_VERSION=3.0.73
RUN npm install -g cline@${CLINE_VERSION}
RUN mkdir -p ~/.cline ~/.agents
CMD ["cline"]
