import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const docsRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = resolve(docsRoot, '..');
const contentRoot = join(docsRoot, 'src', 'content', 'docs');

function walkMarkdown(directory) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    if (statSync(path).isDirectory()) return walkMarkdown(path);
    return path.endsWith('.md') ? [path] : [];
  });
}

const filesToCheck = [
  join(repoRoot, 'CLAUDE.md'),
  join(repoRoot, 'ROADMAP.md'),
  join(repoRoot, 'kix', 'lib', 'architecture.md'),
  join(repoRoot, 'kix', 'lib', 'flowcharts.md'),
  join(docsRoot, 'CLAUDE.md'),
  join(docsRoot, 'README.md'),
  join(repoRoot, 'web', 'public', 'llms.txt'),
  join(repoRoot, 'web', 'src', 'lib', 'links.ts'),
  ...walkMarkdown(join(repoRoot, '.claude', 'skills')),
].filter((path) => existsSync(path));

const mdxPathPattern = /\bdocs\/src\/content\/docs\/[a-zA-Z0-9_./-]+\.mdx\b/g;
const retiredPattern = /\b(?:docs-legacy|guide)\/[a-zA-Z0-9_./-]+\.md\b/g;
const docsUrlPattern = /(?:https:\/\/kix\.run)?\/docs\/([a-zA-Z0-9_./-]*)/g;
const generatedFiles = new Set(['llms.txt', 'llms-small.txt', 'llms-full.txt', 'sitemap-0.xml']);

const errors = [];
let checkedCount = 0;

for (const file of filesToCheck) {
  const relFile = relative(repoRoot, file);
  const source = readFileSync(file, 'utf8');

  for (const match of source.matchAll(retiredPattern)) {
    errors.push(`${relFile}: references retired doc path "${match[0]}"`);
  }

  for (const match of source.matchAll(mdxPathPattern)) {
    checkedCount += 1;
    const target = join(repoRoot, match[0]);
    if (!existsSync(target)) {
      errors.push(`${relFile}: missing referenced doc file "${match[0]}"`);
    }
  }

  if (relFile === 'web/public/llms.txt' || relFile === 'web/src/lib/links.ts') {
    for (const match of source.matchAll(docsUrlPattern)) {
      const slug = match[1].replace(/\/+$/, '');
      if (slug === '...' || generatedFiles.has(slug)) continue;
      checkedCount += 1;
      const directMdx = slug === ''
        ? join(contentRoot, 'index.mdx')
        : join(contentRoot, `${slug}.mdx`);
      const indexMdx = join(contentRoot, slug, 'index.mdx');
      if (!existsSync(directMdx) && !existsSync(indexMdx)) {
        errors.push(`${relFile}: URL "${match[0]}" does not match any .mdx page in docs/src/content/docs/`);
      }
    }
  }
}

if (errors.length > 0) {
  console.error('Broken agent/contributor documentation references:');
  for (const entry of errors) console.error(`  ${entry}`);
  process.exit(1);
}

console.log(`doc-refs: ${checkedCount} agent and llms.txt reference(s) verified across ${filesToCheck.length} files`);
