# 2026-10-02 · `kix/lib/vocab/compose.nix` · `kix.guardArgs` cannot hold package default flags that `extraArgs` may replace.

`guardArgs` knows only flags the package owns, which `extraArgs` may not set.
A package that ships upstream tunables as defaults (`--ps-retries=300`,
`--core-health-freq=20s`) and lets `extraArgs` replace them must drop the
default itself, because the Rust binaries refuse a single-value flag given
twice. `kix/packages/mayastor/common.nix` carries a local `dropOverridden`
for this, with the same `flag` / `flag=` matcher as `guardArgs`. A
`defaults` argument on `guardArgs` would give every package one rule.
