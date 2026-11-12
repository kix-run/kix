# 2026-11-11 · `kix` CLI · No command prints the content hash that `passwordHash` and `mkSecret`'s `hash` need.

The database packages require `passwordHash`, and every `mkSecret` with a SOPS `source` requires `hash`, but the only way to get the value is to reimplement `compute_content_hash` (`cli/kix/src/cluster/secrets.rs`) by hand. The test clusters' hashes in `clusters/dev-secrets/` were made with a Python one-liner.
