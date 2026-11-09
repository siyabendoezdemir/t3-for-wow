# Security policy

## Reporting a vulnerability

Please report privately; do not open a public issue. Use GitHub's **Report a vulnerability**
(Security → Advisories) on this repository. Include steps to reproduce and the version (menu bar →
About, or the addon's `## Version`). You should get a reply within 7 days. Please allow 90 days, or
until a fix ships, before disclosing.

Do not include real T3 tokens, Keychain contents, private thread contents or screenshots of your
game in a report. Redacted values and synthetic reproductions are enough.

## Supported versions

Only the latest release gets fixes.

## Security model, in short

**What is trusted:**
- your macOS user account and Keychain;
- the T3 address you approved;
- the game client's own UI code.

**What is untrusted:**
- every byte of agent and thread text, which the addon displays only after neutralising WoW escapes;
- anything on screen other than this addon's strip;
- the contents of the game folder apart from this app's own folders.

**Hard rules the code and tests enforce:**
- **Token handling:** the bearer token is bound to the exact T3 origin it was approved for. It is
  never sent to another origin, and HTTP redirects are refused.
- **Token storage:** it is stored only in the login Keychain.
- **Approvals:** pairing happens only on T3's own approval page, after your click. Nothing is approved,
  re-paired or retried with credentials on your behalf.
- **Sending:** each send carries a request id that T3 de-duplicates. Sends never move to another thread.
- **Game folder:** the installer touches only `T3ForWoW` and `T3ForWoW_Slot####` folders, and it works
  transactionally (any failure restores the previous state, or keeps a recovery copy and says so).
- **No following links:** every install, repair, rollback, runtime slot write and uninstall refuses to
  work through a symbolic link. This applies to `Interface`, `AddOns`, owned folders and slot files.
  Writes and deletes can't land outside the selected game tree.
- **Uninstall:** refused while the game runs, checked again at the moment files would be removed.
  Unreadable folders and anything left behind are reported as failures.
- **Capture:** limited to the WoW window's top band. Nothing is stored.
- **Addon:** no network access exists in the game; received text is never run as code.

## Out of scope

The out-of-scope cases below are covered in [docs/LIMITS.md](docs/LIMITS.md):
- local attackers who already control your macOS user account;
- T3's own authorization model and scopes (please report those to T3);
- Blizzard's terms.
