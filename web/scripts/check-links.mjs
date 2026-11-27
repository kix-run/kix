import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, extname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const defaultWebRoot = resolve(scriptDir, '..');
const defaultRepoRoot = resolve(defaultWebRoot, '..');

const GENERATED_DOCS_FILES = new Set(['llms.txt', 'llms-full.txt', 'llms-small.txt']);
const ANCHOR_PATTERN = /<a\b[^>]*?\bhref=(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi;
const ID_PATTERN = /\bid=(?:"([^"]+)"|'([^']+)')/gi;

// Return every file under `directory` whose name ends with one of `extensions`.
function walkFiles(directory, extensions) {
  if (!existsSync(directory)) return [];
  return readdirSync(directory).flatMap((name) => {
    const fullPath = join(directory, name);
    if (statSync(fullPath).isDirectory()) return walkFiles(fullPath, extensions);
    return extensions.some((ext) => fullPath.endsWith(ext)) ? [fullPath] : [];
  });
}

// Collect every `id` attribute value present in `htmlPath`.
function getHtmlIds(htmlPath, cache) {
  let ids = cache.get(htmlPath);
  if (!ids) {
    const html = readFileSync(htmlPath, 'utf8');
    ids = new Set();
    for (const match of html.matchAll(ID_PATTERN)) {
      ids.add(match[1] ?? match[2]);
    }
    cache.set(htmlPath, ids);
  }
  return ids;
}

// Resolve a URL pathname to an existing file inside `rootDir`, or return null.
function resolveStaticTarget(rootDir, pathname) {
  const clean = pathname.replace(/^\/+/, '').replace(/\/+$/, '');
  if (clean === '') {
    const rootIndex = join(rootDir, 'index.html');
    return existsSync(rootIndex) ? rootIndex : null;
  }
  if (extname(clean)) {
    const exact = join(rootDir, clean);
    if (existsSync(exact) && statSync(exact).isFile()) return exact;
  }
  const indexHtml = join(rootDir, clean, 'index.html');
  if (existsSync(indexHtml)) return indexHtml;
  const flatHtml = join(rootDir, `${clean}.html`);
  if (existsSync(flatHtml)) return flatHtml;
  return null;
}

// Verify a `/docs/...` pathname against `docs/` and `kix/packages/` in the repository.
function checkRepoDocsTarget(repoRoot, pathname) {
  const afterDocs = pathname.replace(/^\/docs\/?/, '');
  const isMain = afterDocs === 'main' || afterDocs.startsWith('main/');
  const slug = (isMain ? afterDocs.slice('main'.length) : afterDocs).replace(/^\/+|\/+$/g, '');

  if (slug === 'reference/package-catalog' || slug.startsWith('reference/package-catalog/')) {
    if (!isMain) {
      return `package catalog link "${pathname}" must use /docs/main/reference/package-catalog/... because /docs/ serves the latest release tag`;
    }
    const pkgSlug = slug.slice('reference/package-catalog'.length).replace(/^\/+|\/+$/g, '');
    if (pkgSlug === '') {
      const generator = join(repoRoot, 'docs', 'scripts', 'package-catalog.py');
      return existsSync(generator) ? null : `missing catalog generator at docs/scripts/package-catalog.py`;
    }
    if (pkgSlug.startsWith('experimental/')) {
      const name = pkgSlug.slice('experimental/'.length);
      if (!name || name.includes('/')) return `invalid experimental package slug "${pkgSlug}"`;
      const nixFile = join(repoRoot, 'kix', 'packages', 'experimental', name, 'default.nix');
      return existsSync(nixFile) ? null : `missing experimental package at kix/packages/experimental/${name}/default.nix`;
    }
    if (pkgSlug.includes('/')) {
      return `invalid package slug "${pkgSlug}"`;
    }
    const nixFile = join(repoRoot, 'kix', 'packages', 'stable', pkgSlug, 'default.nix');
    if (!existsSync(nixFile)) {
      const expFile = join(repoRoot, 'kix', 'packages', 'experimental', pkgSlug, 'default.nix');
      if (existsSync(expFile)) {
        return `package "${pkgSlug}" is experimental; link to /docs/main/reference/package-catalog/experimental/${pkgSlug}/ instead`;
      }
      return `missing stable package at kix/packages/stable/${pkgSlug}/default.nix`;
    }
    return null;
  }

  if (slug === '') {
    const indexMdx = join(repoRoot, 'docs', 'src', 'content', 'docs', 'index.mdx');
    return existsSync(indexMdx) ? null : 'missing docs/src/content/docs/index.mdx';
  }

  if (GENERATED_DOCS_FILES.has(slug)) {
    return null;
  }

  const contentRoot = join(repoRoot, 'docs', 'src', 'content', 'docs');
  const directMdx = join(contentRoot, `${slug}.mdx`);
  const indexMdx = join(contentRoot, slug, 'index.mdx');
  if (!existsSync(directMdx) && !existsSync(indexMdx)) {
    return `no matching docs page at docs/src/content/docs/${slug}.mdx (or ${slug}/index.mdx)`;
  }
  return null;
}

// Check that every curated member in `web/src/lib/packages.ts` exists as a non-deprecated package.
function checkCuratedPackages(repoRoot, packagesTsPath) {
  if (!packagesTsPath || !existsSync(packagesTsPath)) return [];
  const source = readFileSync(packagesTsPath, 'utf8');
  const errors = [];
  const tuplePattern = /\[\s*'([a-z0-9-]+)'\s*,\s*'((?:[^'\\]|\\.)*)'\s*\]/g;

  for (const match of source.matchAll(tuplePattern)) {
    const name = match[1];
    const stablePath = join(repoRoot, 'kix', 'packages', 'stable', name, 'default.nix');
    const expPath = join(repoRoot, 'kix', 'packages', 'experimental', name, 'default.nix');
    const nixPath = existsSync(stablePath) ? stablePath : existsSync(expPath) ? expPath : null;
    if (!nixPath) {
      errors.push(`web/src/lib/packages.ts: curated package "${name}" does not exist in kix/packages/{stable,experimental}`);
      continue;
    }
    const nixSource = readFileSync(nixPath, 'utf8');
    const metaBlock = nixSource.match(/\bmeta\s*=\s*\{([\s\S]*?)\n  \};/)?.[1] ?? '';
    if (/\bdeprecated\s*=/.test(metaBlock)) {
      errors.push(`web/src/lib/packages.ts: curated package "${name}" is marked deprecated in ${relative(repoRoot, nixPath)}`);
    }
  }
  return errors;
}

// Verify all internal and documentation links in built HTML files under `distDir`.
export function checkLinks({
  distDir = join(defaultWebRoot, 'dist'),
  repoRoot = defaultRepoRoot,
  siteRoot = null,
  packagesTsPath = join(defaultWebRoot, 'src', 'lib', 'packages.ts'),
} = {}) {
  const htmlFiles = walkFiles(distDir, ['.html']);
  if (htmlFiles.length === 0) {
    return { checked: 0, errors: [`No built HTML files found in ${distDir}`] };
  }

  const idCache = new Map();
  const errors = [...checkCuratedPackages(repoRoot, packagesTsPath)];
  let checked = 0;

  for (const htmlFile of htmlFiles) {
    const relHtml = relative(distDir, htmlFile);
    const html = readFileSync(htmlFile, 'utf8');

    for (const match of html.matchAll(ANCHOR_PATTERN)) {
      const rawHref = (match[1] ?? match[2] ?? match[3] ?? '').trim();
      if (!rawHref || rawHref.startsWith('mailto:') || rawHref.startsWith('tel:')) continue;

      let localHref = rawHref;
      if (/^https?:\/\//i.test(rawHref)) {
        const parsed = new URL(rawHref);
        if (parsed.origin !== 'https://kix.run') continue;
        localHref = `${parsed.pathname}${parsed.hash}`;
      }

      checked += 1;
      const hashIndex = localHref.indexOf('#');
      const pathname = hashIndex === -1 ? localHref : localHref.slice(0, hashIndex);
      const fragment = hashIndex === -1 ? '' : decodeURIComponent(localHref.slice(hashIndex + 1));

      if (pathname === '') {
        if (fragment && !getHtmlIds(htmlFile, idCache).has(fragment)) {
          errors.push(`${relHtml}: anchor "${rawHref}" matches no id="${fragment}" on the page`);
        }
        continue;
      }

      if (!pathname.startsWith('/')) {
        errors.push(`${relHtml}: use root-relative link instead of "${rawHref}"`);
        continue;
      }

      if (siteRoot) {
        const target = resolveStaticTarget(siteRoot, pathname);
        if (!target) {
          errors.push(`${relHtml}: broken link "${rawHref}" (not found in staged site ${siteRoot})`);
          continue;
        }
        if (fragment && target.endsWith('.html') && !getHtmlIds(target, idCache).has(fragment)) {
          errors.push(`${relHtml}: broken anchor "${rawHref}" (missing id="${fragment}" in ${relative(siteRoot, target)})`);
        }
        continue;
      }

      if (pathname === '/docs' || pathname.startsWith('/docs/')) {
        const docsError = checkRepoDocsTarget(repoRoot, pathname);
        if (docsError) {
          errors.push(`${relHtml}: broken docs link "${rawHref}" (${docsError})`);
        }
        continue;
      }

      const target = resolveStaticTarget(distDir, pathname);
      if (!target) {
        errors.push(`${relHtml}: broken internal link "${rawHref}"`);
        continue;
      }
      if (fragment && target.endsWith('.html') && !getHtmlIds(target, idCache).has(fragment)) {
        errors.push(`${relHtml}: broken anchor "${rawHref}" (missing id="${fragment}" in ${relative(distDir, target)})`);
      }
    }
  }

  return { checked, errors };
}

if (resolve(fileURLToPath(import.meta.url)) === resolve(process.argv[1] ?? '')) {
  const args = process.argv.slice(2);
  let distDir = join(defaultWebRoot, 'dist');
  let siteRoot = null;

  for (let i = 0; i < args.length; i += 1) {
    if (args[i] === '--dist' && args[i + 1]) {
      distDir = resolve(args[++i]);
    } else if (args[i] === '--site-root' && args[i + 1]) {
      siteRoot = resolve(args[++i]);
    } else {
      console.error(`Unknown argument: ${args[i]}`);
      process.exit(2);
    }
  }

  const { checked, errors } = checkLinks({ distDir, siteRoot });
  if (errors.length > 0) {
    console.error(`Website link check failed (${errors.length} problem(s)):`);
    for (const err of errors) console.error(`  ${err}`);
    process.exit(1);
  }
  console.log(`check-links: ${checked} internal and docs link(s) verified`);
}
