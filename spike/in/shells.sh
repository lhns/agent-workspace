#!/bin/bash
# Which shell do the harnesses use for tool calls on Windows? Read it from the installed sources.
root=$(npm root -g)
echo "== git/python/pty tools"
git --version; python3 -c "import sqlite3,sys; print('python', sys.version.split()[0], 'sqlite', sqlite3.sqlite_version)"
ls /usr/bin | grep -iE '^(winpty|script|expect|unbuffer|flock|setsid|stdbuf|rsync|ssh|curl)(\.exe)?$' | tr '\n' ' '; echo

echo; echo "== pi: shell resolution"
f=$(grep -rlE "isLegacyWslBashPath" "$root/@earendil-works/pi-coding-agent/dist" 2>/dev/null | head -1)
echo "file: $f"
grep -ao "function isLegacyWslBashPath.\{0,3000\}" "$f" | head -c 3500; echo

echo; echo "== cline: shell resolution (win32)"
for f in $(grep -rlaE 'process.platform==="win32"\)return\{file:"powershell.exe"' "$root/cline" --include=*.js 2>/dev/null | head -2); do
    echo "file: $f"
    grep -aoE '.{300}process.platform==="win32"\)return\{file:"powershell.exe".{300}' "$f" | head -c 1200; echo
done
echo "-- cline env SHELL / override:"
grep -rhaoE '.{80}process\.env\.(SHELL|CLINE_SHELL|COMSPEC).{80}' "$root/cline" --include=*.js 2>/dev/null | sort -u | head -8

echo; echo "== opencode binary"
f=$(find "$root/opencode-ai" -name 'opencode*.exe' | head -1)
echo "file: $f"
LC_ALL=C grep -ao '[ -~]\{0,120\}bash\.exe[ -~]\{0,120\}' "$f" | head -6
echo "-- SHELL/COMSPEC:"
LC_ALL=C grep -aoE '[ -~]{0,100}(process\.env\.SHELL|COMSPEC)[ -~]{0,120}' "$f" | sort -u | head -8
echo "-- Shell.preferred/acceptable:"
LC_ALL=C grep -aoE '[ -~]{0,200}(gitbash|preferred\(\)|acceptable\(\))[ -~]{0,300}' "$f" | head -4

echo; echo "== claude binary"
f=$(find "$root/@anthropic-ai" -name 'claude*.exe' | head -1)
echo "file: $f"
LC_ALL=C grep -aoE '[ -~]{0,160}CLAUDE_CODE_GIT_BASH_PATH[ -~]{0,200}' "$f" | head -4
