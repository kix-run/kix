import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const docsRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const contentRoot = join(docsRoot, 'src', 'content', 'docs');
const importPattern = /\bfrom\s+['"](\/src\/[^'"?]+)(?:\?[^'"]*)?['"]/g;

function walk(directory) {
  return readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    return statSync(path).isDirectory() ? walk(path) : [path];
  });
}

const missing = [];

for (const page of walk(contentRoot).filter(
  (path) => path.endsWith('.mdx') && !path.includes(`${join('docs', 'v0.1')}/`),
)) {
  const source = readFileSync(page, 'utf8');
  for (const match of source.matchAll(importPattern)) {
    const imported = match[1];
    const target = join(docsRoot, imported.slice(1));
    if (!existsSync(target)) {
      missing.push(`${relative(docsRoot, page)}: ${imported}`);
    }
  }
}

if (missing.length > 0) {
  console.error('Missing local imports:');
  for (const entry of missing) console.error(`  ${entry}`);
  process.exit(1);
}

console.log('local imports: all referenced files exist');
