// Local server for the site: the static pages plus the same api/ functions Vercel runs, with the
// counters held in memory (no Redis env vars → lib/counter falls back). http://localhost:4174
import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { createRequire } from "node:module";
import { extname, join, normalize, resolve } from "node:path";

const root = resolve(new URL("..", import.meta.url).pathname);
const require = createRequire(import.meta.url);
const routes = {
  "/api/stats": require(join(root, "api/stats.js")),
  "/api/ping": require(join(root, "api/ping.js")),
  "/api/download": require(join(root, "api/download.js")),
  "/download": require(join(root, "api/download.js")),   // the vercel.json rewrite
};
const types = { ".html": "text/html;charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".json": "application/json",
                ".png": "image/png", ".svg": "image/svg+xml", ".dmg": "application/x-apple-diskimage", ".txt": "text/plain" };

createServer(async (req, res) => {
  const path = decodeURIComponent(new URL(req.url, "http://x").pathname);
  const fn = routes[path];
  if (fn) { try { await fn(req, res); } catch (e) { res.statusCode = 500; res.end(String(e)); } return; }
  let file = normalize(join(root, path === "/" ? "index.html" : path));
  if (!file.startsWith(root) || file.includes("node_modules")) { res.statusCode = 403; return res.end(); }
  try {
    if ((await stat(file)).isDirectory()) file = join(file, "index.html");
    res.setHeader("Content-Type", types[extname(file)] || "application/octet-stream");
    res.end(await readFile(file));
  } catch { res.statusCode = 404; res.end("not found"); }
}).listen(4174, () => console.log("VinylCat site → http://localhost:4174  (counters in memory)"));
