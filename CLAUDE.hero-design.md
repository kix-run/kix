# Hero design reference

Research summary on landing-page hero structure for dev tools, gathered
2026-06-12 while iterating the Kix hero. Consult this before restructuring the
hero or adding/moving elements above the fold. Sources at the bottom.

## Consensus hero anatomy (2025-2026 dev tools)

The consensus stack, confirmed by teardown literature and by live inspection
of Vercel, Tailscale, Pulumi, Temporal, Linear, and Fly.io (all six match):

1. **Eyebrow**: news/status line. For early-stage startups this is the
   credibility slot that social proof will later occupy (Evil Martians:
   "helps early-stage startups build credibility"). Pre-launch substitute:
   a status eyebrow like "Private beta · early access open".
2. **H1**: the five-second test. A reader who sees nothing else must know
   what you sell (Shapiro: "fully descriptive of what you're selling").
3. **One sub-block, 1-2 sentences**: answers the question the H1 raises
   (mechanism, "how is that claim possible"). Must NOT restate the H1
   (Demand Curve: "the subheader answers the question the header raises").
   A slogan layer that adds a claim but no information does not belong here.
4. **CTA row**: directly under the sub-block, BEFORE the visual. Held in 6
   of 6 sites inspected. Dominant pattern: primary button + lighter
   secondary. Shapiro's conversion equation (Desire - (Labor + Confusion))
   says the action must be available the moment desire peaks.
5. **Visual**: proves the claim. For infra/SDK products a code snippet is
   the endorsed choice (Evil Martians: common for tools without much UI).

On benefit-vs-category placement there are exactly two stable patterns:
category-in-H1 / benefit-in-sub (Tailscale, Linear), or benefit-in-H1 /
category-in-sub (Fly.io, Supabase). Always two text layers splitting the two
jobs, never three.

**Fletch PMM overlay**: the hero is "minimum viable positioning" and must
anchor to a reference point the buyer already holds: an existing category
plus a modifier, a use case/workflow, or a competitive alternative. They
advise against inventing category nomenclature. "Kubernetes compiler" is
their endorsed "existing category + modifier" move ("compiler" is a concept
every developer holds; Kubernetes is the modifier), so it works as an H1.
Their test also asks the hero to say who it's for or what it replaces
(for Kix: Helm charts, Terraform, hand-rolled YAML, the platform hire).

## How this applied to the Kix hero (June 2026 state)

Findings against the alt2 variant (H1 "Kix is a Kubernetes compiler." /
subline "Kubernetes at startup speed." / body paragraph / steps strip /
caption + code card / CTA):

- **Three text layers is one too many, and the middle one is the weak
  one.** The standalone slogan subline adds no information; the real
  subheadline content (one definition, mistakes fail the build on your
  laptop) was demoted to a muted third layer. Fix: collapse layers 2+3
  into one sub-block; the speed energy survives as a clause, not a layer.
- **CTA after the code card contradicts every observed example.** With
  caption + ~20-line card + badge + footer ahead of it, the button likely
  falls below the fold on laptops. Move CTA above the visual; a secondary
  ghost link ("See a full stack definition ↓") gives the code card an
  explicit job for non-converters.
- **Repeating the category word is a symptom of layer count, not a
  separate disease.** "Kubernetes" appeared 4x in three lines. The
  instances that earn their place: the H1's (category anchor) and a
  specific surprising claim ("less to learn than Kubernetes itself").
  Restatements of the H1's anchor do not. Two layers lands at two mentions.
- **Steps strips are a How-it-works section in the wrong slot.** The code
  card already demonstrates the early steps (the definition is "Define
  your stack"; the `kix check` footer is "Compile & check"). Process
  explanation belongs below the hero (Evil Martians, Fletch both place it
  post-hero). If a trace stays in the hero it goes below the code card as
  a bridge, never between body copy and visual.
- **The two elements the research most strongly endorses keeping**: the
  category-with-modifier H1, and the code card with its `kix check` footer
  strip, which is the strongest proof element on the page and substitutes
  for missing social proof.

Recommended stack: eyebrow → H1 → one merged sub-block (mechanism + laptop
claim + an audience or alternative anchor) → CTA row → caption + code card
→ steps strip demoted to header of the How-it-works section.

## Sources

- https://evilmartians.com/chronicles/we-studied-100-devtool-landing-pages-here-is-what-actually-works-in-2025
  (100-page dev-tool study; the single most relevant source)
- https://www.julian.com/guide/startup/landing-pages (header/subheader jobs;
  Desire - (Labor + Confusion))
- https://www.demandcurve.com/playbooks/above-the-fold (anti-redundancy rule
  between header and subheader)
- https://marketingexamples.com/landing-page/guide (Harry Dry's 5-element
  hero: title/subtitle/visual/social proof/CTA)
- https://baseletter.substack.com/p/homepage-gyaan-ft-fletch-pmm (Fletch's
  hero narrative flow, anchor types, anti-category-creation stance)
- https://www.news.aakashg.com/p/the-ultimate-guide-to-homepages (Anthony
  Pierri's competitive vs contextual anchoring)
- Live heroes inspected: vercel.com, tailscale.com, pulumi.com, temporal.io,
  linear.app, fly.io
