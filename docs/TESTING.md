# Testing: what is proven, and how

Evidence comes in three kinds. They are labelled everywhere:

- **SYNTHETIC:** automated tests with a fake game, fake folders, fake screen and so on. They prove the
  logic, not the real client or macOS.
- **ISOLATED REAL T3:** a real T3 binary, started as a throwaway server with its own empty home
  directory. Never your T3 data.
- **AUTHENTIC:** a person ran it on a real Mac with the real game and their own T3. The date and
  scope are recorded in the release notes.

Run everything with `T3_BIN=/path/to/t3 scripts/test-all.sh`.

| Suite | Kind | Proves |
|---|---|---|
| Lua addon (`tests/lua`) | SYNTHETIC | Codecs, delivery parsing, slot budget, outbox, model and work states, Markdown safety, and the whole UI booted from the `.toc`. A strict stub refuses any template, font, texture or atlas the pinned WoW: Forever UI source doesn't define |
| Journal previews (`tests/preview/render.lua`) | SYNTHETIC | The real addon frame tree lays out without stub violations. It writes watermarked SVG layout previews. These are not in-game captures |
| Swift core (`native/Tests`) | SYNTHETIC | Pixel decoder (scaling, colour spaces, displays), capture plan, permission latches, OAuth/MCP client, origin binding, engine (exactly-once sends, restarts, epochs), setup decisions, transactional install/update/repair/uninstall in a clean fake game folder next to other addons, and version consistency |
| Public API | Build | The app target can use BridgeCore through a plain import |
| Cross-language (`tests/cross`) | SYNTHETIC | Lua-drawn frame → rendered pixels → Swift decoder, and Swift slot → Lua parser |
| Package (`tests/package`) | SYNTHETIC | The addon zip installs from the artifact (not the source tree) into a clean fake game folder without touching another addon. It is checked for private material |
| Contracts (`tests/isolated-t3`) | ISOLATED REAL T3 | 57 checks against T3 0.1.7: OAuth approval, pairing codes, scopes, revocation, MCP tools, send replay, access ceilings |
| End to end (`tests/e2e`) | SYNTHETIC game + ISOLATED REAL T3 | Synthetic game ↔ real bridge process ↔ real throwaway T3: pairing, listing, reading, replying, restarts, exactly-once |
| Leak scan (`scripts/leak_scan.py`) | Static | No credentials, personal paths, private hosts or (with your private term list) personal names in committed files |

## Not covered by automation (manual release gates)

- **macOS:** compiling and running the app on macOS. The app layer uses AppKit and ScreenCaptureKit, so
  it builds only on a Mac.
- **First run:** Gatekeeper, the Screen Recording prompt and the Keychain prompts on a clean macOS
  user account.
- **The real game:** the WoW: Forever client loading the addon and its 480 slots, login time, and the
  strip being captured at your resolution and scaling.
- **Duration:** several hours of real play with the pool, Reload UI and reconnecting.
- **A second person:** another person's T3 on another Mac.

Release notes record which of these were done, by whom (role, not name), and when.
