# 2026-11-06 · `lefthook.yml` · The pre-push signature check refuses a branch after main is merged into it.

The `verify-signatures` hook checks every commit in `@{upstream}..HEAD`. After you merge `origin/main` into a feature branch, that range includes main's commits, and any unsigned ones that reached main through a merged pull request block the push. Re-signing them as the hook suggests would rewrite commits that are already on main. Commits already on a remote need no check, so a range of `HEAD --not --remotes` would test only the new ones.
