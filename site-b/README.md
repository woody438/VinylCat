# VinylCat site (build B)

Three plain HTML pages, one stylesheet, no build step. Palette and type mirror the app
(`Sources/VinylCat/Support/Theme.swift`): Barlow Condensed + IBM Plex Mono / Sans, dark control-room.

- `index.html` — overview: the six-step loop, the five outcomes, features, voice table, measured numbers, needs and limits, download, coffee.
- `install.html` — the six Gatekeeper steps, first-run wizard, updating, where data lives.
- `how-it-works.html` — the six layers with the exact model prompts, Discogs ladder, ranker weights, every knob.
- `assets/img/` — real screens from `.build/debug/VinylCat --render-ui`, plus the icon from `Resources/AppIcon.icns`.
- `assets/js/site.js` — the one place the release URL and version live; every download button reads it.

```bash
npm install     # once
npm run dev     # http://localhost:4174
npm run check   # links, anchors, alt text, tag balance
```

Built 2026-09-09 alongside a second design in `site/` (another session). Pick one, or merge.
