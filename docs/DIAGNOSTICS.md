# bridge-status.json — private local diagnostics (schema 1)

**Location and writing.** The running app writes `~/Library/Application Support/T3ForWoW/bridge-status.json`.
It is on by default, written atomically, and throttled to at most one write every 2 s. It is never sent
anywhere. Sources: `native/Sources/BridgeCore/Diagnostics.swift` (`BridgeStatus`, `CaptureStats`,
`StatusWriter`); the app's writer is in `AppController.writeStatus`. Key whitelist and absence of secrets
are unit-tested (`runDiagnosticsTests`).

**Safe metadata only.** The file never contains:
- OAuth tokens, codes, PKCE values or grant fingerprints;
- cookies, prompts or message text;
- thread or project titles or ids, request ids or keys;
- account identifiers, screenshots or pixels.

| Key | Meaning |
|---|---|
| `schema`, `writtenAt`, `app` | 1, unix seconds, app version |
| `capture.state` | `starting` · `capturing` · `scopeMismatch` · `noGame` · `needsPermission` (not yet checked with the SDK) · `verifying` · `denied` (SDK) · `stoppedByOwner` (macOS Stop, -3817) · `enumerationError` · `startError` · `noPlan` · `stopped` |
| `capture.windowID`, `capture.windowFrame` | selected WoW window (system window number; global points, top-left origin) |
| `capture.displayID`, `capture.sourceRect` | display the band is captured from; display-relative crop in points (≤ 96 pt tall) |
| `capture.outputPixels`, `capture.scale` | `[w, h]` captured pixels = sourceRect × scale (no scaling of the strip) |
| `capture.samples`, `decoded`, `notFound`, `unreadable`, `parseErrors` | counts of complete captured frames and why each did or did not decode |
| `capture.lastDecodeError` | `strip-not-found` · `strip-unreadable` · `frame-<crc/magic/version/short/payload>` |
| `capture.lastValidFrameAgeSeconds` | seconds since the last valid game frame |
| `capture.legacyPreflight` | `CGPreflightScreenCaptureAccess()`. Advisory only; it can be false although Screen Recording is enabled |
| `capture.sdkAccess` | ScreenCaptureKit's own answer: `unknown` · `verifying` · `verified` · `denied` · `stopped` · `error` (denied/stopped latch until a new owner check) |
| `capture.sdkAttempts` | owner-initiated checks this run (button or `--verify-capture-once`) |
| `capture.sdkErrorDomain`, `capture.sdkErrorCode` | domain and code of the last SDK error only (e.g. `…SCStreamErrorDomain`, `-3801` user declined) |
| `capture.bufferWidth`, `bufferHeight`, `pixelFormat` | the ACTUAL delivered CVPixelBuffer size and FourCC (vs. the requested `outputPixels`) |
| `capture.filterStyle`, `filterContentRect`, `filterPointPixelScale` | what ScreenCaptureKit reports for the filter it built (`display` expected). A non-display style stops with `capture.state = scopeMismatch` and is never started |
| `capture.frameContentRect`, `frameContentScale`, `frameScaleFactor` | `SCStreamFrameInfo` numbers of the last complete frame, as the SDK reports them |
| `capture.band` | public-finder aggregates for the top-centre ≤ 1200 px of the band, refreshed at most every 2 s. Fields: `regionX/Width/Height`, alpha `opaque`/`transparent` counts, `cyan`/`yellow`/`black`/`white` counts, `lumaMin`/`lumaMax`, `longestCyanRun`, `finderPrefix` (0–8 cells of C,Y,C,Y,K,W,K,W), `bestX`/`bestY`/`bestPitch`, `pitchKind` (`integer`/`fractional`), `verdict` (`transparent` · `blank` · `noFinderColors` · `finderColorsNoPattern` · `finderPartial` · `finderIntegerPitch` · `finderFractionalPitch`). Never pixels, rows, data-cell colours or payload |
| `capture.band.looseCyan`, `looseYellow`, `looseFinderPrefix`, `looseBestPitch` | DIAGNOSTIC-ONLY chromatic counter (cyan: G,B ≥ 180 and R ≤ 170; yellow: R,G ≥ 180 and B ≤ 170; K/W as strict). Contrasts with the strict decoder tolerance; never used to decode |
| `capture.configuredColorSpace` | `SCStreamConfiguration.colorSpaceName` as configured: currently `unset (display colour space)` |
| `capture.bufferColorPrimaries`, `bufferTransferFunction`, `bufferColorSpace` | CVPixelBuffer colour tags as whitelisted generic labels (e.g. `P3_D65`, `IEC_sRGB`, `displayP3`, `sRGB`); unknown → `other`, nameless (profile-based) → `custom`. No profile names, paths or dictionaries |
| `capture.context`, `contextAgeSeconds` | only when nothing decodes and no finder is seen, at most every 10 s: local OCR of the centre (≤ 1200 px) of the approved band, reduced to one category: `knownWarcraftLogo` (public terms World/Warcraft/Forever) · `noKnownText` · `ocrUnavailable` · `notChecked`. A hint about login/loading/character-select context, never proof. Recognised text is discarded; no images are kept |
| `link.state` | `unpaired` · `verifying` · `connected` · `unreachable` · `revoked` · `expired` · `originChanged` |
| `link.access` | `none` · `read-only` · `operate` · `full-access` |
| `link.threadCount`, `link.lastT3OkAgeSeconds` | number of visible threads (aggregate only); age of the last successful T3 call |
| `delivery.gameSessionSeen` | a game UI session was seen in a valid frame |
| `delivery.epochMatches` | the game acknowledged a delivery from **this** app run (round-trip evidence) |
| `delivery.storeVersion`, `gameAckVersion`, `nextSlot`, `slotWrites` | delivery sequence numbers |
| `delivery.slotWriteFailing` | the last slot write failed |
| `delivery.requestsReceived`, `sendsAttempted` | counts only |
| `install` | `ok` · `outdated` · `damaged` · `notInstalled` · `noTarget` |

**Reading it.**
- A healthy live link shows `capture.state = capturing`, rising `decoded`, a small
  `lastValidFrameAgeSeconds`, `delivery.epochMatches = true` and `gameAckVersion` following
  `storeVersion`.
- `capture.state = needsPermission` with `sdkAttempts = 0` means the SDK has not been asked yet. It is
  not a denial; run the owner check.
- `sdkAccess = denied` with an `sdkErrorCode` is the operating system's actual refusal.
- `samples` rising while `decoded` stays at 0 means the strip is not being read. `lastDecodeError` says
  why.
