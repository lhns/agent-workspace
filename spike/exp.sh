#!/bin/bash
# Spike experiments, run on the windows-2025 runner under its Git Bash. Usage: exp.sh <name>
# Every experiment prints what it runs and the exit code; nothing here is meant to pass or fail.
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
W='C:\spike-work'
mkdir -p /c/spike-work/d1 /c/spike-work/log
dr() { echo; echo "\$ docker run $*"; timeout 300 docker run --rm "$@" 2>&1; echo "[rc=$?]"; }
hdr() { echo; echo "######## $*"; }
# wt <user> <target> <docker args before the image...>: the w.sh write probe
wt() { local u=$1 tgt=$2; shift 2; hdr "write probe as $u on $tgt"; dr --user "$u" "$@" spike-base bash C:/spike/w.sh "$tgt"; }
USERS="ContainerUser ContainerAdministrator"

case ${1:?name} in

info)
    hdr "docker version"; docker version 2>&1
    hdr "docker info"; docker info 2>&1
    hdr "docker info fields"
    docker info -f 'OSType={{.OSType}} OSVersion={{.OSVersion}} KernelVersion={{.KernelVersion}} Isolation={{.Isolation}} ServerVersion={{.ServerVersion}} Driver={{.Driver}}' 2>&1
    hdr "compose"; docker compose version 2>&1; docker-compose version 2>&1
    hdr "images before any pull"; docker images --digests 2>&1
    hdr "host"; cmd //c ver; echo "workspace=$GITHUB_WORKSPACE"; df -h /c /d 2>&1
    ;;

pull)
    hdr "pull servercore:ltsc2025"
    start=$(date +%s)
    docker pull mcr.microsoft.com/windows/servercore:ltsc2025 2>&1
    echo "PULL SECONDS: $(( $(date +%s) - start ))"
    docker images --digests mcr.microsoft.com/windows/servercore 2>&1
    docker image inspect mcr.microsoft.com/windows/servercore:ltsc2025 -f 'Size={{.Size}} bytes OsVersion={{.OsVersion}} Layers={{len .RootFS.Layers}}' 2>&1
    ;;

build-base)
    hdr "build spike-base"
    start=$(date +%s)
    docker build -t spike-base -f spike/Dockerfile spike 2>&1
    rc=$?
    echo "BUILD SECONDS: $(( $(date +%s) - start )) rc=$rc"
    docker images spike-base 2>&1
    docker image inspect spike-base -f 'Size={{.Size}} bytes' 2>&1
    docker history spike-base 2>&1
    exit $rc
    ;;

build-harnesses)
    hdr "build spike-harnesses (npm i -g four harnesses)"
    start=$(date +%s)
    docker build -t spike-harnesses -f spike/Dockerfile.harnesses spike 2>&1
    rc=$?
    echo "BUILD SECONDS: $(( $(date +%s) - start )) rc=$rc"
    docker images spike-harnesses 2>&1
    exit $rc
    ;;

ident)
    mkdir -p /c/Users/runneradmin/x/y
    for u in $USERS; do
        hdr "identity as $u (default workdir)"
        dr --user "$u" spike-base bash C:/spike/ident.sh
        hdr "identity as $u (workdir = mirrored bind C:\\Users\\runneradmin\\x\\y)"
        dr --user "$u" --mount 'type=bind,source=C:\Users\runneradmin\x\y,target=C:\Users\runneradmin\x\y' -w 'C:\Users\runneradmin\x\y' spike-base bash C:/spike/ident.sh
        hdr "cmd view as $u"
        dr --user "$u" spike-base cmd /c 'echo USERPROFILE=%USERPROFILE% & whoami'
    done
    hdr "versions"
    dr spike-base bash -c 'node --version; npm --version; git --version; python --version; python3 --version; rg --version | head -1; jq --version; bash --version | head -1'
    ;;

mounts)
    echo host > /c/spike-work/d1/host.txt
    echo host > /c/spike-work/f.txt
    hdr "Q1 single-file bind: -v"
    dr -v 'C:\spike-work\f.txt:C:\f.txt' spike-base cmd /c type C:\f.txt
    hdr "Q1 single-file bind: --mount"
    dr --mount 'type=bind,source=C:\spike-work\f.txt,target=C:\f.txt' spike-base cmd /c type C:\f.txt
    hdr "Q1 single-file bind into an existing dir"
    dr --mount 'type=bind,source=C:\spike-work\f.txt,target=C:\spike\f.txt' spike-base cmd /c type C:\spike\f.txt
    for u in $USERS; do
        wt $u 'C:\mnt\rw' -v 'C:\spike-work\d1:C:\mnt\rw'
    done
    wt ContainerAdministrator 'C:\mnt\ro' -v 'C:\spike-work\d1:C:\mnt\ro:ro'
    wt ContainerAdministrator 'C:\mnt\ro2' --mount 'type=bind,source=C:\spike-work\d1,target=C:\mnt\ro2,readonly'
    hdr "Q2 mirrored deep host path (dir absent in image)"
    mkdir -p /c/Users/runneradmin/x/y; echo host > /c/Users/runneradmin/x/y/host.txt
    for u in $USERS; do
        wt $u 'C:\Users\runneradmin\x\y' --mount 'type=bind,source=C:\Users\runneradmin\x\y,target=C:\Users\runneradmin\x\y'
    done
    hdr "Q2 mirrored path on D: (runner workspace drive)"
    hw=$(cygpath -w "$GITHUB_WORKSPACE"); echo "workspace host path: $hw"
    dr --mount "type=bind,source=$hw,target=$hw" spike-base cmd /c "dir $hw | find \"README\""
    dr --mount "type=bind,source=$hw,target=C:\\repo" spike-base cmd /c "dir C:\\repo | find \"README\""
    dr -v 'C:\spike-work\d1:D:\x:ro' spike-base cmd /c "dir D:\\x"
    hdr "Q2 profile targets: empty dir and non-empty dir in image, as each user, bind"
    for u in $USERS; do
        wt $u 'C:\Users\ContainerUser\empty' --mount 'type=bind,source=C:\spike-work\d1,target=C:\Users\ContainerUser\empty'
        wt $u 'C:\Users\ContainerUser\nonempty' --mount 'type=bind,source=C:\spike-work\d1,target=C:\Users\ContainerUser\nonempty'
    done
    hdr "Q2 profile target that does not exist (new dir under new parent) as ContainerUser"
    wt ContainerUser 'C:\Users\ContainerUser\.config\git' --mount 'type=bind,source=C:\spike-work\d1,target=C:\Users\ContainerUser\.config\git'
    hdr "parent created by docker: can ContainerUser write in it?"
    dr --user ContainerUser --mount 'type=bind,source=C:\spike-work\d1,target=C:\Users\ContainerUser\.config\git' spike-base bash -c 'echo y > /c/Users/ContainerUser/.config/sibling.txt && echo parent-writable || echo parent-NOT-writable; ls -la /c/Users/ContainerUser/.config'
    hdr "host view of d1 after the container writes"
    ls -la /c/spike-work/d1
    ;;

volumes)
    docker volume create spikev-a >/dev/null; docker volume create spikev-b >/dev/null; docker volume create spikev-c >/dev/null
    for u in $USERS; do
        docker volume rm -f spikev-a >/dev/null 2>&1; docker volume create spikev-a >/dev/null
        wt $u 'C:\vol\new' -v 'spikev-a:C:\vol\new'
        docker volume rm -f spikev-b >/dev/null 2>&1; docker volume create spikev-b >/dev/null
        wt $u 'C:\Users\ContainerUser\empty' -v 'spikev-b:C:\Users\ContainerUser\empty'
        docker volume rm -f spikev-c >/dev/null 2>&1; docker volume create spikev-c >/dev/null
        wt $u 'C:\Users\ContainerUser\nonempty' -v 'spikev-c:C:\Users\ContainerUser\nonempty'
        wt $u 'C:\Users\ContainerUser\.cache' -v 'spikev-c:C:\Users\ContainerUser\.cache'
    done
    hdr "volume over non-empty dir: is baked.txt visible (copy-up)?"
    docker volume rm -f spikev-c >/dev/null 2>&1; docker volume create spikev-c >/dev/null
    dr -v 'spikev-c:C:\Users\ContainerUser\nonempty' spike-base cmd /c dir C:\Users\ContainerUser\nonempty
    docker volume inspect spikev-c 2>&1
    ;;

hostname)
    for h in aw-123456 aw-12345678901 aw-123456789012 aw-1234567890123 aw-1234567890123456 aw-12345678901234567890123; do
        hdr "hostname $h (${#h} chars)"
        dr --hostname "$h" spike-base bash -c 'hostname; echo COMPUTERNAME=$COMPUTERNAME'
    done
    ;;

compose)
    cd /c/spike-work || exit 1
    cat > compose.yaml <<'EOF'
name: spike
services:
  app:
    image: spike-base
    hostname: aw-1234567890123456
    working_dir: 'C:\mnt\rw'
    volumes:
      - type: bind
        source: 'C:\spike-work\d1'
        target: 'C:\mnt\ro'
        read_only: true
      - type: bind
        source: 'C:\spike-work\d1'
        target: 'C:\mnt\rw'
      - type: volume
        source: cache
        target: 'C:\Users\ContainerUser\.cache'
volumes:
  cache:
EOF
    hdr "Q7 compose version / config"; docker compose version; docker compose config 2>&1
    hdr "Q7 compose run -T echo"; docker compose run --rm -T app bash -c 'echo hello from compose; hostname; pwd -W' 2>&1; echo "[rc=$?]"
    hdr "Q1 compose long-syntax read_only: write to ro mount"
    docker compose run --rm -T app bash C:/spike/w.sh 'C:\mnt\ro' 2>&1; echo "[rc=$?]"
    for u in $USERS; do
        hdr "Q3 compose: $u writes rw bind and cache volume"
        docker compose run --rm -T -u "$u" app bash -c 'whoami; echo a > /c/mnt/rw/c-$(whoami).txt && echo bind-ok || echo bind-FAIL; echo a > /c/Users/ContainerUser/.cache/c-$(whoami).txt && echo vol-ok || echo vol-FAIL' 2>&1; echo "[rc=$?]"
    done
    hdr "Q10 exit code: bash -c false"
    docker compose run --rm -T app bash -c false; echo "[rc=$?]"
    hdr "Q10 exit code: bash -c 'exec node -e process.exit(7)'"
    docker compose run --rm -T app bash -c 'exec node -e "process.exit(7)"'; echo "[rc=$?]"
    hdr "Q10 exit code: bash -c 'node -e process.exit(7)' (no exec)"
    docker compose run --rm -T app bash -c 'node -e "process.exit(7)"'; echo "[rc=$?]"
    hdr "Q10 exit code: entrypoint bash, command exits 5"
    docker compose run --rm -T --entrypoint bash app -c 'exit 5'; echo "[rc=$?]"
    hdr "Q10 exit code: node directly"
    docker compose run --rm -T --entrypoint node app -e 'process.exit(9)'; echo "[rc=$?]"
    hdr "Q10 exit code: docker run bash -c false / exec node"
    docker run --rm spike-base bash -c false; echo "[rc=$?]"
    docker run --rm spike-base bash -c 'exec node -e "process.exit(7)"'; echo "[rc=$?]"
    docker compose down -v 2>&1 | tail -3
    ;;

stop)
    stoptest() { # name, command...
        local n=$1; shift
        hdr "stop test $n: $*"
        rm -f /c/spike-work/log/$n.txt
        docker rm -f "spike-$n" >/dev/null 2>&1
        docker run -d --name "spike-$n" --mount 'type=bind,source=C:\spike-work\log,target=C:\log' spike-base "$@" 2>&1
        sleep 8
        echo "-- docker top:"; docker top "spike-$n" 2>&1
        echo "-- logs before stop:"; docker logs "spike-$n" 2>&1
        local t0; t0=$(date +%s)
        docker stop -t 20 "spike-$n" 2>&1
        echo "STOP SECONDS: $(( $(date +%s) - t0 ))"
        docker inspect -f 'status={{.State.Status}} exitcode={{.State.ExitCode}}' "spike-$n" 2>&1
        echo "-- log file written by the app:"; cat /c/spike-work/log/$n.txt 2>&1
        echo "-- logs after stop:"; docker logs "spike-$n" 2>&1 | tail -5
        docker rm -f "spike-$n" >/dev/null 2>&1
    }
    stoptest a bash -c 'exec node C:/spike/long.js C:/log/a.txt'
    stoptest b node C:/spike/long.js C:/log/b.txt
    stoptest c bash -c 'node C:/spike/long.js C:/log/c.txt'
    ;;

harness)
    for u in ContainerUser; do
        hdr "harness probe as $u"
        dr --user "$u" spike-harnesses bash C:/spike/harness.sh
    done
    ;;

tests)
    hw=$(cygpath -w "$GITHUB_WORKSPACE")
    R="type=bind,source=$hw,target=C:\\repo"
    hdr "Q6 start.test.sh as-is"
    dr --mount "$R" -w 'C:\repo' spike-base bash -c 'timeout 280 bash tests/start.test.sh 2>&1 | tail -60; echo "script rc=${PIPESTATUS[0]}"'
    hdr "Q6 launch.test.sh as-is"
    dr --mount "$R" -w 'C:\repo' spike-base bash -c 'timeout 280 bash tests/launch.test.sh 2>&1 | tail -60; echo "script rc=${PIPESTATUS[0]}"'
    stage='mkdir -p /usr/local/lib /opt; cp /opt/agents/start.sh /usr/local/lib/agents-start.sh; cp /opt/agents/environment.md /usr/local/lib/agents-environment.md; cp /opt/agents/menu.sh /usr/local/lib/agents-menu.sh; cp /opt/agents/docker.sh /usr/local/lib/agents-docker.sh; cp /opt/agents/claude/harness.sh /usr/local/lib/agents-harness.sh; touch /opt/agents-user.md; mkdir -p /opt/launch'
    hdr "Q6 start.test.sh with agents staged at Git's /opt/agents (= C:\\git\\opt\\agents) and /usr/local/lib"
    dr --mount "$R" --mount "type=bind,source=$hw\\agents,target=C:\\git\\opt\\agents,readonly" -w 'C:\repo' spike-base bash -c "$stage; timeout 280 bash tests/start.test.sh 2>&1 | tail -80; echo \"script rc=\${PIPESTATUS[0]}\""
    hdr "Q6 launch.test.sh with agents staged"
    dr --mount "$R" --mount "type=bind,source=$hw\\agents,target=C:\\git\\opt\\agents,readonly" -w 'C:\repo' spike-base bash -c "$stage; timeout 280 bash tests/launch.test.sh 2>&1 | tail -80; echo \"script rc=\${PIPESTATUS[0]}\""
    ;;

*) echo "unknown experiment $1"; exit 2 ;;
esac
