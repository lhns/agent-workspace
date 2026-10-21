FROM agent-workspace-base
# renovate: datasource=npm depName=@earendil-works/pi-coding-agent
ARG PI_VERSION=1.3.0
RUN npm install -g --ignore-scripts @earendil-works/pi-coding-agent@${PI_VERSION}
RUN mkdir -p ~/.pi/agent
CMD ["pi"]
