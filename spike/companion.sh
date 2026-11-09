#!/usr/bin/env bash
# Companion for the bounded transport probe (spike/T3ForWoW_Probe). Touches ONLY folders named
# T3ForWoW_Probe* inside the AddOns folder you pass. Never starts, stops or sends input to the game.
#   companion.sh prepare <AddOnsDir>   # before starting the game
#   companion.sh run     <AddOnsDir>   # right after "T3PROBE ... READY" appears in chat
#   companion.sh clean   <AddOnsDir>   # afterwards (game closed)
#   companion.sh pool    <AddOnsDir> N # optional H4: N dummy LoD folders to time startup; 0 removes
set -euo pipefail
CMD=${1:?prepare|run|clean|pool}; A=${2:?AddOns dir}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -d "$A" ] && [ "$(basename "$A")" = AddOns ] || { echo "not an AddOns folder: $A" >&2; exit 2; }
FONT_SRC=${FONT_SRC:-/System/Library/Fonts/Supplemental/Arial.ttf}   # local spike file only; never distributed
ts() { date +%s; }
lod() { # name file-listed
  mkdir -p "$A/$1"
  printf '## Interface: 16001\n## Title: T3 probe %s\n## LoadOnDemand: 1\n## Dependencies: T3ForWoW_Probe\n## Group: T3ForWoW_Probe\nSlot.lua\n' "$1" > "$A/$1/$1.toc"
}
case "$CMD" in
  prepare)
    rm -rf "$A"/T3ForWoW_Probe*
    cp -R "$HERE/T3ForWoW_Probe" "$A/T3ForWoW_Probe"
    lod T3ForWoW_ProbeL1; echo 'T3ForWoWProbe_Ran("L1", 1)' > "$A/T3ForWoW_ProbeL1/Slot.lua"
    lod T3ForWoW_ProbeL2   # Slot.lua deliberately missing
    rm -f "$A/T3ForWoW_Probe/bell.ttf"
    echo "prepared at $(ts). Start WoW, enable 'T3 probe' at character select if needed, log in." ;;
  run)
    T=$(ts); echo "run start $T (align with the probe's READY line)"
    sleep 10; echo 'T3ForWoWProbe_Ran("L1", 2)' > "$A/T3ForWoW_ProbeL1/Slot.lua"; echo "+$(( $(ts)-T ))s L1 rewritten (v2)"
    sleep 20; echo 'T3ForWoWProbe_Ran("L2", 1)' > "$A/T3ForWoW_ProbeL2/Slot.lua"; lod T3ForWoW_ProbeL3; echo 'T3ForWoWProbe_Ran("L3", 1)' > "$A/T3ForWoW_ProbeL3/Slot.lua"; echo "+$(( $(ts)-T ))s L2 file created, L3 folder created"
    sleep 10; cp "$FONT_SRC" "$A/T3ForWoW_Probe/bell.ttf"; echo "+$(( $(ts)-T ))s bell.ttf created"
    sleep 30; rm -f "$A/T3ForWoW_Probe/bell.ttf"; echo "+$(( $(ts)-T ))s bell.ttf deleted"
    sleep 30; cp "$FONT_SRC" "$A/T3ForWoW_Probe/bell.ttf"; echo "+$(( $(ts)-T ))s bell.ttf re-created"
    echo "done; wait for 'T3PROBE ... DONE', then copy the chat lines (or log out to save T3ForWoWProbeDB)" ;;
  clean) rm -rf "$A"/T3ForWoW_Probe*; echo cleaned ;;
  pool)
    N=${3:?N}; rm -rf "$A"/T3ForWoW_ProbePool*
    for i in $(seq 1 "$N"); do d=$(printf 'T3ForWoW_ProbePool%04d' "$i"); lod "$d"; echo "-- empty" > "$A/$d/Slot.lua"; done 2>/dev/null
    echo "pool of $N dummy LoD folders; restart the game and read loadToLogin_ms / addons in the READY line" ;;
  *) echo "unknown command" >&2; exit 2 ;;
esac
