# 2026-09-27 · `flake.nix` · The root flake does not raise the scorecard cap to error.

`clusters/flake.nix` passes `clusterModules = [ { scorecard.maxSeverity =
"error"; } ]` to `mkFlake`, and the root `flake.nix` does not. Both flakes
build the same `clusters/*.nix` files, so a scorecard error such as
`security.nonRoot` passes `nix flake check` at the root and fails the
`clusters/` flake. `housekeeping/reviews/2026-09-20.md` says both flakes
raise the cap.
