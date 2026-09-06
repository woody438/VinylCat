# VinylCat — project notes for Claude

Native macOS app (Swift 6 / SwiftUI, min macOS 15) that catalogues a vinyl collection hands-free via webcam.
Plan of record: `~/.claude/plans/compressed-doodling-stearns.md`. Mockups: `design/mockups/build.mjs` (direction A, dark control-room)
→ published canvas https://claude.ai/code/artifact/8d2d40ea-f9c2-46a6-8846-75de1fc2b15b

## Build / run / test (no Xcode — Command Line Tools only)

```bash
scripts/build-app.sh debug --run   # swift build → build/VinylCat.app (ad-hoc signed) → open
scripts/test.sh                    # built-in checks: `VinylCat --self-test` (no XCTest/Swift Testing in CLT)
B=.build/debug/VinylCat
$B --diagnose                      # permissions, cameras, keys, Discogs reachability, store
$B --render-ui <dir>               # every screen/state → PNG (AppKit controls show as placeholders; no ScrollView in views you want to check)
$B --make-test-images <dir>        # synthetic label/cover photos
$B --pipeline-test <dir>/*.png     # OCR → Discogs → rank, no model
$B --scenario <dir>                # end-to-end ScanController run in a temp store (match, B-side, duplicate, skip, LP, undo, review)
```
Run `--self-test` and `--scenario` after any change to Scan/, Readers/, Discogs/ or Persistence/.

Consequences of CLT-only: no SwiftData macros (→ hand-rolled SQLite store), no XCTest (→ `Support/SelfTest.swift`),
no SwiftUI previews. Fonts are SF Condensed/Mono stand-ins for the mockups' Barlow Condensed / IBM Plex Mono.

## Layout

- `Capture/` — `CameraSession` (AVFoundation, Continuity Camera included), `CaptureEngine` (actor: sharpness/motion/scene-delta/phash
  state machine, modes `.identify` vs `.shot`), `FrameAnalysis`, `PhotoStore` (JPEGs in `~/Library/Application Support/VinylCat/Photos`).
- `Readers/` — `LocalReader` (Vision barcode + OCR, catalogue-number regex), `SleeveReader` protocol + `LunaReader` (OpenAI Responses,
  gpt-5.6-luna) + `GeminiReader` (gemini-3.8-flash), `Identifier` (local pass first, model second, cost meter).
- `Discogs/` — `DiscogsClient` (token auth, 60/min limiter from headers), `CandidateRanker` (catno/barcode/label/title/format/year),
  `Matcher` (search strategy + thresholds 0.85 / 0.60).
- `Scan/` — `ScanController` (the loop: capture → identify → match → extra shots → save; voice command handling), `ScanView` (HUD).
- `Voice/` — `SpeechCommands` (on-device SFSpeechRecognizer, phrase table in `VoiceCommand.phrases`), `Speaker` (TTS, mutes recogniser), `Chimes`.
- `Persistence/` — `Models` (structs), `Store` (SQLite, `revision` drives view refresh, CSV export), `Keychain` (API keys).
- `Library/`, `Review/`, `Settings/` — the other three tabs.

## Conventions

- Secrets only in Keychain. Non-secret prefs in UserDefaults (`readerProvider`, `discogsUsername`, `currency`, `discogsSync`, `askForBSide`, `askForLabelsOnLP`).
- Exports go to `output/` as `vinylcat_export_vN_YYYY-MM-DD.csv`. Reference docs go in `input/`.
- Keep `design/mockups/build.mjs` as the single source for mockup changes; re-seed and republish the same canvas.
