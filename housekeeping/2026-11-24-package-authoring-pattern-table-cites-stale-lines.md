# 2026-11-24 · `.claude/skills/package-authoring/SKILL.md` · Some line citations in the pattern table point at the wrong line.

The table says `pkg:N` means `kix/packages/stable/pkg/default.nix:N`, but most cited packages are in `kix/packages/experimental/`. `victoria-metrics-operator:346` is cited for `kix.reconcileErrorsAlert`, and `operator.nix` has no such call. `keycloak:398` pointed at the end of a `mergeEnv` call before it was corrected on 2026-11-24. Nothing checks the citations, so they drift each time a cited file changes.
