# Known limits and honest disclosures

## Supported

- **Supported setup:** macOS 14+ on Apple silicon, World of Warcraft: Forever (`_forever_`), and your own
  T3 (tested with 0.1.7).
- **Not supported in this release:** Windows, Intel Macs, Retail, Classic or Classic Era clients, more
  than one WoW folder at a time, and voice or images.

## Blizzard

**This is not legal advice, and nothing here is a clearance.** Blizzard has **not** reviewed or
approved this project, and the maintainers have not asked. Whether to use it, and on which account,
is your own risk decision.

Blizzard's rules and how this project relates to them:

- **The UI Add-On Development Policy** requires add-ons to be free and their code to be visible (not
  obfuscated). This project meets those two points.
  - **That is not overall compliance.** The policy also says add-ons must not have a negative impact on
    realms or other players, and Blizzard keeps the discretion to decide.
  - **Unmeasured cost:** how long the game takes to log in with this addon's 481 folders has not been
    measured.
- **Blizzard's EULA** (last revised 21 March 2024) has two clauses that may apply. Blizzard says it may
  allow some third-party user interfaces at its discretion:
  - A *Data Mining* clause prohibits unauthorized software that "intercepts, collects, reads, or
    'mines' information generated or stored by" the Platform. The companion app reads pixels that this
    addon draws in the game window.
  - A separate clause prohibits unauthorized code or software used with the Platform that changes or
    facilitates gameplay or other functionality. The companion app also writes the data files the
    addon loads.
- **Design facts, which are not a defence:**
  - The app reads only the strip this addon draws. It doesn't read game memory, game data or other
    addons.
  - It sends no input to the game and doesn't automate play.
  - Blizzard has not said whether either clause covers this design.

Blizzard's published contact for add-on developer questions is WoWUI@blizzard.com.

## Not notarized

The app is signed ad hoc, not with an Apple Developer ID, and it is not notarized. Notarization needs
a paid Apple Developer Program membership, which this project doesn't have yet. As a result:
- **First open:** macOS blocks it. You allow it once in System Settings → Privacy & Security → Open
  Anyway (macOS Sequoia removed the Control-click shortcut).
- **Updates:** macOS may treat each new build as a different app. It can ask again for Open Anyway,
  for Screen Recording, and for Keychain access to your saved approval.
- **Verification:** you can check the download against the published `SHA256SUMS`, and you can build
  it yourself from source (see [RELEASING.md](RELEASING.md)).

## Finite updates per game session

WoW addons cannot open sockets or read files at runtime. The app delivers data through a pool of
load-on-demand addon folders (480 by default), and the game can load each one only once per UI
session.

| Use | Slots | Notes |
|---|---|---|
| Continuous tracking | about 1 per minute at the normal pace | about 8 hours for 480 slots |
| Typical 4-hour evening | about 264 | Measured, synthetic |

The window shows "updates used/total". When the pool runs out, the journal shows **Reload UI** and never
reloads by itself. `/reload` (or relogging) starts a new pool.

These numbers come from a synthetic measurement (`docs/evidence/pool-budget.jsonl`). How long the
game takes to log in with 481 addon folders has not been measured.

## Other limits

- **T3 approval:** lasts 30 days, with no silent refresh. The app warns 3 days ahead.
- **T3 permissions:** threads that run with Full access are read-only from WoW unless you approved
  this app with Full access. Answering T3 approvals or questions from WoW is not possible: T3 0.1.7
  doesn't allow it over MCP. The journal says "answer in T3".
- **Agent work:** sub-agent or child work isn't listed. "Run finished" never means "verified".
  "Working" is shown only while T3 has confirmed it recently.
- **History:** shows a bounded recent history per thread. "Older…" loads more, a page at a time.
- **Message attribution:** messages from WoW show in T3 as sent by an MCP client.
- **The strip:** a small coloured block at the top-centre of the game window. Keep the top of the window
  visible on screen.
- **One person, one Mac:** each install pairs with one T3 for one macOS user. There is no sharing.

## Testing status

- **Real use:** used on one Mac with one T3 and the real game (owner-run).
- **Not yet tested:** a clean install on a second person's Mac and account. This is a release gate.
- **What the automated tests do and don't prove:** see [TESTING.md](TESTING.md).
