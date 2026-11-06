#!/bin/bash
echo "whoami=$(whoami)"
echo "USERPROFILE=$USERPROFILE HOME=$HOME PWD=$PWD"
echo "pwd -W=$(pwd -W)  cygpath -w .=$(cygpath -w .)  cygpath -u 'C:\\x\\y'=$(cygpath -u 'C:\x\y')"
echo "APPDATA=$APPDATA LOCALAPPDATA=$LOCALAPPDATA TEMP=$TEMP"
echo "root: / = $(cygpath -w /)  /opt/agents = $(cygpath -w /opt/agents)  /tmp = $(cygpath -w /tmp)"
echo "hostname=$(hostname)"
echo "uname=$(uname -a)"
echo "SHELL=${SHELL:-unset} MSYSTEM=${MSYSTEM:-unset}"
for c in bash sh find sort sed awk grep timeout script python python3 rg jq node npm git curl rsync; do printf '%s -> %s\n' "$c" "$(command -v $c || echo MISSING)"; done
echo "-- read without tty:"
bash -c 'read -rsn1 k </dev/null; echo "read -rsn1 rc=$?"'
echo "-- tty: [ -t 0 ]=$([ -t 0 ] && echo yes || echo no)"
