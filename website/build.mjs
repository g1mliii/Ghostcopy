// Builds the deployable site into ./dist.
// Only assets listed here are published - keeps build config (package.json,
// tailwind.config.js, input.css, node_modules) out of the public site.
import { cp, mkdir, rm, readdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';

const root = import.meta.dirname;
const dist = path.join(root, 'dist');

const FILES = ['output.css', 'sw.js', '_headers', 'site.webmanifest'];
const DIRS = ['images', 'icons'];

await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });

// Every top-level .html page
const html = (await readdir(root)).filter((f) => f.endsWith('.html'));
for (const f of [...html, ...FILES]) {
  if (!existsSync(path.join(root, f))) {
    throw new Error(`build: missing required file "${f}" - run "npm run build:css" first?`);
  }
  await cp(path.join(root, f), path.join(dist, f));
}

for (const d of DIRS) {
  if (existsSync(path.join(root, d))) {
    await cp(path.join(root, d), path.join(dist, d), { recursive: true });
  }
}

console.log(`built dist/ with ${html.length} pages + ${FILES.length} assets`);
