# VinylCat

Hands-free vinyl cataloguing for macOS: hold a record up to the camera, it photographs it, reads the label or cover,
finds the release on Discogs, speaks the result, and files it in a local database with a value in your currency
(with an optional two-way sync to your Discogs Collection, off until you switch it on).

Website, download and how it works: **[vinyl-cat.com](https://vinyl-cat.com)**. Current version: 0.2.2.

## Read this first: the app is not signed by Apple

> **⚠️ macOS will refuse to open VinylCat the first time. This is expected — follow the six steps below.**

**VinylCat is ad-hoc signed on the build machine. It is not signed with an Apple Developer ID and it is
not notarised by Apple.** The block is Gatekeeper doing its job on an unnotarised app — it is not a broken
download, and it does not mean anything is wrong with the app.

Double-clicking will show **"Apple could not verify VinylCat is free of malware"** with only a **Done**
button. There is no "Open" button in that dialog, and **right-click → Open does not work on macOS 15 or
later** — that old workaround is gone. The only way in is through System Settings:

1. Drag **VinylCat** onto **Applications**.
2. Double-click **VinylCat**. The malware warning appears — click **Done**. (Nothing has gone wrong; this
   step is required, because it is what tells macOS an app was blocked.)
3. Open **System Settings → Privacy & Security**.
4. Scroll all the way to the bottom, to the **Security** section. You will see
   **"VinylCat was blocked to protect your Mac."** Click **Open Anyway** next to it.
   *This line only appears after step 2. If you don't see it, go back and double-click the app again.*
5. Authenticate with Touch ID or your password if asked, then click **Open Anyway** once more in the
   confirmation dialog.
6. VinylCat opens. **You only ever do this once** — every later launch is a normal double-click.

If you want to skip all of the above, the app has to be signed with a paid Apple Developer ID ($99/year)
and notarised by Apple. Until then, the steps above are the way in — but **only once, ever**: from then on VinylCat
updates itself silently, with no further warnings (see [Updates](#updates)).

## First run

The app opens with a setup wizard (Welcome → Permissions → Discogs → Vision model → Preferences → Ready) that walks
through everything below and tests each piece. Re-run it any time from Settings → "Run setup again".

## What the wizard sets up

1. **Discogs token** — create an account, make a personal access token at discogs.com/settings/developers, paste it in
   **Settings → Discogs → Personal token → Save**, then **Test Discogs**. Without a token the app still looks records up
   (25 requests/min instead of 60) but cannot add them to your Collection. **Adding matches to your Discogs
   Collection is off on a fresh install** — switch it on in the wizard's Discogs step, or later under
   **Settings → "Add matches to my Collection"**. Until you do, VinylCat neither writes to nor pulls from Discogs.
2. **Vision model key** — pick a reader in **Settings → Identification** and paste that provider's key: Anthropic
   (Claude 5.5 — Haiku ~$0.0005, Sonnet ~$0.010, Opus ~$0.020 per scan; Opus is the default rung), OpenAI
   (GPT-5.6 Luna, ~$0.0008) or Google (Gemini 3.8 Flash, ~$0.002). Then **Test model** after you've captured one
   photo. With the `ant` CLI signed in, the Claude reader uses a short-lived token and stores no key. Without any
   key the app runs on local OCR + catalogue numbers only — this works well on labels, worse on artwork-heavy covers.
3. **Permissions** — allow Camera, Microphone and Speech Recognition when macOS asks. (Because the app is ad-hoc signed,
   macOS may ask again after each rebuild.)

## Run

```bash
scripts/build-app.sh debug --run     # build + assemble build/VinylCat.app + launch
scripts/test.sh                      # 117 self-checks (ranker, catalogue numbers, engine, voice, store, import, coffee, spend, updates, reports)
.build/debug/VinylCat --diagnose     # permissions, cameras, keys, Discogs reachability
.build/debug/VinylCat --render-ui ui # every screen/state as PNG, no camera needed
.build/debug/VinylCat --make-test-images img && .build/debug/VinylCat --pipeline-test img/*.png
```

## Scanning

- Set the format in the top bar (or say **"forty-fives" / "twelve inch" / "albums"**). It filters the Discogs search.
- Hold the record steady and sharp for ~0.6 s → chime → it reads, searches, and speaks:
  **Matched** (green) · **N matches — press 1–9 or say the number, N for none** (orange) · **Show me the label** (blue) ·
  **Try again** (amber) · **Not found → review queue** (red) · **Already catalogued** (amber) · **Error → review queue** (red).
- One photo per record, the identifying one. Extra photos only when you ask: **F** / "flip" for the B-side, **P** /
  "add photo", or say "back cover", "gatefold", "disc two". The record closes again after each.
- Thumbs down — **W** / "wrong record" — keeps the record and its evidence for tuning but takes it out of the counts,
  the value and your Discogs Collection, and puts it in the Review tab to fix.
- The bottom bar always lists the keys and words that work right now: SPACE capture · F flip · U undo · W wrong record ·
  P add photo · S skip · D done · R review · N none · 1–9 pick · RETURN add anyway · ESC start over.
- The rail's meters: **DISCOGS** calls used this minute (from Discogs' own headers, back to 0/60 a minute after the last
  call), **LLM COST** this session with the month to date underneath (amber past the figure in Settings → Identification,
  default $5 — a warning, never a stop), **REVIEW** the queue. After a Collection pull the app prices every record that
  has no value yet, one Discogs call every 2.2 s; the rail says "Pricing N of M · leave the app open" while it runs, and it
  carries on from where it left off next launch.

### Voice commands

| Say | Does |
|---|---|
| capture | force a shot now |
| flip / B-side · label · back cover · gatefold · disc two · add photo | take that extra photo for the last record |
| skip | skip what is being asked for (label, retry) — to the review queue |
| done | close the record |
| undo | remove the last extra photo, then the record |
| wrong record | thumbs down: out of the counts and Discogs, into the Review tab |
| review / later | park it for the Review tab |
| again | retake the identification shot |
| one … nine ("number four", "number seven") / none | pick from the candidate list |
| add anyway | keep a second copy of a duplicate |
| forty-fives · twelve inch · albums | switch session format |
| pause / resume · manual mode / auto mode | stop / start auto-capture |

Voice is off until you click VOICE in the top bar (Settings → Voice → "Listen from launch" changes that).

## Sharing the app

```bash
scripts/package.sh      # release build → output/VinylCat_vN_YYYY-MM-DD.dmg (app + Applications shortcut + "Read me first.txt")
```

The recipient needs macOS 15 or later on an Apple silicon Mac (the build is arm64 only; add `--arch arm64 --arch x86_64`
to the `swift build` calls in `scripts/build-app.sh` for an Intel Mac).

**Tell them the app is not signed by Apple and that macOS will block the first launch** — point them at
[Read this first: the app is not signed by Apple](#read-this-first-the-app-is-not-signed-by-apple),
which is also on the DMG as "Read me first.txt". Without those steps they will think the app is broken.

After it opens, the setup wizard asks for Camera, Microphone and Speech Recognition and checks Dictation is on; they
click ALLOW on each, once. They then enter their own Discogs token and model key — none of yours is in the DMG.
Release builds send one anonymous tick to vinyl-cat.com per launch (the word "launch" and the version, nothing else) so
you can see take-up on the site's download card; Settings → ABOUT switches it off. Debug builds never send it.

Updates: the app installs them itself — see [Updates](#updates). Their database and photos live in their own
Application Support folder and survive the swap.

Shipping a release: bump `CFBundleShortVersionString` in `Resources/Info.plist`, push to `main`, and the build
workflow publishes the `latest` release that every copy updates to. The site is still the front door for first
installs, so to put a DMG there as well: `scripts/package.sh`, copy it into `site-b/downloads/`, update
`site-b/release.json` (`version`, `file`, `notes`), push — Vercel deploys the site from `main`.

## Updates

VinylCat updates itself. Every build GitHub Actions publishes carries its own build number and the release stream
it came from, and the app checks at launch and every four hours. A newer build is installed when you are between
records — never mid-scan or mid-import — and takes a second or two: the app quits, swaps itself and reopens. The
catalogue, the photos and the keys are untouched, and because every build is signed with the same certificate macOS
treats it as the same app, so Camera, Microphone and Speech permissions carry over. **There is no Open Anyway on an
update** — only on the very first install.

Left to itself it is silent. An amber UPDATE chip appears in the top bar only when a build is waiting that it has
not installed yet — because a scan is open, or because you turned off installing on its own. Clicking it shows
what's new and INSTALL NOW.

Two streams, switched in **Settings → UPDATES**:

| | where it comes from | who gets it |
| --- | --- | --- |
| `latest` | every push to `main` | everyone |
| `preview` | whichever pull request built last | only with **Get preview builds** on |

Switch previews off again while running one and main's build is *older* by number, so it is not offered as an
update: **BACK TO MAIN RELEASE** installs it there and then. Otherwise the next build from main carries you back.

An update is only ever installed if it is signed with the project's certificate — the same "VinylCat Local Signing"
certificate this Mac builds with, held by GitHub as a secret. An ad-hoc build has nothing to match and so can never
install anything, which is the point: without that check, anything that could write to the release page could
replace the app. This replaced the old release.json notice (0.2.0–0.2.2), which could only point at a DMG, on the
assumption that self-replacement needed a Developer ID. It doesn't — it needs a stable designated requirement,
which a self-signed certificate gives.

### Setting it up

One-off, on this Mac:

1. **Keychain Access → login → My Certificates → "VinylCat Local Signing" → right-click → Export…** as a `.p12`,
   with a password.
2. ```bash
   scripts/signing-cert-to-ci.sh ~/Desktop/Certificates.p12
   ```
   It checks the file holds the right identity, copies it to the clipboard base64'd, and names the two repository
   secrets to paste it into (`SIGNING_CERT_P12`, `SIGNING_CERT_PASSWORD`). Delete the `.p12` afterwards; keep the
   password in your password manager.

Until those secrets exist, CI still builds and publishes — but ad hoc, so nothing auto-updates to those builds and
the run prints a warning saying so. A *replacement* certificate later costs every installed copy one more round of
allowing Camera, Microphone and Speech, and one manual install.

Builds made here with `scripts/build-app.sh` stamp a date for a version and no stream, so they take no part in
updates and say so in Settings. Only CI's builds update themselves.

Bug reports: REPORT A PROBLEM in Settings → ABOUT, or REPORT on a record in the Library. The note, the last 150 log
lines and the record's scan evidence (both optional, keys masked) go to vinyl-cat.com/api/report, which files a GitHub
issue labelled `report` here. If that fails the sheet offers SAVE AS FILE.

## Where things live

- Database: `~/Library/Application Support/VinylCat/VinylCat.sqlite` · Photos: `…/VinylCat/Photos/`
- CSV export: `output/vinylcat_export_vN_YYYY-MM-DD.csv` (Library → Export CSV)
- Keys and tokens: `~/Library/Application Support/VinylCat/keys.json`, mode 0600 (not the login keychain).
