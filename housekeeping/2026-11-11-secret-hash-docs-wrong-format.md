# 2026-11-11 · `docs/.../secrets-crds-and-rbac.mdx` · The `hash` row describes a different hash than Kix checks.

The `scope.mkSecret` table says `hash` is `"sha256:<64-hex>"`, the SHA-256 of the encrypted `source` file. `compute_content_hash` in `cli/kix/src/cluster/secrets.rs` compares it with `sha256-<base64>` of the decrypted `key=value` lines, sorted by key. A user who follows the docs gets a hash mismatch at deploy.
