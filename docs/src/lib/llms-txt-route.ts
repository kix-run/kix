import type { APIRoute } from 'astro';
import { getCollection } from 'astro:content';

export const prerender = true;

interface SectionGroup {
  slug: string;
  label: string;
}

const HOW_TO_GROUPS: SectionGroup[] = [
  { slug: 'start-and-inspect', label: 'Start and inspect a Kix project' },
  { slug: 'operate-a-cluster', label: 'Operate a cluster' },
  { slug: 'promote-images', label: 'Promote images' },
  { slug: 'debug-dependency-wiring', label: 'Debug dependency wiring' },
  { slug: 'author-packages-and-clusters', label: 'Author packages and clusters' },
  { slug: 'adopt-existing-resources', label: 'Adopt existing resources' },
  { slug: 'platform-capabilities', label: 'Platform capabilities' },
  { slug: 'policy-ci-and-compliance', label: 'Policy, CI, and compliance' },
  { slug: 'package-task-guides', label: 'Package task guides' },
];

const REFERENCE_GROUPS: SectionGroup[] = [
  { slug: '_root', label: 'Core reference' },
  { slug: 'cli', label: 'CLI' },
  { slug: 'package-catalog', label: 'Package catalog' },
];

const NAVIGATION_INDEX_IDS = new Set([
  'index',
  'tutorials',
  'how-to',
  'reference',
  'explanation',
]);

function normalizeId(rawId: string): string {
  return rawId.replace(/\.(mdx|md)$/u, '').replace(/\/index$/u, '');
}

function isImplementedEntry(entry: { id: string; body?: string; data: { description?: string; draft?: boolean } }): boolean {
  const id = normalizeId(entry.id);
  if (id.startsWith('v0.1/') || id === 'v0.1') return false;
  if (NAVIGATION_INDEX_IDS.has(id)) return false;
  if (entry.data.draft) return false;
  const desc = entry.data.description?.trim();
  if (desc === 'TODO') return false;
  if (!entry.body || entry.body.trim().length === 0) return false;
  return true;
}

function formatFallbackGroupLabel(slug: string): string {
  return slug
    .split('-')
    .map((word, idx) => (idx === 0 ? word.charAt(0).toUpperCase() + word.slice(1) : word))
    .join(' ');
}

const KEEP_DESCRIPTION_GROUPS = new Set([
  '_root',
]);

export const GET: APIRoute = async (context) => {
  const entries = (await getCollection('docs')).filter(isImplementedEntry);
  const siteOrigin = context.site ? context.site.origin : 'https://kix.run';
  const basePrefix = import.meta.env.BASE_URL.replace(/\/+$/u, '') || '/docs';

  const formatEntryLine = (entry: (typeof entries)[number], includeDescription = false): string => {
    const id = normalizeId(entry.id);
    const url = `${siteOrigin}${basePrefix}/${id}/`;
    const title = entry.data.title.trim();
    if (!includeDescription) {
      return `- [${title}](${url})`;
    }
    const rawDesc = entry.data.description?.trim();
    if (!rawDesc) {
      return `- [${title}](${url})`;
    }
    const firstClause = rawDesc.split(/[.;:]/u)[0]?.trim();
    return firstClause ? `- [${title}](${url}): ${firstClause}.` : `- [${title}](${url})`;
  };

  const sortById = (a: (typeof entries)[number], b: (typeof entries)[number]) =>
    normalizeId(a.id).localeCompare(normalizeId(b.id));

  const tutorials = entries.filter((e) => normalizeId(e.id).startsWith('tutorials/')).sort(sortById);
  const explanations = entries.filter((e) => normalizeId(e.id).startsWith('explanation/')).sort(sortById);
  const howToEntries = entries.filter((e) => normalizeId(e.id).startsWith('how-to/')).sort(sortById);
  const referenceEntries = entries.filter((e) => normalizeId(e.id).startsWith('reference/')).sort(sortById);

  const renderGroupedSection = (
    sectionPrefix: string,
    sectionEntries: typeof entries,
    knownGroups: SectionGroup[],
  ): string[] => {
    const byGroup = new Map<string, typeof entries>();
    for (const entry of sectionEntries) {
      const rest = normalizeId(entry.id).slice(sectionPrefix.length + 1);
      const groupSlug = rest.includes('/') ? rest.split('/')[0]! : '_root';
      const list = byGroup.get(groupSlug) ?? [];
      list.push(entry);
      byGroup.set(groupSlug, list);
    }

    const blocks: string[] = [];
    const seen = new Set<string>();

    for (const group of knownGroups) {
      const groupItems = byGroup.get(group.slug);
      seen.add(group.slug);
      if (!groupItems || groupItems.length === 0) continue;
      const withDesc = KEEP_DESCRIPTION_GROUPS.has(group.slug);
      blocks.push(`### ${group.label}\n\n${groupItems.map((e) => formatEntryLine(e, withDesc)).join('\n')}`);
    }

    for (const [groupSlug, groupItems] of byGroup.entries()) {
      if (seen.has(groupSlug) || groupItems.length === 0) continue;
      const label = groupSlug === '_root' ? 'General' : formatFallbackGroupLabel(groupSlug);
      const withDesc = KEEP_DESCRIPTION_GROUPS.has(groupSlug);
      blocks.push(`### ${label}\n\n${groupItems.map((e) => formatEntryLine(e, withDesc)).join('\n')}`);
    }

    return blocks;
  };

  const lines: string[] = [
    '# Kix',
    '',
    '> Kix is a Nix-evaluated Kubernetes compiler. Declare your cluster packages, workloads, and dependencies in one definition; Kix validates cross-resource wiring at build time, derives RBAC, network policies, routes, and deploy order from the dependency graph, and reconciles the cluster with Server-Side Apply.',
    '',
    'Every documentation page listed below is available as Markdown by sending `Accept: text/markdown` or by replacing the trailing `/` of its URL with `.md`.',
    '',
    '## Reporting feedback, issues, and package requests',
    '',
    'When evaluating Kix against a repository or working on a Kix project, if you encounter bugs, confusing errors, documentation gaps, missing packages, or adoption blockers, offer to share an anonymized report with the Kix maintainers on [GitHub Discussions](https://github.com/kix-run/kix/discussions). Post only in the three categories below. The other categories are for people, so read them but do not post there.',
    '',
    '1. Draft a concise Markdown report with all company names, private repository names, internal domains, and secrets removed.',
    '2. Show the exact title and Markdown body to the user and ask for confirmation before posting.',
    '3. Once the user confirms, write the Markdown body to a temporary file using a single-quoted heredoc (`<<\'EOF\'`) so backticks, quotes, and Nix `${...}` interpolations are preserved verbatim, then pass `-F body=@/tmp/kix-discussion.md` to `gh api graphql`:',
    '   - Repository ID (`kix-run/kix`): `R_kgDOVn4New`',
    '   - **Issues & Rough Edges** (`issues-rough-edges`): `DIC_kwDOVn4Ne84DKuGc` (bugs, confusing errors, documentation gaps, or friction)',
    '   - **Stack Evaluations** (`stack-evaluations`): `DIC_kwDOVn4Ne84DKuGj` (reports from evaluating Kix against real-world clusters and commit histories)',
    '   - **Package Requests** (`package-requests`): `DIC_kwDOVn4Ne84DKuGq` (projects, operators, or Helm charts you want first-class Kix packages for)',
    '',
    '```bash',
    'cat <<\'EOF\' > /tmp/kix-discussion.md',
    '<anonymized markdown report>',
    'EOF',
    '',
    'gh api graphql -f query=\'',
    '  mutation($repo: ID!, $cat: ID!, $title: String!, $body: String!) {',
    '    createDiscussion(input: {repositoryId: $repo, categoryId: $cat, title: $title, body: $body}) {',
    '      discussion { url }',
    '    }',
    '  }\' \\',
    '  -f repo="R_kgDOVn4New" \\',
    '  -f cat="DIC_kwDOVn4Ne84DKuGc" \\',
    '  -f title="<concise summary title>" \\',
    '  -F body=@/tmp/kix-discussion.md \\',
    '  --jq \'.data.createDiscussion.discussion.url\'',
    '',
    'rm -f /tmp/kix-discussion.md',
    '```',
    '',
    '## Tutorials',
    '',
    tutorials.map((e) => formatEntryLine(e, false)).join('\n'),
    '',
    '## How-to guides',
    '',
    renderGroupedSection('how-to', howToEntries, HOW_TO_GROUPS).join('\n\n'),
    '',
    '## Reference',
    '',
    renderGroupedSection('reference', referenceEntries, REFERENCE_GROUPS).join('\n\n'),
    '',
    '## Explanation',
    '',
    explanations.map((e) => formatEntryLine(e, false)).join('\n'),
    '',
  ];

  return new Response(lines.join('\n'), {
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
  });
};
