// The counters behind /api/stats, /api/ping and /download. Plain integers in Redis, nothing else:
// no IPs, no user agents, no identifiers. Keys:
//   downloads            every hit on /download (the DMG redirect)
//   installs             the app's first launch after install ("install" ping, sent once per Mac)
//   launches             every launch of a release build ("launch" ping)
//   launches:v:<ver>     the same, per app version
//   reports              every bug report filed through /api/report (the report itself goes to GitHub, not here)
//   <key>:d:<yyyy-mm-dd> the same, per UTC day, for a chart later
//
// Storage is the Upstash Redis REST API (the "Upstash for Redis" Vercel Marketplace integration
// sets KV_REST_API_URL / KV_REST_API_TOKEN; a store made in the Upstash console sets
// UPSTASH_REDIS_REST_URL / UPSTASH_REDIS_REST_TOKEN — both are accepted). With neither set
// (local `npm run dev`) the counts live in memory and start from zero on every restart.

const TOTALS = ["downloads", "installs", "launches"];

const url = process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL;
const token = process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN;
const memory = new Map();

async function redis(commands) {
  const res = await fetch(`${url}/pipeline`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(commands),
  });
  if (!res.ok) throw new Error(`redis ${res.status}: ${await res.text()}`);
  const out = await res.json();
  const failed = out.find((r) => r.error);
  if (failed) throw new Error(`redis: ${failed.error}`);
  return out.map((r) => r.result);
}

const today = () => new Date().toISOString().slice(0, 10);

/** Increment every key by one (plus its per-day bucket). */
async function bump(keys) {
  const all = keys.flatMap((k) => [k, `${k}:d:${today()}`]);
  if (!url) { for (const k of all) memory.set(k, (memory.get(k) || 0) + 1); return; }
  await redis(all.map((k) => ["INCR", k]));
}

/** One key's value (0 when unset). */
async function count(key) {
  const v = url ? (await redis([["GET", key]]))[0] : memory.get(key);
  return Number(v) || 0;
}

/** The three headline totals. */
async function totals() {
  const values = url ? await redis([["MGET", ...TOTALS]]).then((r) => r[0]) : TOTALS.map((k) => memory.get(k) || 0);
  return Object.fromEntries(TOTALS.map((k, i) => [k, Number(values[i]) || 0]));
}

module.exports = { bump, count, totals, today, TOTALS, backed: Boolean(url) };
