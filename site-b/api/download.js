// GET /download (rewritten here by vercel.json) → count one download, then send the DMG.
// The file itself stays a static asset in downloads/; release.json says which one.
const { bump } = require("../lib/counter");
const release = require("../release.json");

module.exports = async (req, res) => {
  if (req.method !== "GET" && req.method !== "HEAD") { res.statusCode = 405; return res.end(); }
  if (req.method === "GET") { try { await bump(["downloads"]); } catch {} }   // never lose a download over a counter
  res.statusCode = 302;
  res.setHeader("Location", "/" + release.file);
  res.setHeader("Cache-Control", "no-store");
  res.end();
};
