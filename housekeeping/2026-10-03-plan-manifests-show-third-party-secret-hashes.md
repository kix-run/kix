# 2026-10-03 · `cli/kix-cli/src/plan/mod.rs` · `kix plan --detail manifests` shows annotations other tools put on live objects, hashes of Secrets among them.

The old side of an answered object is the whole served object. Only
`checksum/*` and Kix's own hash annotations are hidden, so an annotation such
as Reloader's `reloader.stakater.com/last-reloaded-from`, which carries a
SHA-1 of a Secret's data, is printed.
