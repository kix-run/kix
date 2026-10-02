# 2026-10-02 · `kix/lib/eval/instance.nix` · `meta.scope = "namespace"` also refuses an explicit `ref.<ns>.<instance>` from another namespace, so a package cannot stop automatic cross-namespace binding and still allow a deliberate one.

`immich-machine-learning` sets the scope so that an Immich server never
binds another tenant's worker by the single-candidate fallback in
`resolve.nix`. The same setting makes `_crossNsCheck` throw for
`deps.machineLearning = ref.gpu.ml`, so one GPU worker shared by several
namespaces is reachable only through a `kix.mkImport`, which gets no
derived network policy egress.
