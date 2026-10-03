# 2026-10-03 · `cli/kix/src/cluster/fetch.rs` · A SOPS Secret value changed out of band does not show in `kix diff` or `kix drift`.

A SOPS Secret's build manifest holds no plaintext, so `redact_secret` has nothing to compare the live `data` with, and the applied-content hash covers the `stringData` field set kix owns, not the values the server merged into `data`. A `kubectl edit` of such a Secret reads as unchanged and in sync until the next deploy writes the value back.
