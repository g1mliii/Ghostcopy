// Loads a function module (TypeScript) into Node: types are stripped and each
// relative './x.ts' import is loaded the same way, so the tests run the same
// module graph the edge runtime does. A module is loaded once and shared.
import { readFile } from 'node:fs/promises';
import { stripTypeScriptTypes } from 'node:module';

const urls = new Map();

export function tsModuleUrl(url) {
  if (!urls.has(url.href)) {
    urls.set(url.href, (async () => {
      let source = await readFile(url, 'utf8');
      const specifiers = new Set([...source.matchAll(/from '(\.\/[\w-]+\.ts)'/g)].map((match) => match[1]));
      for (const specifier of specifiers) {
        source = source.replaceAll(`'${specifier}'`, JSON.stringify(await tsModuleUrl(new URL(specifier, url))));
      }
      const compiled = stripTypeScriptTypes(source, { mode: 'transform' });
      return `data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`;
    })());
  }
  return urls.get(url.href);
}

/** Import supabase/functions/_shared/<name>. */
export async function importShared(name) {
  return import(await tsModuleUrl(new URL(`../../supabase/functions/_shared/${name}`, import.meta.url)));
}
