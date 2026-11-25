+++
kind = "fixed"
state = true
+++
When a resource fails during a deploy, `kix deploy --operator` and `kix rollback --operator` now report the wave as failed (for example, `✗ Wave 1: Failed (0/1 applied, 1 failed)`). Previously, they printed `✓ Wave 1: Complete (0/1 applied, 1 failed)` because the final entry in `status.waves` on the `Activation` record was always marked `Complete`. Kix and the Kix operator now set that entry's `status` to `Failed` when any resource fails, and older versions of Kix already recognize `Failed`.
