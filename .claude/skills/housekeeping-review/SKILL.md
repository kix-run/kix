---
name: housekeeping-review
description: Read the housekeeping/ directory, group the entries by the cause they share, and propose architectural and developer-experience fixes. Use when asked to review, triage, or clear housekeeping.
user_invocable: true
---

# Housekeeping review

The `housekeeping/` directory at the repository root collects problems as
agents notice them, one problem to a file. Each entry is one observation,
cheap to write and usually too small to act on alone. The value is in the
shape a month of them makes together, so your job is to find that shape
and say which change would remove a whole group of entries at once.

Take an argument as a window: `2026-08`, `3 months`, `since the last
review`. Every filename starts with the date the entry was written, so a
window is a glob (`housekeeping/2026-08-*`). Without an argument, cover
everything in the directory.

## Process

1. **Read every entry, including the months outside the window.** An
   entry from March that shares a cause with three from September
   changes what you recommend. `cat housekeeping/*.md` reads the lot;
   `head -qn1 housekeeping/*.md` is the index.

2. **Check each entry still holds.** Open the code, run the command,
   build the cluster it names. Problems get fixed as a side effect of
   other work and nobody comes back to delete the entry. `git rm` the
   entries that no longer hold and list them in the review under
   "Already gone". Above roughly fifteen entries to check, fan out
   `Explore` agents and check them in parallel.

3. **Group entries by cause rather than by area.** Two entries in the
   same directory often have nothing in common, while a rule that fires
   on every package, a builder that stamps the wrong labels, and a doc
   that describes the old behaviour can all be the same missing piece
   of the lib. A group of one is fine and stays a one-off.

4. **Read the reference for each group** before proposing anything in
   that area: `kix/lib/architecture.md` for the lib,
   `docs-legacy/BEST-PRACTICES.md` and `docs-legacy/HANDBOOK.md` for
   the user-facing contract, `.claude/skills/kix-migration/SKILL.md`
   for package conventions, `cli/README.md` for the CLI. They record
   why some of this is the way it is.

5. **Take the architectural view.** For each group, ask what single
   change would make the whole group impossible. Prefer a change that
   removes the possibility, because a scorecard rule that fails the
   build outlasts a note asking people to remember. Bugs get the same
   treatment: look past the instance for the change that removes the
   class.

6. **Rank the groups** by how often the problem bites, what each hit
   costs, and what it risks. A one-line fix that saves ten seconds a day
   outranks a rewrite that saves an hour a year.

7. **Write the review** to `housekeeping/reviews/YYYY-MM-DD.md` using
   the template below, and summarise in the session: the three you
   would do first, and why.

## Rules

- Do not implement any of it. The review ends with a proposal, and the
  developer chooses what to take.
- Leave every entry whose problem is still real, however minor it looks.
  An entry leaves the directory when its problem is gone.
- Keep solutions out of the entries. They belong in the review.
- Write the review in plain language, following ISO 24495-1 and
  `CLAUDE.prose.md`.
- A group that turns out to be a feature request belongs in
  `ROADMAP.md`, and one that needs a design belongs in
  `v2_discussions/` via the `structured-thinking` skill. Say so in the
  review rather than designing it there.

## Review template

```markdown
# Housekeeping review: YYYY-MM-DD

Covers N entries written between YYYY-MM and YYYY-MM.

One paragraph on what this batch says about the repository.

## Themes, most worth doing first

### 1. The cause, in one sentence

**Entries:** the dates and titles this covers.

**What it costs us:** how often it bites and what each hit takes.

**What would remove it:** one option, or two where the choice is real.

**Recommendation:** what to do, and what to do first if it is large.

## One-offs worth doing

| Entry | What it needs | Effort |
| ----- | ------------- | ------ |

## Already gone

Entry files deleted from `housekeeping/`, with what closed them.
```
