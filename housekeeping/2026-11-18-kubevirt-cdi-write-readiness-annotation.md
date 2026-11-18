# 2026-11-18 · `kix/packages/experimental/kubevirt`, `kix/packages/experimental/cdi` · `out.mkVirtualMachine` and `out.mkDataVolume` write the `kix.run/readiness` annotation themselves, so the library never validates their rule.

Both builders put `builtins.toJSON { ... }` into the annotations they pass to `mkCR`, which skips `validateReadiness`. `scope.mkCR` now takes `readiness` for one resource and validates it. Once both builders use it, `mkCR` could refuse a `kix.run/readiness` annotation from its caller, so the annotation has one writer.
