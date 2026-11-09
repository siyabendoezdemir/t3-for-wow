#!/usr/bin/env bash
# Builds the addon zip artifact, installs it from the zip (not the source tree) into a clean fake
# game folder with the built bridge's installer, then boots it in the strict stub. SYNTHETIC.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd); LUA=$ROOT/.deps/lua-5.1.5/src/lua
BRIDGE=$(cd "$ROOT/native" && swift build --show-bin-path)/t3wow-bridge
ZIP=$("$ROOT/packaging/build-addon.sh")
W=$(mktemp -d); mkdir -p "$W/unzipped" "$W/World of Warcraft/_forever_/Interface/AddOns/TelegramWoW"
echo keep > "$W/World of Warcraft/_forever_/Interface/AddOns/TelegramWoW/TelegramWoW.lua"
if command -v unzip >/dev/null; then (cd "$W/unzipped" && unzip -q "$ZIP"); else python3 -I -m zipfile -e "$ZIP" "$W/unzipped"; fi
grep -rqiE 'research|private|/home/|/Users/|Bearer [A-Za-z0-9]' "$W/unzipped" && { echo "private material in the artifact"; exit 1; }
OUT=$(cd /tmp && "$BRIDGE" install --addon "$W/unzipped/T3ForWoW" --addons "$W/World of Warcraft/_forever_/Interface/AddOns" --slots 480)
echo "$OUT"
echo "$OUT" | grep -q "slotsCreated=480 restartNeeded=true change=restart folders=481" || exit 1
[ "$(cat "$W/World of Warcraft/_forever_/Interface/AddOns/TelegramWoW/TelegramWoW.lua")" = keep ] || { echo "touched another addon"; exit 1; }
du -sk "$W/World of Warcraft/_forever_/Interface/AddOns" | awk '{print "on-disk KiB (incl. other addon fixture): " $1}'
rm -rf "$W"
echo "packaged addon install: OK ($(basename "$ZIP"))"
