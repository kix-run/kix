# 2026-09-27 · `docs/src/command-output/` · Captured deploy output still says "pass --prune to delete".

The deploy plan and prune lines now say ``kept; `kix deploy --prune` or `kix gc`
deletes them`` and ``kept (warn-only; `kix deploy --prune` or `kix gc` deletes
them)``. The captured outputs under `docs/src/command-output/` were recorded
before that and still show the old wording, for example
`tutorials/04-from-scratch/deploy.json`,
`tutorials/04-from-scratch/deploy-after-edit.json`,
`tutorials/06-service-dep/deploy.json` and
`how-to/adoption-stateful-migration/accepted-dry-run.json`. Regenerate the
captures so the pages match what `kix deploy` prints.
