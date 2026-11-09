# Changelog

## 0.9.1 — release candidate 2

RC1 was not accepted. An independent review reproduced three destructive-path bugs and a timing gap.

**Fixed**
- **Linked AddOns or Interface folder:** uninstall followed it and could delete an exact-name
  `T3ForWoW` folder elsewhere. Install-target validation and every mutation now refuse linked
  `Interface`/`AddOns` folders. External folders survive.
- **Linked slot folder or slot file:** install, repair and runtime writes followed an exact-name link
  and overwrote `Slot.lua`/TOC files elsewhere. Every owned folder and file is now checked with
  no-follow (`lstat`) before each write, during validation, in the transaction, in rollback and in the
  runtime slot writer. Install refuses before any change.
- **Unreadable AddOns folder:** it was reported as a successful zero-folder uninstall. A missing folder
  is still a harmless 0. Unreadable folders, removal errors and anything still present after a
  read-back are now reported as failures. The app says "only partly removed" and lists what is left.
- **Game started during the dialog:** the game-running refusal was checked only before the confirmation
  dialog. The uninstall logic now lives in `BridgeCore.Uninstaller`. It refuses at entry and again
  immediately before removing game files, whichever UI calls it. Tested with an injected provider.

**Docs**
- GitHub Releases is described as the *confirmed* route, not the only workable one. The CurseForge,
  Wago and WoWInterface entries are now "unconfirmed, on hold", with current companion-addon
  counterexamples. The official Homebrew cask needs a signed and notarized app.
- The Blizzard section cites both relevant EULA clauses and the policy's no-negative-impact rule. It
  states that this is not legal advice or a clearance.

## 0.9.0 — release candidate 1

This is the first release meant for people other than the author.

**In game**
- *T3 Journal* in the Map & Quest Log style:
  - a breadcrumb, `T3 › project › thread`;
  - a parchment page for the open thread;
  - a quest-log column with search, collapsible projects and status marks.
- Truthful work indicator: the spinner turns only while T3 has recently confirmed a running run.
  Otherwise the thread shows "Status unknown" or its last known state. Ages keep counting while the
  link is quiet.
- Agent Markdown is rendered as clean WoW text: headings, emphasis, code, lists, tasks, quotes, links
  and tables.
- Tracker with the same states and spinner.
- Slash commands: `/t3 help`, `/t3 tracker`, `/t3 reset`.

**Mac app**
- Menu-bar utility with one next step at a time: Connect T3 → Install Addon → Check Capture Access →
  play.
- **Uninstall…** in Settings removes the addon folders, the Keychain approval, Open at login and the
  app's own data, then explains how to revoke the connection in T3. It is refused while the game runs.
- Install, update and repair are transactional. Uninstall touches only exact `T3ForWoW` and
  `T3ForWoW_Slot####` folder names.
- Pairing-code help moved from the menu to the install guide.

**Project**
- Public docs: install (with every click and consent), privacy, limits, security, testing, releasing.
- Reproducible release candidate: sanitized source export, addon package, checksums and a redacted
  leak-scan report (`scripts/release-candidate.sh`).
- Leak scanner (`scripts/leak_scan.py`) runs in `scripts/test-all.sh`.
