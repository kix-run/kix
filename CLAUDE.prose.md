# Prose corrections

Writing rules Adam has corrected in review. Apply to ALL prose written in this
repo: marketing copy, docs, READMEs, blog posts, discussion docs, code comments,
and docstrings. See `CLAUDE.md` for the code-comment rules. Add new entries here
whenever Adam corrects writing style.

## Punctuation

- **No em dashes (—).** Rewrite the sentence with a comma, colon, period, or
  parentheses instead. This applies everywhere, including page titles and
  terminal/demo output.
- **Use the Oxford comma.** In a list of three or more items, put a comma
  before the final "and" or "or": "check, plan, and deploy", not "check, plan
  and deploy".

## Banned words and phrases

- **"quietly"** as a dramatizing adverb ("quietly becomes a headcount line").
  Just state the thing.
- Pre-existing (from CLAUDE.md): no sentence-ending "with confidence"; no
  "unlock", "empower", "supercharge", "seamless".
- **No insider shorthand for ordinary actions.** "Take a release" means
  "upgrade to a new version"; say that. The same goes for chat messages,
  warnings, and comments: if a phrase only makes sense to someone who already
  knows the jargon, use the plain words.

## AI-tell constructions

- **No "X, not Y" idiom** (e.g., "References, not strings", "Fail the build,
  not the deploy", "Agents need a compiler, not raw kubectl"). It reads as an
  AI-generated cliché. State what Kix does directly.
- **No "WHY THIS MATTERS" or meta-commentary eyebrows/callouts** (e.g., "WHY
  THIS MATTERS", "THE TAKEAWAY", "PAYOFF A", "01 · AUTO-GENERATED SECURITY").
  Never add a box or heading explaining why an output matters. Let the resource
  (`kind: CiliumNetworkPolicy`), the code comment, or the CLI output speak for
  itself.
- **Never label the self-evident.** Do not put badges like `"7 lines total"`,
  `"input"`, `"OUTPUT"`, `"WHAT YOU WRITE"`, or `"WHAT KIX GENERATES"` on top of
  a code editor or terminal pane. If a pane shows `clusters/shop.nix` with 7
  numbered lines, the reader can see it is 7 lines of input code. If the right
  pane shows `$ kix build shop` and `kind: CiliumNetworkPolicy`, the reader can
  see it is the output.
- **No aphoristic paired-punch sentences.** Pattern: two short declaratives
  where the second "lands the twist", e.g. "The benefits are real. The problem
  has always been the price of admission." Reads as AI-generated. Cut these
  rather than rewording them; the surrounding copy usually already makes the
  point.
- **Keep marketing and website copy as short as possible.** Readers scanning a
  page cannot absorb dense walls of text. Use one short sentence of setup per
  section and let the code or CLI output carry the point.
- **No "X is A, not B" antithesis.** Avoid headings and declarative sentences
  built around the rhetorical contrast "X is A, not B" (e.g. "Helm is a
  fallback, not the target model", "Ownership follows fields, not whole
  objects"). State what the thing is directly.

## Reader context

- **Assume 95% of readers are unfamiliar with Nix.** Write about Kix in Kix
  terms, not Nix internals:
  - `kix` is the only CLI users run. Never contrast `kix` commands with raw
    `nix` commands (do not write "evaluate with `kix check` rather than
    `nix build` or `nix flake check`").
  - Say "Kix's local store" instead of "the local Nix store" or `/nix/store`.
  - Say "resource", "built manifest", or "content-addressed manifest" instead
    of "Nix store derivation" or "derivation".
  - Teach the small subset of Nix expression syntax users write in `.nix`
    files, and keep Nix internal mechanisms (such as string context) confined
    to deep-dive architecture sections where that mechanism is the topic.
- **Do not introduce rejected, nonexistent, or internal alternatives merely to
  contrast them with the shipped design.** Describe the current model directly.
  For example, "Kix reads the committed value during evaluation" gives the
  reader the fact they need. Adding "instead of accepting a deploy-time
  override" introduces a concept they did not need to consider. Use a contrast
  only when readers are likely to arrive with that expectation and resolving it
  helps them complete the task.
- **Avoid "hand-written" and "manually written" as categories.** They imply a
  human-versus-agent distinction that is usually irrelevant. Name the actual
  distinction: generated, derived, explicitly configured, defined directly,
  checked in, or a bare file without the generated envelope.

## Capitalization

- **"Kix" with an upper-case K in prose** (headings, body copy, FAQ answers,
  page titles, meta descriptions). Keep lower-case `kix` only in CLI/code
  contexts: terminal commands (`$ kix check`), code snippets
  (`kix.packages.postgres`), file names (`stack.kix`), event names/storage
  keys, and the mono-font logo wordmark.

## Names for the parts of Kix

Use one name for each part, everywhere: errors, warnings, log lines, `kix
doctor` output, help text, docs, skills, and the changelog. Errors that
compare versions name both sides with these nouns and their versions.

| Part | Name | Not |
|---|---|---|
| The product, and the installed tool when you mean the tool | **Kix** ("Kix 0.8.1", "Upgrade Kix to 0.8.1") | "the kix binary", "the kix program", "this kix", "the Kix CLI", "the Kix release" for the installed tool |
| What a person types | `kix`, in code font, only for a command line or a command name (`kix upgrade`, "run `kix build`") | bare lowercase kix in prose |
| The Nix code a project pins in `flake.lock` | **the Kix library** ("This project's Kix library is 0.8.0") | "kixpkgs", the library's old name |
| The programs that ship with Kix in `libexec/kix` (Nix, Helm, kubectl, sops) | **the Kix runtime**; one program in it is "the Helm in the Kix runtime" | "bundled programs", "bundled runtime", "Kix's programs", "runtime directory" except where the folder itself is meant |
| Where Kix keeps fetched and built files (`~/.cache/kix/store`) | **Kix's local store** | "Kix's store", "the local build cache", "the evaluation store", "the Kix store" |
| The file a person downloads | **the release archive** | "the Kix download", "the tarball" |
| How a project is built (`builder` in `kix.toml`) | **builder**, named by its value in code font: "the `nix` builder", "the default builder (`kix`)" | "mode", "backend" |

A version is a property of the thing: "Kix 0.8.1", "the Kix library 0.8.0",
"Helm 4.3.1 in the Kix runtime". Say "a matching version" or "the same
version" rather than "the same release" when two parts must agree.

## Messaging constraints (kix startup positioning)

- Kix (the CLI, the library, and the packages in this repository) is open
  source under the Apache License 2.0. Kix Enterprise is a separate product
  and is not open source. Do not write "no lock-in" as a blanket claim.
- The defensible claim: kix's *output* is standard Kubernetes;
  "leaving kix means losing the tooling, not your infrastructure";
  "no proprietary runtime" is acceptable only when clearly about what runs in
  the cluster.
- **No "don't worry about Kubernetes" framing** (e.g. "nobody's job",
  "without making it your job"). Users should expect to pay attention to
  their infrastructure, like on any normal cloud. The honest claim: Kix makes
  Kubernetes much easier to manage and maintain, and no specialist is needed.
  Scoped falsifiable claims ("broken configs don't ship", "mistakes surface
  before deploy") are fine.
- The resonant subtraction is *specialists*, not headcount generally.
- The homepage H1 is "Kix is a Kubernetes compiler." The supporting copy is
  "Compile your whole cluster from one definition" followed by "If it compiles,
  it will deploy safely." Preserve this approved wording. The page title is
  "Kix | The Kubernetes compiler".
- The landing page tells one storyline: we felt the pain, tried the tools,
  built a Kubernetes compiler. New sections should serve that arc, not
  restart it.

## Errors and warnings

- Name what failed and the affected resource, instance, field, or file. Keep
  identifiers users need to locate the problem.
- Explain the consequence in plain language. Prefer "dependency" to "edge",
  "built resources" to "closure", and "cluster capability" to "axiom" unless
  the internal term is itself the API the user must edit.
- Give a concrete next step when one is known. Check command names, flags,
  and configuration fields against the code before recommending them.
- Distinguish what Kix knows from what it cannot verify. A failed registry
  request does not prove an image is missing; an undeclared operator does
  not prove its annotations are unused.
- For warnings, say what Kix skips, assumes, or continues doing. For errors,
  preserve the underlying cause instead of replacing it with generic text.
- Keep routine messages short. Put the explanation next to the failure;
  avoid internal design history, issue numbers, mathematical shorthand,
  and implementation vocabulary that does not help the user fix it.
