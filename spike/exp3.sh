#!/bin/bash
# Third round. Usage: exp3.sh <name>
export MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*'
hdr() { echo; echo "######## $*"; }

case ${1:?name} in

shells)
    hdr "shell source details"
    docker run --rm --user ContainerUser spike-harnesses bash C:/spike/shells2.sh 2>&1
    hdr "winpty under docker run -t"
    docker run -t --rm --user ContainerUser spike-base bash C:/spike/shells2.sh 2>&1 | sed -n '/winpty with a console/,$p'
    ;;

tty)
    for h in claude opencode pi cline; do
        hdr "tty start: $h (bash -c 'exec $h', -t, no stdin)"
        n=spike-tty-$h; docker rm -f $n >/dev/null 2>&1
        docker run -dt --name $n --user ContainerUser -e 'HOME=C:\Users\ContainerUser' -e 'SHELL=C:\git\bin\bash.exe' \
            -e DISABLE_AUTOUPDATER=1 -e OPENCODE_DISABLE_AUTOUPDATE=1 -e PI_SKIP_VERSION_CHECK=1 -e CLINE_NO_AUTO_UPDATE=1 \
            spike-harnesses bash -c "exec $h" 2>&1
        sleep 15
        echo "state: $(docker inspect -f 'running={{.State.Running}} status={{.State.Status}} exit={{.State.ExitCode}}' $n)"
        echo "-- logs (ANSI stripped, first 1000 chars):"
        docker logs $n 2>&1 | sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g' | tr -d '\r' | grep -v '^$' | head -c 1000; echo
        echo "-- docker top:"; docker top $n 2>&1 | grep -iv "svchost\|smss\|csrss\|wininit\|services\|lsass\|fontdrv\|CExecSvc\|Aggregator"
        echo "-- profile entries written (no Temp):"
        docker exec $n bash -c 'find "$USERPROFILE" -newer /c/spike/w.sh -not -path "*/Temp/*" -not -path "*/AppData/Local/Microsoft/*" -not -iname "NTUSER*" 2>/dev/null | sed "s|^$USERPROFILE||" | head -50' 2>&1
        docker rm -f $n >/dev/null 2>&1
    done
    ;;

*) echo "unknown $1"; exit 2 ;;
esac
