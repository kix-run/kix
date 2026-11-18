# 2026-11-18 · `scripts/check-bump.sh` · The "still appears" list matches the old version string everywhere, including Kix's own releases.

For a package pinned at `0.9.0`, the review list names 95 lines, such as `cli/kix-cli/src/commands/upgrade/plan.rs:209`, that refer to the Kix release `0.9.0`. Each line needs a reader to decide it is unrelated, so the list hides real leftovers. The search needs the package name or the old image digest, or the path should drop the Kix history folders. Where to look: the `left=$(git grep -nF "$old" ...)` line.
