---
name: update-dev-blog
description: Update the kixpkgs developer blog (docs/blog/) with new posts covering recent commits. Use when the user asks to update, extend, or add to the dev blog, or when new features have landed and need blog coverage.
---

# Dev Blog Update Process

The blog lives in `docs/blog/`. Each post is a standalone markdown file covering one major feature or development.

## Step 1: Find what's new

```bash
# Get the latest commit referenced in any existing blog post
grep -h "commit:" docs/blog/*.md | tail -1
# Then check what landed since
git log <last-commit>..HEAD --oneline --format="%h %ai %s"
```

Group commits into major features. Ignore chores, thoughts, and minor fixes unless they're part of a bigger story.

## Step 2: Plan the posts

Before writing, list the proposed posts with:
- Title
- Date range
- What it covers (2-3 bullets)
- Which commits it maps to

Present this to the user for approval. One post per major feature or development. Don't try to cover everything -- if a change is minor, skip it.

## Step 3: Write each post

### Frontmatter format

```yaml
---
title: "Post Title Here"
date: 2026-03-28
date_end: 2026-03-29  # omit if single day
series: 15
commits:
  - abc1234  # feat: short description
  - def5678  # feat: another one
---
```

- `series` is just the post number. No total (e.g. `15`, not `15/17`).
- `commit` (singular) for one commit, `commits` (list) for multiple.

### Title and date line

```markdown
# Post Title Here

*2026-03-28 to 2026-03-29 -- Post 15*

---
```

### Writing style

Read `.claude/skills/adam-friendly/SKILL.md` for the full style guide. The short version:

- **Context before content.** Open with 3-5 sentences: what problem does this solve, why would someone want it.
- **Concrete before abstract.** Show the code or the CLI output first. Explain the principle after.
- **Before/after comparisons.** When showing a new feature, show what the old way looked like. The contrast is the argument.
- **Walk through examples.** Whiteboard style, not textbook. "Here's what happens when you run this."
- **Short sentences.** Bold first use of new terms. Use "you" and "your."
- **No emojis.**
- **No assumed knowledge of Nix.** Each post should be readable by someone who knows K8s but not Nix. If a Nix concept is needed, explain it in one sentence.
- **Don't use jargon without explaining it.** "DSL" -> explain what it means. "Fixpoint" -> show the pattern first, name it after.
- **~500-900 words per post.**

### Content rules

- No internal cluster names (NW1, FB1, etc.) or client names (Northwind, Fabrikam). Use generic names like "prod", "cluster-prod", "prod.example.com", "a client's production cluster".
- Reference the Adam + Luca collaboration where relevant ("Luca pointed out...", "we debated...").
- End posts with a bridge to the next topic when natural, but don't force it.

## Step 4: Update series numbers

When adding posts, do NOT update the `/N` total in existing posts -- there is no total. Each post just has `series: 12` etc.

Increment from the highest existing post number.

## Step 5: Review

After writing, grep for:
- Internal names: `NW1|nw1|Northwind|Fabrikam|fabrikam|lithus`
- Stale series totals: `of [0-9]` in date lines
- Consistency: all posts should have the same frontmatter fields and date line format
