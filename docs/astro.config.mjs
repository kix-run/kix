import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import starlightLlmsTxt from 'starlight-llms-txt';
import starlightVersions from 'starlight-versions';

// https://astro.build/config
export default defineConfig({
  site: 'https://docs.kixops.dev',
  integrations: [
    starlight({
      title: 'Kix',
      description: 'Nix-evaluated Kubernetes packages and clusters',
      plugins: [
        starlightLlmsTxt(),
        starlightVersions({
          // The current dev tree is "Latest" (implicit). Listed versions
          // become frozen snapshots: on first build, the plugin copies
          // src/content/docs into src/content/docs/<slug>/. Add more
          // entries as we cut new versions.
          // See https://starlight-versions.vercel.app/
          versions: [{ slug: 'v0.1', label: 'v0.1' }],
        }),
      ],
      // Starlight ≥0.39 removed the `{ label, autogenerate }` shorthand.
      // Each labelled group wraps autogenerate in an `items` array.
      sidebar: [
        { label: 'Tutorials', items: [{ autogenerate: { directory: 'tutorials' } }] },
        {
          label: 'How-to guides',
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
          label: 'Reference',
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
        { label: 'Explanation', items: [{ autogenerate: { directory: 'explanation' } }] },
      ],
    }),
  ],
});
