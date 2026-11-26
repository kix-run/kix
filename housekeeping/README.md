# Housekeeping

This folder tracks unfixed problems noticed while developing Kix: rough edges, stale docs, slow commands, confusing names, and bugs someone worked around.

## Why there are so many files

Kix is developed largely by AI coding agents, directed and reviewed by its two maintainers. Agents keep no memory between sessions, so anything they do not write down is lost. They add a file for every problem they notice and do not fix, even when it is unrelated to their current task. Putting one problem in each file prevents merge conflicts across parallel branches.

When a problem is fixed, its file is deleted, usually in the same commit. Only open problems stay in this folder, and Git history keeps the closed ones. Since the folder started on 18 September 2026, 524 entries have been deleted. As of 26 November 2026, 537 remain open.

## How to read the entries

Each entry is named `YYYY-MM-DD-short-slug.md` for the date the problem was noticed. Its first line names the affected path or subsystem and states the problem in one sentence.

From the repository root, run `head -qn1 housekeeping/*.md` to list the first line of every file, or `grep -ril <keyword> housekeeping/` to search by keyword.

- Entries record current problems only, with no priority, owner, or promise of a fix. Missing features go in [`ROADMAP.md`](../ROADMAP.md), and open design discussions go in [`v2_discussions/`](../v2_discussions/).
- When an agent runs into the same problem again, it adds `Hit again <date> while <what it was doing>` to the existing entry. Repeat hits show the maintainers which problems come up most often.
- Entries that need a maintainer's decision before they can be fixed include a `Decision required from` line.
- Periodic batch reviews in [`housekeeping/reviews/`](reviews/) group entries by shared cause, since one underlying fix often resolves many entries at once.

## Reporting bugs and contributing

If you hit a bug while using Kix, open an issue in [GitHub Issues](https://github.com/kix-run/kix/issues). Ask questions and share feedback in [GitHub Discussions](https://github.com/kix-run/kix/discussions).

If you notice a problem while working on this repository and leave it unfixed, add a file here instead of opening a GitHub issue. See [`CLAUDE.housekeeping.md`](../CLAUDE.housekeeping.md) for the format and rules.
