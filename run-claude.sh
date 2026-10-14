#!/bin/sh
exec "$(dirname "$0")/agents/run.sh" claude "$@"
