// POST /api/report {"title","body","version"} → one GitHub issue on the private repo, filed by the server.
// The app (Sources/VinylCat/Support/BugReport.swift) builds the whole text and shows it to the person
// before SEND; nothing is added here but the "report" label. GITHUB_TOKEN is a fine-grained personal
// access token with Issues read/write on woody438/VinylCat, set in the Vercel project's environment.
// Without it the endpoint answers 503 and the app offers SAVE AS FILE instead. Caps: title 120 chars,
// body 60k, 100 reports a day (a runaway client cannot fill the tracker). The counter key `reports`
// is bumped alongside the others — an integer, nothing from the report itself.
const { bump, count, today } = require("../lib/counter");

const REPO = process.env.GITHUB_REPO || "woody438/VinylCat";
const DAILY_CAP = 100;
const MAX_BODY = 60_000;

function readBody(req) {
  if (req.body !== undefined) return Promise.resolve(req.body);   // Vercel has parsed it already
  return new Promise((resolve) => {
    let raw = "";
    req.on("data", (c) => { raw += c; if (raw.length > MAX_BODY + 4096) req.destroy(); });
    req.on("end", () => { try { resolve(JSON.parse(raw || "{}")); } catch { resolve({}); } });
  });
}

function reply(res, status, obj) {
  res.statusCode = status;
  res.setHeader("Content-Type", "application/json");
  res.setHeader("Cache-Control", "no-store");
  res.end(JSON.stringify(obj));
}

module.exports = async (req, res) => {
  if (req.method !== "POST") { res.statusCode = 405; return res.end(); }
  const token = process.env.GITHUB_TOKEN;
  if (!token) return reply(res, 503, { error: "Reports are not switched on at the server yet." });

  const body = (await readBody(req)) || {};
  const title = String(body.title || "").trim().slice(0, 120);
  const text = String(body.body || "");
  if (!title || !text.trim()) return reply(res, 400, { error: "A title and some text are needed." });
  if (text.length > MAX_BODY) return reply(res, 413, { error: "That report is too long." });

  try {
    if ((await count(`reports:d:${today()}`)) >= DAILY_CAP) return reply(res, 429, { error: "Enough reports for today — try tomorrow." });
  } catch {}   // the cap is a courtesy; a counter outage must not block a report

  let issue;
  try {
    const r = await fetch(`https://api.github.com/repos/${REPO}/issues`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "vinyl-cat.com report",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ title, body: text, labels: ["report"] }),
    });
    if (!r.ok) return reply(res, 502, { error: `GitHub answered ${r.status}.` });
    issue = await r.json();
  } catch (e) {
    return reply(res, 502, { error: "GitHub could not be reached." });
  }
  try { await bump(["reports"]); } catch {}
  reply(res, 201, { url: issue.html_url, number: issue.number });
};
