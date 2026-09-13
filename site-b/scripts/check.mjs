// Static checks: every local href/src resolves, every img has alt, every page has a title, no unclosed <section>.
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { resolve, dirname } from "node:path";

const root = resolve(new URL("..", import.meta.url).pathname);
const pages = readdirSync(root).filter((f) => f.endsWith(".html"));
let problems = 0;
const bad = (msg) => { problems++; console.log("  ✗ " + msg); };

for (const page of pages) {
  const html = readFileSync(resolve(root, page), "utf8");
  console.log(page);
  if (!/<title>[^<]+<\/title>/.test(html)) bad("no <title>");
  const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]));
  for (const m of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
    const u = m[1];
    if (/^(https?:|mailto:|#$)/.test(u)) continue;
    if (u.startsWith("#")) { if (!ids.has(u.slice(1))) bad(`anchor ${u} has no target`); continue; }
    const [path, hash] = u.split("#");
    const file = resolve(dirname(resolve(root, page)), path);
    if (!existsSync(file)) { bad(`${u} does not exist`); continue; }
    if (hash && path.endsWith(".html")) {
      const other = readFileSync(file, "utf8");
      if (!new RegExp(`\\sid="${hash}"`).test(other)) bad(`${u}: no id ${hash} in ${path}`);
    }
  }
  for (const m of html.matchAll(/<img\b[^>]*>/g)) if (!/\balt="/.test(m[0])) bad(`img without alt: ${m[0].slice(0, 60)}`);
  const open = (html.match(/<section\b/g) || []).length, close = (html.match(/<\/section>/g) || []).length;
  if (open !== close) bad(`section tags: ${open} open, ${close} close`);
  const dopen = (html.match(/<div\b/g) || []).length, dclose = (html.match(/<\/div>/g) || []).length;
  if (dopen !== dclose) bad(`div tags: ${dopen} open, ${dclose} close`);
  if (!/data-download/.test(html)) bad("no download link");
}
console.log(problems ? `\n${problems} problem(s)` : "\nall clear");
process.exit(problems ? 1 : 0);
