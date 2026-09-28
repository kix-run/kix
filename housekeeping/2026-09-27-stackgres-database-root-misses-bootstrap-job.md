# 2026-09-27 · `kix/packages/stackgres-database` · The package root does not reach its bootstrap Job.

`root` is the `credentials` Secret, and nothing it depends on reaches
`bootstrapJob`, `bootstrapPassword` or `superuserRef`. Consumers reach the
Job through the context `scope.forwardEdges` packs into `out.host`, and in
clusters with network policy on, the Job's generated policy reaches it too.
In `clusters/example-import.nix` neither holds for the instance itself, so
the build warns that the three resources are "not referenced by root or its
dependencies", and `pi-wiring-cluster-example-import` fails `nix flake check`
(invariant 4 in `kix/pi-checks.nix`).

Decision required from Adam: whether the Job joins the package through
`postHooks` (the commented-out line in `root`), through `requires`, or
whether the invariant should accept a resource that only consumers reach.
