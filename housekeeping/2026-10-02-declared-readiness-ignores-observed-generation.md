# 2026-10-02 · `kix/packages/arc` · An AutoscalingRunnerSet's declared readiness passes on a stale status right after an apply.

The package's `{ path; equals; }` rule reads `status.phase`, and the
AutoscalingRunnerSet status has no `observedGeneration` (the vendored
schema lists only the runner counts and `phase`), so the CLI has nothing to
compare with `metadata.generation`. A set that was `Running` stays
`Running` until its controller reconciles the new spec and writes
`Pending`, so a deploy that changed its credentials or URL can pass before
the controller has seen the change. `kix/packages/arc/default.nix`
documents the gap.
