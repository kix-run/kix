import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const docsRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = resolve(process.env.KIX_REPO_ROOT ?? join(docsRoot, '..'));
const contentRoot = join(docsRoot, 'src', 'content', 'docs');

function walkFiles(directory, extensions) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory).flatMap((name) => {
    const path = join(directory, name);
    if (statSync(path).isDirectory()) return walkFiles(path, extensions);
    return extensions.some((ext) => path.endsWith(ext)) ? [path] : [];
  });
}

function expandBraces(pattern) {
  const braceMatch = pattern.match(/^(.*)\{([^{}]+)\}(.*)$/);
  if (!braceMatch) return [pattern];
  const [, prefix, inner, suffix] = braceMatch;
  return inner.split(',').flatMap((part) => expandBraces(`${prefix}${part}${suffix}`));
}

const maintainerFiles = [
  join(repoRoot, 'CLAUDE.md'),
  join(repoRoot, 'ROADMAP.md'),
  join(repoRoot, 'cli', 'README.md'),
  join(repoRoot, 'kix', 'lib', 'architecture.md'),
  join(repoRoot, 'kix', 'lib', 'flowcharts.md'),
  join(docsRoot, 'CLAUDE.md'),
  join(docsRoot, 'README.md'),
  join(repoRoot, 'web', 'public', 'llms.txt'),
  join(repoRoot, 'web', 'src', 'lib', 'links.ts'),
  ...walkFiles(join(repoRoot, '.claude', 'skills'), ['.md']),
  ...walkFiles(join(repoRoot, '.claude', 'rules'), ['.md']),
].filter((path) => existsSync(path));

const mdxFiles = walkFiles(contentRoot, ['.mdx']);
const filesToCheck = [...maintainerFiles, ...mdxFiles];

const mdxPathPattern = /\bdocs\/src\/content\/docs\/[a-zA-Z0-9_./-]+\.mdx\b/g;
const retiredPattern = /\b(?:docs-legacy|guide|fibery_docs)\/[a-zA-Z0-9_./-]*|\b(?:HANDBOOK|BEST-PRACTICES|MAJOR_FEATURES)\.md\b|\bdocs\/blog\//g;
const bannedTokens = [
  { pattern: /\bkix scorecard\b/g, reason: 'use `kix check` (no `kix scorecard` subcommand exists)' },
  { pattern: /\bkix validate\b/g, reason: 'use `kix check` (no `kix validate` subcommand exists)' },
  { pattern: /\bkix inspect package\b/g, reason: 'use `kix list packages` or `kix list resources <cluster>`' },
  { pattern: /\bkix\.flavors\.vanilla\b/g, reason: 'use `kix.flavors.generic` or `kix.flavors.kubeadm`' },
  { pattern: /\bkix\.rules\.recommended\b/g, reason: 'use explicit rule categories (`kix.rules.security`, etc.)' },
  { pattern: /\bscope\.byAvailability\b/g, reason: 'use `kix.byAvailability availability`' },
  { pattern: /\bkix\.helm\.mkPackage\b/g, reason: 'use `kix.importChart` or `kix.helmChart`' },
  { pattern: /\bscope\.prefixedName\b/g, reason: 'use `scope.name` (`scope.prefixedName` does not exist)' },
  { pattern: /\bnamespaces\s*\.\s*<[a-zA-Z0-9_-]+>\s*\.\s*instances\b/g, reason: 'use top-level `instances.<ns>.<name>`' },
];
const kixApplyPattern = /\bkix apply\b/g;
const repoSourceRefPattern =
  /(?<![a-zA-Z0-9_./-])((?:kix|cli|clusters|scripts|docs|\.claude|kix-cli|kix-kube|kix-helm)\/[a-zA-Z0-9_{}.,/-]+\.(?:nix|rs|py|sh|mdx|md|json|toml))(?:\b|(?=:))(?::(\d+)(?:[-–](\d+))?)?/g;
const placeholderPaths = new Set([
  'kix/packages/stable/pkg/default.nix',
  'kix/packages/stable/foo/default.nix',
  'kix/packages/stable/bar/default.nix',
]);
const docsUrlPattern = /(?:https:\/\/kix\.run)?\/docs\/([a-zA-Z0-9_./-]*)/g;
const generatedFiles = new Set(['llms.txt', 'llms-small.txt', 'llms-full.txt', 'sitemap-0.xml']);
const lineCountCache = new Map();

function getLineCount(absPath) {
  if (!lineCountCache.has(absPath)) {
    lineCountCache.set(absPath, readFileSync(absPath, 'utf8').split('\n').length);
  }
  return lineCountCache.get(absPath);
}

const errors = [];
let checkedCount = 0;

for (const file of filesToCheck) {
  const relFile = file.startsWith(docsRoot)
    ? join('docs', relative(docsRoot, file))
    : relative(repoRoot, file);
  const source = readFileSync(file, 'utf8');

  for (const match of source.matchAll(retiredPattern)) {
    errors.push(`${relFile}: references retired doc path "${match[0]}"`);
  }

  if (relFile !== 'ROADMAP.md') {
    for (const { pattern, reason } of bannedTokens) {
      for (const match of source.matchAll(pattern)) {
        errors.push(`${relFile}: banned identifier "${match[0]}" (${reason})`);
      }
    }
  }

  if (relFile !== 'ROADMAP.md') {
    for (const match of source.matchAll(kixApplyPattern)) {
      errors.push(`${relFile}: references "${match[0]}"; use "kix deploy" (no \`kix apply\` command exists)`);
    }
  }

  for (const match of source.matchAll(mdxPathPattern)) {
    checkedCount += 1;
    const subPath = match[0].replace(/^docs\//, '');
    const target = join(docsRoot, subPath);
    if (!existsSync(target)) {
      errors.push(`${relFile}: missing referenced doc file "${match[0]}"`);
    }
  }

  const checkSourceRefs =
    relFile !== 'ROADMAP.md' &&
    (!file.startsWith(contentRoot) || relFile.startsWith('docs/src/content/docs/reference/cli/'));
  if (checkSourceRefs) {
    for (const match of source.matchAll(repoSourceRefPattern)) {
      const rawPath = match[1].replace(/[.,;:]+$/, '');
      const startLine = match[2] ? Number(match[2]) : null;
      const endLine = match[3] ? Number(match[3]) : null;
      for (const expanded of expandBraces(rawPath)) {
        if (placeholderPaths.has(expanded)) continue;
        checkedCount += 1;
        const candidate =
          expanded.startsWith('kix-cli/') ||
          expanded.startsWith('kix-kube/') ||
          expanded.startsWith('kix-helm/') ||
          (relFile === 'cli/README.md' &&
            (expanded.startsWith('kix/src/') || expanded.startsWith('kix/tests/')))
            ? join(repoRoot, 'cli', expanded)
            : expanded.startsWith('docs/')
              ? join(docsRoot, expanded.slice('docs/'.length))
              : join(repoRoot, expanded);
        if (!existsSync(candidate)) {
          errors.push(`${relFile}: referenced file does not exist: "${expanded}"`);
          continue;
        }
        if (startLine !== null) {
          const totalLines = getLineCount(candidate);
          if (startLine < 1 || startLine > totalLines) {
            errors.push(
              `${relFile}: line ${startLine} out of range for "${expanded}" (${totalLines} lines)`,
            );
          }
          if (endLine !== null && (endLine < startLine || endLine > totalLines)) {
            errors.push(
              `${relFile}: line range ${startLine}-${endLine} out of range for "${expanded}" (${totalLines} lines)`,
            );
          }
        }
      }
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
