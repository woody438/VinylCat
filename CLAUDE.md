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
$B --scenario <dir>                # end-to-end ScanController run in a temp store (match, B-side, duplicate, extra photo, LP, undo, thumbs-down, review)
$B --ocr-eval [n] [--model]        # LocalReader over the real photos in the live store, scored against each record's catno (see below);
                                   #   --model also scores the vision model (~$0.001/photo). Env: VINYLCAT_EVAL_VERBOSE=1 prints OCR lines
                                   #   for ranked misses, VINYLCAT_EVAL_DUMP=<dir> writes the zoom close-ups, VINYLCAT_MODEL_PLAIN=1 sends
                                   #   the model the old single 1024px frame (A/B for the close-ups)
$B --export-feedback [dir]         # thumbs-up/down verdicts + evidence → output/vinylcat_feedback_vN_date.jsonl
```
Run `--self-test` and `--scenario` after any change to Scan/, Readers/, Discogs/ or Persistence/.
`VINYLCAT_NO_KEYCHAIN=1` makes every key read as missing: `--scenario` then runs OCR-only against unauthenticated Discogs
at 25/min (what its docstring promises), and nothing is spent on the model.
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
  state machine, modes `.identify` vs `.shot`), `FrameAnalysis`, `PhotoStore` (JPEGs in `~/Library/Application Support/VinylCat/Photos`),
  `SignalGauges` (SHARP / STILL / RECORD colour bars — red/amber/green against `CaptureTuning.fromDefaults()`, the Settings sliders;
  shown in the HUD banner while armed/steady and, with numbers, in Settings → CAPTURE. The raw "sharp · motion · scene" text is gone
  from the HUD at Woody's request: too technical).
- `Readers/` — `LocalReader` (Vision barcode + OCR in three orientations, then a zoom pass: the smallest print cropped, magnified 2–4× and
  read again; `closeUps` are those crops, sent to the model), `CatalogueNumber` (regex + shape scoring; the `--ocr-eval` rank list drives
  every rule in `shapeScore`), `SleeveReader` protocol + `LunaReader` (OpenAI Responses,
  gpt-5.6-luna) + `GeminiReader` (gemini-3.8-flash), `Identifier` (local pass first, model second, cost meter).
- `Discogs/` — `DiscogsClient` (token auth, 60/min limiter from headers), `CandidateRanker` (catno/barcode/label/title/format/year),
  `Matcher` (search strategy + thresholds 0.85 / 0.60), `CollectionSync` (the pull half of two-way sync: once at launch and from
  Settings / Library "PULL FROM DISCOGS"; imports collection instances as photo-less records under `importSession`, adopts the
  instance id for local records of the same release, unlinks — never deletes — local records whose instance has gone from
  Discogs, skipping anything under ten minutes old). A scan that matches a photo-less imported record attaches its photo to it
  instead of reporting a duplicate. After a pull, `valueUnvalued` prices every catalogue record with no `valuedAt` (imports, and
  scans whose price call failed), one call every 2.2 s so scanning keeps most of the rate limit.
- `Scan/` — `ScanController` (the loop: capture → identify → match → extra shots → save; voice command handling), `ScanView` (HUD,
  plus `ScanKey`: the keyboard table — SPACE capture, F flip, U undo, W wrong record, P add photo, S skip, D done, R review, N none,
  1–3 pick, RETURN add anyway, ESC start over — per phase; the bottom-bar legend shows exactly `ScanKey.set(for:)`, with the
  spoken word beside each key while VOICE is on. Keys and voice both go through `handle(command:)`. They are installed only on
  the Scan tab: a bare-letter shortcut in the top bar would fire while typing in the Library/Review search fields).
  A model failure never aborts a scan: `Identifier` falls back to OCR-only and records `modelError`; Discogs/network failures
  land in `ScanPhase.error` with a `FriendlyError` sentence, spoken and shown, and the photo is parked in the review queue
  (with a "Scan error: …" note) so nothing is lost. `park` saves `ScanEvidence` too, so the model's reading survives for Review.
- `Voice/` — `SpeechCommands` (on-device SFSpeechRecognizer, phrase table in `VoiceCommand.phrases`), `Speaker` (TTS, mutes recogniser), `Chimes`.
- `Persistence/` — `Models` (structs), `Store` (SQLite, `revision` drives view refresh, CSV + feedback JSONL export), `Keychain` (API keys).
  `Store.insert` is `INSERT OR REPLACE`, which deletes the row first: never give a records-keyed table an `ON DELETE CASCADE`
  (the `evidence` and `feedback` tables are cleaned up by hand in `Store.delete`).
- `Library/` (+ `ManualEntry`: "+ ADD RECORD" in the detail column — type what is known, search Discogs at 50 per query, pick a
  release or save without one), `Review/` (search box focused per record, every candidate listed), `Settings/` (scrolls; under
  `--render-ui` the `staticRender` environment flag lays it flat, since ImageRenderer draws nothing inside a ScrollView).
- `Support/Coffee.swift` — the tip jar (2026-09-07, Woody's call: free app, own keys, Ko-fi at 0% — `Coffee.url`). The ask grows
  with `Store.scannedCount()` (live records with a photo; Discogs pulls and typed-in records don't count): a strip at 25, a card at
  100 and 250, a launch-time sheet from 500 and every 500 after. It lives above the Library footer and on the Scan rail only while
  `.paused`; never in the HUD, never blocking a capture. "Later" (label gets ruder per rung) hides it until the next milestone
  (`coffeeDismissedAt`); "I've bought one" gets one cheeky confirm, then `coffeeBought` silences everything for good and a COFFEE
  meter appears on the rail. Settings → SUPPORT can undo it. `--render-ui` writes every rung as `coffee-*.png`; the self-test
  covers the ladder.
- `Setup/` — `SetupWizard` (first run, until `setupCompleted`) and `Tour` (first-run callout bubbles over the main view, until
  `tourCompleted`; re-run from Settings → SHOW THE TOUR AGAIN). Point the tour at a view with `.tourAnchor(.x)` and add a `TourStep`;
  `--render-ui` writes every step as `tour-NN-<anchor>.png`.

## Verdicts (thumbs up / down)

- Every match saves `ScanEvidence` (OCR lines, model reading, ranked Discogs candidates, chosen release) next to the record.
- Thumbs-down (session row, Library detail "WRONG RECORD", or voice "wrong record") sets `status = .rejected`: the record
  and photos stay for tuning, it leaves the Discogs collection (`DiscogsClient.removeFromCollection`), and it drops out of
  the Library counts, value, CSV and the duplicate check. Thumbs-up / "RESTORE" flips it back and marks it `verified`.
- Every fix done by hand logs a `.fixed` verdict with a `CorrectionNote` (source review/library/manual, what was typed, the
  release chosen, the release/status the scan had) — `Store.logFeedback(_:_:correction:)`; the feedback JSONL carries it as
  `correction` next to the evidence saved at scan time. That pair is the "what did it take to fix this" signal.
- Rejected records sit in the Review tab's queue as WRONG MATCH (`Store.reviewCount` counts `needsReview` + `rejected`).
  Its re-search seeds from the saved evidence's `mergedReading` (the record's own fields came from the wrong release) and
  drops that release from the candidates; USE / SAVE AS MANUAL ENTRY bring it back into the catalogue. The feedback JSONL
  then carries the down verdict with the wrong `chosenReleaseID` in the evidence and the corrected `discogsReleaseID` on
  the record — the best tuning signal there is.
- The Discogs removal after a thumbs-down runs in a Task: it must re-fetch before writing (a thumbs-up or delete may have
  landed meanwhile; writing the stale `rejected` copy back resurrected deleted records as ghosts in the queue).
- Library delete also removes the Discogs collection instance when there is one (`ScanController.delete`).

## Conventions

- Model replies: `max_output_tokens` is 2500 (reasoning tokens count against it; at 600 Luna ran out mid-JSON, which surfaced
  as "The data couldn't be read because it isn't in the correct format"). An `incomplete` status or unparseable JSON throws
  `ReaderError.badResponse` with the reason, and `Identifier` carries on OCR-only.
- Secrets (`Secrets`, alias `Keychain`) live in `~/Library/Application Support/VinylCat/keys.json`, mode 0600 — NOT the login
  keychain any more (2026-09-07, Woody's call). The keychain pins each item to the storing build's code hash via the
  `partition_id` ACL entry; without an Apple team identity that cannot be widened or stripped (tested: "allow all
  applications" only covers the application list; removing the entry prompts too), so every rebuild re-prompted once per key.
  Legacy keychain items are read once on first access, copied to the file and deleted. Non-secret prefs in UserDefaults (`readerProvider`, `discogsUsername`, `currency`, `discogsSync`,
  `voiceOnLaunch` — default off: the speech recogniser only runs once VOICE is clicked, `setupCompleted`, `tourCompleted`).
- One photo per record, the identifying one. There is no shot plan any more (the SHOTS settings, `CaptureProfile`, `expectedShots`,
  `isComplete` and the INCOMPLETE filter went on 2026-09-07 at Woody's call): extra photos are only ever asked for by hand — F / "flip",
  P / "add photo", "back cover", "gatefold", "disc two" — and the record closes again after each one. "undo" with nothing open removes
  the last extra photo first, then the record. The `expected_shots` column is still in the schema, written as `[]`.
- Ambiguous matches list every distinct variant within 0.25 of the top score, three to nine; keys 1–9 and voice "one"…"nine"
  ("number four" / "number seven": bare "four" and "seven" clash with "for" and "seven inch"). More than three rows go compact
  and scroll inside the banner.
- The logo (2026-09-07, from Woody's logo chat: the record *is* the cat's head — ears above the disc edge, burnt-orange label)
  is drawn, not an asset: `Support/LogoMark.swift` (SwiftUI, top bar and wizard header) and `scripts/make-icon.swift`
  (CoreGraphics → `Resources/AppIcon.icns`) share the numbers in `LogoGeometry`; change both together. The chat's visuals were
  hidden in the share, so this is a rendering of its description — swap in the real file if Woody exports one.
- Settings → ABOUT shows `BuildInfo`: version from Info.plist, and `VinylCatBuild` (date · time · commit) stamped by
  `scripts/build-app.sh`; the bare `.build/debug` binary reports a dev build.
- Exports go to `output/` as `vinylcat_export_vN_YYYY-MM-DD.csv` and `vinylcat_feedback_vN_YYYY-MM-DD.jsonl`. Reference docs go in `input/`.
- Keep `design/mockups/build.mjs` as the single source for mockup changes; re-seed and republish the same canvas.
