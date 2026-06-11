# Prose corrections

Writing rules Adam has corrected in review. Apply to ALL prose written in this
repo: marketing copy, docs, READMEs, blog posts, discussion docs. Add new
entries here whenever Adam corrects writing style.

## Punctuation

- **No em dashes (—).** Rewrite the sentence with a comma, colon, period, or
  parentheses instead. This applies everywhere, including page titles and
  terminal/demo output.

## Banned words and phrases

- **"quietly"** as a dramatizing adverb ("quietly becomes a headcount line").
  Just state the thing.
- Pre-existing (from CLAUDE.md): no sentence-ending "with confidence"; no
  "unlock", "empower", "supercharge", "seamless".

## AI-tell constructions

- **No aphoristic paired-punch sentences.** Pattern: two short declaratives
  where the second "lands the twist", e.g. "The benefits are real. The problem
  has always been the price of admission." Reads as AI-generated. Cut these
  rather than rewording them; the surrounding copy usually already makes the
  point.

## Capitalization

- **"Kix" with an upper-case K in prose** (headings, body copy, FAQ answers,
  page titles, meta descriptions). Keep lower-case `kix` only in CLI/code
  contexts: terminal commands (`$ kix check`), code snippets
  (`kix.packages.postgres`), file names (`stack.kix`), event names/storage
  keys, and the mono-font logo wordmark.

## Messaging constraints (kix startup positioning)

- kix the CLI/service is proprietary and closed source, and will remain so.
  Do not write "no lock-in" as a blanket claim or imply the tool is or will
  become open source.
- The defensible claim instead: kix's *output* is standard Kubernetes;
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
  Current H1: "Kubernetes any developer can run." (alternates parked in a
  comment in Hero.tsx).
