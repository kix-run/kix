# 2026-11-18 · `clusters/test-immich.nix` · Its Firezone secrets hold placeholder strings that stop the pod at boot.

The `firezone-secrets` instance sets `SECRET_KEY_BASE` and
`DATABASE_ENCRYPTION_KEY` to placeholder strings, and Firezone decodes both as
base64. Its `firezone-wireguard` instance uses the placeholder
`PLACEHOLDER_GENERATE_WITH_wg_genkey` as the WireGuard key. Firezone 0.7.26
fails at boot with "must be a base64-encoded string", and a test that deploys
`immich` sees a crash loop with no hint of the cause. Not run against
`immich`: the same values failed on `test-firezone`. Use the values in
`clusters/test-firezone.nix` as the model.
