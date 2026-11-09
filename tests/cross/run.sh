#!/usr/bin/env bash
# Cross-language fixtures with the REAL producers/consumers on both sides. SYNTHETIC.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); LUA=$ROOT/.deps/lua-5.1.5/src/lua
BRIDGE=$(cd "$ROOT/native" && swift build --show-bin-path)/t3wow-bridge
W=$(mktemp -d)
"$LUA" "$ROOT/tests/cross/frame.lua" "$ROOT" frame "$W/frame.ppm"
OUT=$("$BRIDGE" decode "$W/frame.ppm")
echo "$OUT" | grep -q "session=123456789 seq=42 nextSlot=12 slotCount=480 flags=5 epochAck=7 ack=99" || { echo "frame header mismatch: $OUT"; exit 1; }
echo "$OUT" | grep -q 'chunk req=1 0/1 fields=S|thread:é|x|multi' || { echo "chunk mismatch: $OUT"; exit 1; }
echo "Lua frame -> pixels -> Swift decode: OK"
mkdir -p "$W/AddOns/T3ForWoW_Slot0005"
"$BRIDGE" write-test-slot --addons "$W/AddOns" --slot 5 --session 4242 >/dev/null
"$LUA" "$ROOT/tests/cross/frame.lua" "$ROOT" slot "$W/AddOns/T3ForWoW_Slot0005/Slot.lua" 4242
rm -rf "$W"
