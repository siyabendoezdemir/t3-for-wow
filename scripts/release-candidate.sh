#!/usr/bin/env bash
# Private release candidate from the CURRENT COMMIT (clean working tree required):
#   source/                         sanitized export (packaging/export-manifest.txt), fresh 1-commit history
#   t3-for-wow-<ver>-src.tar.gz     deterministic git archive of that export
#   T3ForWoW-addon-<ver>.zip        addon as installed (built from the export)
#   SHA256SUMS  CONTENTS.txt  LEAK-SCAN.txt
#   TEST-*.log                      with --test: the full suite run inside the export (independent-style)
# Never pushes, uploads, publishes, signs or touches a game/device. Stops on any unreviewed leak finding.
#
#   scripts/release-candidate.sh OUT_DIR [--terms private/leak-terms.txt] [--test] [--t3 /path/to/t3]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT"
OUT=${1:?usage: release-candidate.sh OUT_DIR [--terms FILE] [--test] [--t3 PATH]}; shift
TERMS=() ; RUN_TESTS=0 ; T3=""
while [ $# -gt 0 ]; do
  case "$1" in
    --terms) TERMS=(--terms "$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2 ;;
    --test) RUN_TESTS=1; shift ;;
    --t3) T3=$2; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -z "$(git status --porcelain)" ] || { echo "refusing: working tree is not clean (commit first)" >&2; exit 1; }
VER=$(tr -d '[:space:]' < VERSION)
DATE=$(git show -s --format=%cI HEAD)
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
[ ! -e "$OUT/source" ] || { echo "refusing: $OUT/source already exists" >&2; exit 1; }
SCAN() { python3 -I "$ROOT/scripts/leak_scan.py" "$@" --allow "$ROOT/scripts/leak-allow.tsv" ${TERMS[@]+"${TERMS[@]}"}; }

echo "== 1. export allowlisted paths from HEAD (not the working tree)"
PATHS=()
while IFS= read -r l; do case "$l" in ''|'#'*) ;; *) PATHS+=("$l") ;; esac; done < packaging/export-manifest.txt
mkdir -p "$OUT/source"
git archive --format=tar HEAD -- "${PATHS[@]}" | tar -x -C "$OUT/source"
for internal in CURRENT-STATE.md PRODUCT-BRIEF.md docs/EVIDENCE.md docs/OWNER-RUN.md docs/VISUAL-FEEDBACK.md docs/TRANSPORT-DECISION.md private; do
  [ ! -e "$OUT/source/$internal" ] || { echo "refusing: internal path $internal in export" >&2; exit 1; }
done
# every relative Markdown link in the export must resolve inside the export
python3 -I - "$OUT/source" <<'PY'
import os, re, sys
root = sys.argv[1]; bad = []
for d, _, fs in os.walk(root):
    for f in fs:
        if not f.endswith(".md"): continue
        p = os.path.join(d, f)
        for m in re.finditer(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", open(p, encoding="utf-8").read()):
            t = m.group(1)
            if re.match(r"^[a-z]+:", t): continue
            if not os.path.exists(os.path.normpath(os.path.join(d, t))): bad.append("%s -> %s" % (os.path.relpath(p, root), t))
if bad: print("dangling links:\n  " + "\n  ".join(bad)); sys.exit(1)
print("markdown links: all resolve inside the export")
PY

echo "== 2. fresh history (one commit, neutral author, release commit date)"
(cd "$OUT/source" && git init -q && git checkout -q -b main 2>/dev/null || true
 cd "$OUT/source" && git add -A && \
 GIT_AUTHOR_NAME="T3 for WoW contributors" GIT_AUTHOR_EMAIL="t3forwow@users.noreply.invalid" \
 GIT_COMMITTER_NAME="T3 for WoW contributors" GIT_COMMITTER_EMAIL="t3forwow@users.noreply.invalid" \
 GIT_AUTHOR_DATE="$DATE" GIT_COMMITTER_DATE="$DATE" \
 git -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -q -m "T3 for WoW $VER")
EXPORT_REV=$(git -C "$OUT/source" rev-parse HEAD)

echo "== 3. source tarball + addon zip"
TAR=t3-for-wow-$VER-src.tar.gz
git -C "$OUT/source" archive --format=tar --prefix="t3-for-wow-$VER/" HEAD | gzip -n -9 > "$OUT/$TAR"
STAGE=$(mktemp -d); git -C "$OUT/source" archive --format=tar HEAD | tar -x -C "$STAGE"
ADDON_ZIP=$("$STAGE/packaging/build-addon.sh"); cp "$ADDON_ZIP" "$OUT/"; rm -rf "$STAGE"
ZIP=$(basename "$ADDON_ZIP")

echo "== 4. contents + checksums"
{ echo "# T3 for WoW $VER release candidate — contents"
  echo "export commit: $EXPORT_REV (fresh history; author 'T3 for WoW contributors')"
  echo; echo "## $TAR (git blob ids)"; git -C "$OUT/source" ls-tree -r --format='%(objectname) %(objectsize) %(path)' HEAD
  echo; echo "## $ZIP"
  python3 -I -c "import zipfile,sys,hashlib
z=zipfile.ZipFile(sys.argv[1])
for i in z.infolist():
    if not i.is_dir(): print(hashlib.sha256(z.read(i)).hexdigest()[:16], i.file_size, i.filename)" "$OUT/$ZIP"
} > "$OUT/CONTENTS.txt"
(cd "$OUT" && (shasum -a 256 "$TAR" "$ZIP" 2>/dev/null || sha256sum "$TAR" "$ZIP") > SHA256SUMS)

echo "== 5. leak scan (redacted)"
UNPACK=$(mktemp -d); tar -xzf "$OUT/$TAR" -C "$UNPACK"
set +e
{ echo "# Leak scan — T3 for WoW $VER release candidate (redacted: rule, location, length, sha256 prefix only)"
  if [ ${#TERMS[@]} -gt 0 ]; then echo "private term list: supplied ($(grep -cvE '^[[:space:]]*(#|$)' "${TERMS[1]}") terms; terms and file location not included)"
  else echo "private term list: not supplied"; fi
  echo; SCAN tree "$OUT/source"; a=$?
  echo; SCAN history "$OUT/source"; b=$?
  echo; SCAN tree "$UNPACK"; c=$?
  echo; SCAN zip "$OUT/$ZIP"; d=$?
  echo; echo "commit identities in export history:"; git -C "$OUT/source" log --all --format='  %an <%ae> / %cn <%ce>' | sort -u
  echo; [ $((a+b+c+d)) -eq 0 ] && echo "RESULT: no unreviewed findings" || echo "RESULT: FINDINGS — release candidate refused"
} > "$OUT/LEAK-SCAN.txt"
set -e
rm -rf "$UNPACK"
cat "$OUT/LEAK-SCAN.txt"
grep -q "^RESULT: no unreviewed findings" "$OUT/LEAK-SCAN.txt" || exit 1

if [ "$RUN_TESTS" = 1 ]; then
  echo "== 6. full suite inside a fresh clone of the export (pinned .deps reused read-only via symlink)"
  CLONE=$(mktemp -d)/t3-for-wow; git clone -q "$OUT/source" "$CLONE"
  ln -s "$ROOT/.deps" "$CLONE/.deps"
  [ -z "$T3" ] || export T3_BIN=$T3
  (cd "$CLONE" && scripts/test-all.sh) > "$OUT/TEST-export-clone.log" 2>&1 && R=PASS || R=FAIL
  sed -i.bak -e "s#$CLONE#<clone>#g" -e "s#$ROOT#<repo>#g" -e "s#$HOME#<home>#g" "$OUT/TEST-export-clone.log" && rm -f "$OUT/TEST-export-clone.log.bak"
  echo "suite in export clone: $R (log: TEST-export-clone.log)"
  rm -rf "$(dirname "$CLONE")"
  [ "$R" = PASS ] || exit 1
fi
echo "release candidate: $OUT"
cat "$OUT/SHA256SUMS"
