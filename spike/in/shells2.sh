#!/bin/bash
root=$(npm root -g)
echo "== pi: getShellConfig region"
f=$(grep -rlE "isLegacyWslBashPath" "$root/@earendil-works/pi-coding-agent/dist" 2>/dev/null | head -1)
awk '/function isLegacyWslBashPath/{f=1} f{print substr($0,1,500); n++} n>45{exit}' "$f"

echo; echo "== cline: @cline/shared getDefaultShell"
for f in $(grep -rlaE 'function getDefaultShell|getDefaultShell=' "$root/cline/node_modules/@cline" --include=*.js 2>/dev/null | head -2); do
    echo "file: $f"
    grep -aoE '.{0,200}getDefaultShell.{0,900}' "$f" | head -3 | cut -c1-1300
done
echo "-- cline CN() full:"
f="$root/cline/node_modules/@cline/core/dist/hub/index.js"
grep -aoE 'function UU\(e\)\{.{0,900}' "$f" | head -1
echo "-- env names mentioning SHELL in cline:"
grep -rhaoE 'process\.env\.[A-Z_]*SHELL[A-Z_]*' "$root/cline" --include=*.js 2>/dev/null | sort | uniq -c | head

echo; echo "== sqlite URI forms with a Windows path (python.exe)"
mkdir -p /tmp/sq && python3 -c "
import sqlite3
sqlite3.connect(r'C:\\Users\\ContainerUser\\AppData\\Local\\Temp\\sq\\a.db').execute('create table t(x)')
" 2>&1
for uri in 'file:C:\Users\ContainerUser\AppData\Local\Temp\sq\a.db?mode=ro' 'file:C:/Users/ContainerUser/AppData/Local/Temp/sq/a.db?mode=ro' 'file:/C:/Users/ContainerUser/AppData/Local/Temp/sq/a.db?mode=ro' 'file:/tmp/sq/a.db?mode=ro'; do
    printf '%s -> ' "$uri"
    python3 -c "import sqlite3,sys; sqlite3.connect(sys.argv[1], uri=True).execute('select 1 from t'); print('open ok')" "$uri" 2>&1 | tail -1
done
echo "python3 argv for /tmp path (MSYS conversion on):"
python3 -c "import sys; print(sys.argv[1])" /tmp/sq/a.db
echo "python3 argv with MSYS2_ARG_CONV_EXCL=*:"
MSYS2_ARG_CONV_EXCL='*' python3 -c "import sys; print(sys.argv[1])" /tmp/sq/a.db
echo "cygpath -m /tmp/sq/a.db: $(cygpath -m /tmp/sq/a.db)"
echo "python3 sees /tmp/x as: $(python3 -c "import os; print(os.path.abspath('/tmp/x'))")"

echo; echo "== winpty with a console (docker run -t)"
{ sleep 1; printf 'q'; sleep 1; } | winpty bash -c 'read -rsn1 k; echo "winpty read got=[$k]"; [ -t 0 ] && echo "stdin is a tty under winpty"' 2>&1 | head -5
echo "rc=$?"
echo "plain: [ -t 0 ]=$([ -t 0 ] && echo yes || echo no) [ -t 1 ]=$([ -t 1 ] && echo yes || echo no)"
