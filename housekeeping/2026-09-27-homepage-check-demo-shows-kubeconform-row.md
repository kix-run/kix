# 2026-09-27 · `web/src/components/landing/Hero.tsx` · The homepage `kix check` demo shows a `kubeconform pass` row that `kix check` no longer prints.

`kix check` reports only `eval` and `scorecard`; schema validation runs in
`nix flake check` through the `schema-cluster-<name>` check. The hero
terminal (around line 135) still claims `kubeconform pass, no schema
errors`, so a visitor who runs the command sees a different table. Left
alone because `web/` had uncommitted homepage work at the time.
