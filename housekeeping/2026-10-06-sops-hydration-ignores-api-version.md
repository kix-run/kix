# 2026-10-06 · `cli/kix/src/cluster/secrets.rs` · SOPS hydration decrypts into any object of kind Secret, whatever its apiVersion.

`needs_hydration` checks `kind == "Secret"` only. A custom resource of kind `Secret` with a `kix.run/sops-source` annotation gets the decrypted values in its `stringData`, which its API group need not treat as secret. The plan now hides values only for `types::is_secret` (`v1`, `Secret`), so the two rules differ.
