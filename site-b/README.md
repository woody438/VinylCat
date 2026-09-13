# VinylCat site (build B)

Three plain HTML pages, one stylesheet, no build step. Palette and type mirror the app
(`Sources/VinylCat/Support/Theme.swift`): Barlow Condensed + IBM Plex Mono / Sans, dark control-room.

- `index.html` — overview: the six-step loop, the five outcomes, features, voice table, measured numbers, needs and limits, download, coffee.
- `install.html` — the six Gatekeeper steps, first-run wizard, updating, where data lives.
- `how-it-works.html` — the six layers with the exact model prompts, Discogs ladder, ranker weights, every knob.
- `assets/img/` — real screens from `.build/debug/VinylCat --render-ui`, plus the icon from `Resources/AppIcon.icns`.
- `release.json` — the one place the version and DMG path live: the pages show the version from it, `/download` redirects to the file.
- `assets/js/site.js` — fills in the version and the take-up counters.
- `api/` + `lib/counter.js` — the take-up counter (below). `vercel.json` rewrites `/download` to `api/download.js`.

```bash
npm run dev     # http://localhost:4174 — static pages plus the api/ functions, counters in memory (scripts/dev.mjs)
npm run check   # links, anchors, alt text, tag balance
```

No dependencies: `npm install` has nothing to do.

## Take-up counter

Three integers, nothing else. No IPs, user agents or identifiers are read, kept or logged by the code here
(Vercel's own request logs are the only place an IP ever appears, and only for as long as Vercel keeps them).

| Counter     | Bumped by                                                                    |
|-------------|------------------------------------------------------------------------------|
| `downloads` | every `GET /download` — the download buttons point there; it counts, then 302s to the DMG |
| `installs`  | the app's first launch on a Mac (`POST /api/ping {"event":"install"}`, sent once, flag in UserDefaults) |
| `launches`  | every launch of a release build (`POST /api/ping {"event":"launch","version":"0.1.0"}`) |

Per-version (`launches:v:<ver>`) and per-UTC-day (`<key>:d:<yyyy-mm-dd>`) keys are kept alongside for a chart later.
`GET /api/stats` returns the three totals (cached 60 s); the download card on every page shows them and stays
hidden if the API is unreachable. The app's side is `Sources/VinylCat/Support/LaunchPing.swift`: release builds
only, Settings → ABOUT → "Count launches" is the user's switch, `VINYLCAT_PING=1 VINYLCAT_PING_URL=http://localhost:4174/api/ping`
points a dev build at the local server.

### Hosting on Vercel (once)

1. `vercel.com` → Add New Project → import `woody438/VinylCat`, **Root Directory `site-b`**, framework "Other". Deploy.
2. Storage → Marketplace → **Upstash for Redis** (free tier: 10k commands/day, far more than this needs) → connect it to the
   project. It sets `KV_REST_API_URL` / `KV_REST_API_TOKEN`; `lib/counter.js` reads those. Redeploy so the functions see them.
3. Project → Domains → add `vinyl-cat.com` and `www.vinyl-cat.com`; at GoDaddy point the apex A record at Vercel's IP and
   `www` CNAME at `cname.vercel-dns.com` (the Domains page shows the exact values). The GoDaddy site builder page goes away.
4. Check `https://vinyl-cat.com/api/stats` returns `{"downloads":0,"installs":0,"launches":0}` and the card on the front page
   shows the line. Every push to `main` redeploys.

The counts live in Redis, not in the deployment: redeploys, and `vercel --prod` from a laptop, never reset them. To read them
outside the site: the Upstash console's data browser, or `curl https://vinyl-cat.com/api/stats`.

Built 2026-09-09 alongside a second design in `site/` (another session). Pick one, or merge.
