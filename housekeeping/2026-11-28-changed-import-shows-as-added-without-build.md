# 2026-11-28 · `cli/kix/src/cluster/owned_view.rs` · With no deployed build on the machine, an import whose content changed shows as an added resource.

Kix writes no object for an import marker, so a plan or `kix diff --live` without the deployed build takes the marker from the new build (`imports_as_built`) only when the deployed package index lists an import with the same object hash. A marker whose content changed has no old side, so the package diff lists it as added to its package rather than changed.
