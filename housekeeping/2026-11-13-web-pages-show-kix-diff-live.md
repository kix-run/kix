# 2026-11-13 · `web/` · The marketing pages still show `kix diff shop` as the live-cluster preview.

From 0.10, `kix diff <cluster>` alone is refused and the live comparison is `kix plan <cluster> --read-only`. `web/src/components/sections/PayoffB.astro`, `HomeHub.astro`, `Ai.astro`, `Deploying.astro`, and `web/HANDOVER.md` still show the old command, so a visitor who copies it gets an error.
