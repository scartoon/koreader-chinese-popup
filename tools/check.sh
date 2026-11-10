#!/bin/sh
# Syntax-check every Lua file and run the offline tests. Run before every push
# to a device: a syntax error in any file takes the whole plugin down.
set -e
cd "$(dirname "$0")/.."
status=0
for f in $(find chinesepopup.koplugin tests -name '*.lua'); do
    luac -p "$f" || status=1
    # LuaJIT is what KOReader runs; it rejects some 5.4-only syntax luac accepts.
    if command -v luajit >/dev/null; then luajit -b "$f" /dev/null || status=1; fi
done
[ $status -eq 0 ] && echo "syntax ok"
luajit tests/run.lua || status=1
exit $status
