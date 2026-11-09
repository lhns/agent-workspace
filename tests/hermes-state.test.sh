#!/bin/bash
# Hermes state in a Windows container (ADR 27), run inside the hermes container, once per mode:
#   set     writes a config value through hermes
#   check   a later container still has it; the home is the mounted folder
#   gateway the gateway of the mounted profile starts (hermes refuses a profile's own gateway unless
#           the entrypoint opted it out)
set -u
cfg=$HERMES_HOME/config.yaml
case ${1:-} in
    set)
        hermes config set ci.persisted yes || exit 1
        grep -q 'persisted: yes' "$cfg" || { echo "FAIL: the value is not in $cfg" >&2; exit 1; } ;;
    check)
        grep -q 'persisted: yes' "$cfg" || { echo "FAIL: the value from the earlier container is missing in $cfg" >&2; exit 1; }
        grep -q 'check: false' "$cfg" || { echo "FAIL: updates.check is not false in $cfg" >&2; exit 1; }
        [ ! -d "$HERMES_HOME/installs" ] || { echo "FAIL: a dependency environment was built in the mounted folder" >&2; exit 1; }
        echo "state found" ;;
    gateway)
        out=$(timeout 20 hermes gateway run 2>&1); echo "$out" | head -20
        case $out in
            *"does not get a gateway of its own"*) echo "FAIL: the gateway was refused" >&2; exit 1 ;;
            *"Gateway Starting"*) echo "gateway started" ;;
            *) echo "FAIL: no gateway start banner" >&2; exit 1 ;;
        esac ;;
    *) echo "usage: hermes-state.test.sh set|check|gateway" >&2; exit 2 ;;
esac
