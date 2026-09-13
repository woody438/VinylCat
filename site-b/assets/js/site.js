// One place for the things that change per release.
// Every download link on the site carries data-download and picks this up.
const RELEASE = {
  version: "0.1.0",
  // The DMG ships with the site (downloads/). Rebuild it with scripts/package.sh, copy it here,
  // and change this one line; every button follows.
  url: "downloads/VinylCat_v1_2026-09-09.dmg",
};

document.querySelectorAll("a[data-download]").forEach((a) => {
  a.href = RELEASE.url;
});
document.querySelectorAll("[data-version]").forEach((el) => {
  el.textContent = RELEASE.version;
});
