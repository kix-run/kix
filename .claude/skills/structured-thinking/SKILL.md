---
name: structured-thinking
description: >
  Guide the user through structured thinking on business, strategy, or technical topics.
  Use when the user wants to brainstorm, analyze, design, or think through something —
  keywords like "think about", "brainstorm", "let's figure out", "what should we do about",
  "design", "explore the idea of". Also use when the user references business_discussions/
  or v2_discussions/ directly. Prefer this over plan mode for bigger new features or ideas.
---

# Structured Thinking

Turn loose thinking into a short, durable document that someone can pick up later.

## Ground yourself first (mandatory)

1. Read `v2_discussions/README.md` (has Status + Relevance markers, Recently Archived, `interesting_thoughts/` index) and `ls business_discussions/`.
2. For loose/abstract technical topics, skim `v2_discussions/29_compiler-design.md` to know what kix *is*.
3. For technical opinions, read the relevant files in `kix/lib/` and `cli/README.md`. Opine on code, not on stale docs.

## Orient, then propose

Answer to the user in one message:

1. **Topic** — restate in one sentence.
2. **Destination** —
   - `business_discussions/` — market, GTM, pricing, positioning, fundraising.
   - `v2_discussions/` — technical, near-term, would be opened in the next 1–2 milestones.
   - `v2_discussions/interesting_thoughts/` — technical, future/curious, no near-term driver. Signals: "at some point", "cool idea, not blocking", requires scale/hardware/customers we don't have. **Default here when in doubt.**
3. **Existing docs on the topic** — list the leading active doc, relevant archived docs, related `interesting_thoughts/` entries.
4. **Plan** — new doc or iteration on existing (see next section). Propose a number and name.
5. **Mode** — Interactive (ask questions one at a time with AskUserQuestion) or First draft (write, then react). Ask the user.

As a default, wait for confirmation before writing.

## Keep documents short — rotate, don't extend

**Discussion docs should stay under ~400 lines.** Long docs are unreadable and carry stale thinking forward. When a topic needs a new take, don't pile it onto the existing doc — **start a fresh doc and archive the old one**:

1. Read the existing leading doc end-to-end. Note (a) what's been decided, (b) what's still undiscussed or important.
2. Start a new numbered doc (`NN_same_topic_v2.md` or a new name). It must:
   - Cite the predecessor in `**Supersedes:** archive/NN_old.md`.
   - Carry forward **only** the undiscussed / still-important parts — rewritten tight, not copy-pasted.
   - Not re-litigate settled points. A one-line "we decided X in NN_old" is enough.
3. Move the old doc to `archive/` with `**Status:** Superseded by NN`.
4. Update `v2_discussions/README.md`: replace the old row, add a one-line "Recently archived" entry.

Variants / counter-proposals use `NN[a-z]_variant.md` naming so the relationship is obvious.

Only genuinely new topics get a brand-new number with no predecessor.

## Archive on ship (mandatory)

When a feature ships (user says "done", "landed", "merged", or a commit closes out a design doc), archive the design doc in the **same session** as the implementation:

1. Identify the leading doc for what shipped.
2. Split shipped content from still-open content:
   - Actionable near-term → `ROADMAP.md § Open design questions`.
   - Future / exploratory → new or existing `interesting_thoughts/` doc.
3. Move the doc to `archive/` with `**Status:** Implemented`.
4. Update the README (remove active row, add to Recently Archived with a one-line reason).
5. Sweep sibling/child docs on the same topic that are now orphans — archive those too.

Consult the user if the split is non-obvious.

## Numbering

Two-digit prefix, next available number (check the README for the current highest). Variants: `NN[a-z]_name.md`. After creating a doc, add it to the appropriate theme group in the README.

## Document types

Pick the one that matches the maturity of the thinking. All v2_discussions docs start with:

```
# NN: Title

**Status:** Draft | Accepted | Rejected | Implemented | Superseded by NN
**Related:** `other_doc.md`
**Supersedes:** archive/NN_old.md   (if replacing a predecessor)
```

| Type | When | Key sections |
|---|---|---|
| **Brainstorm** | Early exploration, no committed direction | Freeform. No frontmatter required for v2. |
| **RFC** | Proposing a feature *should exist*. Argues what + why, not how. | Problem, Proposal, Motivation, Open questions. |
| **Design Doc** | How an accepted feature gets implemented. References `kix/lib/` and `cli/` paths. | Context, Design, Alternatives considered, Migration, Open questions. |
| **Implementation Plan** | Scoped work plan for a settled design. | Scope, Phases, Current state. |
| **Strategy Memo** (business) | Business case, market, strategic direction. | Frontmatter (title, status, created, last_updated, prereqs, summary) + freeform body (context, analysis, options, recommendation). |
| **Analysis** (business) | Research-heavy: market, pricing, competitive. | Same frontmatter as Strategy Memo. Data-driven body. |

Maturity flow: Brainstorm → RFC → Design Doc → Implementation Plan → `archive/`. Skip stages when obvious. Dead-end brainstorms go to `archive/` or `interesting_thoughts/`.

## Principles

- **Short beats long.** A 400-line doc with sharp open questions beats a 1200-line doc that re-explains settled points. When a doc grows stale, rotate it — don't extend.
- **Archive on ship.** A shipped design doc in the active folder is a bug.
- **Future → `interesting_thoughts/`.** The active folder is for the next 1–2 milestones only.
- **Status is mandatory.** Every doc says where it stands.
- **Ground in code.** Read `kix/lib/` and `cli/` before opining. Stale-doc opinions are worthless.
- **Capture the *why*.** Rationale + rejected alternatives, not just the chosen direction.
- **One idea per doc.** Split when two distinct topics surface.
- **Archive is not trash.** Check `archive/` for prior thinking before writing.
