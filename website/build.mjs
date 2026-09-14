// Builds the deployable site into ./dist.
//
// Only assets listed here are published - keeps build config (package.json,
// tailwind.config.js, input.css, node_modules) out of the public site.
//
// CSS and JS are content-hashed into /assets and referenced by their hashed
// name. That is what makes the year-long immutable Cache-Control in _headers
// correct: previously output.css was marked immutable under a filename that
// never changed, so a deploy was invisible to anyone who had already visited
// until their cache expired. A new build now means a new URL.
import { cp, mkdir, rm, readdir, readFile, writeFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';

const root = import.meta.dirname;
const dist = path.join(root, 'dist');

// Copied verbatim, cached normally.
const FILES = ['_headers', '_redirects', 'site.webmanifest', 'robots.txt', 'sitemap.xml'];

// Content-hashed into /assets, cached forever.
const HASHED = ['output.css', 'waitlist.js', 'reset-password.js'];

// Rewritten (so it points at the hashed names) but served from the root, which
// a service worker must be to control the whole origin.
const REWRITTEN = ['sw.js'];

const DIRS = ['icons'];

await rm(dist, { recursive: true, force: true });
await mkdir(path.join(dist, 'assets'), { recursive: true });

function require_(file) {
  if (!existsSync(path.join(root, file))) {
    throw new Error(`build: missing required file "${file}" - run "npm run build:css" first?`);
  }
}

// 1. Hash each asset and write it under its new name.
const hashedNames = new Map();
for (const file of HASHED) {
  require_(file);
  const body = await readFile(path.join(root, file));
  const hash = createHash('sha256').update(body).digest('hex').slice(0, 8);
  const ext = path.extname(file);
  const name = `${path.basename(file, ext)}.${hash}${ext}`;
  await writeFile(path.join(dist, 'assets', name), body);
  hashedNames.set(file, `/assets/${name}`);
}

// 2. Point every reference at the hashed name. Matches "./x", "/x" and bare "x"
//    so it catches both the HTML link/script tags and the service worker's
//    precache list.
function rewrite(text) {
  for (const [file, url] of hashedNames) {
    const pattern = new RegExp(`(\\./|/)?${file.replace(/[.]/g, '\\.')}`, 'g');
    text = text.replace(pattern, url);
  }
  return text;
}

const html = (await readdir(root)).filter((f) => f.endsWith('.html'));
for (const file of [...html, ...REWRITTEN]) {
  require_(file);
  const body = await readFile(path.join(root, file), 'utf8');
  await writeFile(path.join(dist, file), rewrite(body));
}

// 3. Everything else, unchanged.
for (const file of FILES) {
  require_(file);
  await cp(path.join(root, file), path.join(dist, file));
}

for (const dir of DIRS) {
  if (existsSync(path.join(root, dir))) {
    await cp(path.join(root, dir), path.join(dist, dir), { recursive: true });
  }
}

console.log(
  `built dist/ with ${html.length} pages, ` +
  `${hashedNames.size} hashed assets (${[...hashedNames.values()].map((u) => path.basename(u)).join(', ')})`
);
