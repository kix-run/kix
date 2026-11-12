# 2026-11-12 · `kix/packages/default.nix` · A misspelled package name, such as `packages.experimental.cert-manger`, fails with a bare "attribute 'cert-manger' missing".

A Nix attribute set cannot answer a name it lacks, so Kix gives no suggestion. `packages.stable.<experimental name>` and the old pre-0.10 names now carry markers with the right spelling, but a typo has nothing to carry.
