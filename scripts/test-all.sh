#!/usr/bin/env bash
# Every automated check. All game-side fixtures are SYNTHETIC; none of this is in-game evidence.
# The isolated-T3 suites need a T3 v0.1.7 binary: T3_BIN=/path/to/t3 (skipped, and said so, if absent).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
LUA=$ROOT/.deps/lua-5.1.5/src/lua
if [ "$(uname -s)" = Linux ]; then export PATH=$ROOT/.deps/swift/usr/bin:$PATH; fi
echo "== Lua addon tests (core + strict WoW stub UI)"; "$LUA" tests/lua/run.lua "$ROOT"
echo "== Journal layout previews (synthetic; zero stub violations)"; PREV_DIR="$(mktemp -d)"; "$LUA" tests/preview/render.lua "$ROOT" "$PREV_DIR" >/dev/null; rm -rf "$PREV_DIR"
echo "== Swift bridge core tests"
(cd native && swift build --product bridgecore-tests >/dev/null && swift build --product t3wow-bridge >/dev/null)
(cd native && "$(swift build --show-bin-path)/bridgecore-tests")
echo "== Public BridgeCore API used by the macOS app (release build, plain import)"
(cd native && swift build -c release --product t3wow-bridge >/dev/null && B=$(swift build -c release --show-bin-path) && mkdir -p "$ROOT/.build/public-api" \
  && OBJS=$(for f in Sources/BridgeCore/*.swift; do printf '%s\n' "$B/BridgeCore.build/$(basename "$f").o"; done) \
  && swiftc -I "$B/Modules" "$ROOT/tests/public-api/main.swift" $OBJS -o "$ROOT/.build/public-api/check" && "$ROOT/.build/public-api/check" | tail -1)
echo "== Cross-language: Lua frame -> rendered pixels -> Swift decoder; Swift slot -> Lua delivery parser"
tests/cross/run.sh
echo "== Packaged addon artifact installs into a clean fake game folder"
tests/package/run.sh
if [ -n "${T3_BIN:-}" ] && [ -x "$T3_BIN" ]; then
  echo "== Real T3 contracts (isolated throwaway server)"
  node tests/isolated-t3/contract.mjs "$T3_BIN" "$ROOT/.build/iso-contract" "$ROOT/.build/fixtures-rerun" | tail -1
  echo "== Cross-process end to end (synthetic game, real bridge, real isolated T3)"
  node tests/e2e/run.mjs "$T3_BIN" "$(cd native && swift build --show-bin-path)/t3wow-bridge" "$LUA" "$ROOT/.build/e2e" "$ROOT/.build/e2e-evidence.json" | tail -1
else
  echo "== SKIPPED: isolated real-T3 suites (set T3_BIN to a T3 v0.1.7 binary)"
fi
echo "== Leak scan (files a commit would contain; redacted report)"
TERMS=(); [ -f "$ROOT/private/leak-terms.txt" ] && TERMS=(--terms "$ROOT/private/leak-terms.txt")
python3 -I scripts/leak_scan.py tracked "$ROOT" --allow scripts/leak-allow.tsv ${TERMS[@]+"${TERMS[@]}"} | tail -n +2
echo "ALL AUTOMATED CHECKS PASSED (synthetic game side; not in-game evidence)"
