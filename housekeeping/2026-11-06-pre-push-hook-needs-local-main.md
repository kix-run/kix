# 2026-11-06 · `lefthook.yml` · The pre-push hook fails in a clone that has no local `main` branch.

A clone made with `git clone --branch <feature>` has no local `main`. On the first push of a new branch, lefthook runs `git diff --name-only HEAD main`, which fails with "ambiguous argument 'main'", and the push stops at `verify-signatures: exit status 128`. Agents that test a branch in a fresh clone hit this every time. `git branch main origin/main` clears it.
