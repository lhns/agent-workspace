#!/bin/bash
# Second round of spike experiments (follow-ups to exp.sh). Usage: exp2.sh <name>
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
dr() { echo; echo "\$ docker run $*"; timeout 300 docker run --rm "$@" 2>&1; echo "[rc=$?]"; }
hdr() { echo; echo "######## $*"; }

case ${1:?name} in

ident)
    hw=$(cygpath -w "$GITHUB_WORKSPACE")
    mkdir -p /c/Users/runneradmin/x/y /c/spike-work/d1
    hdr "host ACLs"
    for d in 'C:\Users\runneradmin\x\y' 'C:\spike-work\d1' "$hw"; do echo "-- $d"; icacls "$d" 2>&1 | head -12; done
    for u in ContainerUser ContainerAdministrator; do
        hdr "$u: HOME unset vs HOME=C:\\Users\\$u, SHELL, pwd, cygpath -wa"
        dr --user "$u" -w 'C:\Users\runneradmin\x\y' --mount 'type=bind,source=C:\Users\runneradmin\x\y,target=C:\Users\runneradmin\x\y' spike-base bash -c 'echo "unset: HOME=[$HOME] SHELL=[$SHELL]"; echo "pwd=[$(pwd)] pwd-W=[$(pwd -W)] cygpath-wa=[$(cygpath -wa .)] PWD-spaced=[$(echo $PWD | sed "s/./& /g")]"; echo "git=$(git --version)"; python3 -c "import sqlite3; print(sqlite3.sqlite_version)"'
        dr --user "$u" -e "HOME=C:\\Users\\$u" -e SHELL=/usr/bin/bash spike-base bash -c 'echo "HOME=[$HOME] SHELL=[$SHELL]"; cd ~ && echo "cd ~ -> $(pwd) / $(pwd -W)"; echo "tilde=[$(echo ~)] cygpath-wa=[$(cygpath -wa ~)]"; node -e "console.log(require(\"os\").homedir())"; bash -lc "echo login-shell HOME=\$HOME"'
    done
    hdr "workspace on D: bound to C:\\repo, as each user (host ACL of D:\\a\\...)"
    for u in ContainerUser ContainerAdministrator; do
        dr --user "$u" --mount "type=bind,source=$hw,target=C:\\repo" spike-base bash -c 'echo "user=$(whoami)"; ls /c/repo | head -3; touch /c/repo/.probe && echo WRITE-OK && rm /c/repo/.probe || echo WRITE-FAIL'
    done
    hdr "target on another drive letter (D:) for the workspace"
    dr --mount "type=bind,source=$hw,target=D:\\workspace" spike-base cmd /c "dir D:\\"
    dr --mount "type=bind,source=C:\\spike-work\\d1,target=E:\\x" spike-base cmd /c "dir E:\\"
    hdr "drives visible in the container"
    dr spike-base cmd /c "wmic logicaldisk get name"
    ;;

stop)
    cat > /c/spike-work/trap.sh <<'EOF'
trap 'echo TRAP-TERM >> /c/log/trap.txt; exit 143' TERM
trap 'echo TRAP-INT >> /c/log/trap.txt; exit 130' INT
trap 'echo TRAP-EXIT >> /c/log/trap.txt' EXIT
echo started >> /c/log/trap.txt
while :; do sleep 1; done
EOF
    rm -f /c/spike-work/log/trap.txt
    docker rm -f spike-trap >/dev/null 2>&1
    hdr "stop with a bash trap handler (pid1 = bash, no exec)"
    docker run -d --name spike-trap --mount 'type=bind,source=C:\spike-work,target=C:\sw' --mount 'type=bind,source=C:\spike-work\log,target=C:\log' spike-base bash C:/sw/trap.sh
    sleep 6
    time docker stop -t 20 spike-trap
    docker inspect -f 'status={{.State.Status}} exit={{.State.ExitCode}}' spike-trap
    echo "-- trap log:"; cat /c/spike-work/log/trap.txt
    docker rm -f spike-trap >/dev/null 2>&1
    hdr "kill -s SIGINT / SIGTERM via docker kill on exec'd node"
    for sig in SIGINT SIGTERM SIGBREAK; do
        rm -f /c/spike-work/log/k.txt; docker rm -f spike-k >/dev/null 2>&1
        docker run -d --name spike-k --mount 'type=bind,source=C:\spike-work\log,target=C:\log' spike-base bash -c 'exec node C:/spike/long.js C:/log/k.txt' >/dev/null
        sleep 6
        docker kill --signal=$sig spike-k 2>&1
        sleep 3
        echo "-- $sig: status=$(docker inspect -f '{{.State.Status}} exit={{.State.ExitCode}}' spike-k)"; cat /c/spike-work/log/k.txt
        docker rm -f spike-k >/dev/null 2>&1
    done
    ;;

tty)
    # TTY-less start in the CI sense: a container with a pseudo-console (-t) and no stdin; must still run after 12s.
    for h in claude opencode pi cline; do
        hdr "tty start: $h"
        n=spike-tty-$h; docker rm -f $n >/dev/null 2>&1
        docker run -dt --name $n --user ContainerUser -e DISABLE_AUTOUPDATER=1 -e OPENCODE_DISABLE_AUTOUPDATE=1 -e PI_SKIP_VERSION_CHECK=1 -e CLINE_NO_AUTO_UPDATE=1 spike-harnesses $h 2>&1
        sleep 12
        echo "state: $(docker inspect -f 'running={{.State.Running}} status={{.State.Status}} exit={{.State.ExitCode}}' $n)"
        echo "-- logs (ANSI stripped, first 1200 chars):"
        docker logs $n 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r' | head -c 1200; echo
        echo "-- profile files written (excluding Temp, node-compile-cache):"
        docker exec $n bash -c 'find "$USERPROFILE" -newer /c/spike/w.sh -not -path "*/Temp/*" -not -path "*/AppData/Local/Microsoft/*" -not -name "NTUSER*" -not -name "ntuser*" \( -type f -o -type d \) 2>/dev/null | sed "s|^$USERPROFILE||" | head -40' 2>&1
        docker rm -f $n >/dev/null 2>&1
    done
    ;;

shells)
    docker run --rm --user ContainerUser spike-harnesses bash C:/spike/shells.sh 2>&1
    ;;

tests)
    hw=$(cygpath -w "$GITHUB_WORKSPACE")
    R="type=bind,source=$hw,target=C:\\repo"
    A="type=bind,source=$hw\\agents,target=C:\\git\\opt\\agents,readonly"
    stage='mkdir -p /usr/local/lib /opt; cp /opt/agents/start.sh /usr/local/lib/agents-start.sh; cp /opt/agents/environment.md /usr/local/lib/agents-environment.md; cp /opt/agents/menu.sh /usr/local/lib/agents-menu.sh; cp /opt/agents/docker.sh /usr/local/lib/agents-docker.sh; cp /opt/agents/claude/harness.sh /usr/local/lib/agents-harness.sh; touch /opt/agents-user.md; mkdir -p /opt/launch'
    for conv in default excl; do
        extra=(); [ $conv = excl ] && extra=(-e 'MSYS2_ARG_CONV_EXCL=*')
        for t in start launch; do
            hdr "Q6 $t.test.sh staged, MSYS arg conversion: $conv (non-ok lines, then counts)"
            dr --mount "$R" --mount "$A" -w 'C:\repo' "${extra[@]}" spike-base bash -c "$stage; timeout 280 bash tests/$t.test.sh > /tmp/out.txt 2>&1; rc=\$?; grep -v '^ok' /tmp/out.txt | cut -c1-300; echo \"ok=\$(grep -c '^ok' /tmp/out.txt) fail=\$(grep -c '^FAIL' /tmp/out.txt) rc=\$rc\""
        done
    done
    ;;

*) echo "unknown $1"; exit 2 ;;
esac
