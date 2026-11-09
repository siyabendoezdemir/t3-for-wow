#!/usr/bin/env python3
"""Leak scan for release candidates. Reports REDACTED findings only: rule, location, length and a short
SHA-256 of the match, never the matched value itself.

  python3 -I scripts/leak_scan.py tree    DIR   [--terms FILE] [--allow FILE]
  python3 -I scripts/leak_scan.py history REPO  [--terms FILE] [--allow FILE]
  python3 -I scripts/leak_scan.py zip     FILE  [--terms FILE] [--allow FILE]
  python3 -I scripts/leak_scan.py tracked REPO  [--terms FILE] [--allow FILE]   # files a commit would contain

`history` scans every blob, commit message and author/committer identity reachable from ALL refs
(branches, tags, notes, tool checkpoints) and from the reflog.
`--terms` is an optional private file (one literal per line, e.g. personal names, hostnames). It is never
committed: keep it under private/ (git-ignored). Its terms are matched case-insensitively and are
reported only as "private-term #N".
`--allow` lists "rule<TAB>sha10" pairs that were reviewed and accepted (e.g. a documented placeholder).
Exit status: 0 = no unreviewed findings, 1 = findings, 2 = usage error.
"""
import hashlib, io, os, re, subprocess, sys, zipfile

RULES = [
    ("private-key", re.compile(rb"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("jwt", re.compile(rb"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{5,}")),
    ("bearer-token", re.compile(rb"Bearer\s+[A-Za-z0-9._~+/=-]{16,}")),
    ("github-token", re.compile(rb"\bgh[pousr]_[A-Za-z0-9]{30,}")),
    ("slack-token", re.compile(rb"\bxox[abprs]-[A-Za-z0-9-]{10,}")),
    ("aws-key", re.compile(rb"\bAKIA[0-9A-Z]{16}\b")),
    ("api-key-sk", re.compile(rb"\bsk-(?:ant-)?[A-Za-z0-9_-]{20,}")),
    ("telegram-bot-token", re.compile(rb"\b\d{8,10}:AA[A-Za-z0-9_-]{33}\b")),
    ("secret-assignment", re.compile(rb"(?i)\b(?:client_secret|access_token|refresh_token|api[_-]?key|password|passwd|secret)\b[\"']?\s*[:=]\s*[\"']([^\"'\s]{12,})[\"']")),
    ("home-path", re.compile(rb"/(?:home|Users)/(?!runner\b|USER\b|you\b|<|\$|\{|example\b|name\b|me\b)[A-Za-z0-9._-]+")),
    ("infra-path", re.compile(rb"/mnt/[A-Za-z0-9_.-]+/|/root/|/var/folders/[A-Za-z0-9_]+/")),
    ("email", re.compile(rb"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b")),
    ("public-ipv4", re.compile(rb"\b(?!127\.|0\.0\.0\.0|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.|255\.)(?:\d{1,3}\.){3}\d{1,3}\b")),
    ("private-host", re.compile(rb"(?i)\b[a-z0-9-]+\.(?:ts\.net|ngrok(?:-free)?\.(?:app|io)|trycloudflare\.com)\b|tailscale")),
]
# Matches that are public by construction (documentation domains, tool attribution).
BUILTIN_ALLOW = [
    re.compile(rb"noreply@anthropic\.com"), re.compile(rb"@example\.(?:com|org|net)"), re.compile(rb"\.invalid$"), re.compile(rb"git@github\.com"),
    re.compile(rb"^(?:\d{1,3}\.){3}\d{1,3}$"),  # filtered further below
]
VERSIONISH = re.compile(rb"^(?:\d+\.){3}\d+$")

def h10(b): return hashlib.sha256(b).hexdigest()[:10]

class Scanner:
    def __init__(self, terms, allow):
        self.terms = [t.strip().lower().encode() for t in terms if t.strip() and not t.startswith("#")]
        self.allow = allow
        self.findings = []

    def scan(self, data, where):
        if not data: return
        lines = data.split(b"\n")
        for n, line in enumerate(lines, 1):
            if len(line) > 20000: line = line[:20000]
            for rule, rx in RULES:
                for m in rx.finditer(line):
                    s = m.group(0)
                    if rule == "email" and any(a.search(s) for a in BUILTIN_ALLOW[:4]): continue
                    if rule == "public-ipv4":
                        parts = [int(p) for p in s.split(b".")]
                        if any(p > 255 for p in parts) or VERSIONISH.match(s) and parts[0] < 10: continue
                    self.add(rule, where, n, s)
            low = line.lower()
            for i, t in enumerate(self.terms, 1):
                if t in low: self.add("private-term #%d" % i, where, n, t)

    def add(self, rule, where, n, s):
        key = h10(s)
        if (rule, key) in self.allow: return
        self.findings.append((rule, where, n, len(s), key))

def load_lines(path):
    if not path: return []
    with open(path, encoding="utf-8") as f: return f.read().splitlines()

def scan_tree(sc, root):
    for d, dirs, files in os.walk(root):
        dirs[:] = [x for x in dirs if x not in (".git", ".build", ".deps", "node_modules", "private")]
        for f in files:
            p = os.path.join(d, f)
            if os.path.islink(p): continue
            try:
                with open(p, "rb") as fh: data = fh.read(8 << 20)
            except OSError: continue
            sc.scan(data, os.path.relpath(p, root))

def git(repo, *args, input=None):
    return subprocess.run(["git", "-C", repo, *args], input=input, capture_output=True, check=True).stdout

def scan_history(sc, repo):
    refs = git(repo, "for-each-ref", "--format=%(refname)").decode().split()
    revs = set(refs)
    try:
        for line in git(repo, "reflog", "--all", "--format=%H").decode().split(): revs.add(line)
    except subprocess.CalledProcessError: pass
    objs = git(repo, "rev-list", "--objects", "--all", "--reflog").decode().splitlines()
    blobs = {}
    for line in objs:
        sha, _, path = line.partition(" ")
        blobs.setdefault(sha, path)
    kinds = git(repo, "cat-file", "--batch-check=%(objectname) %(objecttype) %(objectsize)", input="\n".join(blobs).encode()).decode().splitlines()
    commits = 0; nblobs = 0
    for k in kinds:
        sha, typ, size = k.split()
        if typ == "blob" and int(size) <= (8 << 20):
            sc.scan(git(repo, "cat-file", "blob", sha), "blob %s (%s)" % (sha[:10], blobs[sha] or "?")); nblobs += 1
        elif typ == "commit":
            sc.scan(git(repo, "cat-file", "commit", sha), "commit %s" % sha[:10]); commits += 1
    print("history scope: %d refs, %d commits (incl. reflog), %d blobs" % (len(refs), commits, nblobs))

def scan_tracked(sc, repo):
    names = git(repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard").split(b"\0")
    n = 0
    for name in names:
        if not name: continue
        p = os.path.join(repo, name.decode())
        if os.path.isfile(p) and not os.path.islink(p):
            with open(p, "rb") as fh: sc.scan(fh.read(8 << 20), name.decode()); n += 1
    print("tracked scope: %d files (tracked + untracked, not ignored)" % n)

def scan_zip(sc, path):
    with zipfile.ZipFile(path) as z:
        for i in z.infolist():
            if not i.is_dir(): sc.scan(z.read(i), "%s:%s" % (os.path.basename(path), i.filename))
            sc.scan(i.filename.encode(), "%s:<name>" % os.path.basename(path))

def main(argv):
    if len(argv) < 3 or argv[1] not in ("tree", "history", "zip", "tracked"): print(__doc__); return 2
    terms = load_lines(argv[argv.index("--terms") + 1]) if "--terms" in argv else []
    allow = set()
    if "--allow" in argv:
        for l in load_lines(argv[argv.index("--allow") + 1]):
            if l.strip() and not l.startswith("#"):
                r, k = l.split("\t")[:2]; allow.add((r, k))
    sc = Scanner(terms, allow)
    {"tree": scan_tree, "history": scan_history, "zip": scan_zip, "tracked": scan_tracked}[argv[1]](sc, argv[2])
    by_rule = {}
    for f in sc.findings: by_rule.setdefault(f[0], []).append(f)
    print("scan %s %s: %d finding(s)%s" % (argv[1], os.path.basename(os.path.abspath(argv[2])), len(sc.findings), " (private terms: %d)" % len(sc.terms) if sc.terms else ""))
    for rule in sorted(by_rule):
        fs = by_rule[rule]
        print("  %-20s %d" % (rule, len(fs)))
        seen = set()
        for r, where, n, ln, key in fs:
            if (where.split(" (")[-1], key) in seen: continue
            seen.add((where.split(" (")[-1], key))
            print("    %s:%d len=%d sha=%s" % (where, n, ln, key))
    return 1 if sc.findings else 0

if __name__ == "__main__":
    sys.exit(main(sys.argv))
