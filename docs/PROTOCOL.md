# T3 for WoW transport protocol, version 1

Original to this repository. The game never makes network requests and never evaluates
remote text as code. The bridge never injects code, reads game memory or generates game input.

```
 WoW addon --(pixel strip, captured by the bridge with the owner's Screen Recording consent)--> bridge
 WoW addon <--(pre-created load-on-demand "slot" addons, each loadable once per UI session)-- bridge
 bridge    <--(T3's own MCP tools over loopback/owner-selected URL, owner-approved OAuth bearer)--> T3
```

Identity: addon `T3ForWoW`, slot addons `T3ForWoW_Slot0001…`, SavedVariables `T3ForWoWDB`,
global functions `T3ForWoW_Deliver` only, frame magic `"3W"`, delivery magic `"T3D1"`.
Nothing is shared with any other addon (in particular not with Telegram for WoW).

## 1. Game → bridge: pixel strip

A grid of solid square cells anchored at the TOP-CENTRE of the UI (the Telegram addon's strip is
top-left; the two never overlap and use different finder patterns).

* `COLS = 80`. Row 0: cells 0–7 **finder** `C Y C Y K W K W` (`C=(0,255,255) Y=(255,255,0)
  K=(0,0,0) W=(255,255,255)`); cells 8–71 **palette** symbol `s` (0..63) in its own colour;
  cells 72–79 **end marker** `W K W K Y C Y C`. The decoder measures cell pitch across the whole
  row and classifies data cells by the nearest *observed* palette colour (calibrates gamma/profile).
* Symbol colour: `r = L[floor(s/16)%4], g = L[floor(s/4)%4], b = L[s%4]`, `L = {0,85,170,255}`.
* Data starts row 1 cell 0, row-major, 3 bytes → 4 six-bit symbols big-endian, zero padded.
  60 bytes per data row. `rows` is 2..16 (1 header row + 1..15 data rows); idle frames use 2.

Frame bytes (big-endian):

| off | size | field |
|---|---|---|
| 0 | 2 | magic `"3W"` |
| 2 | 1 | version `1` |
| 3 | 1 | rows |
| 4 | 4 | gameSession (random per UI load) |
| 8 | 2 | frameSeq (wraps) |
| 10 | 4 | epochAck (bridge epoch of the last applied delivery, 0 = none) |
| 14 | 4 | deliveryAck (store version the game has applied) |
| 18 | 2 | nextSlot (slot the game loads next; 0 = none left) |
| 20 | 2 | slotCount |
| 22 | 1 | flags: bit0 window open, bit1 slots exhausted, bit2 tracker visible |
| 23 | 2 | payloadLen |
| 25 | n | payload: request chunks |
| 25+n | 4 | CRC-32 (IEEE) of bytes 0..25+n-1 |

Chunk: `reqId u32, chunkIndex u8, chunkCount u8, len u16, data[len]`. A request body is a list of
netstrings `<len>:<bytes>`:

| type | fields | meaning |
|---|---|---|
| `W` | threadId | watch: deliver this thread's recent history and keep it fresh |
| `H` | threadId, beforePosition | one older history page |
| `S` | threadId, text | reply to exactly this thread (T3 `t3_thread_send`, `mode=queue`) |
| `N` | projectId, title, text | new thread in an existing project (`t3_thread_launch`) |
| `Z` | — | resync: resend the complete visible state |

Requests are re-shown round-robin until the bridge reports an `r` record for that `reqId`.
**Exactly once:** `S`/`N` carry T3 `clientRequestId = "wow:<gameSession hex>:<reqId>"`. T3 derives
the message/thread id from (bridge session, key), so a retry after a crash, restart or a lost
acknowledgement replays instead of duplicating. The bridge's ledger additionally refuses to send a
request a second time after it changed bearer session (re-pairing): such a request becomes
`unknown`, never silently re-sent.

## 2. Bridge → game: slots

The installer creates `T3ForWoW_Slot0001 … T3ForWoW_SlotNNNN` (load-on-demand, `## Group: T3ForWoW`
so the AddOns list collapses them under the parent). Each `Slot.lua` is exactly

```lua
T3ForWoW_Deliver(7,"...")
```

with one string literal containing only printable ASCII except `"` and `\`; every other byte is
`\ddd`. The installer writes `T3ForWoW_Deliver(k,"")` (= "nothing written"). Files are replaced
atomically (temp + rename).

Payload netstrings: `"T3D1", slot, epoch, gameSession, version, more(0/1), bridgeTime, recordCount`
then `recordCount` records, each a netstring list `[type, …]`. The game applies a delivery only if
magic, slot and gameSession match and `version` is newer than the last applied for that epoch; a new
epoch (bridge restart) replaces the model.

| record | fields |
|---|---|
| `st` | bridge(`online`), t3(`connected`/`unreachable`/`unpaired`/`revoked`/`expired`), t3CheckedAt, notice, pairExpiresAt, access, hint(seconds) |
| `p` | projectId, title |
| `t` | threadId, projectId, title, status, pending, updatedAt, settled, runtimeMode, canReply, summary |
| `tl` | ordered threadIds (priority order, ≤ 60) |
| `m` | threadId, itemId, position, kind, status, author, updatedAt, text, truncated |
| `h` | threadId, oldestPosition, hasMore, loading |
| `r` | reqId, state, detail, threadId, messageId |
| `x` | key (tombstone for `t:<id>`, `m:<thread>:<item>`) |

Request states: `received`, `sending`, `accepted` (T3 stored the message), `queued` (T3 will run it
after the current turn), `failed`, `rejected` (e.g. permission ceiling), `unknown`. None of them means
the work is done; a thread's `completed` status means **its model turn ended**, not that the task is
verified or deployed. Only top-level threads are listed; subagent/child work is not shown and never
inferred.

## 3. Cadence and budget (game side)

The game decides when to load the next slot. Policy interval: reply in flight or watched thread
working 15 s; window open 30 s; tracker with working/needs-you threads 60 s; tracker idle 120 s;
bridge silent (empty/stale slot) backs off 60→120→300 s. A governor never lets the interval drop below
`k × (horizonRemaining / slotsRemaining)` with k = 0.25 while > 50 % of slots remain, 0.5 above 25 %, then 1.0 (horizon 8 h from UI load), so bursts cannot drain the
pool early. At ≤ 10 % left the tracker says so; when exhausted it states the measured use and offers a
user-clicked `/reload`. Nothing reloads automatically.

## 4. Limits

Request body ≤ 4 KiB, ≤ 64 chunks; ≤ 16 partial requests; partial requests expire after 60 s.
Delivery payload ≤ 64 KiB; message text ≤ 4 KiB per record (`truncated=1` beyond); ≤ 60 threads.
