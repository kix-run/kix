# 2026-10-17 · `CLAUDE.md` · `CLAUDE.md` says `.claude/worktrees/` is gitignored, but only this checkout's `.git/info/exclude` ignores it.

`git check-ignore -v .claude/worktrees/x` names `.git/info/exclude:11`, and `.gitignore` has no such line. On a fresh clone, worktrees under `.claude/worktrees/` show up as untracked files, contrary to what `CLAUDE.md` line 209 says.
