#!/usr/bin/env bash
# macOS only: tests, arm64 release build, app bundle with the addon inside, signature, zip, checksums.
#   SIGN_IDENTITY  codesign identity (default "-" = ad hoc). Use the SAME identity for every update so
#                  macOS keeps the user's Screen Recording / Keychain decisions. Never commit identities.
# Not notarized: Developer ID + notarization need a paid Apple Developer membership (docs/RELEASING.md).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ "$(uname -s)" = Darwin ] || { echo "build-app.sh runs on macOS" >&2; exit 2; }
VER=$(tr -d '[:space:]' < "$ROOT/VERSION")
PLIST_VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$ROOT/packaging/Info.plist")
[ "$VER" = "$PLIST_VER" ] || { echo "VERSION ($VER) != Info.plist ($PLIST_VER)" >&2; exit 1; }
SIGN_IDENTITY=${SIGN_IDENTITY:--}

"$ROOT/scripts/test-all.sh"
# Never ship the builder's paths: remap source paths in literals/debug info, then strip debug symbols
# (the leak scan of the zip below refuses the build if a home path survives).
PREFIX_MAP=(-Xswiftc -file-prefix-map -Xswiftc "$ROOT=/t3forwow")
(cd "$ROOT/native" && swift build -c release --arch arm64 "${PREFIX_MAP[@]}" --product T3ForWoWApp)
BIN=$(cd "$ROOT/native" && swift build -c release --arch arm64 "${PREFIX_MAP[@]}" --show-bin-path)/T3ForWoWApp
APP=$ROOT/dist/T3\ for\ WoW.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/AddOn"
cp "$BIN" "$APP/Contents/MacOS/T3ForWoW"
strip -S -x "$APP/Contents/MacOS/T3ForWoW"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp -R "$ROOT/addon/T3ForWoW" "$APP/Contents/Resources/AddOn/T3ForWoW"
cp "$ROOT/LICENSE" "$ROOT/THIRD-PARTY-NOTICES.md" "$APP/Contents/Resources/"
cp "$ROOT/packaging/licenses/T3Code-LICENSE.txt" "$APP/Contents/Resources/"
# The headless test bridge (grant-file path) must never ship to users.
if find "$APP" -name 't3wow-bridge*' | grep -q .; then echo "refusing: test bridge inside the app bundle" >&2; exit 1; fi
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$APP"
codesign --verify --strict --verbose=2 "$APP"
# Real AppKit status views, SYNTHETIC states, light+dark, opaque 2x; fails the build if any check fails.
# Runs before any controller/Keychain/config/capture/network code (see PreviewExporter).
rm -rf "$ROOT/dist/preview"
"$APP/Contents/MacOS/T3ForWoW" --export-previews "$ROOT/dist/preview"

# Zip: the app, a short read-me and the licence in one folder.
NAME=T3ForWoW-mac-$VER
STAGE=$ROOT/dist/stage/$NAME
rm -rf "$ROOT/dist/stage"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/T3 for WoW.app"
cp "$ROOT/packaging/Read Me First.txt" "$STAGE/Read Me First.txt"
cp "$ROOT/LICENSE" "$STAGE/LICENSE.txt"
(cd "$ROOT/dist/stage" && rm -f "$ROOT/dist/$NAME.zip" && ditto -c -k --keepParent "$NAME" "$ROOT/dist/$NAME.zip")
rm -rf "$ROOT/dist/stage"
ADDON_ZIP=$("$ROOT/packaging/build-addon.sh")
python3 -I "$ROOT/scripts/leak_scan.py" zip "$ROOT/dist/$NAME.zip" --allow "$ROOT/scripts/leak-allow.tsv" \
  ${LEAK_TERMS:+--terms "$LEAK_TERMS"} > "$ROOT/dist/$NAME.leak-scan.txt" || { cat "$ROOT/dist/$NAME.leak-scan.txt"; echo "refusing: leak scan findings in the app zip" >&2; exit 1; }
(cd "$ROOT/dist" && shasum -a 256 "$NAME.zip" "$(basename "$ADDON_ZIP")" > SHA256SUMS)
echo "built $ROOT/dist/$NAME.zip (signed: $SIGN_IDENTITY; not notarized)"
cat "$ROOT/dist/SHA256SUMS"
