#!/usr/bin/env bash
# Project-local development tools (no sudo, no global installs). All pinned by SHA-256.
#   * Lua 5.1.5 (the Lua dialect WoW embeds) for addon tests
#   * Linux only: Swift 6.1.2 toolchain (matches the macOS build host's Command Line Tools)
#   * pinned WoW: Forever generated UI source (read-only reference for the strict test stub;
#     never redistributed)
# Set T3WOW_DL_CACHE to a directory holding already-downloaded tarballs to avoid re-downloading;
# their checksums are verified exactly like fresh downloads.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
DL=$ROOT/.deps/dl
mkdir -p "$DL"
sha() { (shasum -a 256 "$1" 2>/dev/null || sha256sum "$1") | cut -d' ' -f1; }
fetch() { # name url sha
  local f=$DL/$1
  if [ ! -f "$f" ] && [ -n "${T3WOW_DL_CACHE:-}" ] && [ -f "$T3WOW_DL_CACHE/$1" ]; then cp "$T3WOW_DL_CACHE/$1" "$f"; fi
  [ -f "$f" ] || curl -fL -o "$f" "$2"
  [ "$(sha "$f")" = "$3" ] || { echo "checksum mismatch for $1" >&2; rm -f "$f"; exit 1; }
}

if [ ! -x "$ROOT/.deps/lua-5.1.5/src/lua" ]; then
  fetch lua-5.1.5.tar.gz https://www.lua.org/ftp/lua-5.1.5.tar.gz 2640fc56a795f29d28ef15e13c34a47e223960b0240e8cb0a82d9b0738695333
  tar xzf "$DL/lua-5.1.5.tar.gz" -C "$ROOT/.deps"
  if [ "$(uname -s)" = Darwin ]; then (cd "$ROOT/.deps/lua-5.1.5" && make -s macosx >/dev/null)
  else (cd "$ROOT/.deps/lua-5.1.5" && make -s posix MYLIBS="-ldl" >/dev/null); fi
fi
"$ROOT/.deps/lua-5.1.5/src/lua" -v

if [ "$(uname -s)" = Linux ] && [ ! -x "$ROOT/.deps/swift/usr/bin/swift" ]; then
  F=swift-6.1.2-RELEASE-ubuntu24.04.tar.gz
  fetch $F https://download.swift.org/swift-6.1.2-release/ubuntu2404/swift-6.1.2-RELEASE/$F d749d5fe2d6709ee988e96b16f02bca7b53304d09925e31063fd5ec56019de9f
  mkdir -p "$ROOT/.deps/swift" && tar xzf "$DL/$F" -C "$ROOT/.deps/swift" --strip-components=1
fi

REF=9dc84f0d3bbae1768ac3405b3716000bd93eda06
if [ ! -d "$ROOT/.deps/wow-ui-source-$REF/Interface/AddOns" ]; then
  fetch wow-ui-source-$REF.tgz "https://codeload.github.com/Gethe/wow-ui-source/tar.gz/$REF" 3c2c1a44ff256ee7921c7b4a45494daee59629b29a0f71b0e3b72cdad17d222c
  tar xzf "$DL/wow-ui-source-$REF.tgz" -C "$ROOT/.deps"
fi
echo "wow-ui-source $REF (WoW: Forever 1.60.1.70862) present"
