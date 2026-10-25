// release.json is the one place the version and the download live: the pages show the version from
// it, and /download (api/download.js) counts a hit and redirects to the file — the `latest` GitHub
// release the build workflow republishes on every push to main. Every download link on the site
// carries data-download and already points at /download.
fetch("/release.json").then((r) => r.json()).then((rel) => {
  document.querySelectorAll("[data-version]").forEach((el) => { el.textContent = rel.version; });
}).catch(() => {});

// The take-up counters on the download card: three integers from /api/stats (see lib/counter.js).
// The block stays hidden until they arrive, so a missing API costs nothing but the line.
const stats = document.querySelector("[data-stats]");
if (stats) {
  const fmt = new Intl.NumberFormat("en-GB");
  fetch("/api/stats").then((r) => (r.ok ? r.json() : Promise.reject(r.status))).then((t) => {
    stats.querySelectorAll("[data-stat]").forEach((el) => { el.textContent = fmt.format(t[el.dataset.stat] || 0); });
    stats.hidden = false;
  }).catch(() => {});
}
