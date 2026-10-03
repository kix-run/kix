# 2026-10-03 · `ROADMAP.md` · An open ROADMAP item says `kix diff` renders every resource as `Kind/unknown`, which it no longer does.

The item under "Drift detection & diffing" still recommends `deploy --dry-run` as the workaround. `kix diff` names every resource correctly on kind and on stage1 (2026-10-03), and `deploy --dry-run` now runs `kix plan`. The item should be closed or rechecked.
