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
$B --scenario <dir>                # end-to-end ScanController run in a temp store (match, B-side, duplicate, skip, LP, undo, thumbs-down, review)
$B --ocr-eval [n] [--model]        # LocalReader over the real photos in the live store, scored against each record's catno (see below);
                                   #   --model also scores the vision model (~$0.001/photo). Env: VINYLCAT_EVAL_VERBOSE=1 prints OCR lines
                                   #   for ranked misses, VINYLCAT_EVAL_DUMP=<dir> writes the zoom close-ups, VINYLCAT_MODEL_PLAIN=1 sends
                                   #   the model the old single 1024px frame (A/B for the close-ups)
$B --export-feedback [dir]         # thumbs-up/down verdicts + evidence → output/vinylcat_feedback_vN_date.jsonl
```
Run `--self-test` and `--scenario` after any change to Scan/, Readers/, Discogs/ or Persistence/.
Run `--ocr-eval` before and after any change to `LocalReader` / `CatalogueNumber` / `Matcher` and quote the
numbers. 2026-09-06, after the zoom pass (92 photos): catno-in-candidates 91% (was 84%, 75% before that), exact 86%,
first candidate usable 49% (was 39%), 0.65s/photo (was 0.36s; the zoom pass adds ~3.6 magnified crops per photo).
With `--model`: the model's catalogue number is usable first time on 88% of photos (90% counting `otherNumbers`),
$0.0009/photo, 4.3s/photo. A/B with VINYLCAT_MODEL_PLAIN=1 (single 1024px frame, no close-ups): 89% / 92%, $0.0006 —
the close-ups do not help the model, which reads the small print fine already; they only help Vision. The model is the
stronger path for the catalogue number (88% vs OCR's 49% first-time), so when OCR and model disagree, trust the model. The eval prints `rank N … ahead: …` for every photo where the right token isn't first —
that list is where to look next. What's left there: album numbers quoted on singles when "album" is on another OCR
line, RCA/Capitol LP references, misread digits on worn print, and two label photos with nothing legible.

Consequences of CLT-only: no SwiftData macros (→ hand-rolled SQLite store), no XCTest (→ `Support/SelfTest.swift`),
no SwiftUI previews. Fonts are SF Condensed/Mono stand-ins for the mockups' Barlow Condensed / IBM Plex Mono.

## Layout

- `Capture/` — `CameraSession` (AVFoundation, Continuity Camera included), `CaptureEngine` (actor: sharpness/motion/scene-delta/phash
  state machine, modes `.identify` vs `.shot`), `FrameAnalysis`, `PhotoStore` (JPEGs in `~/Library/Application Support/VinylCat/Photos`).
- `Readers/` — `LocalReader` (Vision barcode + OCR in three orientations, then a zoom pass: the smallest print cropped, magnified 2–4× and
  read again; `closeUps` are those crops, sent to the model), `CatalogueNumber` (regex + shape scoring; the `--ocr-eval` rank list drives
  every rule in `shapeScore`), `SleeveReader` protocol + `LunaReader` (OpenAI Responses,
  gpt-5.6-luna) + `GeminiReader` (gemini-3.8-flash), `Identifier` (local pass first, model second, cost meter).
- `Discogs/` — `DiscogsClient` (token auth, 60/min limiter from headers), `CandidateRanker` (catno/barcode/label/title/format/year),
  `Matcher` (search strategy + thresholds 0.85 / 0.60).
- `Scan/` — `ScanController` (the loop: capture → identify → match → extra shots → save; voice command handling), `ScanView` (HUD).
- `Voice/` — `SpeechCommands` (on-device SFSpeechRecognizer, phrase table in `VoiceCommand.phrases`), `Speaker` (TTS, mutes recogniser), `Chimes`.
- `Persistence/` — `Models` (structs), `Store` (SQLite, `revision` drives view refresh, CSV + feedback JSONL export), `Keychain` (API keys).
  `Store.insert` is `INSERT OR REPLACE`, which deletes the row first: never give a records-keyed table an `ON DELETE CASCADE`
  (the `evidence` and `feedback` tables are cleaned up by hand in `Store.delete`).
- `Library/`, `Review/`, `Settings/` — the other three tabs.
- `Setup/` — `SetupWizard` (first run, until `setupCompleted`) and `Tour` (first-run callout bubbles over the main view, until
  `tourCompleted`; re-run from Settings → SHOW THE TOUR AGAIN). Point the tour at a view with `.tourAnchor(.x)` and add a `TourStep`;
  `--render-ui` writes every step as `tour-NN-<anchor>.png`.

## Verdicts (thumbs up / down)

- Every match saves `ScanEvidence` (OCR lines, model reading, ranked Discogs candidates, chosen release) next to the record.
- Thumbs-down (session row, Library detail "WRONG RECORD", or voice "wrong record") sets `status = .rejected`: the record
  and photos stay for tuning, it leaves the Discogs collection (`DiscogsClient.removeFromCollection`), and it drops out of
  the Library counts, value, CSV and the duplicate check. Thumbs-up / "RESTORE" flips it back and marks it `verified`.
- Rejected records sit in the Review tab's queue as WRONG MATCH (`Store.reviewCount` counts `needsReview` + `rejected`).
  Its re-search seeds from the saved evidence's `mergedReading` (the record's own fields came from the wrong release) and
  drops that release from the candidates; USE / SAVE AS MANUAL ENTRY bring it back into the catalogue. The feedback JSONL
  then carries the down verdict with the wrong `chosenReleaseID` in the evidence and the corrected `discogsReleaseID` on
  the record — the best tuning signal there is.
- The Discogs removal after a thumbs-down runs in a Task: it must re-fetch before writing (a thumbs-up or delete may have
  landed meanwhile; writing the stale `rejected` copy back resurrected deleted records as ghosts in the queue).
- Library delete also removes the Discogs collection instance when there is one (`ScanController.delete`).

## Conventions

- Secrets only in Keychain. Non-secret prefs in UserDefaults (`readerProvider`, `discogsUsername`, `currency`, `discogsSync`, `askForBSide`, `askForFrontOnLP`, `askForCoversOnLP`, `askForLabelsOnLP`,
  `voiceOnLaunch` — default off: the speech recogniser only runs once VOICE is clicked, `setupCompleted`, `tourCompleted`).
- Exports go to `output/` as `vinylcat_export_vN_YYYY-MM-DD.csv` and `vinylcat_feedback_vN_YYYY-MM-DD.jsonl`. Reference docs go in `input/`.
- Keep `design/mockups/build.mjs` as the single source for mockup changes; re-seed and republish the same canvas.
