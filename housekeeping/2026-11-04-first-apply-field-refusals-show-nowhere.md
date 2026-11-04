# 2026-11-04 · `cli/kix/src/cluster/apply/ssa.rs` · A field the server refused or changed at apply shows in no diff and in no drift check.

When the CRD schema prunes a field Kix applied, or a mutating webhook overwrites a value, the live object never holds what the build says. `kix diff` compares an object the build does not change as its build manifest, so the field does not show there. The drift stamp is the hash of the apply response, so `kix drift` and the diff's drift section call the object in sync. The user believes a setting is in effect when it is not. Before the comparison went by identity hash, `kix diff` showed these as field changes.

Decision required from Adam: warn at apply time by comparing the server's apply response with the manifest on Kix's fields (`apply/ssa.rs` around the `applied_content_hash` call), or check manifests at compile time against the vendored CRD schema.
