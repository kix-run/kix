# 2026-11-10 · `.claude/skills/package-review/SKILL.md` · The skill's `every-package-evaluates` command fails on any machine, at the cilium package.

The skill's tool table says to run `nix build .#checks.x86_64-linux.every-package-evaluates`. That build stops at `helm-render-cilium.json`, because plain `nix build` cannot render a Helm chart. CI runs the same check through `kix` (`flake_checks_evaluate_with_helm` in `.github/workflows/bundle-checks.yml`). An author who follows the skill gets a failure that has nothing to do with their package and learns nothing from the check.
