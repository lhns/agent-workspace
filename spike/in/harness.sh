#!/bin/bash
# Per harness: version, TTY-less start under timeout 10, then what files appeared in the profile.
mark=/tmp/spike-mark; : > $mark; sleep 1
export DISABLE_AUTOUPDATER=1 OPENCODE_DISABLE_AUTOUPDATE=1 PI_SKIP_VERSION_CHECK=1 CLINE_NO_AUTO_UPDATE=1
for h in claude opencode pi cline; do
    echo "=================== $h"
    echo "-- which: $(command -v $h)"
    echo "-- $h --version:"; timeout 60 $h --version 2>&1 | head -5; echo "rc=${PIPESTATUS[0]}"
    echo "-- $h TTY-less start (timeout 10, stdin from sleep 30):"
    ( sleep 30 | timeout 10 $h > /tmp/$h.out 2>&1; echo "exit=${PIPESTATUS[1]}" )
    head -c 1500 /tmp/$h.out; echo
done
echo "=================== claude -p (no credentials)"
timeout 60 claude -p "say hi" 2>&1 | head -c 800; echo
echo "=================== new files in profile since start"
find "$USERPROFILE" -newer $mark -type f 2>/dev/null | head -100
echo "=================== profile top level"
ls -la "$USERPROFILE"
echo "=================== AppData tree (3 deep)"
find "$USERPROFILE/AppData" -maxdepth 3 2>/dev/null | head -60
echo "=================== shell hints in harness sources"
root=$(npm root -g)
echo "npm root: $root"
for p in "$root/@earendil-works/pi-coding-agent" "$root/cline"; do
    echo "-- $p"
    grep -rIlE "process\.env\.SHELL|findBashOnWindows|getShellConfig|bash\.exe|COMSPEC|powershell" "$p" --include=*.js --include=*.md 2>/dev/null | head -8
done
echo "-- pi shell lines"
grep -rIhE "process\.env\.SHELL|bash\.exe|shellPath|findBash" "$root/@earendil-works/pi-coding-agent" --include=*.js 2>/dev/null | head -15
echo "-- cline shell lines"
grep -rIhoE ".{60}(process\.env\.SHELL|bash\.exe|ComSpec|powershell).{60}" "$root/cline" --include=*.js 2>/dev/null | head -10
echo "-- opencode binary strings"
f=$(find "$root/opencode-ai" -name 'opencode*.exe' 2>/dev/null | head -1); echo "bin: $f"
[ -n "$f" ] && strings -n 8 "$f" 2>/dev/null | grep -E "bash\.exe|process\.env\.SHELL|SHELL\b.*bash|Bun.which\(.bash" | head -10
