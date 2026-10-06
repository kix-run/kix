import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLlmsTxt from 'starlight-llms-txt';
// Vendored locally so we can modify it for coexistence with
// starlight-versions. See src/lib/sidebar-topics/README-VENDOR.md.
import starlightSidebarTopics from './src/lib/sidebar-topics/index.ts';
import starlightLinksValidator from 'starlight-links-validator';
import starlightGitHubAlerts from 'starlight-github-alerts';
import starlightPageActions from 'starlight-page-actions';
import starlightVersions from 'starlight-versions';
import rehypeTableWrap from './src/lib/rehype-table-wrap.mjs';

// Plugin ordering matters for the topics×versions coexistence:
//   - At `config:setup` time, we want topics FIRST so it sets the
//     topic-grouped sidebar, then versions wraps that into per-version
//     groups.
//   - At route middleware time, we want versions FIRST so it unwraps
//     the per-version shell, leaving topics to find topic groups in a
//     flat sidebar.
//
// We get both because:
//   1. plugins[] order = config:setup order (topics, versions).
//   2. Vendored topics middleware uses `order: 'post'`; versions uses
//      the default bucket. Starlight runs pre → default → post. See
//      src/lib/sidebar-topics/index.ts for the vendor mod notes.

// https://astro.build/config
export default defineConfig({
  // Deployed at kix.run/docs/ as a subdirectory of the homepage
  // GH Pages artifact.
  site: 'https://kix.run',
  base: '/docs',
  markdown: {
    rehypePlugins: [rehypeTableWrap],
  },
  integrations: [
    starlight({
      title: 'Kix',
      description: 'Nix-evaluated Kubernetes packages and clusters',
      // Kix theme: tokens, content and chrome styles. The design source is
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
        // Two-row header: logo, search, version, GitHub, theme and the
        // install link, then the Diátaxis topic tabs.
        Header: './src/components/Header.astro',
        // Used by Starlight's mobile menu footer. Renders VersionSelect
        // because overriding ThemeSelect displaces starlight-versions'
        // own override.
        ThemeSelect: './src/components/ThemeSelect.astro',
        // Logo mark, "kix" and "/docs".
        SiteTitle: './src/components/SiteTitle.astro',
        // Eyebrow, title and lead. Displaces both starlight-page-actions
        // (its copy button moves to PageSidebar) and starlight-versions
        // (its VersionNotice is rendered here).
        PageTitle: './src/components/PageTitle.astro',
        // "On this page" plus the Copy as Markdown action.
        PageSidebar: './src/components/PageSidebar.astro',
        // Grid of the article column and the right rail.
        TwoColumnContent: './src/components/TwoColumnContent.astro',
        // Topic heading, numbered tutorial lessons, grouped how-to and
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
                { label: 'Cluster module', items: [{ autogenerate: { directory: 'reference/cluster-module' } }] },
                { label: 'Package schema', items: [{ autogenerate: { directory: 'reference/package-schema' } }] },
                { label: 'meta', items: [{ autogenerate: { directory: 'reference/meta' } }] },
                { label: 'Instance schema', items: [{ autogenerate: { directory: 'reference/instance-schema' } }] },
                { label: 'scope helpers', items: [{ autogenerate: { directory: 'reference/scope-helpers' } }] },
                { label: 'kix helpers', items: [{ autogenerate: { directory: 'reference/kix-helpers' } }] },
                { label: 'out', items: [{ autogenerate: { directory: 'reference/out' } }] },
                { label: 'Flavors', items: [{ autogenerate: { directory: 'reference/flavors' } }] },
                { label: 'Scorecard', items: [{ autogenerate: { directory: 'reference/scorecard' } }] },
                { label: 'CLI', items: [{ autogenerate: { directory: 'reference/cli' } }] },
                { label: 'Annotations and CRDs', items: [{ autogenerate: { directory: 'reference/annotations-and-crds' } }] },
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
        // Per-version snapshots under /docs/v0.1/, /docs/v0.2/, etc.
        // MUST come AFTER starlight-sidebar-topics so it wraps the
        // topic-grouped sidebar into per-version groups. See the
        // ordering comment at the top of this file.
        starlightVersions({
          versions: [{ slug: 'v0.1' }],
        }),
        starlightLlmsTxt(),
        // Fails the build on broken internal links — catches rot in the
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
