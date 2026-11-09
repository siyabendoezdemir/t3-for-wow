#!/usr/bin/env bash
# Packages the addon folder exactly as it is installed (Interface/AddOns/T3ForWoW) into dist/.
# The delivery slots are NOT in this zip: they are created by the Mac app's installer.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
VER=$(sed -n 's/^## Version: //p' "$ROOT/addon/T3ForWoW/T3ForWoW.toc")
OUT=$ROOT/dist; mkdir -p "$OUT"; STAGE=$(mktemp -d)
cp -R "$ROOT/addon/T3ForWoW" "$STAGE/T3ForWoW"; cp "$ROOT/LICENSE" "$STAGE/T3ForWoW/LICENSE.txt"
(cd "$STAGE" && find T3ForWoW -exec touch -t 202611080000 {} + && rm -f "$OUT/T3ForWoW-addon-$VER.zip" && \
  if command -v zip >/dev/null; then zip -qrX "$OUT/T3ForWoW-addon-$VER.zip" T3ForWoW; else python3 -I -m zipfile -c "$OUT/T3ForWoW-addon-$VER.zip" T3ForWoW; fi)
rm -rf "$STAGE"
(cd "$OUT" && (shasum -a 256 "T3ForWoW-addon-$VER.zip" 2>/dev/null || sha256sum "T3ForWoW-addon-$VER.zip") > "T3ForWoW-addon-$VER.zip.sha256")
echo "$OUT/T3ForWoW-addon-$VER.zip"
