# kix Website — Rewrite Plan (v3)

## Who this is for

Four readers, ranked by how much revenue they can unlock:

1. **Platform engineer / staff+ IC.** Evaluates the tool, brings it to
   leadership. Bullshit-sensitive. Will bounce on the first hand-wave.
2. **VP Engineering / CTO.** Decides the budget. Reads the first 30
   seconds, maybe the first minute. Wants the shape of the problem and
   an honest read on risk.
3. **App developer.** Will actually use it day-to-day. Needs to feel
   that their hands-on life gets better, not worse.
4. **CISO / compliance lead.** Secondary sponsor. Cares about audit
   evidence and supply-chain trust.

It is **not** for:

- Investors. They have a different deck. Nothing on the site needs to be
  written to survive a VC read.
- Twitter / HN discourse. No meta-arguments about categories. No
  "paradigm shift" language.
- Ourselves. No inside jokes, no author-voice flexing.

## The one job of the site

A reader who has never heard of kix should, in under five minutes,
understand:

1. **The problem kix is for.** Day-2 (every change after install) is
   where Kubernetes hurts — specifically, the blast-radius review
   that every change needs and nobody can do without a senior engineer.
2. **How kix addresses it.** It compiles the cluster. The dependency
   graph is explicit; blast radius is a graph traversal; selectors,
   NetworkPolicies, RBAC are derived not written; rollback is a pointer
   swap.
3. **What they should do next.** Either talk to us (design partner), or
   clone the repo and try the kind demo.

That's it. Everything else is noise.

## The bullshit-radar rules

The buyers on this list have seen every Kubernetes pitch of the last
five years. Every "revolutionary" framing, every "fearless" adjective,
every pitch-deck analogy. They are primed to tune us out.

Clarity rules, hard:

- **Show, don't claim.** "Here's a terminal showing blast radius" beats
  "blast radius as cryptographic proof" every time. Where we can't show
  yet, we say so.
- **Concede what isn't shipped.** Stateful migration, operator swap,
  cross-cluster — design in `v2_discussions/`, not in CI. Saying this
  up front buys credibility for everything else.
- **Real nouns.** "StackGres → CloudNativePG" not "fearless operator
  swaps." "10Gi at /data, PVC + volume + mount" not "storage as a
  first-class concern."
- **No pitch-deck vocabulary.** Cut: *paradigm, reframe, revolutionary,
  categorical, invariably, structurally guaranteed, impossible elsewhere,
  moat, defensible.* The content behind those words may be real —
  describe it in plain English instead.
- **No unverifiable numbers presented as fact.** "One engineer runs
  10–15 clusters" is our claim; state it as a target supported by the
  nixpkgs analogue, not as a benchmark we've measured on prod customers.
- **Name the audience tension out loud.** "Yes, this depends on Nix."
  "Yes, the demo runs on kind." "Yes, we're pre-revenue." Every
  concession we make before they ask is credibility we don't have to
  earn back.
- **No moat talk.** A buyer's continuity question ("will this still
  exist?") is answered by team, open code, and public design docs —
  not by a defensibility paragraph. Investor-speak off the site.
- **No meta.** Don't tell them the site is sharper now. Don't explain
  our writing philosophy. Just be clearer.

## Site structure

Four pages. Same spine, different lens. Each page is independently
readable — a visitor landing anywhere should understand the whole.

### `index.html` — the argument

- **Hero.** One question that frames the category: *"Your cluster
  compiled once. Will the next change compile too?"* One sentence
  naming day-2 as the problem.
- **Scene.** One concrete day-2 failure mode, told vividly: Tuesday,
  postgres upgrade, Luca is out, nobody will hit enter. Why nobody
  will hit enter. End with a single line naming the shape of the
  problem — *compiler-shaped hole*.
- **The two tables.** NixOS/Ubuntu on day-1/day-2, then Helm/kix on
  day-1/day-2. The strongest single asset in the corpus; deserves its
  own vertical real estate. Zero fluff around it.
- **One sentence on the paradigm.** *Every competitor treats day-2 as
  a runtime problem. kix treats it as a compile-time problem.* Then
  the short competitor table (Helm, Argo, Backstage, OPA, Humanitec,
  kix) to back it up.
- **What becomes possible.** Four cards, each naming a concrete
  capability: blast radius as a graph traversal; compliance evidence
  as a build artifact; operator swaps as planned refactor; fleet
  consistency by hash equality. Each card ends with one sentence
  connecting it to the substrate.
- **Why this matters now.** The AI angle, told without the word
  "AI-native": generation is cheap; the bottleneck is the review that
  proves the change is safe; compilers are that review.
- **Three continuations.** One card per audience, short, honest
  descriptions. Not "pick your variant" — *here are three ways to
  keep reading.*
- **CTA.** One email. One link to the demo.

### `executive.html` — the cost

Audience: VP Eng, CTO, CISO.

- **Hero + Luca scene.** Same Luca, told as a business problem:
  one reviewer, one queue, one key-person risk.
- **Where the money goes.** Four cost rows (review queue, config
  incidents, audit season, onboarding tax). Ranges where we have
  them, concession where we don't.
- **The forcing function.** VMware refugees. Name two or three
  specific price events (UK university, AT&T). Why they're the most
  receptive buyer — not because they're early adopters, because
  they're paying down day-2 debt right now.
- **Unit economics.** The 10–15 clusters per engineer claim, stated
  as a target, grounded in the nixpkgs analogy. One short sentence
  conceding this is the hypothesis we're validating.
- **One foundation, many consequences.** Six claim cards covering
  managed ops, compliance evidence, IDP-as-consequence, AI ops, VMware
  migration, fleet consistency. Each is one consequence of the same
  substrate — not six products.
- **Why you can bet on this.** Replaces the old "moat" section.
  Short and honest: open source (fork it), public design docs
  (`v2_discussions/` is the actual roadmap), real demo (`kix deploy
  .#cluster-ludo-kind` runs today), pre-revenue (we're looking for
  design partners, not charging you). Continuity signals, not
  defensibility.
- **CTA.** One email, one link to platform.

### `platform.html` — the mechanism

Audience: platform engineers, staff+ ICs.

- **Hero.** *Kubernetes doesn't need a new abstraction. It needs a
  compiler.* One paragraph: past attempts failed because they tried
  to hide the resources; the resources aren't the problem, the wiring
  is.
- **The wiring problem.** Concrete list: Service selector ↔ workload
  matchLabels; env var host:port; port declared in four places; RBAC
  triples; PVC/volume/mount name string. Each is a class of bug the
  buyer has lived through.
- **The right analogy.** Assembly → C, applied correctly: you don't
  replace the language, you compile the wiring.
- **Why Nix.** String context is the reason. Real code example —
  a consumer referencing `postgres.out.fqdn`. The dependency edge
  falls out of the computation. The graph is always correct because
  you couldn't build without it.
- **What gets derived.** Six claim cards: selectors, NetworkPolicies,
  RBAC, storage, deploy ordering, blast radius. Each short, each
  concrete.
- **Compiler passes.** Six steps: resolution, compilation, wiring
  validation, derivation, whole-cluster analysis, emission. Enough
  depth that a staff engineer sees this isn't hand-waving. Link to
  `v2_discussions/29_compiler-design.md` and
  `kix/lib/architecture.md` for the real thing.
- **How it fits with what they have.** Helm charts import. Argo
  stays. Backstage stays. OPA stays. kix changes what gets decided,
  not what gets applied.
- **The CLI.** One command (`kix deploy`), one terminal mockup
  showing plan → waves → activation hash.
- **Honest caveats.** Needs Nix. Demo is kind. Some day-2 flows are
  roadmap. Pre-revenue.
- **CTA.** Link to developer page.

### `developer.html` — the experience

Audience: hands-on engineers.

- **Hero.** *Write a package. Deploy it. Change it. Without fear.*
  One paragraph pointing them at the right page if they want the
  argument or the mechanism.
- **Moment 1: Write.** One real package (API server that talks to
  postgres). Full code. Then the list of things they didn't have to
  write — nine emitted resources from four written, zero hand-sync.
- **Moment 2: Deploy.** `kix deploy` terminal output. Plan → waves →
  structured readiness.
- **Moment 3: Change.** Bump an image. `kix diff --vs-live` shows one
  hash changed, 246 proven unchanged. This is where "blast radius" lands
  viscerally.
- **Moment 4: The harder change.** StackGres → CloudNativePG operator
  swap. Terminal shows the migration plan. Followed by a concession:
  this specific flow is on the M2–M3 roadmap. The foundation is shipped,
  the apex is landing.
- **How much Nix do you have to learn?** Narrow surface: attribute
  sets, function args, three constructors, pipe operator. Compare to
  Rust onboarding — compiler catches invariants you don't know yet.
- **Getting started.** Three commands: install Nix, clone repo,
  `kix deploy .#cluster-ludo-kind`.
- **What doesn't work yet.** Stateful migration, cross-cluster, in-cluster
  eval mode, SaaS control plane, LSP. Tell them, don't bury.
- **CTA.** GitHub link, email.

## Cross-page rules

- **Every page ends with a footer** linking to the other three. A
  visitor who lands on executive should reach platform in one click.
- **Nav is the same everywhere:** Overview, Business, Platform,
  Developer.
- **No JS unless it pays for itself.** Pure HTML + CSS. Fast, portable,
  readable offline, trivially hostable.
- **One shared CSS file.** Content differs by page; design language
  does not.
- **Dark theme, monospace accents.** Already in place. Don't redesign
  for the sake of it.

## What I will cut in this pass

Concrete deletions from the current site:

1. **`executive.html` → "Why it's defensible" section.** Investor
   language. Replaced by a shorter "Why you can bet on this" anchored
   on open source, public design docs, honest stage.
2. **`index.html` → rename "What becomes possible" cards' framing.**
   Remove "Things that cannot exist without a compiler" — too close
   to "impossible elsewhere" pitch-speak. Keep the cards; soften the
   header to *What the substrate unlocks* or *What you get that the
   current stack can't give you.*
3. **`index.html` → "Why this matters now."** Keep the AI substance,
   cut the word "AI-native." Keep it short — two paragraphs, not
   three.
4. **Executive `10–15 clusters` number.** Keep the claim; add one
   sentence conceding it's a target grounded in nixpkgs, not a
   customer benchmark.
5. **Anywhere the word *paradigm* appears.** Replace with plain
   English (*different shape of problem*, *same data model, different
   operation*, etc.).

## Success test

A skeptical platform engineer reading the site end-to-end should
finish with **three sentences they could repeat to a colleague**:

> *Day-2 is the real K8s cost. kix compiles the cluster so every
> change has a known blast radius before it touches anything. It's
> Nix-based, the demo runs on kind, they're pre-revenue and looking
> for design partners.*

If the site doesn't produce those three sentences in that reader's
head, it hasn't done its job. Everything else — tone, design,
copy — is subordinate to that.
