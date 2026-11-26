# Housekeeping

This folder is the open working log of problems noticed and left unfixed while working on Kix: rough edges, stale docs, slow commands, confusing names, and bugs someone stepped around.

## Why there are so many files

Kix is developed largely by AI coding agents, directed and reviewed by its two maintainers. When an agent's session ends, its memory goes with it, so anything unrecorded is lost. Agents add an entry for every problem they notice and do not fix, whether or not it relates to the work in hand.

When a problem is fixed, its file is deleted, in the same commit as the fix where there is one. The folder is the list of problems still open, and Git history keeps the closed ones. Since the folder began on 18 September 2026, 524 entries have been deleted; as of 26 November 2026, 537 are open.

## How to read it

Each file records one problem under `YYYY-MM-DD-short-slug.md`, using the date it was noticed. Its first line states the problem in one sentence, with the path or subsystem it is about.

From the repository root, `head -qn1 housekeeping/*.md` prints a one-line index, and `grep -ril <keyword> housekeeping/` searches by keyword.

- Entries record current problems only, with no priority, owner, or promise of a fix. Missing features go in `ROADMAP.md`, and designs still being discussed go in `v2_discussions/`.
- When an agent meets the same problem again, it adds `Hit again <date> while <what it was doing>` to the existing entry. How often a problem comes back is the signal the maintainers most want.
- Entries waiting for a decision carry a line starting with `Decision required from`.
- Maintainers review entries in batches in `housekeeping/reviews/`, because the right fix for several related entries often differs from the fix any one of them suggests.

## Issues and contributions

Bugs that affect people using Kix belong in [GitHub Issues](https://github.com/kix-run/kix/issues). Questions and feedback go to GitHub Discussions.

`housekeeping/` is the working log of the people and agents changing the code. If you spot a problem while working in the repository and leave it unfixed, add an entry here rather than opening an issue; [`CLAUDE.housekeeping.md`](../CLAUDE.housekeeping.md) covers the format and rules.
