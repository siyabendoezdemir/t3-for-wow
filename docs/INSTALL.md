# Installing T3 for WoW

One download (the Mac app) installs everything. The app carries the addon inside it and installs it
into your game when you click **Install Addon**. You don't need Node, Python, Homebrew or Terminal.

## Before you start

- A Mac with Apple silicon, running macOS 14 Sonoma or newer.
- World of Warcraft: Forever installed on that Mac (the folder that contains `_forever_`).
- **Your own T3**, running and signed in in your default browser. It can run on this Mac or on a
  machine this Mac can reach. Nobody else's T3 is used, and nothing is shared with the authors.

## Steps, with every click and consent

Counts assume a first install with T3 on this Mac. Steps marked **macOS** or **T3** are their own
dialogs. This app never answers them for you and never works around them.

| # | You do | Who asks | Clicks / input | Notes |
|---|---|---|---|---|
| 1 | Download `T3ForWoW-mac-<version>.zip` and check it against `SHA256SUMS` (optional) | — | 1 | GitHub Releases |
| 2 | Double-click the zip, then drag **T3 for WoW** into Applications | — | 2 | |
| 3 | Open **T3 for WoW**; macOS says it cannot verify the developer → **Done** | **macOS** Gatekeeper | 1 | The app is not notarized (see [Limits](LIMITS.md#not-notarized)) |
| 4 | **System Settings → Privacy & Security → Open Anyway**, then your password or Touch ID, then **Open** | **macOS** | 3–4 | Do this within about an hour of step 3 |
| 5 | Click **T3** in the menu bar → **Connect T3…** | — | 2 | Your browser opens **T3's own** approval page |
| 6 | On T3's page, choose the access level → **Approve** | **T3** | 1–2 | "Approval required" is enough for most threads. See "Access levels" below |
| 7 | **Install Addon** | — | 1 | Adds only the `T3ForWoW` folders to your game |
| 7a | *Only if the app can't tell which game folder to use:* **Choose Folder…** and pick your WoW folder | — | 2–3 | |
| 8 | **Check Capture Access** → macOS asks about Screen Recording → **Open System Settings** → turn on **T3 for WoW** → password or Touch ID | **macOS** TCC | 3–4 | macOS may ask you to quit and reopen the app; do so |
| 8a | *If macOS asked to reopen:* reopen T3 for WoW, then **Check Capture Access** again | — | 2 | |
| 9 | Start World of Warcraft: Forever (restart it if it was running) | — | — | The app never starts, quits or types into the game |
| 10 | In game: `/t3` | — | — | The tracker sits top-left; `/t3 help` lists commands |
| — | *Optional:* Settings… → **Open at login** | **macOS** may list it under Login Items | 2 | Off unless you turn it on |

**Total:** about 10–14 clicks, two or three password or Touch ID prompts, and one game (re)start.
It is not one click, and it can't be: macOS and T3 each require your own approval, and that is deliberate.

### Access levels on T3's page

- **Approval required:** read your threads, reply, and start new threads in your existing projects.
  You can't reply from WoW to threads that run with *Full access*. They show as read-only, with a reason.
- **Full access:** also lets you reply to Full-access threads. T3 then also grants this app
  `settings:write` and `source-control:write`. That is T3's design; choose it only if you want that.

You can revoke either in **T3 → Settings → Connections**. The app warns you 3 days before an approval
expires (approvals last 30 days). Re-approving takes 2 clicks.

### Pairing code (only if T3's page asks for one)

T3's page asks for a one-time pairing code when your browser has no T3 session. For example, you use
the T3 desktop app and not T3 in a browser. Create a code in T3 and type it into **T3's page**, never
into this app. If you use T3's command line, the least-access code is:

```sh
t3 auth pairing create --scope orchestration:read --scope orchestration:operate --ttl 10m
```

For Full access, add `--scope settings:write --scope source-control:write`.

### T3 on another machine

If T3 isn't running on this Mac, **Find T3…** asks for its address, for example `http://192.168.1.20:3773`
or your own HTTPS URL. Only addresses you type are used. The approval is bound to that exact address:
if it changes, the app asks you to approve again rather than sending your token elsewhere.

## Updating

1. Quit T3 for WoW (menu bar → **Quit**), and replace the app in Applications with the new version.
2. Open it. If the bundled addon changed, it shows **Update Addon** (1 click). It then tells you
   whether `/reload` is enough or the game must restart.
3. Because the app is not notarized, macOS may treat a new version as a new app. It can ask again for
   **Open Anyway**, for **Screen Recording**, and for Keychain access ("T3 for WoW wants to use your
   confidential information…" → **Always Allow** with your password). That is expected; allow it only
   for an app you downloaded yourself.

Your T3 approval, game folder choice and tracker position are kept across updates.

## Uninstalling

1. Quit World of Warcraft.
2. Menu bar → **T3** → **Settings…** → **Uninstall…** → **Uninstall**. This removes:
   - the `T3ForWoW` addon, its `T3ForWoW_Slot0001…` folders, and any leftover install-transaction folder;
   - the saved approval in your Keychain (service `T3ForWoW`);
   - Open at login, if you turned it on;
   - `~/Library/Application Support/T3ForWoW` (settings, send ledger, diagnostics).

   It removes nothing else: other addons, your game settings and your T3 are untouched.

   **Safety rules:**
   - **Game running:** uninstall is refused while World of Warcraft runs. This is checked again at the
     moment files would be removed, so starting the game while the dialog is open still stops it.
   - **Links:** if `Interface`, `AddOns` or one of the app's folders is a link (alias) to another place,
     nothing is deleted there. You are told which link to remove.
   - **Partial results:** if something can't be removed (for example a permission problem), the app
     says what is left and calls the result "only partly removed". It never reports a partial result as
     done.
3. In **T3 → Settings → Connections**, revoke the T3 for WoW connection.
4. Move **T3 for WoW** from Applications to the Trash.
5. *Optional:* in **System Settings → Privacy & Security → Screen Recording**, remove T3 for WoW. The
   game keeps a few tracker-position settings in `WTF/…/SavedVariables/T3ForWoW.lua`; delete that file if
   you like. It holds no messages.

**If the app is already gone:** delete the `T3ForWoW` and `T3ForWoW_Slot*` folders from
`World of Warcraft/_forever_/Interface/AddOns`. Delete the "T3ForWoW" item in Keychain Access. Delete
`~/Library/Application Support/T3ForWoW`.

## Troubleshooting

The app always shows **one** next step in the menu bar. Common cases:

| You see | Meaning | Do |
|---|---|---|
| "Connect your T3 / Find T3…" | T3 isn't running on this Mac | Start T3, or enter its address |
| "Reconnect your T3" | The approval expired or was revoked in T3 | **Reconnect T3…** and approve again |
| "Approve this T3" | T3's address changed since you approved | Approve the new address (your token is never sent to the new address first) |
| "Needs Keychain access" | macOS refused or locked the Keychain | Unlock your Keychain, then **Try Again** |
| "macOS denied screen capture" | Screen Recording is off for this app | Turn it on in System Settings, then **Check Again** |
| "Screen capture stopped" | You stopped capture from the macOS menu | **Resume Capture** |
| "Waiting for the addon" | The game is running but its strip isn't visible | Make sure the addon is enabled in the AddOns list and the top of the game window is visible |
| "Repair the addon" | Addon files are missing or changed, or an install was interrupted | **Repair Addon** |
| In game: "Paused · Reload UI" | This session used all delivery slots (about 8 hours) | Click **Reload UI** in the journal |
| In game: "Status unknown" | The app is quiet or T3 hasn't been confirmed recently | Check the menu-bar app; nothing is shown as "working" until it is confirmed |

**Settings… → Show details** shows each check. Private diagnostics (no messages, no tokens) are in
`~/Library/Application Support/T3ForWoW/bridge-status.json`; the fields are described in
[DIAGNOSTICS.md](DIAGNOSTICS.md).
