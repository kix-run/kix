# 2026-11-11 · `kix/package-eval.nix` · The check that builds every package does not build experimental packages.

`every-package-evaluates` reads only `kix/packages/stable/`. A package under
`kix/packages/experimental/` that no cluster names never runs through the
validators and the scorecard. The check keys its `settings`, `skip`, and
`knownFailures` tables by package name, and an experimental package may share
a stable package's name, so the tables cannot hold both today.
