# 2026-09-27 · `kix/lib/core/markers.nix` · `kix.untrackedRef` accepts any resource as `by`, not only a creator.

The `by` check in `mkUntrackedRef` only asks for an attrset with an `outPath`, so `by = self.someConfigMap` passes. That reference then drops out of the `architecture.untrackedReferences` audit as if its creator were named. A wrong `by` shows up only at deploy, when the `kix.run/expects` wait times out after 180s. Nothing at eval ties `by` to a Job or workload that can create the named object.
