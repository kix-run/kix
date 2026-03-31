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

You are helping the user think through a topic in a structured way, producing a written artifact in the appropriate discussion folder. The goal is to turn loose thinking into a document that future-you (or a cofounder, investor, or engineer) can pick up and build on.

## Step 0: Ground yourself

Before anything else, ground your understanding in the actual system:

1. **List both folders** — `ls business_discussions/` and `ls v2_discussions/` to see what discussions currently exist. This is mandatory every time — don't rely on memory.
2. **Read the compiler doc** — `v2_discussions/29_compiler-design.md` is the conceptual anchor for the whole project. If the user's topic is loose or abstract, read this to ground yourself in what kix actually *is* and *does*. Not mandatory for narrow topics, but reach for it when you need to orient.
3. **Read code when opining on technical topics** — skim relevant files in `lib/` and read `cli/README.md` for CLI context. Your opinions in design docs must be grounded in what the code actually does today, not just what docs say it does. If you're writing about the DSL, read the relevant lib files. If you're writing about deploy, read the CLI README and relevant command source.

## Step 1: Orient

Before writing anything, figure out:

1. **What's the topic?** Restate it back in one sentence.
2. **Which folder?** Route based on content:
   - `business_discussions/` — market, strategy, GTM, pricing, positioning, business model, competitive analysis, partnerships, fundraising
   - `v2_discussions/` — technical design, architecture, DSL features, deployment, operator, tooling, compiler
   - If it spans both (e.g. "how do we productize feature X"), pick the one that matches the *primary question*. A technical feature's business case goes in `business_discussions/`. A business need's technical design goes in `v2_discussions/`.
3. **What type of document?** Choose carefully — the type reflects the maturity of the idea (see Document Types below). You may consult the user on what document type they feel like describes their thought best. In case the user creates a new document type that is not listed, update this skill.
4. **What exists already?** From the folder listings in Step 0, identify related docs. Surface what you find — the user may want to build on or reference existing work.

Tell the user what you found and propose: folder, document type, and any existing docs worth reading first. Wait for confirmation before writing.

## Step 2: Read context

Discussion documents build on each other. Before writing:

- In `business_discussions/`: check the `prereqs` field in frontmatter of related docs. Read those if they're relevant.
- In `v2_discussions/`: check the `Related:` links at the top. Read those if they're relevant. They may or may not be relevant.
- Skim `ROADMAP.md` for relevant sections when the topic touches planned or built features.
- **Check `v2_discussions/archive/`** for superseded or implemented discussions on the same topic. Archived docs aren't wrong — they represent prior thinking that may still be valid or contain important context for why something was decided.

Summarize key context that's relevant to the new document.

## Step 3: Ask how to write

Before drafting, ask the user their preferred mode:

- **Interactive** — you ask questions one at a time using the AskUserQuestion tool, building the document from their answers. Better for early-stage thinking where the user wants to discover what they think.
- **First draft** — you produce a complete draft the user can read, edit, and react to. Better when the user already has a clear picture and wants to save time.

You may or may not want to write multiple documents.

## Step 4: Write

Use the appropriate format (see Document Types below).

### Numbering

- `business_discussions/`: two-digit prefix, next available number. Check existing files.
- `v2_discussions/`: two-digit prefix, next available number. Check existing files.
In case the new discussion is simply a new variant of another main document you may use <number>[a-Z]_doc-name.

## Document types

The type reflects the maturity and intent of the thinking. Choose carefully — the wrong type leads to the wrong conversation.

### Brainstorm (either folder)

**When:** Early-stage exploration. The user has an idea or problem but hasn't committed to a direction. Capturing raw thinking.
**Structure:** Light — a title, status line (`**Status:** Exploration`), and freeform sections. No frontmatter required for v2_discussions brainstorms. Use frontmatter for business_discussions brainstorms (keeps the prereqs chain intact).
**Graduates to:** RFC (if a feature emerges) or Strategy Memo (if a business direction emerges).

### RFC — Request for Comments (v2_discussions)

**When:** Proposing that a feature or capability *should exist*. The RFC argues for the "what" and "why" — not the implementation details. It's a pitch: here's the problem, here's what the solution looks like at a high level, here's why it's worth doing.
**Structure:**
```
# NN: Title

**Status:** Draft | Accepted | Rejected | Superseded by NN
**Related:** `other_doc.md`, `another_doc.md`

## Problem
What's broken or missing, with concrete examples.

## Proposal
What the feature does, from the user's perspective. Include API sketches or usage examples.

## Motivation
Why this matters — what it enables, what pain it removes.

## Open questions
What needs to be resolved before accepting.
```
**Graduates to:** Design Doc (for implementation planning).

### Design Doc (v2_discussions)

**When:** Working out *how* an accepted feature gets implemented. Digs into the architecture, data flow, edge cases, and integration points. Must be grounded in the actual codebase — reference specific files, functions, and data structures.
**Structure:**
```
# NN: Title

**Status:** Draft | Open problem | Implemented | Superseded by NN
**Related:** `other_doc.md`, `another_doc.md`

## Context
What RFC or decision this implements. Link it.

## Design
The proposed implementation. Reference actual code paths (lib/, cli/). Include code sketches where they clarify.

## Alternatives considered
What else could work and why this approach is better.

## Migration / compatibility
What changes for existing packages or clusters.

## Open questions
What's unresolved.
```
**Graduates to:** Implementation Plan (if the scope is large).

### Implementation Plan (v2_discussions)

**When:** The design is settled and the work needs to be broken into concrete steps. This is the most refined technical document — it's a sequenced work plan, not a discussion.
**Structure:**
```
# NN: Title — Implementation Plan

**Status:** In progress | Complete | Stalled
**Related:** `design_doc.md`

## Scope
What's being built, with a link to the design doc.

## Phases
Sequenced work items with concrete deliverables. Each phase should be independently shippable or at least testable.

## Current state
What's done, what's next. Keep this updated as work progresses.
```

### Strategy Memo (business_discussions)

**When:** Making a business case, analyzing a market, or proposing strategic direction. Board/investor-grade documents.
**Structure:**
```yaml
---
title: "Title"
status: draft | current | superseded
created: YYYY-MM-DD
last_updated: YYYY-MM-DD
prereqs: [doc_name_without_extension, ...]
summary: >
  2-4 sentence summary. This is what someone reads to decide
  whether to open the full document.
---
```
Body is freeform but typically: context, analysis, options, recommendation.

### Analysis (business_discussions)

**When:** Research-heavy — market landscape, competitive positioning, pricing analysis.
**Structure:** Same frontmatter as strategy memos. Body is data-driven: tables, comparisons, sourced claims.

## Document lifecycle

Ideas mature through documents:

```
Brainstorm → RFC → Design Doc → Implementation Plan
                 ↘ Strategy Memo → Analysis
```

Not every idea goes through every stage. A brainstorm might die. An RFC might be rejected. A design doc might be written directly if the "what" is obvious and only the "how" needs discussion. Use judgment.

When a document is superseded or fully implemented, move it to `v2_discussions/archive/` with a status update. Don't delete — the reasoning history matters.
Consult the user first if you plan to move a document.

## Principles

- **Build on what exists.** Don't start from scratch if there's a related doc. Reference it, extend it, or explicitly supersede it.
- **Status is mandatory.** Every doc must say where it stands. Update status when things change.
- **Link the chain.** Use `prereqs` (business) or `Related:` (technical) so readers can trace the reasoning.
- **Ground in code.** Technical documents must reference actual code paths. "The evaluator does X" is worthless if you haven't checked what the evaluator actually does. Read `lib/` and `cli/` before writing technical opinions.
- **Capture the *why*.** Decisions without rationale are useless in 6 months. Record alternatives considered and why they were rejected.
- **One idea per document.** If the brainstorm surfaces two distinct topics, split them.
- **Archive is not trash.** Superseded and implemented docs in `archive/` contain valid reasoning and historical context. Check them when working on related topics.
