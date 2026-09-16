import { readdir, readFile } from 'node:fs/promises';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const docsRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const contentRoot = join(docsRoot, 'src/content/docs/how-to');
const ledgerPath = join(docsRoot, 'how-to-coverage.json');

async function findPages(directory) {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) return findPages(path);
    if (!entry.isFile() || !entry.name.endsWith('.mdx') || entry.name === 'index.mdx') return [];
    return [path];
  }));
  return nested.flat();
}

const ledger = JSON.parse(await readFile(ledgerPath, 'utf8'));
const entries = ledger.pages ?? [];
const actualPages = (await findPages(contentRoot))
  .map((path) => relative(contentRoot, path).replace(/\.mdx$/u, ''))
  .sort();
const ledgerPages = entries.map(({ page }) => page).sort();
const errors = [];
let unverifiedTotal = 0;

for (const page of new Set(ledgerPages)) {
  if (ledgerPages.filter((candidate) => candidate === page).length > 1) {
    errors.push(`duplicate ledger entry: ${page}`);
  }
}
for (const page of actualPages) {
  if (!ledgerPages.includes(page)) errors.push(`page missing from ledger: ${page}`);
}
for (const page of ledgerPages) {
  if (!actualPages.includes(page)) errors.push(`ledger points to a missing page: ${page}`);
}

for (const entry of entries) {
  if (!ledger.scenarios?.[entry.scenario]) {
    errors.push(`${entry.page}: unknown scenario ${entry.scenario}`);
  }
  if (!['planned', 'implemented'].includes(entry.status)) {
    errors.push(`${entry.page}: invalid status ${entry.status}`);
  }
  const pagePath = join(contentRoot, `${entry.page}.mdx`);
  const content = await readFile(pagePath, 'utf8');
  const isPlaceholder = /^description: TODO$/mu.test(content);
  if (entry.status === 'implemented' && isPlaceholder) {
    errors.push(`${entry.page}: marked implemented but still has a TODO description`);
  }
  if (entry.status === 'planned' && !isPlaceholder) {
    errors.push(`${entry.page}: has content but is still marked planned`);
  }

  // Unlike `<Snippet>` excerpts, hand-written ```nix blocks are not checked
  // against a source file. The September 2026 audit found that most examples
  // that failed as written were in these blocks (v2_discussions/142).
  //
  // They remain useful for short fragments and files the reader is creating.
  // Recording the count in the ledger makes each addition explicit and keeps
  // the remaining unverified examples measurable.
  const declared = entry.unverifiedNixBlocks ?? 0;
  const actual = (content.match(/^```nix\b/gmu) ?? []).length;
  if (actual !== declared) {
    const verb = actual > declared ? 'added' : 'removed';
    errors.push(
      `${entry.page}: ${actual} hand-written \`\`\`nix block(s), ledger declares ${declared}. ` +
      `If you ${verb} one deliberately, update unverifiedNixBlocks in how-to-coverage.json. ` +
      `Prefer a region snippet from kix-examples, which is drift-checked against its source.`,
    );
  }
  unverifiedTotal += actual;
}

if (errors.length > 0) {
  console.error(errors.join('\n'));
  process.exit(1);
}

const implemented = entries.filter(({ status }) => status === 'implemented').length;
console.log(
  `how-to coverage: ${implemented}/${entries.length} implemented; ledger matches content tree; ` +
  `${unverifiedTotal} unverified hand-written nix block(s)`,
);
