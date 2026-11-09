#!/usr/bin/env bash
# Footprint (real installer from the packaged addon) and budget (real governor) per pool size.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); LUA=$ROOT/.deps/lua-5.1.5/src/lua
BRIDGE=$(cd "$ROOT/native" && swift build --show-bin-path)/t3wow-bridge
for N in 400 480 1000 2000; do
  W=$(mktemp -d)
  FP=$("$BRIDGE" install --addon "$ROOT/addon/T3ForWoW" --addons "$W/AddOns" --slots "$N" | sed -E 's/.*folders=([0-9]+) files=([0-9]+) bytes=([0-9]+)/{"folders":\1,"files":\2,"bytes":\3}/')
  KIB=$(du -sk "$W/AddOns" | cut -f1)
  BUD=$("$LUA" "$ROOT/tests/measure/budget.lua" "$ROOT" "$N")
  echo "{\"footprint\":$FP,\"diskKiB\":$KIB,\"budget\":$BUD}"
  rm -rf "$W"
done
