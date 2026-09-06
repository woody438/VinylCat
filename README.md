# VinylCat

Hands-free vinyl cataloguing for macOS: hold a record up to the camera, it photographs it, reads the label or cover,
finds the release on Discogs, speaks the result, asks for the B-side / back cover / disc 2, and files everything in a
local database (with an optional push to your Discogs Collection).

## First run

The app opens with a setup wizard (Welcome → Permissions → Discogs → Vision model → Preferences → Ready) that walks
through everything below and tests each piece. Re-run it any time from Settings → "Run setup again".

## What the wizard sets up

1. **Discogs token** — create an account, make a personal access token at discogs.com/settings/developers, paste it in
   **Settings → Discogs → Personal token → Save**, then **Test Discogs**. Without a token the app still looks records up
   (25 requests/min instead of 60) but cannot add them to your Collection.
2. **Vision model key** — paste an OpenAI key (GPT-5.6 Luna, ~$0.001 per scan) or a Google AI key (Gemini 3.8 Flash)
   in **Settings → Identification**, then **Test model** after you've captured one photo. Without a key the app runs
   on local OCR + catalogue numbers only — this works well on labels, worse on artwork-heavy covers.
3. **Permissions** — allow Camera, Microphone and Speech Recognition when macOS asks. (Because the app is ad-hoc signed,
   macOS may ask again after each rebuild.)

## Run

```bash
scripts/build-app.sh debug --run     # build + assemble build/VinylCat.app + launch
scripts/test.sh                      # 35 self-checks (ranker, catalogue numbers, engine, voice, store)
.build/debug/VinylCat --diagnose     # permissions, cameras, keys, Discogs reachability
.build/debug/VinylCat --render-ui ui # every screen/state as PNG, no camera needed
.build/debug/VinylCat --make-test-images img && .build/debug/VinylCat --pipeline-test img/*.png
```

## Scanning

- Set the format in the top bar (or say **"forty-fives" / "twelve inch" / "albums"**). It filters Discogs and sets what
  extra shots are asked for: 7" → label A + B; 12" → cover + label; LP → front + back + label; 2×LP / gatefold detected
  from Discogs and asked for automatically.
- Hold the record steady and sharp for ~0.6 s → chime → it reads, searches, and speaks:
  **Matched** (green) · **N matches — say one/two/three/none** (orange) · **Show me the label** (blue) ·
  **Next shot: B-side / back cover / disc 2 side C** (blue) · **Not found → review queue** (red) · **Already catalogued** (amber).
- The bottom bar always lists the words that work right now.

### Voice commands

| Say | Does |
|---|---|
| capture | force a shot now |
| flip / B-side · label · back cover · gatefold · disc two · add photo | take that specific shot for the open record |
| skip | skip the shot being asked for |
| done | finish this record early |
| undo | retake the last shot (or delete the record if it only has one) |
| review / later | park it for the Review tab |
| again | retake the identification shot |
| one / two / three / none | pick from the candidate list |
| add anyway | keep a second copy of a duplicate |
| forty-fives · twelve inch · albums | switch session format |
| pause / resume | stop / start auto-capture |

## Sharing the app

```bash
scripts/package.sh      # release build → output/VinylCat_vN_YYYY-MM-DD.zip
```

The recipient needs macOS 15 or later. The app is signed locally, not notarised, so on first launch they must
**right-click VinylCat.app → Open** (or System Settings → Privacy & Security → Open Anyway). Their own Discogs token and
model key go in via the wizard; nothing of yours is in the zip.

## Where things live

- Database: `~/Library/Application Support/VinylCat/VinylCat.sqlite` · Photos: `…/VinylCat/Photos/`
- CSV export: `output/vinylcat_export_vN_YYYY-MM-DD.csv` (Library → Export CSV)
- Keys and tokens: macOS Keychain only.
