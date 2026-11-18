# 2026-11-18 · `scripts/worktrees` · Another session committed to a bump worktree while its agent was working in it.

Commit 585a7660 (a housekeeping note) appeared on `bump/infisical-operator-0.11.18` between two of my commits, in `/scratch/worktrees/bump/slot-1`. The reflog also shows earlier clickhouse-operator commits there. A bump agent cannot tell its own commits from another session's, and a PR built from that branch carries the stray commit. Give each bump its own worktree and branch, and check `git reflog` before a push.
