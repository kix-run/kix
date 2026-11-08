// Classifies Markdown links at build time by target document type:
// - Internal links (`/docs/tutorials/...`, `/docs/how-to/...`,
//   `/docs/explanation/...`, `/docs/reference/...`) receive:
//   - `data-link-kind`: "tutorial" | "how-to" | "explanation" | "reference"
//   - `data-link-badge`: short label ("Tutorial", "How-to", "Explanation", "Reference")
//   - `data-link-tooltip`: "<Quadrant> · <Target Page Title>" (plus "· #<Section>" when linking to an anchor)
// - External links (`http://...`, `https://...`) receive:
//   - `data-link-kind="external"`
import { readdirSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import GithubSlugger from 'github-slugger';
import { visit } from 'unist-util-visit';

const docsRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const contentRoot = join(docsRoot, 'src', 'content', 'docs');

const QUADRANTS = {
  tutorials: { kind: 'tutorial', badge: 'Tutorial' },
  'how-to': { kind: 'how-to', badge: 'How-to' },
  explanation: { kind: 'explanation', badge: 'Explanation' },
  reference: { kind: 'reference', badge: 'Reference' },
};

function walkMdx(dir) {
  return readdirSync(dir).flatMap((name) => {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) return walkMdx(full);
    return full.endsWith('.mdx') || full.endsWith('.md') ? [full] : [];
  });
}

function cleanTitle(raw) {
  return raw
    .replace(/^['"]|['"]$/g, '')
    .replace(/`/g, '')
    .trim();
}

function buildPageMetadata() {
  const pages = new Map();
  for (const file of walkMdx(contentRoot)) {
    const rel = relative(contentRoot, file)
      .replace(/\\/g, '/')
      .replace(/\.(mdx|md)$/, '')
      .replace(/\/index$/, '');
    const source = readFileSync(file, 'utf8');
    const titleMatch = source.match(/^title:\s*(.+)$/m);
    const title = titleMatch ? cleanTitle(titleMatch[1]) : null;

    const headings = new Map();
    const slugger = new GithubSlugger();
    let inFence = false;
    for (const line of source.split('\n')) {
      if (/^```/.test(line.trim())) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;
      const hMatch = line.match(/^#{2,4}\s+(.+)$/);
      if (hMatch) {
        const headingText = cleanTitle(hMatch[1]);
        const headingSlug = slugger.slug(headingText);
        headings.set(headingSlug, headingText);
      }
    }

    pages.set(rel, { title, headings });
  }
  return pages;
}

const pageMetadata = buildPageMetadata();

export default function rehypeLinkTypes({ base = '/docs' } = {}) {
  const normalizedBase = base.replace(/\/+$/, '');

  return (tree) => {
    visit(tree, 'element', (node, _index, parent) => {
      if (node.tagName !== 'a') return;
      const href = node.properties?.href;
      if (typeof href !== 'string' || !href) return;

      // Skip heading anchor links and explicitly excluded elements.
      if (
        parent?.type === 'element' &&
        /^h[1-6]$/.test(parent.tagName)
      ) {
        return;
      }
      const classList = Array.isArray(node.properties?.className)
        ? node.properties.className
        : [];
      if (classList.includes('sl-anchor-link')) return;

      // External links
      if (href.startsWith('http://') || href.startsWith('https://')) {
        node.properties['data-link-kind'] = 'external';
        return;
      }

      // Internal doc links (matching either `/docs/...` or configured `base`)
      let rest = null;
      if (href.startsWith(`${normalizedBase}/`)) {
        rest = href.slice(normalizedBase.length + 1);
      } else if (href.startsWith('/docs/')) {
        rest = href.slice('/docs/'.length);
      }
      if (!rest) return;

      const [pathPart, hashPart] = rest.split('#');
      const slug = pathPart.replace(/^\/+|\/+$/g, '');
      if (!slug) return;

      const topSegment = slug.split('/')[0];
      const quadrant = QUADRANTS[topSegment];
      if (!quadrant) return;

      const meta = pageMetadata.get(slug);
      const tooltipParts = [quadrant.badge];
      if (meta?.title) {
        tooltipParts.push(meta.title);
      }
      if (hashPart) {
        const headingTitle = meta?.headings?.get(hashPart) ?? hashPart;
        tooltipParts.push(`#${headingTitle}`);
      }

      node.properties['data-link-kind'] = quadrant.kind;
      node.properties['data-link-badge'] = quadrant.badge;
      node.properties['data-link-tooltip'] = tooltipParts.join(' · ');
    });
  };
}
