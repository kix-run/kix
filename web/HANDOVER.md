# Website handover

Notes for whoever works on kix.run next. The brief and design live in the
`kix-oss-handoff` repo (`phase-1-website/`, design frame `m22NM`).

## Phase 1 · Landing page (2026-10-06)

The landing page is rebuilt to "Kix Landing Page · Story edit": paper, ink and
orange, Inter Tight and JetBrains Mono, night panels for every terminal and
code file. Light only, as designed.

### Stack change: React to Astro

The brief said to keep React, Vite and shadcn. The site is now a plain Astro
6 project with Tailwind v4, at Adam's request. The React app rendered on
the client, so its HTML was an empty `<div id="root">`. Crawlers and coding
agents that don't run JavaScript saw nothing but meta tags. Astro renders
every section to static HTML, and the page ships three small inline scripts
(nav menu, copy buttons, hairline on scroll) and no framework runtime.

- Starlight was considered and rejected for this page: its layout fights a
  marketing page, and the docs project's `base: '/docs'` cannot serve `/`.
- `web/` stays separate from `docs/`. `.github/workflows/pages.yml` is
  unchanged apart from comments (`npm run build` now runs Astro and still
  writes `web/dist/`).
- `vite@7` is a direct dev dependency so `@tailwindcss/vite` and Astro share
  one Vite; without it npm installs Vite 8 for the plugin and `astro check`
  fails on mismatched plugin types.
- The lefthook `typecheck-web` hook now runs `astro check`.

### Where things are

| What | Where |
|---|---|
| Tokens (design variables as Tailwind colours), fonts, focus ring, `kicker` utility | `src/styles/global.css` |
| Page and meta tags (title, description, Open Graph, Twitter, canonical) | `src/layouts/Base.astro`, `src/pages/index.astro` |
| 404 page | `src/pages/404.astro` (replaces `public/404.html`) |
| Shared primitives | `src/components/`: `Container`, `Section` (paper, paper-2, night), `Heading`, `Logo`, `Button` (primary, ink, outline, outline-night), `CommandBar`, `CopyButton`, `Terminal`, `TermLine`, `CodeCard` |
| Static syntax colouring for code cards | `src/lib/code.ts` |
| Link targets and nav anchors | `src/lib/links.ts`, `src/lib/nav.ts` |
| Sections, in page order | `src/components/sections/`: `Nav`, `Hero`, `Story`, `RootIdea`, `PayoffsIntro`, `PayoffA`…`PayoffD`, `Packages`, `Ai`, `Language`, `Deploying`, `Faq`, `Team`, `FinalCta` (includes the footer) |
| Team photos | `src/assets/` (optimised to WebP by `astro:assets`) |
| Social card | `public/og-image.png`, `public/og-image@2x.png` (design frame `lcDUr`) |
| Install script (not published) | `install.sh` |

Every terminal and sample output is a data array at the top of its section
file, so wording can change without touching markup.

### Decisions

- **D1** (install command): `install.sh` is written but not published.
  "Install the Kix CLI" links to tutorial 02 (local setup), "Read the docs" to
  tutorial 01. The command bars in `Hero.astro` and `FinalCta.astro` are
  commented out. To publish: copy `install.sh` to `public/install`,
  uncomment both `CommandBar`s and their imports, and check the script
  against a machine with and without Nix. kixpkgs is private, so
  `nix profile install github:kix-run/kixpkgs#kix` only works for people
  with access until the repo is public.
- **D2**: the design's copy, without "verifiable cluster artifact"; Adam is
  retiring the phrase.
- **D3**: the Team section ships as "Core team" with Luca Dombetzki and Adam
  Charnock, their photos and bios from the unvibe homepage, and LinkedIn
  links. The "TBC" paragraph and the quotes placeholder are left out.
- **D4**: no Contact link in the footer.
- **D5**: "An optional in-cluster operator is in development." as designed.
- **D6**: the agent toggle is gone; the AI section replaces it.
- **A2** (addendum): Postgres examples use `cnpg-cluster` (CloudNativePG);
  no other Postgres operator is named.
- **A1** (addendum): "Why the Nix language?" uses the new copy, with no
  aside and four points; `kix check`, `kix build` and `flake.lock` are inline
  code. The claims are verified in the handoff's `shared/CLAIMS.md`.
- **Meta**: the old site's tags are kept. The description is now the hero's
  H1 and subhead. `og:image` and `twitter:image` point at the 2x card
  (2400×1260) so it stays sharp on high-density screens; `twitter:card` is
  `summary_large_image`.
- **Early-access form**: the old final CTA had a Forminit email form. The
  design has none, so the form and its script are gone. Bring it back if
  email capture is still wanted.

### Derived rather than designed

- **Sticky nav** with a hairline once scrolled; below 1024px a menu button
  opens a full-width sheet of the nav links and the install button.
- **Breakpoints**: two-column layouts start at 1280px (`xl`), because at
  1024px the design's fixed side columns leave the text column too narrow.
  Below that every section is the obvious single column. The YAML stack
  diagram scales with its container; the mistakes table stacks into labelled
  rows below 768px; terminals scroll inside themselves.
- **Contrast**: the design's `t-dim` (`#6B707A`) is `#80858F` on night, as in
  the docs. Links and small orange text use `accent-text` (`#AD3D1D`, a shade
  darker than the design's `#B5401F`, which is 4.49:1 on paper-2). Orange
  buttons use a new `accent-button` (`#D4441E`) because white on the brand
  orange is 3.4:1; the "B." marker on paper-2 uses it too. Line numbers keep
  the design's low contrast and come from CSS (`attr(data-line)`) so they
  stay out of copied text.
- **Receipt "clean"**: the design colours it `#2E8B57`, which has no token;
  it is semibold ink instead.
- **404**: same copy as before, in the new style.

### Claims checked

Checked against kix/lib, the CLI source, the docs captures in
`docs/src/command-output/`, and a real `kix check` run on the hero cluster
(the CLI built from source).

| Claim | Result |
|---|---|
| Hero `clusters/shop.nix` | Evaluates as drawn (`web.nix` must declare a `replicas` option for `config.replicas`). |
| Hero `kix check shop` | Real TOOL / RESULT / DETAILS table. A real run of the hero cluster with `cnpg-cluster` gave 37 manifests; the warning count (2) matches the OG card and depends on `web.nix` (the test run gave 1). The OG card still reads 41, the count from before A2. |
| Root idea: RBAC | Was "derived from the bindings you declare". Kix builds Roles and bindings from the access each package declares (`kix/lib/vocab/rbac.nix`); wording changed. |
| Root idea: network policies | Cilium-only and opt-in (`networkPolicy.enable`); "when enabled" added. |
| Payoff A messages | Full strings from `eval/validate.nix`, `scope/validators.nix` and `core/resource.nix`, including the `[web]` instance prefix, the Secret's "declared keys" line, Kix's two selector labels, and the fix-it sentences the design cut. |
| Payoff B terminal | Rebuilt in the real `kix diff` layout: package summary, namespaces sorted, added before changed, `$.path` with old/new, "via dependency", Activation line. `kix diff` has no `-v` and no "Plan:" line (that is `kix deploy`/`kix plan`). |
| Payoff B notes | rollback reapplies from the local Nix store, and `kix gc` keeps at least the 10 newest records; drift, `--prune` (never deletes Namespaces or CRDs) and `snapshot save` / `diff --from` reworded to match the reference. |
| Payoff B waves | Illustrative diagram; the database step is `Cluster/db`, the CloudNativePG resource `cnpg-cluster` renders (addendum A2). |
| Payoff C receipt | Real: `status.receipt` on the Activation, schema `kix.run/receipt/v1`; card fields map to `cluster`, `deployedAt`, `source.gitCommit`, `source.dirty`, `builder.kixVersion`, `builder.arch/os`, `images`. Cluster renamed `shop`. Manifests are excluded because they carry secrets (`receipt.rs`). |
| Payoff C moments | "rebuild a previous deploy" was false; rollback reapplies the stored build. `pin check --source-rev` and `kix compliance` (CycloneDX SBOM, unsigned SLSA provenance, one framework per audit) reworded. |
| Payoff D | `packages.clickhouse` does not adapt to availability; the diagram now shows `packages.cnpg-cluster` (1 instance at `none`, 3 at `zone`; addendum A2). The ClickHouse provider swap is real (`clusters/test-clickhouse-swap/`) but also needs operator and Keeper instances; the comment says so, and comments use `#`. |
| Deploying PR card | Matches `kix diff -o markdown`: Plan and Resources lines, Added packages, Changed packages as collapsed details, Activation. The design's "Plan for cluster shop:" sentence does not exist. Same sample change as Payoff B. |
| FAQ "Does anything need to run in my cluster?" | Nothing runs in the cluster, but Kix adds two CRDs and records deploys as Activations; answer updated. |
| Everything else in CLAIMS.md § Website | Verified as listed there. |

The OG card (`lcDUr`) shows the hero snippet in a shortened form with the same
check counts. Re-export it if the hero snippet changes shape.

### Checks

- `npm run build` (runs `astro check`, then builds) passes.
- No horizontal page scroll at 360, 390, 768, 1024, 1280 and 1440px.
- axe-core (WCAG 2 A/AA and best practices): no violations. Lighthouse on
  the production build: performance 98, accessibility 100, best practices
  100, SEO 100.
- One `h1`; section headings in order; skip link; visible orange focus ring;
  copy buttons announce through a live region.

### Known gaps

- The install script is unpublished (D1).
- The Team section has no founder note; the design's was a placeholder.
- No email capture (see Decisions).

### How to run it

```bash
cd web
npm ci
npm run dev        # http://localhost:4321/ (add --host 0.0.0.0 to reach it over the network)
npm run build      # astro check, then a static build into dist/
npm run preview    # serve dist/
```

Links into `/docs/` only resolve on the deployed site, or when the docs dev
server runs behind the same origin.
