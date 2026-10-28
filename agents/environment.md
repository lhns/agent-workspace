<!-- generated at each start by agent-workspace; edit shared/AGENTS.md instead -->
# Environment
- Docker container, user `agent`: no root, sudo or apt. Home resets each run except `~/.cache`.
- The workspace is the user's folder on their machine, possibly over the network: writes there are slow. Scratch and clones go in `/tmp`, downloads and caches in `~/.cache`, standalone tools in `~/.cache/bin` (on PATH, kept). Never put tools in the project; install its dependencies only when the task needs them.
