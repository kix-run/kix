# 2026-11-23 · `changes/` · Records named after the branch collide when a package has two pending bumps.

The bump task says to write `changes/bump-<package>.md`, but `changes/bump-cloudflared.md` already holds the pending 2026.11.1 record. The second bump had to pick another name (`bump-cloudflared-2026.11.2.md`). Name records after the version too, or document a rule for a second record per package.
