# Contributing

Thanks for helping. Keep changes small and focused, and make sure everything is tested.

## Set up

```sh
scripts/bootstrap-dev.sh   # downloads pinned Lua 5.1.5, the WoW UI reference (and Swift 6.1.2 on Linux) into .deps/
```

You also need `git`. For the isolated contract and end-to-end suites you need Node 20+ and a T3 binary
(`T3_BIN=/path/to/t3`). Those suites start their own throwaway T3 server. They never use your real T3 data.

## Test

```sh
T3_BIN=/path/to/t3 scripts/test-all.sh
```

- **Lua tests:** run the whole addon in a strict stub that refuses any template, font, texture or
  atlas the pinned game UI doesn't define.
- **Swift tests:** cover the bridge core: codecs, decoder, engine, installer, setup and lifecycle.
- **Leak scan:** checks every file that a commit would contain.

UI changes need a synthetic preview (`tests/preview/render.lua`). Previews are labelled synthetic, so
never present them as in-game captures.

## Rules for changes

- The app never does anything in your place: no clicks, approvals, game input, reloads or restarts.
  macOS, T3 and the player decide.
- Every state shown must be true. Prefer "unknown" to a guess (see `Model:workState`).
- Only the client's own UI assets in the addon. In text, only glyphs from WoW's Latin-1/Windows-1252
  font set.
- No new network destinations, telemetry or dependencies without discussion.
- Never commit tokens, Keychain dumps, screenshots or recordings of a real game or desktop, personal
  paths or names, or real thread contents. Fixtures must be synthetic or redacted.
  `python3 -I scripts/leak_scan.py tracked .` must pass. You can keep a git-ignored list of your own
  private terms in `private/leak-terms.txt` and pass it with `--terms`.

By contributing you agree your contribution is licensed under the MIT licence of this repository.
