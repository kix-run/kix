# 2026-09-18 · `lefthook.yml` · The commit-msg hook rejects the `Co-Authored-By` trailer that the Claude Code harness adds to every commit.

Each commit fails once, and the agent retries without the trailer.
Nothing in CLAUDE.md says the hook wins, so every session rediscovers it.
