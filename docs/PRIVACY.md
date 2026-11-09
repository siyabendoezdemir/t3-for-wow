# Privacy: what T3 for WoW reads, stores and sends

Short version: it reads a small strip at the top of your game window and talks only to **your** T3.
Nothing goes to the authors or to any other service. There is no analytics, telemetry, crash
reporting, update check or advertising.

## The Mac app reads

- **Screen pixels:** only the World of Warcraft window, and only its top band (at most 96 points
  tall, where the addon draws its strip). It uses macOS ScreenCaptureKit with your Screen Recording
  permission, at native resolution, without the cursor or audio. Frames are decoded in memory and
  dropped. No screenshot, video or pixel data is ever written to disk or sent anywhere.
  Diagnostics keep only counts (for example how many frames decoded).
- **Which apps are running:** to see whether the game is running (bundle id and name only).
- **Your T3's local runtime file** (`~/.t3/userdata/server-runtime.json`): only its `origin` field,
  to find T3 on this Mac. It never reads T3's credentials or databases.
- **Your game folder:** only to find `Interface/AddOns` and to install, check or remove its own folders.

## The Mac app stores

| Where | What | Why |
|---|---|---|
| Login Keychain, service `T3ForWoW`, account `t3-grant` | The access token T3 issued when you approved, its expiry, granted scopes and the T3 address it is bound to | Talking to your T3 |
| `~/Library/Application Support/T3ForWoW/config.json` | The T3 address you typed (if any) and the game folder you chose (if any) | Your choices |
| `…/send-ledger.json` | For each message sent from WoW: request id, state, thread id, message id, a short status or error detail. **No message text.** At most 500 entries | Exactly-once sending across crashes |
| `…/bridge-status.json` | Safe metadata: app version, capture state and counts, link state, delivery counters, install state. No messages, titles, tokens or pixels | Diagnostics you can read or share |
| `World of Warcraft/_forever_/Interface/AddOns/T3ForWoW_Slot*` | The latest status and conversation updates for the game to load. These are rewritten all the time | The only way to get data into the game |

The delivery slots contain thread titles and message text from your T3. They stay on your Mac in your
game folder. Uninstall removes them.

## The addon stores

`T3ForWoWDB` (WoW SavedVariables) holds only the tracker and window positions and the tracker's
collapsed state. Messages, drafts and credentials are never saved. Drafts live in memory until the UI
reloads.

## The Mac app sends

Only to the T3 address you approved, over HTTP(S), with the bearer token T3 issued:
- MCP calls `t3_project_list`, `t3_thread_list`, `t3_thread_read` (to show your threads),
  `t3_thread_send` (only when you send a reply) and `t3_thread_launch` (only when you start a new
  thread from WoW);
- the OAuth approval exchange with that same T3 when you click Connect.

Redirects are not followed and cookies are not used. The token is never sent to a different address
than the one you approved. If T3's address changes, you are asked to approve again.

## What T3 sees

Messages you send from WoW appear in your T3 as sent through T3's MCP connection. T3 0.1.7 labels them
as created by an agent/MCP client, not by you typing in T3. T3 records the connection under
**Settings → Connections**, where you can revoke it.

## The game

The addon uses only the game client's own frames, fonts and textures. It makes no network requests,
and it never runs received text as code: every `|` escape in agent text is neutralised before display.
