import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import kixLlmsTxt from './src/lib/llms-txt.ts';
// Vendored locally. See src/lib/sidebar-topics/README-VENDOR.md.
import starlightSidebarTopics from './src/lib/sidebar-topics/index.ts';
import starlightLinksValidator from 'starlight-links-validator';
import starlightGitHubAlerts from 'starlight-github-alerts';
import starlightPageActions from 'starlight-page-actions';
import rehypeTableWrap from './src/lib/rehype-table-wrap.mjs';
import rehypeLinkTypes from './src/lib/rehype-link-types.mjs';
import remarkDocsBase from './src/lib/remark-docs-base.mjs';

const base = process.env.KIX_DOCS_BASE ?? '/docs';

// Return a docs path with the base in front, for redirect targets.
const under = (path) => `${base.replace(/\/$/, '')}${path}`;

// https://astro.build/config
export default defineConfig({
  // Deployed under kix.run/docs/. CI builds the docs once per Kix version
  // and serves each build under its own path (docs/flake.nix,
  // .github/workflows/pages.yml): the latest release at /docs, main at
  // /docs/main, older minor releases at /docs/v<major>.<minor>.
  site: 'https://kix.run',
  base,
  // Pages that 0.10 renamed or folded into another page. Astro prefixes
  // the old path with `base` and leaves the new one as written.
  redirects: {
    '/reference/cli/deploy-apply': under('/reference/cli/deploy'),
    '/reference/cli/pf': under('/reference/cli/port-forward'),
    '/reference/cli/inspect': under('/reference/cli/list'),
    '/reference/cli/images': under('/reference/cli/list'),
    '/reference/cli/health': under('/reference/cli/status'),
    '/reference/cli/drift': under('/reference/cli/status'),
    '/how-to/operate-a-cluster/preview-changes-with-kix-diff': under('/how-to/operate-a-cluster/preview-changes-with-kix-plan'),
    '/how-to/operate-a-cluster/use-kix-pf': under('/how-to/operate-a-cluster/use-kix-port-forward'),
    '/how-to/policy-ci-and-compliance/generate-pr-review-markdown-from-kix-diff': under('/how-to/policy-ci-and-compliance/generate-pr-review-markdown-from-kix-plan'),
  },
  markdown: {
    remarkPlugins: [[remarkDocsBase, { base }]],
    rehypePlugins: [rehypeTableWrap, [rehypeLinkTypes, { base }]],
  },
  integrations: [
    starlight({
      title: 'Kix',
      description: 'Nix-evaluated Kubernetes packages and clusters',
      // Kix theme: tokens, content, and chrome styles. The design source is
      // the kix-oss-handoff folder (frames mJBvI, o1hudj, z240z).
      customCss: [
        '@fontsource-variable/inter-tight',
        '@fontsource-variable/jetbrains-mono',
        './src/styles/kix.css',
      ],
      lastUpdated: true,
      components: {
        // Adds <link rel="alternate" type="text/markdown"> pointing at
        // the page's `.md` twin, which is how Codex CLI discovers it.
        Head: './src/components/Head.astro',
        // Two-row header: logo, search, version, GitHub, theme, and the
        // install link, then the Diátaxis topic tabs.
        Header: './src/components/Header.astro',
        // Used by Starlight's mobile menu footer: the version picker and
        // the theme toggle.
        ThemeSelect: './src/components/ThemeSelect.astro',
        // Logo mark, "kix", and "/docs".
        SiteTitle: './src/components/SiteTitle.astro',
        // Eyebrow, title, lead, and the notice on docs that are not the
        // latest release. Displaces starlight-page-actions (its copy
        // button moves to PageSidebar).
        PageTitle: './src/components/PageTitle.astro',
        // "On this page" plus the Copy as Markdown action.
        PageSidebar: './src/components/PageSidebar.astro',
        // Grid of the article column and the right rail.
        TwoColumnContent: './src/components/TwoColumnContent.astro',
        // Topic heading, numbered tutorial lessons, and grouped how-to and
        // reference sections. Takes precedence over the vendored
        // starlight-sidebar-topics Sidebar override.
        Sidebar: './src/components/Sidebar.astro',
        Pagination: './src/components/Pagination.astro',
        Footer: './src/components/Footer.astro',
      },
      plugins: [
        // Splits the sidebar into Diátaxis "topics" so only the
        // current topic's children show in the left nav. The topics
        // render as tabs in src/components/Header.astro on wide screens
        // and at the top of the sidebar in the mobile menu.
        // See https://starlight-sidebar-topics.netlify.app/
        //
        // The second arg maps URL patterns to topic ids so that pages
        // not enumerated in `items` (e.g. each quadrant's index.mdx,
        // versioned snapshots under `v0.1/`) still resolve to a topic.
        starlightSidebarTopics(
          [
            {
              id: 'home',
              label: 'Start',
              link: '/',
              icon: 'star',
              items: [
                { label: 'Welcome', link: '/' },
              ],
            },
            {
              id: 'tutorials',
              label: 'Tutorials',
              link: '/tutorials/',
              icon: 'open-book',
              items: [
                { autogenerate: { directory: 'tutorials' } },
              ],
            },
            {
              id: 'how-to',
              label: 'How-to guides',
              link: '/how-to/',
              icon: 'rocket',
              items: [
                { label: 'Start and inspect a Kix project', items: [{ autogenerate: { directory: 'how-to/start-and-inspect' } }] },
                { label: 'Operate a cluster', items: [{ autogenerate: { directory: 'how-to/operate-a-cluster' } }] },
                { label: 'Promote images', items: [{ autogenerate: { directory: 'how-to/promote-images' } }] },
                { label: 'Debug dependency wiring', items: [{ autogenerate: { directory: 'how-to/debug-dependency-wiring' } }] },
                { label: 'Author packages and clusters', items: [{ autogenerate: { directory: 'how-to/author-packages-and-clusters' } }] },
                { label: 'Adopt existing resources', items: [{ autogenerate: { directory: 'how-to/adopt-existing-resources' } }] },
                { label: 'Platform capabilities', items: [{ autogenerate: { directory: 'how-to/platform-capabilities' } }] },
                { label: 'Policy, CI, and compliance', items: [{ autogenerate: { directory: 'how-to/policy-ci-and-compliance' } }] },
                { label: 'Package task guides', items: [{ autogenerate: { directory: 'how-to/package-task-guides' } }] },
              ],
            },
            {
              id: 'reference',
              label: 'Reference',
              link: '/reference/',
              icon: 'information',
              items: [
                {
                  label: 'Clusters and instances',
                  items: [
                    'reference/kix-toml',
                    'reference/cluster-configuration',
                    'reference/instances-and-composition',
                    'reference/flavors-and-capabilities',
                  ],
                },
                {
                  label: 'Package authoring',
                  items: [
                    'reference/package-anatomy',
                    'reference/resources-and-out',
                    'reference/composition-helpers',
                    'reference/secrets-crds-and-rbac',
                    'reference/helm-and-imports',
                  ],
                },
                {
                  label: 'Policy and runtime contracts',
                  items: [
                    'reference/dependency-contracts',
                    'reference/scorecard-and-rules',
                    'reference/validation-checks',
                    'reference/annotations-crds-and-receipts',
                  ],
                },
                { label: 'CLI', items: [{ autogenerate: { directory: 'reference/cli' } }] },
                { label: 'Package catalog', items: [{ autogenerate: { directory: 'reference/package-catalog' } }] },
              ],
            },
            {
              id: 'explanation',
              label: 'Explanation',
              link: '/explanation/',
              icon: 'puzzle',
              items: [
                { autogenerate: { directory: 'explanation' } },
              ],
            },
          ],
          {
            topics: {
              tutorials: ['/tutorials', '/tutorials/**', '/*/tutorials', '/*/tutorials/**'],
              'how-to': ['/how-to', '/how-to/**', '/*/how-to', '/*/how-to/**'],
              reference: ['/reference', '/reference/**', '/*/reference', '/*/reference/**'],
              explanation: ['/explanation', '/explanation/**', '/*/explanation', '/*/explanation/**'],
            },
          },
        ),
        kixLlmsTxt(),
        // Fails the build on broken internal links, catching rot in the
        // dense Diátaxis cross-link graph.
        starlightLinksValidator(),
        // Renders GitHub-style `> [!NOTE]` / `> [!WARNING]` blocks as
        // Starlight asides (handy when copying from issues/READMEs).
        starlightGitHubAlerts(),
        // Generates the `.md` twins behind "Copy as Markdown". The button
        // itself is rendered by src/components/PageSidebar.astro because
        // our PageTitle override displaces the plugin's.
        starlightPageActions({ actions: { chatgpt: false, claude: false, markdown: true } }),
      ],
    }),
  ],
});
