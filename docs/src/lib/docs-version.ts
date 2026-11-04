// Which build of the docs this is. CI builds the docs once per Kix version
// and sets these through docs/flake.nix (see .github/workflows/pages.yml):
//
// - `release`: the latest release, served at /docs.
// - `main`: the main branch, served at /docs/main. Also what a local build
//   or the dev server shows.
// - `archived`: an older minor release, served at /docs/v<major>.<minor>.
export type DocsChannel = 'release' | 'main' | 'archived';

export const docsChannel: DocsChannel = (process.env.KIX_DOCS_CHANNEL as DocsChannel) ?? 'main';

// The Kix version these docs describe, from cli/Cargo.toml.
export const docsVersion: string = process.env.KIX_DOCS_VERSION ?? '';

// `0.5.0` reads as `v0.5`: each minor release has one set of docs.
const minor = docsVersion.split('.').slice(0, 2).join('.');

export const docsVersionLabel: string =
  docsChannel === 'main' ? 'main' : docsChannel === 'release' ? `v${minor} (latest)` : `v${minor}`;

// Where the latest release's docs live, whichever build this is.
export const latestDocsPath = '/docs/';

// Written by CI next to the builds: every version's label and path.
export const versionsListPath = '/docs/versions.json';
