# Docs handover

Notes for whoever works on the docs site next. One section per phase of the
website and docs redesign; the briefs live in the `kix-oss-handoff` repo.

## Phase 2 · Docs theme (2026-10-06)

The Starlight docs now use the Kix theme: paper, ink and orange, Inter Tight
and JetBrains Mono, night panels for every terminal and code block, mono caps
labels, and the orange "you are here" edge. Light and dark are both done. The
design source is `kix-oss-handoff/design/kix-oss.pen.json`, frames `mJBvI`
(light page), `o1hudj` (dark page) and `z240z` (theme sheet).

### Where things are

| What | Where |
|---|---|
| Tokens (`--kix-*`), the mapping onto Starlight's `--sl-*`, and all Markdown, aside, table, card, steps, file tree and layout styles | `src/styles/kix.css` (replaces `lagoon.css`) |
| Fonts | `@fontsource-variable/inter-tight`, `@fontsource-variable/jetbrains-mono` in `customCss`; Geist removed |
| Expressive Code settings | `ec.config.mjs` (Starlight's `<Code>` needs them in their own file); theme `src/lib/kix-night.theme.json`; line numbers via `@expressive-code/plugin-line-numbers` |
| Tables wrapped in a scrolling `div.kix-table` | `src/lib/rehype-table-wrap.mjs`, registered in `astro.config.mjs` → `markdown.rehypePlugins` |
| Header (logo, search trigger, version, GitHub, theme, Install the CLI, topic tabs) | `src/components/Header.astro`, `SiteTitle.astro`, `ThemeToggle.astro` |
| Mobile menu footer (version + theme) | `src/components/ThemeSelect.astro` |
| Left sidebar | `src/components/Sidebar.astro` |
| Eyebrow, H1, lead | `src/components/PageTitle.astro`, `src/lib/page-section.ts` |
| Column layout: article column and a sticky 260px right rail | `src/components/TwoColumnContent.astro` |
| Right rail (On this page, Copy as Markdown) | `src/components/PageSidebar.astro` |
| Pagination, footer | `src/components/Pagination.astro`, `Footer.astro` |
| Terminal blocks | `src/components/Command.astro` (restyled; props, sidecar contract and build-time checks unchanged) |
| Snippets | `src/components/Snippet.astro` (file path as the tab title, `L12–L18` range, real line numbers) |
| New components | `src/components/Recap.astro`, `Loop.astro`, shared parser `src/lib/list-rows.ts` |
| Search placeholder text | `src/content/i18n/en.json` (`search.label`), collection added in `src/content.config.ts` |

### Decisions

- **D7** (footer links): no "Edit this page" and no "Report a problem". No
  public edit or issue target yet.
- **D8** (eyebrow): section and number only, derived at render time:
  `TUTORIAL 05`, `HOW-TO GUIDE / OPERATE A CLUSTER`, `REFERENCE / CLI`. Topic
  index pages get none. No reading time or prerequisites.
- **D9** (new components): built. `Recap` has a plain-text row as well as
  the command row, at Adam's request. Converted tutorials 04, 05 and 06 to
  `Recap` and tutorial 05's loop list to `Loop` (wording from the design).
  Authors write ordinary Markdown lists inside both; `docs/CLAUDE.md`
  documents the usage.
- **D10** (topic tabs): in the header. The home topic is relabelled "Start".
- **D11** (page actions): only Copy as Markdown.
- "Install the CLI" links to tutorial 02 (local setup) until phase 1's D1
  settles an install command.

### Overrides and how they compose with the plugins

| Component | Ours | Plugin pieces we now render |
|---|---|---|
| `Header` | `Header.astro` | `VersionSelect` (ours, see below), topics from `Astro.locals.starlightSidebarTopics` |
| `ThemeSelect` | `ThemeSelect.astro` | `VersionSelect` |
| `PageTitle` | `PageTitle.astro` | `VersionNotice` (ours); starlight-page-actions' button moved to `PageSidebar` |
| `Sidebar` | `Sidebar.astro` | Wins over the vendored sidebar-topics override because `astro.config.mjs` components take precedence (the vendored plugin spreads `starlightConfig.components` after its own). The vendored code is unchanged. The topic list renders here for the mobile menu only. |
| `TwoColumnContent`, `PageSidebar`, `Pagination`, `Footer` | ours | none |
| `Search` | still Starlight's | trigger restyled from `kix.css`; phase 3 replaces it |

Each Kix version's docs are a separate build: CI builds the docs at each
release tag and at main, and serves them at `/docs` (the latest release),
`/docs/main`, and `/docs/v<major>.<minor>` (`.github/workflows/pages.yml`).
`src/lib/docs-version.ts` reads which build this is from the environment
`docs/flake.nix` sets. `VersionSelect` lists the versions from the
`/docs/versions.json` CI writes, and `VersionNotice` marks main's and older
releases' pages.

starlight-page-actions stays installed with only `markdown: true`: it still
generates the `.md` twins that Copy as Markdown fetches.

### Derived rather than designed

- **Dark caution, danger and version notice**: caution uses `#E9C46A` on a
  12% fill; danger (unused in content) takes the caution shape in `#FF7A6B`
  dark / `#B3261E` light. The outdated-version notice uses the caution colours.
- **Aside icons**: by title through `aria-label` (Reference: book;
  Explanation and Background: lightbulb; Use it in a task and every tip:
  arrow), and by type otherwise (info for notes, triangle for caution).
- **Sidebar heading** on every topic, not only tutorials; the "N lessons"
  count only on tutorials.
- **Mobile**: one header row (logo, search, menu). Topics, version and theme
  move into the menu. The right rail becomes Starlight's "On this page" bar,
  restyled; Copy as Markdown is not shown on mobile.
- **Wide screens**: the 1440px proportions are kept (300 / 80 / 720 / 80 /
  260) with spare width on the right, by a grid in `TwoColumnContent.astro`
  rather than Starlight's centred layout and fixed-position rail. Between
  72rem and 90rem the gutters shrink to 40px.
- **Titles with backticks** (`` `deploy` / `apply` ``): code in the H1,
  backticks stripped in the sidebar, eyebrow and pagination.
- **Code fences without a title** show no line numbers; titled ones do.
- **Command**: the chrome row shows `cwd` (or `title`) without the old "Run
  in" prefix. Blocks without either get a floating copy button. The capture
  tag ("offline capture" / "live capture") shows while an expandable block is
  open. "Output excerpt" is a tag in the chrome.
- **404**: Starlight's own page on the new tokens.

### Contrast (WCAG AA, 4.5:1 for small text)

| Token | Design | Shipped | Why |
|---|---|---|---|
| `t-dim` as text, light | `#6B707A` (4.3:1 on paper) | `--kix-dim` `#62666F` (5.0:1, 4.6:1 on paper-2) | mono labels, counts, footer date |
| `t-dim` as text, dark and on night panels | `#6B707A` (3.8:1) | `#80858F` (5.1:1 on page, 4.6:1 on chrome) | labels, line counts, comments |
| `accent-text`, light | `#B5401F` (4.49:1 on paper-2) | `#AD3D1D` (4.8:1 on paper-2) | links and the tip label sit on paper-2 inside asides |
| `caution`, light | `#A8761C` (3.2:1 on its fill) | `#86600F` (4.6:1) | caution label |

Line numbers keep the design's `#3E434C`; they are decorative.

### Known gaps

- The search dialog is still Starlight's (phase 3).
- Markdown twins show component tags (`<Command …/>`, `<Recap>`) as before.
- No `Related` list exists in content yet as `## Related` + list; the rows
  style in `kix.css` is ready for it.
- The design highlights a line in tutorial 05's code fence; the page does not
  mark one, and content was left alone.

### How to run it

```bash
nix run ./docs#dev                 # or, with generated content already synced:
cd docs && npx astro dev           # http://localhost:4321/docs/
nix build ./docs#site              # full build with the links validator
```

Adding an npm dependency changes `npmDepsHash` in `docs/flake.nix`; the build
error prints the new hash.
