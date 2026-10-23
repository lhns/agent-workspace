FROM agent-workspace-base
# renovate: datasource=npm depName=@earendil-works/pi-coding-agent
ARG PI_VERSION=1.4.0
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_VERSION}
# The image pins the version (Renovate); this only silences the update notice.
ENV PI_SKIP_VERSION_CHECK=1
RUN mkdir -p ~/.pi/agent
CMD ["pi"]
