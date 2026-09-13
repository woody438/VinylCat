// POST /api/ping  {"event":"launch"|"install","version":"0.1.0"}
// The app calls this once per launch ("launch") and once per Mac after install ("install").
// The body is the whole message: nothing about the machine or the person is read, kept or logged.
const { bump } = require("../lib/counter");

const EVENTS = new Set(["launch", "install"]);
const VERSION = /^\d+\.\d+(\.\d+)?$/;

function readBody(req) {
  if (req.body !== undefined) return Promise.resolve(req.body);   // Vercel has parsed it already
  return new Promise((resolve) => {
    let raw = "";
    req.on("data", (c) => { raw += c; if (raw.length > 1024) req.destroy(); });
    req.on("end", () => { try { resolve(JSON.parse(raw || "{}")); } catch { resolve({}); } });
  });
}

module.exports = async (req, res) => {
  if (req.method !== "POST") { res.statusCode = 405; return res.end(); }
  const body = (await readBody(req)) || {};
  const event = String(body.event || "");
  const version = String(body.version || "");
  if (!EVENTS.has(event)) { res.statusCode = 400; return res.end("bad event"); }
  const keys = event === "install" ? ["installs"] : ["launches"];
  if (event === "launch" && VERSION.test(version)) keys.push(`launches:v:${version}`);
  try {
    await bump(keys);
    res.statusCode = 204;
  } catch (e) {
    res.statusCode = 503;
  }
  res.end();
};
