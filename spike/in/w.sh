#!/bin/bash
# Usage: w.sh <dir>: who am I, can I read host files, write a file, make a dir, delete.
d=$1
echo "user=$(whoami) dir=$d"
ls -la "$d" 2>&1 | head -8
for t in "echo x > '$d/w.txt'" "mkdir '$d/sub'" "rm -f '$d/w.txt'"; do
    if out=$(bash -c "$t" 2>&1); then echo "OK   $t"; else echo "FAIL $t -> $out"; fi
done
# Leave a marker so the host can see what the container wrote.
echo from-container > "$d/marker.txt" 2>/dev/null || true
