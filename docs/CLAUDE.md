# Kix Docs Authoring Guidance

This file is for LLMs and maintainers writing the Kix documentation site. It
adds Kix-specific judgment on top of the Diátaxis system:
https://diataxis.fr/

Do not treat this as a generic writing guide. Assume the model already knows
Diátaxis. The work here is keeping Kix docs approachable, correctly sequenced,
and connected across tutorials, how-to guides, reference, and explanation.

## Goal

Kix docs should feel like an experienced engineer walking another engineer
through a system that is powerful but unfamiliar. Be direct, concrete, and
friendly. A little informal tone is fine; cleverness is not worth it if it
makes the idea harder to grasp.

The reader is expected to know Kubernetes basics, but may have little or no
Nix experience. Nix syntax, Kix dependency wiring, and package/instance
boundaries are the biggest places to slow down and teach deliberately.

## Source of Truth

- The docs site lives under `docs/src/content/docs/`.
- Use `.mdx` for every page in `docs/src/content/docs/`, even when the page is
  plain Markdown. This keeps Starlight components available everywhere.
- Render every shell command the reader is meant to run with the `Command`
  component (`docs/src/components/Command.astro`). Do not pair it with a
  separate shell fence or a `CommandCwd`. Do not use a raw ```` ```sh ```` /
  ```` ```bash ```` fence for runnable commands: fences are reserved for
  illustrative snippets, file paths, and inline file content (Nix, YAML,
  expected text the reader does not type).
- `Command` usage:
  - Single command: `<Command commands={["kix list clusters"]} cwd="kix-examples/" />`
  - Multi-command sequence (each entry renders its own `❱` prompt):
    `<Command commands={["kubectl get pods -n X", "kubectl get svc -n X"]} />`
  - Per-step output for inline commands (each entry is `{ command, stdout? }`):
    `<Command commands={[{ command: "curl http://localhost:8080/", stdout: "Hello!" }]} />`
  - With generated output: declare the capture in `docs/nix/captures.nix`,
    import its committed JSON sidecar from `docs/src/command-output/`, and
    spread it: `<Command {...check} />`. Sidecars use the same
    `commands: Step[]` schema the component accepts.
  - Hide output behind a disclosure: add `expandable`
    (`<Command expandable {...deployFirst} />`). The command lines stay
    visible; the output is in a `<details>` block. Use for long or noisy
    outputs (full deploy banners, large `kix build` dumps).
  - Working directory: set `cwd` when the reader must be in a specific
    location. End directory cwds with `/` (e.g. `cwd="kix-examples/"`). Omit
    `cwd` when the command can run from anywhere.
  - Terminal colour: ANSI SGR codes in captured output are translated to
    styled spans automatically. Don't strip them from sidecar `stdout`.
- Output policy. Show command output only when it teaches something:
  - the next step depends on values in the output;
  - the output confirms success or failure the reader should learn to
    recognise;
  - the command is being introduced and the shape of its result matters;
  - the output demonstrates Kix behaviour, diagnostics, dependency ordering,
    generated resources, or validation results.
  Skip output for install/setup/navigation commands (`cd`, `mkdir`, `git
  clone`, `nix develop`, kind/kubectl prep), repeated commands where the
  shape was already taught, long or unstable output that distracts from the
  lesson, or commands whose result depends heavily on local machine state.
  When success is obvious from the next prose step, omit the output.
- Prefer captured command output over separately maintained examples where
  correctness matters. Declare both offline and live captures in
  `docs/nix/captures.nix`. Keep its steps grouped by docs page or example so
  it stays readable as the docs grow.
- Run `npm run check:local-imports` after synchronizing generated snippets.
  The standard dev app and site build run it automatically. Every static
  `/src/...` import must resolve before Astro starts or builds.
- Regenerate offline captures with
  `nix run ./docs#regen-captures-offline -- --apply`. Use these for commands
  that need no live Kubernetes API, including `check`, `build`, `graph`, and
  `list`, as well as intentional failures. CI checks that the committed
  offline sidecars are current.
- Regenerate live captures with
  `nix run ./docs#regen-captures -- --apply`. This creates a dedicated kind
  cluster and captures commands such as `deploy`, `diff`, `status`, and
  `kubectl get`. Keep inherently noisy steps out of drift comparison with the
  capture manifest's `skipDriftCheck` flag.
- The capture workspace uses the checked-in `kix-examples` flake. It cannot
  capture commands for files the reader creates only in their own checkout,
  such as `tutorial-04/`. Leave those commands output-less and carry the
  explanation in prose.
- Hand-write `stdout` on `Command` only for short, stable output that the
  capture pipelines cannot produce, such as the deterministic response from
  `curl` against an example echo server. Add a docs comment explaining why it
  is maintained separately so future maintainers know it can drift.
- Fenced code blocks (```` ```nix ````, ```` ```text ````, ```` ```yaml ````)
  remain the right tool for *file contents* (the snippet the reader edits or
  pastes into a file). `Command` is for *executions* (what the reader runs in
  a shell). Both can sit side-by-side on the same page.
- **Astro template gotcha.** Inside `{...}` expressions in an `.astro`
  template, arrow functions returning JSX **must be expression-bodied**:
  `items.map((x) => <span>{x}</span>)`. Block bodies like
  `items.map((x) => { ...; return <span>{x}</span>; })` fail with a misleading
  "Expected ')' but found '{'" at a phantom line position. If you need
  per-item logic, pre-compute the data in the script section and keep the
  template a plain `.map(node => <jsx/>)`. See `Command.astro` for the
  pattern (the `RenderUnit` / `PreUnit` / `DetailsUnit` shape) and
  [withastro/astro#6955](https://github.com/withastro/astro/issues/6955).
- The canonical planning issue is:
  https://github.com/adamcharnock/kixpkgs/issues/20
- The example repo guidance in `kix-examples/CLAUDE.md` applies when writing
  tutorial/example material, especially around concept sequencing and inline
  comments.
- Prefer current code over older prose for reference facts. In particular,
  check CLI facts against `cli/kix-cli/src/cli.rs` and command behavior against
  `cli/kix-cli/src/commands/`.
- Treat older broad docs as source material, not truth. Verify before importing
  from `kix/lib/architecture.md`, `ROADMAP.md`, or raw `v2_discussions/` notes.

## Page Openings, Titles, and `Helpful background`

- **Keep page titles and filenames short and scannable.** Prefer concise noun
  phrases for Explanation and Reference chapters (`Availability levels` in
  `availability-levels.mdx`, `Helm integration` in `helm-integration.mdx`,
  `Network policy` in `network-policy.mdx`). Rename the `.mdx` file whenever a
  page title changes so the URL slug matches the title.
- **Frontmatter `description` is metadata only.** `PageTitle.astro` does not
  render `description` under the `<h1>`. Keep `description` accurate in
  frontmatter for `<head>` metadata and `llms.txt`, and never write dense
  "How X drives Y, Z, and W" taglines at the top of a page.
- **Start Reference and Explanation pages with a plain-English warm-up
  paragraph.** Ease a non-expert into the page in 2 to 4 sentences: explain
  what problem or part of the workflow the page covers and when to reach for
  it before introducing internal vocabulary or code.
- **Follow the warm-up with a `:::note[Helpful background]` box.** List 3 to 4
  bullet links to prerequisite material so readers can get up to speed before
  diving in. Link to Kix Tutorials, Explanation pages, Reference pages, or
  authoritative external documentation (such as official Kubernetes or Nix
  docs), with a short description after each link explaining why to read it:

  ```md
  :::note[Helpful background]
  - [07. Package anatomy and safe resource composition](/docs/tutorials/07-package-anatomy-and-safe-resource-composition/): walk through a complete Kix package from top to bottom.
  - [Packages and clusters](/docs/explanation/packages-and-clusters/): see how packages separate application authoring from cluster-specific configuration.
  - [Module system (nix.dev)](https://nix.dev/tutorials/module-system/): review the NixOS `lib.mkOption` and `lib.types` system that Kix packages use for option declarations.
  :::
  ```

- **Build-time link badges, tooltips, and external icons are automatic.**
  `src/lib/rehype-link-types.mjs` inspects every Markdown link at build time:
  - Inside `:::note[Helpful background]`, internal links automatically render a
    monospace pill badge (`TUTORIAL`, `HOW-TO`, `EXPLANATION`, `REFERENCE`).
  - External links (`http://`, `https://`) everywhere automatically render a
    Wikipedia-style external link icon.
  - Internal links in body prose and tables automatically get a hover tooltip
    showing `<Quadrant> · <Page Title>` (plus `· #<Section>` for anchor links).
  Write ordinary Markdown links; do not hand-code badge spans or external-link
  arrows in `.mdx` files.

## Diátaxis Mode

Each page must have one job. Do not blur modes just because the nearby concept
is interesting.

Tutorials are lessons. They build skill by leading the reader through a working
state. Use them to introduce concepts in the planned order, one layer at a
time.

How-to guides are recipes. They assume the reader knows the concepts and wants
to accomplish one task. Do not re-teach the mental model; link to the tutorial
or explanation that does.

Reference pages describe the machinery. Be complete, terse, and easy to scan.
Do not teach by story. Do not bury defaults, types, flags, or edge cases in
paragraphs when a table or list is clearer.

Explanation pages build understanding. They answer why the system works this
way, what tradeoffs are involved, and how concepts relate. Do not turn them
into step-by-step procedures.

## Build on What Came Before

Never leave the reader to infer missing prerequisites.

- Before writing a page, identify what the reader must already know.
- If that knowledge is part of the tutorial path, link to the tutorial that
  introduced it.
- If it is conceptual background, link to the explanation page.
- If it is a specific API, option, command, helper, or schema field, link to
  reference.
- If the page depends on an example file, link to the file or example heading
  instead of repeating a large block of code.

For tutorials, assume the reader is moving linearly. Do not use `deps`, `ref`,
`out`, aliases, auto-instantiation, flavors, imports, scorecards, or deploy
graph details before the tutorial sequence has introduced them. If a later
concept must appear early, name it lightly and promise the later tutorial.

Good pattern:

> For now, treat `out` as the public interface another instance exposes. The
> graph tutorial explains why these references also affect deploy order.

Bad pattern:

> This works because Nix string context propagates dependency metadata into
> the activation DAG.

That statement may be true, but it arrives too early for a beginner tutorial.

## Cross-Linking

Cross-linking is part of the teaching, not decoration. Each page should help a
reader choose their next level of detail without feeling dumped into a
different kind of doc by surprise.

Use normal inline links for definitions already in the reader's path. Use a
standard callout when the link changes Diátaxis mode.

Use these labels consistently:

Cross-link paths are **always absolute, prefixed with `/docs/`** (the site's
base path), never relative (`../`). The `starlight-links-validator` plugin
enforces this: relative links aren't validated, and absolute links without
the `/docs/` prefix fail validation because the validator matches against
final URL paths.

```md
:::tip[Try it as a tutorial]
Work through the [first local package and service-to-service dependency tutorial](/docs/tutorials/06-first-local-package-and-service-to-service-dependency/)
if you want to learn this by building it from scratch.
:::

:::tip[Use it in a task]
See [Wire cross-namespace dependencies explicitly](/docs/how-to/debug-dependency-wiring/wire-cross-namespace-dependencies-explicitly/)
when you already know the model and just need the steps.
:::

:::note[Reference]
See [`deps`](/docs/reference/instances-and-composition/#deps) for the exact instance schema.
:::

:::note[Explanation]
See [Dependency resolution and why explicit deps matter](/docs/explanation/the-dependency-graph/#dependency-resolution-and-explicit-deps)
for the design reasoning behind this rule.
:::
```

Callout rules:

- Use at most two mode-switch callouts near the point where the reader would
  naturally ask for more.
- Do not stack all four quadrants at the end of every page.
- Link to the most specific page available, not a section index.
- Make the sentence say why the reader would follow the link.
- Keep the link text human. Avoid naked filenames unless the file itself is
  the thing the reader needs.
- Prefer contextual link text over bare page titles. For example, write
  "work through the [project files and flake entry point tutorial](/docs/tutorials/03-project-skeleton-and-flake-shape/)"
  rather than "work through [Project files and flake entry point](/docs/tutorials/03-project-skeleton-and-flake-shape/)".

## Tutorials

Tutorials should make progress feel steady and unsurprising.

- Start with what the reader will build and what they should already know.
- Keep each tutorial focused on one new brick.
- Prefer small working clusters over abstract fragments.
- Show commands the reader can run, then show how to inspect the result.
- Give code fences a `title` with the path the snippet belongs to. In
  tutorials, use the learner's tutorial directory for build-along code, for
  example `title="tutorial-04/flake.nix"`. When inspecting the public examples,
  use the real example path, for example
  `title="kix-examples/examples/02-hello-world/cluster.nix"`.
- Leave the title off short illustrative fragments that are not meant to be
  copied into a specific file.
- Introduce Nix syntax only when the page needs it.
- When a Nix construct appears for the first time, add a one-sentence note.
- Keep deeper mechanics out of the main flow; link to explanation/reference.
- End by naming what the reader has learned and what the next tutorial adds.
- Wrap the "What you learned" list in `<Recap>` (`src/components/Recap.astro`).
  Write an ordinary Markdown list inside it. An item that starts with inline
  code (`` `kix check` catches problems before deploy ``) shows the code in a
  command column; any other item is a plain statement. The page's Markdown
  twin keeps the list text between the `<Recap>` tags.
- `<Loop>` (`src/components/Loop.astro`) renders a short ordered list of
  commands as a strip of cells, each item written as `` `kix check` what it
  does ``. Tutorial 05 uses it for the check, build, diff, deploy, and graph
  loop. Keep it to a handful of steps.

Code in tutorials should carry teaching comments where they reduce context
switching. Preserve those comments when editing. If a snippet is imported from
examples, do not duplicate the whole file in prose; explain what to look for
and link to the file or rendered snippet.

## How-To Guides

How-to guides should help a competent reader finish a task quickly.

- Title pages as tasks: "Expose a service with Ingress", not "Ingress".
- State assumptions briefly.
- Give the shortest reliable path first.
- Include checks that prove the task worked.
- Add troubleshooting only for likely failure modes.
- Link to tutorials for learning and explanation pages for design context.
- Avoid broad conceptual introductions.

If the guide has many variants, split it. A how-to that tries to cover every
cluster provider, every secret backend, and every deploy mode is usually three
guides and one reference page.

## Reference

Reference must be accurate before it is elegant.

- Verify names, defaults, flags, types, and behavior against current code.
- Prefer tables for schema fields, CLI flags, outputs, and defaults.
- Include compact examples only when they clarify usage.
- Say whether content is generated or hand-maintained.
- Do not make reference depend on tutorial order.
- Link out to how-to guides for common tasks and explanation for rationale.

When documenting generated or generated-adjacent material, prefer improving the
generator over hand-editing pages that will drift.

## Explanation

Explanation pages should make the system easier to reason about.

- Start from a real confusion a Kix user will have.
- Explain tradeoffs and consequences, not just architecture.
- Compare with familiar Kubernetes/Helm/Kustomize/GitOps ideas where useful.
- Use diagrams or short examples when they clarify a relationship.
- Link to reference for exact fields and to tutorials/how-to guides for action.
- Avoid turning explanation into a dumping ground for every fact about a topic.

Good explanation writing makes future tutorials shorter because the reader can
leave the lesson, understand the model, and come back.

## Examples and Snippets

The docs can render snippets extracted from `.nix`, `.sh`, and `.py` files in
`kix-examples` and this repository. Prefer that for code that should stay
tested and tied to a real example or implementation.

- Use `Snippet.astro` for substantial Nix, shell, and Python examples.
- Prefer snippets for code that exists in `kix-examples`, `clusters/`,
  `kix/packages/`, or another tested source file. Keep inline fenced code for
  tiny hypothetical fragments or learner-created files only.
- Avoid snippets that expose local-only development paths or private repository
  assumptions unless that is currently how the source example runs. When the
  learner should create a public-facing file, write that build-along code
  inline with the tutorial path as the title.
- Name snippet regions after the concept they teach (`helloWorldInstance`,
  `crossNamespaceDep`, `packageRule`), not after line numbers.
- Close snippet regions with named end markers, such as
  `# endregion:helloWorldInstance`.
- Nested regions are allowed. When a tutorial needs to show an outer frame
  before zooming into an inner detail, prefer `<Snippet elide={{ ... }} />`
  over duplicating source code by hand.
- Keep snippets small enough to read in one screen.
- Let code comments teach the local detail.
- In prose, explain why the snippet matters and what changes after using it.
- Do not repeat long code blocks that already live in an example file.
- If a file is mostly unchanged from a prior example, say so and link back.

## How-to scenario workflow

How-to guides are backed by a small set of reusable scenarios in the
`kix-examples` repository. Do not create one cluster per page, and do not add
unrelated features to one catch-all cluster. Extend the smallest coherent
scenario that can exercise a group of related guides.

- Check `docs/how-to-coverage.json` before starting a guide. It assigns every
  page to a scenario family and records implemented pages, snippets, and
  captures. Update the entry when the page is implemented.
- Use `kix-examples/how-to/` for reusable how-to scenarios. Keep numbered
  tutorials under `kix-examples/tutorials/`; how-to scenarios are not part of
  that learning sequence.
- Keep each scenario runnable in its checked-in state. Put temporary edits,
  invalid values, drift, and intentional failures in capture `setup` or
  `mutate` steps under `docs/nix/captures.nix`.
- Use named source regions for substantial code. Region names describe the
  concept (`healthCheckBuildEntry`, `reusedInstances`), not the page or line
  number. The extractor supports `.nix`, `.sh`, and `.py` sources.
- Add offline captures for important `check`, `build`, `graph`, `list`, and
  intentional-validation output. Add live captures only when the guide teaches
  Kubernetes behavior such as deployment, readiness, drift, rollback, or
  ownership transitions.
- Reader-facing commands must be commands a developer would reasonably run
  to complete the task. **Never put `jq` commands (`| jq ...`, `jq -e ...`) or
  `grep` test-assertion commands in documentation pages.** Instead, show the
  `kix` or `kubectl` command directly and state in a sentence which fields to
  check in the output.
- Use `stdoutJq` only as capture-time plumbing in `docs/nix/captures.nix` when
  a command's full JSON output would obscure the object being discussed. The
  generated sidecar keeps the original `kix` command (without `| jq`) and
  labels the rendered result "Output excerpt". Prefer the command's normal text
  or YAML output where possible.
- Prefer a `shell` step when the command the reader types is a command
  *line* rather than a single binary with arguments, such as a shell redirect
  (`kix build demo > demo.yaml`). `kix` (and `kubectl`, live) are already on
  PATH carrying the driver's flags, so write the command exactly as the page
  shows it.
- Use a string `prepare` in `docs/nix/captures.nix` for a capture-only check
  that must not appear on the page (such as verifying a generated file in the
  capture harness). It runs on every regeneration and writes no sidecar. Do not
  copy `prepare` assertions into `.mdx` files.
- Every step is bounded by `timeout` (default 600s). A step that stops making
  progress fails the run by name. Raise it for a genuinely slow command; do
  not raise it to hide one that stopped terminating.
- Set `resetCluster = true` on the first live group whose output must not
  depend on what earlier groups deployed. `kix diff`, `status`, `snapshot
  save`, and `gc` read only the Kix cluster you named, but print a line
  counting the objects of each other Kix cluster they skipped, so the
  tutorial deployments would otherwise appear in the capture.
- Put a group that deliberately breaks the cluster last. A deploy whose probe
  fails leaves a Degraded activation, and later groups preparing a deploy
  would inherit the broken cluster.
- Use `stdoutGrep` for a generated text excerpt when a command's stable,
  actionable diagnostic would otherwise be buried in stack traces or other
  incidental output. Match the diagnostic itself, not line positions. Matching
  lines have their leading display padding removed. The capture fails if the
  expression matches nothing, and the reader still sees the original command
  with an "Output excerpt" label.
- Regenerate one group while developing with `--group`, for example:

  ```sh
  nix run ./docs#regen-captures-offline \
    --override-input kix-examples git+file:///path/to/kix-examples \
    -- --group how-to/application-health-check --apply
  ```

- Develop both repositories together by overriding the docs input with the
  local `kix-examples` checkout. Before finishing, commit the examples, update
  `docs/flake.lock` to that reachable revision, regenerate captures, and build
  without a local override. Do not leave committed docs dependent on an
  unpublished examples revision.
- Run `npm run check:how-to-coverage` from `docs/`. The site build runs the
  same check and fails when a page is missing from the ledger or its status no
  longer matches its content.

Use this evidence order for examples:

1. Extract substantial executable code from a tested scenario or package.
2. Capture Kix output when its shape or behavior teaches part of the task.
3. Keep small declarations and files the reader is actively creating inline.
4. Render routine commands with `Command` without manufacturing unhelpful
   output.

## Voice

Write for engineers, but do not make the reader prove they belong.

- Prefer concrete nouns and consequences.
- Prefer "Kix uses this to..." over "This enables powerful abstractions...".
- Avoid unexplained jargon, even if it is precise.
- Avoid hype, jokes that carry meaning, and cute metaphors.
- Use contractions when they make the sentence more natural.
- Keep paragraphs short.
- Use bullets when the reader is scanning choices or constraints.

The best tone is: clear enough for a tired reader, precise enough for a
skeptical one.

## Page Checklist

Before finishing a docs page, check:

- The page has one Diátaxis mode and does not drift.
- The reader's prerequisites are stated or linked.
- New concepts are introduced in the right order.
- Commands, flags, schema fields, and defaults were checked against code.
- Cross-links point to the most specific useful page.
- Mode-switch links use the standard callout labels.
- Code comments still teach the important local details.
- The page does not repeat long code that should be a snippet or source link.
- The title says what the page helps the reader do, know, or understand.
