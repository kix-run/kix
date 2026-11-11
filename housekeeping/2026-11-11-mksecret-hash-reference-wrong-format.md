# 2026-11-11 · `docs/src/content/docs/reference/secrets-crds-and-rbac.mdx` · The `mkSecret` reference describes `hash` in a format and over data that Kix does not use.

The reference says `hash` is the SHA-256 of the encrypted `source` file,
written `sha256:<64-hex>`, and required whenever `source` is a path. The
deploy (`cli/kix/src/cluster/secrets.rs`, `compute_content_hash`) hashes the
decrypted key-value pairs and compares `sha256-<base64>`, and a local deploy
skips the check when `hash` is unset. The SOPS how-to page says the latter.
An author who follows the reference writes a hash that can never match.
