# T3 for WoW

See what **your own** T3 (T3 Code) agents are doing while you play World of
Warcraft: Forever, read the real conversation, and reply to the exact thread — without alt-tabbing.

- **In game:** a quest-log-style *T3 Journal* (`/t3`) and a small tracker. Threads that need you come first.
  A spinner turns only while an agent is really working. Agent Markdown is shown as clean WoW text.
- **On your Mac:** a small menu-bar app that connects your T3 to the game. It installs the addon for you.

Free and open source (MIT). Unofficial: not made, approved or supported by T3 or Blizzard. Each person
uses **their own** T3 and their own approval. There is no hosted service, shared account, relay,
telemetry or paid component.

> **Status: 0.9.1 release candidate.** It has been used on one Mac with the real game and its owner's T3. It has not yet been tested on a
> second person's Mac, and the app is not notarized by Apple. See [Known limits](docs/LIMITS.md).

## What you need

| | |
|---|---|
| Mac | Apple silicon, macOS 14 Sonoma or newer |
| Game | World of Warcraft: Forever (the `_forever_` client), on that Mac |
| T3 | Your own T3 (tested with 0.1.7), running on this Mac or reachable from it, signed in in your browser |

Windows, Intel Macs and other WoW flavours are not supported in this release.

## Install (about 10 clicks, one game restart)

1. Download `T3ForWoW-mac-<version>.zip` from Releases, open it, and move **T3 for WoW** to Applications.
2. Open it. macOS blocks apps that are not notarized. Go to **System Settings → Privacy & Security** and
   click **Open Anyway**, then enter your password.
3. Click the **T3** item in the menu bar and follow its single next step:
   **Connect T3…** (approve on T3's own page) → **Install Addon** → **Check Capture Access** (allow
   Screen Recording for T3 for WoW) → start WoW.
4. In game, type `/t3`.

Every click, permission and password prompt is listed in [docs/INSTALL.md](docs/INSTALL.md), along with
updating, uninstalling and troubleshooting.

## How it works

```
WoW addon ──(small pixel strip at the top of the game window)──▶ T3 for WoW.app ──(T3's own tools)──▶ your T3
WoW addon ◀──(load-on-demand "delivery slot" addon folders)──── T3 for WoW.app
```

The game gives addons no network or file access. So the addon shows a tiny coloured strip, and the app
reads only that strip with macOS Screen Recording. Replies go the other way through small addon files
that the game loads on demand. The details are in [docs/PROTOCOL.md](docs/PROTOCOL.md).

- The addon never makes network requests and never runs received text as code. Agent text is shown with
  WoW's escape codes neutralised.
- The app talks only to the T3 address you approved. Your approval is stored only in your macOS
  Keychain. Revoke it at any time in T3 → Settings → Connections.
- Each message carries a request id that T3 itself de-duplicates. Retries, reloads and crashes never
  send twice or to another thread.

What the app reads, stores and sends is described in [docs/PRIVACY.md](docs/PRIVACY.md).

## Known limits (short version)

- **Finite updates per game session:** the game loads each delivery slot once per UI session. 480 slots
  last about 8 hours of continuous tracking. After that the journal offers **Reload UI** (it never
  reloads by itself).
- **Re-approval:** a T3 approval lasts 30 days. The app warns you 3 days ahead.
- **Not notarized:** the first open needs "Open Anyway". An update to the app may ask again for Screen
  Recording and Keychain access.
- **Blizzard's rules:** Blizzard has not reviewed or approved this project, and two clauses of its EULA
  may apply to a companion app like this one. This is not legal advice or a clearance. Read
  [docs/LIMITS.md](docs/LIMITS.md#blizzard) before using it on an account you care about.

## Build and test from source

```sh
scripts/bootstrap-dev.sh                  # pinned Lua 5.1.5, Swift 6.1.2 (Linux), WoW UI reference
T3_BIN=/path/to/t3 scripts/test-all.sh    # every suite; real-T3 suites use a throwaway isolated server
packaging/build-app.sh                    # macOS: app bundle + zip + checksums (ad-hoc signed)
```

Read [docs/TESTING.md](docs/TESTING.md) for what each suite proves, and which evidence is synthetic.
Read [docs/RELEASING.md](docs/RELEASING.md) for building a release, signing and the distribution routes.

**Layout:**
- `addon/T3ForWoW`: Lua addon.
- `native/Sources/BridgeCore`: portable Swift — codecs, OAuth/MCP, engine, installer, setup logic.
- `native/Sources/App`: macOS menu-bar app.
- `native/Sources/HeadlessBridge`: test-only bridge.
- `tests/`: the test suites.

## Contributing, security, licence

- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md).
- Reporting vulnerabilities: [SECURITY.md](SECURITY.md).
- Licence: [LICENSE](LICENSE) (MIT). Third-party notices: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

"T3" and "World of Warcraft" belong to their owners. Their names are used only to say what this works with.
