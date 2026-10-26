#!/bin/sh
# Removes what install.sh wrote (the agent-workspace command).
exec "$(dirname "$0")/install.sh" --uninstall
