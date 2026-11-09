# Releasing (maintainers)

## 1. Release candidate from source (any OS)

```sh
scripts/release-candidate.sh <out-dir>          # e.g. ../t3-for-wow-rc
```

The script needs a clean checkout at the commit to release. It writes:

- `source/`: a **sanitized source export**. Files are selected by the allowlist in
  `packaging/export-manifest.txt`. It starts a fresh git history with one commit and a neutral author.
  Internal notes and the original history are never included.
- `t3-for-wow-<version>-src.tar.gz`: `git archive` of that export, which is deterministic.
- `T3ForWoW-addon-<version>.zip`: the addon exactly as installed, without slots. The app installs it;
  this zip exists for review and for addon sites.
- `SHA256SUMS` and `CONTENTS.txt`: digests and full file lists.
- `LEAK-SCAN.txt`: a redacted scan of the export tree, its history, the zip and the tarball. The release
  stops if anything unreviewed is found. Pass `--terms private/leak-terms.txt` (git-ignored) to also
  search for personal names or hosts.

## 2. macOS app (on a Mac)

From the exported `source/` (or the tarball), on macOS 14+ with Xcode Command Line Tools (Swift 6.1+):

```sh
scripts/bootstrap-dev.sh
T3_BIN=/path/to/t3 packaging/build-app.sh       # tests, release build, bundle, signature, zip, checksums
```

`build-app.sh` writes `dist/T3ForWoW-mac-<version>.zip`. It contains **T3 for WoW.app**, a
**Read Me First.txt** and the licence, plus a `SHA256SUMS` entry.

**Signing:**
- Default is ad hoc (`SIGN_IDENTITY=-`).
- To keep macOS permissions stable across your own updates, sign with the same identity every time:
  `SIGN_IDENTITY="<your identity>" packaging/build-app.sh`. Never commit identities, certificates or
  passwords.
- **Gate:** Developer ID signing and notarization (`xcrun notarytool`) need a paid Apple Developer
  Program membership. Until then the app is distributed as "not notarized", and
  [INSTALL.md](INSTALL.md) explains Open Anyway.

**Bundle identity:** the bundle identifier `local.t3forwow.bridge` and the Keychain service `T3ForWoW`
must not change between releases. macOS ties the user's Screen Recording grant and Keychain item to
them.

## 3. Distribution routes (checked 2026-11-09; re-check before publishing)

| Route | Status | Notes |
|---|---|---|
| GitHub Releases (app zip + addon zip + checksums) | **Confirmed** | Supports release notes and binary assets, and works without a paid account. Users follow the Open Anyway steps. "Confirmed" means verified as available, not that it is the only possible route |
| Official Homebrew cask (homebrew/cask) | **Unavailable** while the app is not signed and notarized | Homebrew's cask audit requires casks to be signed and notarized by Apple |
| Self-hosted Homebrew tap | Not evaluated | Separate from the official cask list. Check Homebrew's current tap rules before relying on it |
| CurseForge | **Unconfirmed, on hold** | **Counterexamples exist:** CurseForge lists companion addons whose descriptions require a separately installed desktop app (TSM AppHelper, WeakAuras Companion), so an addon-only listing that states the app requirement is not ruled out. No current rule was found that settles this design (screen-pixel companion, about 480 slot folders, files rewritten by the app). The package rules expect one root folder and allow no external download links. Never bundle the app |
| Wago Addons | **Unconfirmed, on hold** | Its current terms could not be retrieved. No rule was found either way |
| WoWInterface | **Unconfirmed, on hold** | Its FAQ says executables are not normally allowed in uploads. An addon-only upload that states the app requirement was not ruled on |

Comparable projects (WeakAuras Companion, Raider.IO, TradeSkillMaster) ship the addon on addon sites and
the desktop app from their own site or GitHub. None of them is precedent for reading screen pixels. Any
listing also depends on the Blizzard question in [LIMITS.md](LIMITS.md#blizzard), which these sites
expect projects to follow.

## 4. Checklist before publishing

- [ ] `scripts/test-all.sh` passes on Linux **and** on the Mac that builds the app.
- [ ] `release-candidate.sh` leak scan is clean (with your private terms file).
- [ ] App built, opened from the zip on a Mac, and `--export-previews` checks passed.
- [ ] Clean-install walkthrough on a second Mac and macOS user with their own T3 (record date and role).
- [ ] At least one long real session (more than 2 h, Reload UI path, reconnect).
- [ ] Release notes state the not-notarized status, the limits, and which evidence is authentic and
      which is synthetic.
- [ ] The owner approves publishing. Repository visibility and uploads are manual owner actions.
