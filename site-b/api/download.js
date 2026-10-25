// GET /download (rewritten here by vercel.json) → count one download, then send the app.
// release.json says where it lives: since 0.2.3 that is the `latest` GitHub release the build
// workflow replaces on every push to main, so the link never goes stale and every first install
// is a CI build that can update itself. A path without a scheme is still served from this site.
const { bump } = require("../lib/counter");
const release = require("../release.json");

module.exports = async (req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") { res.statusCode = 405; return res.end(); }
  if (req.method === "GET") { try { await bump(["downloads"]); } catch {} }   // never lose a download over a counter
  res.statusCode = 302;
  res.setHeader("Location", /^https?:\/\//.test(release.file) ? release.file : "/" + release.file);
  res.setHeader("Cache-Control", "no-store");
  res.end();
};
