# 2026-11-18 · `clusters/test-immich.nix` · Its Firezone secrets hold placeholder strings that stop the pod at boot.

The `firezone-secrets` and `firezone-wireguard` instances set values such as
`PLACEHOLDER_CHANGE_ME_secret_key_base` and `PLACEHOLDER_GENERATE_WITH_wg_genkey`.
Firezone decodes `SECRET_KEY_BASE` and `DATABASE_ENCRYPTION_KEY` as base64,
and it needs a real WireGuard key, so the pod fails at boot with "must be a
base64-encoded string". Anyone who builds or deploys `immich` for a test sees
a crash loop with no hint that the values are the cause. Use the values in
`clusters/test-firezone.nix` as the model, or mark the cluster as unable to
run the Firezone pod.
