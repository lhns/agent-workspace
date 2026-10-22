FROM agent-workspace-base
# renovate: datasource=npm depName=cline
ARG CLINE_VERSION=3.0.73
RUN npm install -g cline@${CLINE_VERSION}
# The image pins the version (Renovate); an in-container update is lost on exit.
ENV CLINE_NO_AUTO_UPDATE=1
RUN mkdir -p ~/.cline ~/.agents
CMD ["cline"]
