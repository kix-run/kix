# 2026-11-13 · `cli/kix-cli/src/commands` · `kix build`, `kix plan`, and `kix deploy` do not show the Kix library's warnings.

Only `kix check` lists them, from `ClusterOutput::warnings`. `kix build` has the same `ClusterOutput` and drops them. `kix plan` and `kix deploy` load the build through `Build::of_flake`, which does not read `kix-warnings.json`. A user who goes straight to `kix plan` never sees a warning such as a skipped `meta.compatibleWith` check.
