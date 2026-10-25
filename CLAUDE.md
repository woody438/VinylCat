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
$B --import <dir> [7|12|lp]        # every photo in the folder through the scan pipeline into the LIVE store (matches land in the
                                   #   catalogue and, if sync is on, the Discogs collection): one line per photo, exit 1 if anything
                                   #   parked or errored. Same run as the Library's "+ IMPORT PHOTOS"; VINYLCAT_NO_KEYCHAIN=1 → OCR-only.
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
  gpt-5.6-luna) + `GeminiReader` (gemini-3.8-flash) + `ClaudeReader` (Anthropic Messages), `Identifier` (local pass first, model second, cost meter).
- `ClaudeReader` covers three rungs through one type: `ClaudeModel` (`claudeModel` in UserDefaults, **default `.opus`**) picks
  `claude-haiku-5-5` / `claude-sonnet-5-5` / `claude-opus-5-5` and carries their pricing. Thinking is adaptive and cannot be switched off
  on Opus 5.5 or Sonnet 5.5 (`thinking: {type: "disabled"}` is a 400 there), so the only lever is `output_config.effort`, set to `low`;
  reasoning tokens are billed as output and come out of `max_tokens`, which is 4000 here rather than the usual 2500. Structured output is
  `output_config.format` with `ClaudeReader.schema` — `SleeveReading.jsonSchema` with one change, made at runtime and verified
  2026-10-25: a property carrying an `enum` must not also declare a type union, so `formatGuess` loses its `["string","null"]` and keeps
  the enum (with the null still in it). Without that the API rejects the whole schema — *"Enum value '7in' does not match declared type
  '['string', 'null']'"*. Every other property's `["string","null"]` union is accepted as it stands, so this is one line, not Gemini's
  dialect rewrite. A 400 mentioning schema/format/output_config still falls back to asking for the same JSON in the prompt and unwrapping
  any code fence (`ClaudeReader.jsonBody`).
  **Measured 2026-10-25**, `--ocr-eval 100 --model` over the same first 100 records for all three providers (model's catalogue number
  usable first time / usable counting `otherNumbers` / $ per photo / s per photo):
  Opus 5.5 **97% / 98% / $0.0200 / 4.3s** · Haiku 5.5 **94% / 97% / $0.00052 / 2.7s** · Luna **92% / 94% / $0.00084 / 3.9s**.
  So Haiku beats the incumbent Luna outright and costs 38× less than Opus; Opus's 3-point lead is 3 photos in 100 and is *not*
  established by a sample this size. On `catno+otherNumbers` — what `Matcher` actually searches — Haiku and Opus are 97 vs 98, a tie.
  Haiku over the **full** set (347 records / 353 photos): 85% / 92% / $0.00053 / 2.8s. The first 100 records are materially easier than
  the tail (local OCR scores 91% in-candidates on them against 85% over everything), so the head-to-head numbers flatter all three
  equally — compare providers on the 100, not the full-set figure.
- `AnthropicCredential` — short-lived credentials ahead of the pasted key, in that order: workload identity federation (all four
  `ANTHROPIC_FEDERATION_*` / identity-token env vars set), then an OAuth profile, then `Secrets.Key.anthropic`. A bearer token goes on
  `Authorization` **plus** `anthropic-beta: oauth-2025-04-20` — `/v1/messages` rejects it without that header. Both token paths shell out
  to the `ant` CLI (`auth print-credentials --access-token`), which already owns the exchange, the refresh and the on-disk profile format;
  do not hand-roll the `/v1/oauth/token` exchange against an undocumented layout. Tokens are cached for 4 minutes and re-minted once on a
  401. Federation is for CI, not the Mac app: a personal Mac has no workload identity provider to federate from, and a JWT shipped in the
  bundle would be a long-lived secret — worse than the key it replaced. The OAuth path is exercised and working (2026-10-25, Woody's
  `ant auth login` profile, scopes `user:developer user:inference user:profile`, tokens good for 8h); the federation path still has not
  been run — there is nothing on this Mac to federate from.
- `Discogs/` — `DiscogsClient` (token auth, 60/min limiter from headers), `CandidateRanker` (catno/barcode/label/title/format/year),
  `Matcher` (search strategy + thresholds 0.85 / 0.60), `CollectionSync` (the pull half of two-way sync: once at launch and from
  Settings / Library "PULL FROM DISCOGS"; imports collection instances as photo-less records under `importSession`, adopts the
  instance id for local records of the same release, unlinks — never deletes — local records whose instance has gone from
  Discogs, skipping anything under ten minutes old). A scan that matches a photo-less imported record attaches its photo to it
  instead of reporting a duplicate. After a pull, `valueUnvalued` prices every catalogue record with no `valuedAt` (imports, and
  scans whose price call failed), one call every 2.2 s so scanning keeps most of the rate limit. The Scan rail shows
  `collectionSync.status` under the meters while a pull or that pass runs: a DISCOGS meter climbing with nobody scanning is
  this, not a leak (2026-09-14, Woody asked).
- `Scan/` — `ScanPipeline` (extension on `ScanController`: the camera-free core both the webcam loop and the folder importer run —
  `lookup` readers → Discogs, `process` one photo to a `Resolution` (saved / attached to a photo-less Discogs import / duplicate /
  ambiguous / notFound / parked), `commit` the save with the duplicate and attach rules, `parkRecord` into the review queue with
  evidence; nothing in it touches the engine, HUD, chimes or speaker), `ScanController` (the webcam loop: capture → `lookup` → the
  prompts only a person can answer (label, retry, pick a number, add anyway) → `commit`/`park` → extra shots; voice command
  handling; `enrich` tasks are tracked so `awaitEnrichment` can wait for the Discogs writes), `ScanView` (HUD,
  plus `ScanKey`: the keyboard table — SPACE capture, F flip, U undo, W wrong record, P add photo, S skip, D done, R review, N none,
  1–3 pick, RETURN add anyway, ESC start over — per phase; the bottom-bar legend shows exactly `ScanKey.set(for:)`, with the
  spoken word beside each key while VOICE is on. Keys and voice both go through `handle(command:)`. They are installed only on
  the Scan tab: a bare-letter shortcut in the top bar would fire while typing in the Library/Review search fields).
  A model failure never aborts a scan: `Identifier` falls back to OCR-only and records `modelError`; Discogs/network failures
  land in `ScanPhase.error` with a `FriendlyError` sentence, spoken and shown, and the photo is parked in the review queue
  (with a "Scan error: …" note) so nothing is lost. `park` saves `ScanEvidence` too, so the model's reading survives for Review.
- `Readers/SpendLedger.swift` — model spend across launches (2026-09-14, Woody's call): month-to-date and all-time cost + reads in
  UserDefaults `llmSpend`, rolled on the first read or launch of a new calendar month. The rail's LLM COST meter shows the session
  on top and `MONTH $x` under it, amber once the month passes `Identifier.monthlyBudgetUSD` (`llmBudget`, default $5, 0 = never;
  Settings → IDENTIFICATION "Warn me past") — a warning, never a stop. All-time sits in Settings → ABOUT. The self-test covers the
  roll, the total and the round trip.
- `Voice/` — `SpeechCommands` (on-device SFSpeechRecognizer, phrase table in `VoiceCommand.phrases`), `Speaker` (TTS, mutes recogniser), `Chimes`.
- `Persistence/` — `Models` (structs), `Store` (SQLite, `revision` drives view refresh, CSV + feedback JSONL export), `Keychain` (API keys).
  `Store.insert` is `INSERT OR REPLACE`, which deletes the row first: never give a records-keyed table an `ON DELETE CASCADE`
  (the `evidence` and `feedback` tables are cleaned up by hand in `Store.delete`).
- `Library/` (+ `ManualEntry`: "+ ADD RECORD" in the detail column — type what is known, search Discogs at 50 per query, pick a
  release or save without one; + `PhotoImport`: `PhotoImporter` and `ImportSheet` behind "+ IMPORT PHOTOS" and a Finder drop of a
  folder or image files onto the Library. `walk` is the folder walk (sorted, jpg/jpeg/png/heic, dotfiles and hidden folders skipped),
  `load` decodes with EXIF orientation applied, `run` sends each photo through `ScanController.process` serially and never waits on
  the user: match → saved (or attached to a photo-less Discogs import), ambiguous / not found → parked with the candidates in
  `ScanEvidence`, duplicate → skipped and the photo dropped, Discogs/network error → parked with the `FriendlyError` note. Photos are
  named `import-<stamp>-NNN` so they sort after the webcam's. `CollectionSync.paused` holds valuation for the run. The sheet
  (progress, MATCHED / PARKED / DUPLICATES / ERRORS, the LLM cost delta, STOP that finishes the photo in hand, OPEN REVIEW at the
  end) is presented from `RootView` so a tab change mid-run doesn't dismiss it; `--render-ui` writes `import-1-running.png` and
  `import-2-finished.png` from `PhotoImporter.preview`), `Review/` (search box focused per record, every candidate listed), `Settings/` (scrolls; under
  `--render-ui` the `staticRender` environment flag lays it flat, since ImageRenderer draws nothing inside a ScrollView).
- `Support/Coffee.swift` — the tip jar (2026-09-07, Woody's call: free app, own keys, Ko-fi at 0% — `Coffee.url`). The ask grows
  with `Store.scannedCount()` (live records with a photo; Discogs pulls and typed-in records don't count): a strip at 25, a card at
  100 and 250, a launch-time sheet from 500 and every 500 after. It lives above the Library footer and on the Scan rail only while
  `.paused`; never in the HUD, never blocking a capture. "Later" (label gets ruder per rung) hides it until the next milestone
  (`coffeeDismissedAt`); "I've bought one" gets one cheeky confirm, then `coffeeBought` silences everything for good and a COFFEE
  meter appears on the rail. Settings → SUPPORT can undo it. `--render-ui` writes every rung as `coffee-*.png`; the self-test
  covers the ladder.
- `Support/LaunchPing.swift` — the take-up counter (2026-09-13): one anonymous POST to `https://vinyl-cat.com/api/ping` per launch
  (`{"event":"launch","version":…}`, plus `install` once per Mac), release builds only (`build-app.sh` stamps `VinylCatChannel`;
  `VINYLCAT_PING=1` forces it, `VINYLCAT_PING_URL` redirects it to `site-b`'s `npm run dev`). Settings → ABOUT → "Count launches"
  (`launchPing`, default on) is the user's switch. The site side is `site-b/api/` + `lib/counter.js` (Upstash Redis, three
  integers, `/download` counts and redirects to the DMG, `/api/stats` feeds the download card) — see `site-b/README.md`.
  Nothing identifying is ever sent or stored; keep it that way, the site copy promises it.
- `Support/UpdateCheck.swift` + `Support/Updater.swift` — the self-updater (2026-10-25, ported from busy-bar-sign; it replaced
  the release.json notice of 2026-09-14, which only pointed at a DMG because self-replacement was thought to need a Developer ID.
  It doesn't: it needs a stable designated requirement, which the self-signed cert gives). `.github/workflows/build.yml` publishes
  every push to `main` as the `latest` release and every pull request as `preview`, each with `VinylCat.zip` + `VinylCat.json`
  (`build` = the run number, which is what's compared; `notes` = the commit subject, shown in the chip). The app checks at launch
  and every four hours and installs when `AppState.midRecord` is false — never mid-scan or mid-import. A download is only installed
  if it satisfies this app's own designated requirement, i.e. it carries the "VinylCat Local Signing" certificate (`scripts/sign.sh`,
  from the `SIGNING_CERT_P12` secret that `scripts/signing-cert-to-ci.sh` installs); quarantine is stripped, so updates never hit
  Gatekeeper. Settings → UPDATES (`Settings/UpdatesSettings.swift`, column one so it doesn't push Settings into scrolling) has the
  two switches and BACK TO MAIN RELEASE, the one case where the build you want has the *lower* number. The amber UPDATE chip
  (`UpdateChip` / `UpdatePopover` in `VinylCatApp.swift`) now means "waiting, not yet installed" — a scan is open, or installing on
  its own is off — and INSTALL NOW does it. Local builds take no part: `build-app.sh` writes a date for CFBundleVersion and no
  stream unless `VINYLCAT_BUILD` / `VINYLCAT_UPDATE_CHANNEL` are set (distinct from `VinylCatChannel`, which gates `LaunchPing`),
  so `Updater.enabled` is false and nothing swaps. `--render-ui` writes `update-available.png`; the self-test covers the release
  comparison and that a local build opts out.
- `Support/BugReport.swift` — bug reports (2026-09-14): REPORT A PROBLEM in Settings → ABOUT, or REPORT on a record in the Library.
  The sheet (`BugReportSheet`) takes a note and an optional reply email, ticks for the last 150 log lines and the record's
  `ScanEvidence`, builds the whole thing as Markdown (`BugReport.markdown`; `scrub` masks anything key-shaped), PREVIEW shows it,
  SEND POSTs `{title, body, version}` to `https://vinyl-cat.com/api/report` (`VINYLCAT_REPORT_URL` redirects it), which files a
  GitHub issue labelled `report` on woody438/VinylCat with the `GITHUB_TOKEN` in the Vercel project env (`site-b/api/report.js`).
  503 (no token) or any failure → the sheet offers SAVE AS FILE to the Desktop. `--render-ui` writes `report-1-settings.png` and
  `report-2-record.png`; the self-test covers title, scrub, markdown and the request body.
  Issues made with Woody's own token never notify him, so `.github/workflows/report-notify.yml` assigns each `report` issue to him
  and comments on it as the Actions bot: that fires the phone's "assigned" and "direct mentions" notifications (tested 2026-09-14).
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
- Model replies on Claude: `max_tokens` is 4000 (see `ClaudeReader`), and `thinking` is omitted rather than disabled.
- Secrets (`Secrets`, alias `Keychain`) live in `~/Library/Application Support/VinylCat/keys.json`, mode 0600 — NOT the login
  keychain any more (2026-09-07, Woody's call). The keychain pins each item to the storing build's code hash via the
  `partition_id` ACL entry; without an Apple team identity that cannot be widened or stripped (tested: "allow all
  applications" only covers the application list; removing the entry prompts too), so every rebuild re-prompted once per key.
  Legacy keychain items are read once on first access, copied to the file and deleted. Non-secret prefs in UserDefaults (`readerProvider`, `discogsUsername`, `currency`, `discogsSync` — default **off**
  (2026-09-07, Woody's call: a fresh install touches Discogs only once the wizard's Discogs step or Settings switches it on);
  read it through `CollectionSync.enabledByUser`, never a raw `UserDefaults` lookup, so the default stays in one place,
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
