// GET /api/stats → {"downloads":N,"installs":N,"launches":N}. The site reads it for the download card;
// anyone else may too, there is nothing in it but three integers.
const { totals } = require("../lib/counter");

module.exports = async (req, res) => {
  if (req.method !== "GET") { res.statusCode = 405; return res.end(); }
  try {
    const t = await totals();
    res.setHeader("Content-Type", "application/json");
    res.setHeader("Cache-Control", "public, max-age=60, s-maxage=60");
    res.setHeader("Access-Control-Allow-Origin", "*");
    res.end(JSON.stringify(t));
  } catch (e) {
    res.statusCode = 503;
    res.end(JSON.stringify({ error: String(e.message || e) }));
  }
};
