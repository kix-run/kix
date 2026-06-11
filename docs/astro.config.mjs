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
  // Deployed at kixops.dev/docs/ as a subdirectory of the homepage
  // GH Pages artifact.
  site: 'https://kixops.dev',
  base: '/docs',
  integrations: [
    starlight({
      title: 'Kix',
      description: 'Nix-evaluated Kubernetes packages and clusters',
      // Lagoon palette shared with the homepage (web/src/index.css).
      customCss: ['./src/styles/lagoon.css'],
      components: {
        // Replace the default theme dropdown (laptop icon labelled
        // "Auto") with three explicit Light/Dark/Auto icon buttons.
        ThemeSelect: './src/components/ThemeSelect.astro',
      },
      plugins: [
        // Splits the sidebar into Diátaxis "topics" so only the
        // current topic's children show in the left nav. The topic
        // switcher renders at the top of the sidebar.
        // See https://starlight-sidebar-topics.netlify.app/
        //
        // The second arg maps URL patterns to topic ids so that pages
        // not enumerated in `items` (e.g. each quadrant's index.mdx,
        // versioned snapshots under `v0.1/`) still resolve to a topic.
        starlightSidebarTopics(
          [
            {
              id: 'home',
              label: 'Home',
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
        // "Copy as Markdown" + "Open in ChatGPT/Claude" + share menu in
        // the page header.
        starlightPageActions(),
      ],
    }),
  ],
});
